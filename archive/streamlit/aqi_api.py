"""Measured climate & air-quality data for destinations — no more hallucination.

Replaces AI-invented monthly AQI/climate numbers with real data:

Provider A — Open-Meteo (no API key required)
  * Air Quality API: hourly ``us_aqi`` (CAMS reanalysis, global archive since
    Aug 2022) -> monthly mean-of-hourly US AQI  (workbook primary series)
  * Historical Weather API (ERA5/ERA5-Land, 1940->): daily max/min temperature
    and precipitation -> 2016-2025 climate normals for High/Low (C),
    Rain (mm) and Rainy Days (>= 1 mm, WMO rain day).

Provider B — OpenAQ v3 (free API key, ground monitoring stations)
  * Real PM2.5 measurements from the nearest stations (<= 5 within 10 km).
  * Hourly station PM2.5 -> US AQI via EPA 2024 breakpoints -> monthly
    mean-of-hourly, median across sensors, 50 % coverage gate.
  * The detail-page chart is always-on with up to four series: dotted =
    trailing 12 months, solid = multi-year typical (mean of the yearly
    monthly means, >= 3 year-samples); amber/brown = CAMS model, teal =
    ground stations.

Every fetched ground (sensor, month) is cached on disk the moment it
arrives, so ground fetches are resumable after an interruption (laptop
shutdown, quota wall) — just rerun the same command.

Methodology notes
  * AQI month value = mean of HOURLY US AQI over all valid hours of the
    calendar month (both providers computed identically -> comparable).
  * Calendar-month averages only count if >= 80 % (model) / >= 50 % (ground)
    of expected hours exist; otherwise the month is left empty.
  * The incomplete current month is always excluded.
  * Ground months without station data are simply empty (no guessing).

Usage:
    python aqi_api.py "Chennai" "Bangalore" --dry-run
    python aqi_api.py --all --aqi-only
    python aqi_api.py --all --dry-run --report
    python aqi_api.py "Chennai" --ground-full        # resumable ground typical
    python aqi_api.py --all --backfill-typical       # model typical, 1 req/city

Requires: requests, openpyxl (already in requirements.txt).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path

import openpyxl
import requests

# The one canonical definition of a "rainy day" (WMO: >= 1 mm/day).
import rainy_days  # noqa: E402  (kept after data_utils to preserve import order)
from data_utils import (
    DATA_PATH,
    WorkbookLockedError,
    _clear_destination_cache,
    _find_destination_sheet,
    journal_cell_changes,
    load_workbook_for_update,
    save_workbook_atomic,
)

# ── Constants ────────────────────────────────────────────────────────────────

AQ_API_URL = "https://air-quality-api.open-meteo.com/v1/air-quality"
ARCHIVE_API_URL = "https://archive-api.open-meteo.com/v1/archive"
OPENAQ_API_URL = "https://api.openaq.org/v3"

MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# AQI archive window: first full calendar year of CAMS global data -> last
# complete month. Fixed window (not trailing 12 months) so several seasonal
# cycles are averaged and Diwali-date shifts even out.
AQI_START_YEAR = 2023

# Climate-normal window for ERA5 weather (temps/rain are stable; 10 full
# years is the classic climate-normal length).
CLIMATE_START_YEAR = 2016
CLIMATE_END_YEAR = 2025

MODEL_COVERAGE = 0.80   # min fraction of valid hours for a model month
GROUND_COVERAGE = 0.50  # ground stations have real gaps; be more lenient
GROUND_RADIUS_M = 10_000
GROUND_MAX_SENSORS = 5
OPENAQ_PAGE_LIMIT = 1000
OPENAQ_MAX_PAGES = 100  # API-side cap; also our politeness cap

# Divergence rule (user requirement "similar -> one, divergent -> both"):
# a month counts as DIVERGENT only when BOTH thresholds are exceeded, so
# small absolute noise at low AQI never splits the series.
DIVERGENCE_ABS = 15.0
DIVERGENCE_REL = 0.30

# Multi-year "typical" series (climate-normal convention): a calendar month
# needs at least this many valid year-samples, else it stays empty.
MIN_TYPICAL_YEARS = 3

CACHE_DIR = Path(__file__).parent / "aqi_cache"

# EPA 2024 PM2.5 -> US AQI breakpoints (24h, ug/m3, truncated to 1 decimal).
PM25_BREAKPOINTS = [
    (0.0, 9.0, 0, 50),
    (9.1, 35.4, 51, 100),
    (35.5, 55.4, 101, 150),
    (55.5, 125.4, 151, 200),
    (125.5, 225.4, 201, 300),
    (225.5, 325.4, 301, 500),
]

SESSION = requests.Session()
SESSION.headers["Accept"] = "application/json"

# Windows consoles often use cp1252/cp437 — printing a Turkish/Arabic/Greek
# station name would raise UnicodeEncodeError and kill the whole ground
# fetch. Replace unencodable characters instead of crashing.
try:
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass


# ── Small helpers ────────────────────────────────────────────────────────────

def _slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(name).strip().lower()).strip("-")


def _last_complete_month(today: date | None = None) -> tuple[int, int]:
    """Return (year, month) of the last COMPLETE calendar month."""
    today = today or date.today()
    y, m = today.year, today.month
    return (y - 1, 12) if m == 1 else (y, m - 1)


def _month_add(y: int, m: int, delta: int) -> tuple[int, int]:
    m2 = m + delta
    return (y + (m2 - 1) // 12, (m2 - 1) % 12 + 1)


def _month_days(y: int, m: int) -> int:
    if m == 12:
        nxt = date(y + 1, 1, 1)
    else:
        nxt = date(y, m + 1, 1)
    return (nxt - date(y, m, 1)).days


def _http_get(url: str, params: dict | None = None, headers: dict | None = None,
              timeout: int = 90):
    """GET with one polite retry on transient errors."""
    last_exc = None
    for attempt in range(2):
        try:
            resp = SESSION.get(url, params=params, headers=headers, timeout=timeout)
            if resp.status_code in (408, 429, 500, 502, 503, 504) and attempt == 0:
                wait = int(resp.headers.get("Retry-After", "5") or "5")
                time.sleep(wait)
                continue
            if resp.status_code != 200:
                raise RuntimeError(f"HTTP {resp.status_code} from {url}: {resp.text[:300]}")
            return resp.json()
        except (requests.exceptions.ConnectionError,
                requests.exceptions.Timeout) as exc:
            last_exc = exc
            time.sleep(3)
    raise RuntimeError(f"Could not reach {url}: {last_exc}")


def _days_in_span(y1: int, m1: int, y2: int, m2: int) -> int:
    """Days from first day of (y1,m1) to day before first day of (y2,m2)."""
    start = date(y1, m1, 1)
    end_y, end_m = _month_add(y2, m2, 1)
    end = date(end_y, end_m, 1)
    return (end - start).days


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_found(found) -> tuple[int, bool]:
    """Parse OpenAQ v3 ``meta.found``.

    The API answers with a capped marker string (e.g. ``'>1000'``) whenever
    more records exist than reported. Returns ``(count, is_capped)`` — for
    capped answers the true total is unknown and pagination must continue
    until a short page arrives.
    """
    if found is None:
        return 0, False
    s = str(found).strip()
    capped = s.startswith(">") or s.startswith(">=")
    try:
        return int(s.lstrip(">=< ")), capped
    except ValueError:
        return 0, capped


# ── EPA PM2.5 -> US AQI ──────────────────────────────────────────────────────

def pm25_to_us_aqi(pm25_ugm3: float) -> float:
    """Convert a PM2.5 concentration (ug/m3) to US AQI (EPA 2024 rule).

    EPA truncates the concentration to one decimal before lookup; the index
    is interpolated linearly within the breakpoint category.
    """
    c = math.floor(pm25_ugm3 * 10) / 10.0
    if c < 0:
        return 0.0
    for lo_c, hi_c, lo_i, hi_i in PM25_BREAKPOINTS:
        if c <= hi_c:
            return round((hi_i - lo_i) / (hi_c - lo_c) * (c - lo_c) + lo_i)
    return 500.0  # above the highest breakpoint


# ── Monthly aggregation core ────────────────────────────────────────────────

def _monthly_mean_of_hourly(hourly_times: list[str], hourly_values: list,
                            y_from: int, m_from: int, y_to: int, m_to: int,
                            coverage: float) -> dict[str, float | None]:
    """Mean of hourly values per calendar month in [y_from m_from .. y_to m_to].

    ``hourly_times`` are ISO strings (already local thanks to timezone=auto).
    Months below the coverage gate get ``None``.
    """
    buckets: dict[tuple[int, int], list[float]] = {}
    for t, v in zip(hourly_times, hourly_values):
        if v is None:
            continue
        try:
            dt = datetime.fromisoformat(t)
        except ValueError:
            continue
        key = (dt.year, dt.month)
        if (y_from, m_from) <= key <= (y_to, m_to):
            buckets.setdefault(key, []).append(float(v))

    out: dict[str, float | None] = {}
    y, m = y_from, m_from
    while (y, m) <= (y_to, m_to):
        vals = buckets.get((y, m))
        expected = _month_days(y, m) * 24
        if vals and len(vals) / expected >= coverage:
            out[MONTHS_SHORT[m - 1]] = round(sum(vals) / len(vals))
        else:
            out[MONTHS_SHORT[m - 1]] = None
        y, m = _month_add(y, m, 1)
    return out


def _multiyear_typical(hourly_times: list[str], hourly_values: list,
                       y_from: int, m_from: int, y_to: int, m_to: int,
                       coverage: float, min_years: int) -> dict[str, float | None]:
    """Multi-year "typical" per calendar month (climate-normal convention).

    For each COMPLETE (year, month) passing the coverage gate the monthly
    mean-of-hourly is computed; the typical value is then the MEAN OF THE
    YEARLY MONTHLY MEANS (equal weight per year — NOT a pooled hourly mean,
    so no single long year dominates). Months with fewer than ``min_years``
    valid year-samples stay empty.
    """
    buckets: dict[tuple[int, int], list[float]] = {}
    for t, v in zip(hourly_times, hourly_values):
        if v is None:
            continue
        try:
            dt = datetime.fromisoformat(t)
        except ValueError:
            continue
        key = (dt.year, dt.month)
        if (y_from, m_from) <= key <= (y_to, m_to):
            buckets.setdefault(key, []).append(float(v))

    yearly: dict[int, list[float]] = {i: [] for i in range(12)}
    for (y, m), vals in buckets.items():
        expected = _month_days(y, m) * 24
        if len(vals) / expected >= coverage:
            yearly[m - 1].append(sum(vals) / len(vals))

    out: dict[str, float | None] = {}
    for i, mname in enumerate(MONTHS_SHORT):
        samples = yearly[i]
        out[mname] = (round(sum(samples) / len(samples))
                      if len(samples) >= min_years else None)
    return out


# ── Provider A: Open-Meteo ───────────────────────────────────────────────────

def fetch_openmeteo_aqi(lat: float, lon: float,
                        y_from: int | None = None) -> dict[str, dict]:
    """US AQI series from the Open-Meteo air-quality archive (ONE request).

    Returns {"monthly": {Jan..Dec}, "typical": {Jan..Dec}}:
      * "monthly" — trailing 12M: for each calendar month the value of the
        latest complete (year, month) in the window (the workbook's
        ``{Mon} AQI`` series, identical to the pre-typical behaviour);
      * "typical" — multi-year climate-normal style mean of the yearly
        monthly means (>= MIN_TYPICAL_YEARS year-samples).
    Both share the same MODEL_COVERAGE hour gate, so they stay comparable.
    """
    yf = y_from or AQI_START_YEAR
    ly, lm = _last_complete_month()
    params = {
        "latitude": lat,
        "longitude": lon,
        "hourly": "us_aqi",
        "start_date": f"{yf}-01-01",
        "end_date": f"{ly}-{lm:02d}-{_month_days(ly, lm):02d}",
        "timezone": "auto",
    }
    data = _http_get(AQ_API_URL, params)
    hourly = data.get("hourly") or {}
    times, values = hourly.get("time") or [], hourly.get("us_aqi") or []
    if not times:
        raise RuntimeError("Open-Meteo air-quality returned no data")
    monthly = _monthly_mean_of_hourly(times, values, yf, 1, ly, lm,
                                      MODEL_COVERAGE)
    typical = _multiyear_typical(times, values, yf, 1, ly, lm,
                                 MODEL_COVERAGE, MIN_TYPICAL_YEARS)
    return {"monthly": monthly, "typical": typical}


def fetch_openmeteo_climate(lat: float, lon: float) -> dict[str, list]:
    """2016-2025 climate normals from the Open-Meteo historical (ERA5) archive.

    Returns {"High (C)": [12], "Low (C)": [12], "Rain (mm)": [12],
             "Rainy Days": [12]} — each month averaged across the 10 years.
    """
    params = {
        "latitude": lat,
        "longitude": lon,
        "start_date": f"{CLIMATE_START_YEAR}-01-01",
        "end_date": f"{CLIMATE_END_YEAR}-12-31",
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_sum",
        "timezone": "auto",
    }
    data = _http_get(ARCHIVE_API_URL, params)
    daily = data.get("daily") or {}
    times = daily.get("time") or []
    tmax, tmin, precip = (daily.get(k) or [] for k in
                          ("temperature_2m_max", "temperature_2m_min", "precipitation_sum"))
    if not times:
        raise RuntimeError("Open-Meteo archive returned no data")

    # Per calendar-month accumulators across all years.
    highs: dict[int, list[float]] = {i: [] for i in range(12)}
    lows: dict[int, list[float]] = {i: [] for i in range(12)}
    # Rain needs per-(year, month) totals: precipitation_sum is a DAILY total,
    # so it is summed within each month-year first, then averaged across the
    # 10 years (workbook convention: monthly mm totals + rainy days/month).
    rain_totals: dict[tuple[int, int], list[float]] = {}  # (y, m) -> [mm, rainy]

    for i, t in enumerate(times):
        dt = date.fromisoformat(t)
        idx = dt.month - 1
        if tmax[i] is not None:
            highs[idx].append(float(tmax[i]))
        if tmin[i] is not None:
            lows[idx].append(float(tmin[i]))
        if precip[i] is not None:
            acc = rain_totals.setdefault((dt.year, dt.month), [0.0, 0.0])
            acc[0] += float(precip[i])
            # One shared definition of "rainy day" for the whole project.
            acc[1] += 1.0 if rainy_days.is_rain_day(precip[i]) else 0.0

    def _monthly_avg(bucket: dict[int, list[float]], years: int) -> list:
        # Each calendar month should appear once per year (10 samples).
        return [round(sum(v) / len(v), 1) if len(v) >= years * 0.8 else None
                for v in (bucket[i] for i in range(12))]

    def _monthly_rain(years: int, item: int) -> list:
        out = []
        for m in range(1, 13):
            vals = [v[item] for (_, mm), v in rain_totals.items() if mm == m]
            out.append(round(sum(vals) / len(vals), 1)
                       if len(vals) >= years * 0.8 else None)
        return out

    years_n = CLIMATE_END_YEAR - CLIMATE_START_YEAR + 1
    return {
        "High (C)": _monthly_avg(highs, years_n),
        "Low (C)": _monthly_avg(lows, years_n),
        "Rain (mm)": _monthly_rain(years_n, 0),
        "Rainy Days": _monthly_rain(years_n, 1),
    }


# ── Provider B: OpenAQ ground stations ──────────────────────────────────────

# Per-(sensor, month) disk cache: every fetched calendar month of a
# sensor's hourly PM2.5 bucket is written to disk IMMEDIATELY (atomically),
# so a fetch killed mid-run (laptop shutdown, quota wall) resumes exactly
# where it stopped instead of re-spending requests.
GROUND_MONTH_DIR = CACHE_DIR / "ground_months"


def _ground_month_path(sensor_id: int, y: int, m: int) -> Path:
    GROUND_MONTH_DIR.mkdir(parents=True, exist_ok=True)
    return GROUND_MONTH_DIR / f"{sensor_id}_{y}{m:02d}.json"


def _load_ground_month(sensor_id: int, y: int,
                       m: int) -> dict[datetime, list[float]] | None:
    """Cached hourly bucket, or None when not cached / unreadable."""
    p = _ground_month_path(sensor_id, y, m)
    if not p.exists():
        return None
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None
    out: dict[datetime, list[float]] = {}
    for iso, vals in (raw.get("hours") or {}).items():
        try:
            dt = datetime.fromisoformat(iso)
        except ValueError:
            continue
        out[dt] = [float(v) for v in vals]
    return out


def _save_ground_month(sensor_id: int, y: int, m: int,
                       bucket: dict[datetime, list[float]]) -> None:
    p = _ground_month_path(sensor_id, y, m)
    payload = {"hours": {k.isoformat(): v for k, v in bucket.items()}}
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    tmp.replace(p)  # atomic: no half-written cache files, ever


def _openaq_key() -> str | None:
    """API key from openaq_secrets.py / env / st.secrets (mirrors deepseek)."""
    key = ""
    try:
        import openaq_secrets  # gitignored local module
    except Exception:
        openaq_secrets = None
    if openaq_secrets is not None:
        key = getattr(openaq_secrets, "OPENAQ_API_KEY", "") or ""
    if not key:
        import os
        key = os.environ.get("OPENAQ_API_KEY", "") or ""
    if not key:
        try:
            import streamlit as st
            key = st.secrets.get("OPENAQ_API_KEY", "") or ""
        except Exception:
            key = ""
    return (key or "").strip() or None


def fetch_openaq_ground(lat: float, lon: float,
                        months: int = 12,
                        typical: bool = False,
                        max_sensors: int = GROUND_MAX_SENSORS) -> dict[str, dict]:
    """Monthly mean-of-hourly US AQI from the nearest OpenAQ PM2.5 stations.

    Returns {"monthly": {Jan..Dec: aqi|None}, "typical": {Jan..Dec}}.
    ``None`` for a month means "no comparable ground data" (no stations,
    too sparse, or below the coverage gate) — never a guessed number.
    Raises RuntimeError when the key is missing or the API is unreachable.

    ``monthly`` is strictly the trailing 12 complete months (same window as
    the CAMS model series, so both stay comparable month-for-month). With
    ``typical=True`` the fetch window extends back to AQI_START_YEAR and
    ``typical`` additionally holds the multi-year value per calendar month:
    the mean of the yearly per-station-median monthly values (>=
    MIN_TYPICAL_YEARS year-samples), tolerating station churn.
    """
    key = _openaq_key()
    if not key:
        raise RuntimeError("OpenAQ API key missing (openaq_secrets.py / OPENAQ_API_KEY)")
    headers = {"X-API-Key": key}

    # 1) Nearest locations with PM2.5 sensors. One station can expose SEVERAL
    #    pm25 sensor ids (an old, dead instrument alongside the current one)
    #    and the API returns them in no guaranteed order, so collect ALL ids
    #    per station and try newest-first until one reports data.
    locs = _http_get(
        f"{OPENAQ_API_URL}/locations",
        {"coordinates": f"{lat},{lon}", "radius": GROUND_RADIUS_M, "limit": 100},
        headers,
    )
    candidates: list[tuple[float, list[int], str]] = []
    seen_names: set[str] = set()
    for loc in locs.get("results") or []:
        c = loc.get("coordinates") or {}
        plat, plon = c.get("latitude"), c.get("longitude")
        if plat is None or plon is None:
            continue
        dist_km = math.hypot((plat - lat) * 111.32,
                             (plon - lon) * 111.32 * math.cos(math.radians(lat)))
        pm25_ids = sorted(
            (s["id"] for s in loc.get("sensors") or []
             if (s.get("parameter") or {}).get("name", "").lower() == "pm25"),
            reverse=True,  # newest ids first — legacy ids are usually dead
        )
        name = str(loc.get("name", "?")).strip()
        if pm25_ids and name.lower() not in seen_names:
            seen_names.add(name.lower())
            candidates.append((dist_km, pm25_ids, name))
    candidates.sort(key=lambda x: x[0])
    if not candidates:
        raise RuntimeError(f"No PM2.5 ground stations within {GROUND_RADIUS_M // 1000} km")

    # 2) Window as a list of (year, month): the trailing N complete months —
    #    or the full archive window when the multi-year typical is wanted.
    ly, lm = _last_complete_month()
    if typical:
        sy, sm = AQI_START_YEAR, 1
    else:
        sy, sm = _month_add(ly, lm, -(months - 1))
    months_window: list[tuple[int, int]] = []
    wy, wm = sy, sm
    while (wy, wm) <= (ly, lm):
        months_window.append((wy, wm))
        wy, wm = _month_add(wy, wm, 1)

    # 3) Fetch measurements one CALENDAR MONTH at a time: a full 12-month
    #    window on 15-minute reporting stations makes the OpenAQ backend time
    #    out (HTTP 408, "smaller time frame"), while a single month (~2900
    #    records = 3 pages) is safe. Probe with the newest month first so a
    #    dead sensor costs one request instead of twelve. Every fetched
    #    month lands in the per-(sensor, month) disk cache immediately, so
    #    an interrupted run resumes without re-spending requests.
    def _fetch_month(sensor_id: int, yy: int, mm: int) -> dict[datetime, list[float]]:
        dt_from = datetime(yy, mm, 1, tzinfo=timezone.utc)
        ey, em = _month_add(yy, mm, 1)
        dt_to = datetime(ey, em, 1, tzinfo=timezone.utc)
        out: dict[datetime, list[float]] = {}
        page = 1
        while page <= OPENAQ_MAX_PAGES:
            for _attempt in range(2):
                try:
                    data = _http_get(
                        f"{OPENAQ_API_URL}/sensors/{sensor_id}/measurements",
                        {
                            "datetime_from": _iso(dt_from),
                            "datetime_to": _iso(dt_to),
                            "limit": OPENAQ_PAGE_LIMIT,
                            "page": page,
                        },
                        headers,
                    )
                    break
                except RuntimeError as exc:
                    # OpenAQ rate limit: one patient retry after 60 s.
                    if _attempt == 0 and "429" in str(exc):
                        print(f"      sensor {sensor_id} {yy}-{mm:02d}: "
                              f"rate limited, waiting 60 s …", flush=True)
                        time.sleep(60)
                        continue
                    raise
            total, capped = _parse_found((data.get("meta") or {}).get("found"))
            results = data.get("results") or []
            for row in results:
                val = row.get("value")
                period = row.get("period") or {}
                df_from = ((period.get("datetimeFrom") or {}).get("utc")) or ""
                if val is None:
                    continue
                try:
                    dt = datetime.fromisoformat(df_from.replace("Z", "+00:00"))
                except ValueError:
                    continue
                # Truncate to the hour so 15-minute CPCB readings roll up
                # into hourly PM2.5 means (EPA-style hourly AQI input).
                out.setdefault(dt.replace(minute=0, second=0, microsecond=0),
                               []).append(float(val))
            done = len(results) < OPENAQ_PAGE_LIMIT
            done = done or (not capped and total and page * OPENAQ_PAGE_LIMIT >= total)
            if done:
                break
            page += 1
            time.sleep(1.0)  # ~1 page/s keeps us inside the 60 req/min limit
        return out

    month_cache_hits = 0

    def _get_month_bucket(sensor_id: int, yy: int,
                          mm: int) -> dict[datetime, list[float]]:
        """Hourly bucket for one (sensor, month) — disk cache first."""
        nonlocal month_cache_hits
        cached = _load_ground_month(sensor_id, yy, mm)
        if cached is not None:
            month_cache_hits += 1
            return cached
        bucket = _fetch_month(sensor_id, yy, mm)
        _save_ground_month(sensor_id, yy, mm, bucket)
        return bucket

    per_sensor_monthly: dict[int, dict[datetime, list[float]]] = {}
    used = 0
    for dist_km, sensor_ids, name in candidates:
        if used >= max_sensors:
            break

        # Active id: newest-first probe of the latest complete month; a
        # sensor id with < 24 h there is effectively dead for our purposes.
        active_id = None
        for sensor_id in sensor_ids:
            try:
                probe = _get_month_bucket(sensor_id, *months_window[-1])
            except RuntimeError as exc:
                print(f"      sensor {sensor_id} ({name[:30]}): {exc} (trying next id)",
                      flush=True)
                continue
            if not probe or len(probe) < 24:
                continue  # dead legacy id — fall through to the next one
            active_id = sensor_id
            break
        if active_id is None:
            print(f"      {name[:34]}: no recent data (tried {len(sensor_ids)} ids), skipped",
                  flush=True)
            continue

        # Legacy fallback: an older id of the SAME station that still
        # reports in the FIRST window month — stations sometimes swap
        # sensor ids mid-window. Only consulted per month when the active
        # id has nothing (see _bucket_for_month).
        chain = [active_id]
        if typical:
            for sensor_id in sensor_ids:
                if sensor_id == active_id:
                    continue
                try:
                    old = _get_month_bucket(sensor_id, *months_window[0])
                except RuntimeError:
                    continue
                if old and len(old) >= 24:
                    chain.append(sensor_id)
                    break

        def _bucket_for_month(yy: int, mm: int,
                             _chain: list = chain) -> dict[datetime, list[float]]:
            """First chain id with a real month of data; else the fullest
            partial bucket (the coverage gate decides its fate later)."""
            best: dict[datetime, list[float]] | None = None
            for sid in _chain:
                b = _get_month_bucket(sid, yy, mm)
                if len(b) >= 24:
                    return b
                if b and (best is None or len(b) > len(best)):
                    best = b
            return best or {}

        bucket: dict[datetime, list[float]] = {}
        for (yy, mm) in months_window:
            try:
                bucket.update(_bucket_for_month(yy, mm))
            except RuntimeError as exc:
                print(f"      sensor {active_id} {yy}-{mm:02d}: {exc} (month skipped)",
                      flush=True)
            time.sleep(0.2)
        per_sensor_monthly[active_id] = bucket
        used += 1
        print(f"      sensor {active_id} ({name[:30]}): "
              f"{sum(len(v) for v in bucket.values())} records, "
              f"{len(bucket)} hours"
              + (f" (legacy fallback {chain[1]})" if len(chain) > 1 else ""),
              flush=True)
        time.sleep(0.3)  # be polite between sensors

    if not per_sensor_monthly:
        raise RuntimeError("No ground sensor data could be retrieved")

    # 4) Per (sensor, year, month): mean-of-hourly-AQI (coverage gated in
    #    HOURS — buckets hold hourly PM2.5 means, so 15-min and hourly
    #    stations aggregate identically). Per (year, month) the per-sensor
    #    values collapse to a MEDIAN across stations. The 12M series reads
    #    the trailing 12 months; the typical series averages the yearly
    #    medians per calendar month (>= MIN_TYPICAL_YEARS year-samples),
    #    tolerating station churn between years.
    per_ym: dict[tuple[int, int], list[float]] = {}
    window_set = set(months_window)
    for bucket in per_sensor_monthly.values():
        hours: dict[tuple[int, int], list[list[float]]] = {}
        for k, vs in bucket.items():
            key = (k.year, k.month)
            if key in window_set:
                hours.setdefault(key, []).append(vs)
        for (y, m), hour_lists in hours.items():
            expected = _month_days(y, m) * 24
            if len(hour_lists) / expected < GROUND_COVERAGE:
                continue
            aqis = [pm25_to_us_aqi(statistics.mean(vs)) for vs in hour_lists]
            per_ym.setdefault((y, m), []).append(sum(aqis) / len(aqis))

    def _month_median(y: int, m: int) -> float | None:
        vals = per_ym.get((y, m))
        return round(statistics.median(vals)) if vals else None

    monthly: dict[str, float | None] = {}
    for (y, m) in months_window[-12:]:
        monthly[MONTHS_SHORT[m - 1]] = _month_median(y, m)

    typical_out: dict[str, float | None] = {}
    if typical:
        for mi, mname in enumerate(MONTHS_SHORT, 1):
            year_vals = []
            for (y, m) in months_window:
                if m == mi:
                    v = _month_median(y, mi)
                    if v is not None:
                        year_vals.append(v)
            typical_out[mname] = (round(sum(year_vals) / len(year_vals))
                                  if len(year_vals) >= MIN_TYPICAL_YEARS else None)
    if month_cache_hits:
        print(f"      month cache: {month_cache_hits} sensor-months reused from disk",
              flush=True)
    return {"monthly": monthly, "typical": typical_out}


# ── Comparison (the user's display rule) ────────────────────────────────────

def divergent_months(model: dict, ground: dict | None) -> list[str]:
    """Months where model and ground series disagree beyond the thresholds.

    Divergent iff abs diff > 15 AND rel diff > 30 % — both must be exceeded
    so tiny absolute noise at low AQI never splits the display.
    """
    if not ground:
        return []
    div = []
    for m in MONTHS_SHORT:
        a, b = model.get(m), ground.get(m)
        if a is None or b is None:
            continue
        abs_diff = abs(a - b)
        rel = abs_diff / max(abs(a), abs(b), 1)
        if abs_diff > DIVERGENCE_ABS and rel > DIVERGENCE_REL:
            div.append(m)
    return div


# ── Cache ────────────────────────────────────────────────────────────────────

def _cache_path(slug: str) -> Path:
    CACHE_DIR.mkdir(exist_ok=True)
    return CACHE_DIR / f"{slug}.json"


def load_cached(slug: str) -> dict | None:
    p = _cache_path(slug)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def save_cached(slug: str, payload: dict) -> None:
    _cache_path(slug).write_text(
        json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8"
    )


def fetch_all_providers(lat: float, lon: float, slug: str,
                        want_ground: bool = True, max_age_days: int = 30) -> dict:
    """Fetch/caches model AQI + climate (+ ground AQI) for one location.

    Fresh cached entries are reused as-is — but only when they were fetched for
    **these** coordinates. The cache key is the slug alone, so a corrected
    coordinate in ``city_coordinates.json`` used to keep serving the payload of
    the old location for up to 30 days.

    If a fresh entry has NO ground data because the ground provider failed
    earlier (e.g. a transient OpenAQ 429), the cached model/climate is kept and
    ONLY the ground provider is retried — so Open-Meteo quota is never burned
    twice.
    """
    cached = load_cached(slug)
    if cached:
        same_place = (
            cached.get("lat") is not None
            and abs(float(cached["lat"]) - float(lat)) < 1e-6
            and abs(float(cached["lon"]) - float(lon)) < 1e-6
        )
        fetched = cached.get("fetched", "")
        try:
            age = (datetime.now(timezone.utc)
                   - datetime.fromisoformat(fetched)).days
        except (ValueError, TypeError):
            age = None
        if same_place and age is not None and age <= max_age_days:
            have_ground = cached.get("ground_aqi") is not None
            if not want_ground or have_ground:
                return cached
            print("   (cached model/climate; retrying ground provider …)",
                  flush=True)
            try:
                cached["ground_aqi"] = fetch_openaq_ground(lat, lon)["monthly"]
                cached["ground_error"] = None
            except Exception as exc:
                # Keep the failure marker but do NOT reset `fetched`: the model
                # series must still age out and be refreshed.
                cached["ground_aqi"] = None
                cached["ground_error"] = str(exc)
                cached["ground_retried"] = datetime.now(timezone.utc).isoformat()
            save_cached(slug, cached)
            return cached
        if not same_place:
            print(f"   (cache for {slug} was fetched for "
                  f"{cached.get('lat')},{cached.get('lon')} — refetching)",
                  flush=True)

    model = fetch_openmeteo_aqi(lat, lon)
    result = {
        "fetched": datetime.now(timezone.utc).isoformat(),
        "lat": lat,
        "lon": lon,
        "model_aqi": model["monthly"],
        "model_aqi_typical": model["typical"],
        "climate": fetch_openmeteo_climate(lat, lon),
    }
    if want_ground:
        try:
            result["ground_aqi"] = fetch_openaq_ground(lat, lon)["monthly"]
            result["ground_error"] = None
        except Exception as exc:
            result["ground_aqi"] = None
            result["ground_error"] = str(exc)
    save_cached(slug, result)
    return result


def refresh_ground_full(lat: float, lon: float, slug: str) -> dict:
    """(Re)fetch the ground series over the FULL archive window and add the
    multi-year typical series — shutdown-safe.

    Every (sensor, month) is cached on disk the moment it is fetched, and
    the city cache is saved BEFORE the workbook is written. An interrupted
    run (laptop shutdown!) simply continues via::

        python aqi_api.py <City> --ground-full

    The model typical rides along when the Open-Meteo daily quota still
    allows one air-quality request; a quota failure only skips it (rerun
    with --backfill-typical tomorrow) and never aborts the ground work.
    """
    cached = load_cached(slug)
    if not cached or not cached.get("model_aqi"):
        raise RuntimeError(f"no cached model data for '{slug}' — run a normal fetch first")

    if not cached.get("model_aqi_typical"):
        try:
            model = fetch_openmeteo_aqi(lat, lon)
            cached["model_aqi"] = model["monthly"]
            cached["model_aqi_typical"] = model["typical"]
            save_cached(slug, cached)
            print("   model typical: fetched (12M refreshed from same request)",
                  flush=True)
        except RuntimeError as exc:
            print(f"   model typical: SKIPPED ({exc})", flush=True)
            print("   (Open-Meteo daily quota likely spent — rerun with "
                  "--backfill-typical tomorrow; ground work continues)",
                  flush=True)

    print(f"   ground full-window fetch {AQI_START_YEAR}-01 -> last complete "
          f"month (per-month disk cache in {GROUND_MONTH_DIR.name}/ — "
          f"safe to interrupt, rerun to resume) …", flush=True)
    ground = fetch_openaq_ground(lat, lon, typical=True)
    cached["ground_aqi"] = ground["monthly"]
    cached["ground_aqi_typical"] = ground["typical"]
    cached["fetched"] = datetime.now(timezone.utc).isoformat()
    save_cached(slug, cached)  # durable BEFORE the workbook write
    return cached


# ── Workbook writing ─────────────────────────────────────────────────────────

def _find_row(ws, dest_col: int, name: str) -> int | None:
    for r in range(2, ws.max_row + 1):
        v = ws.cell(r, dest_col).value
        if v is not None and str(v).strip().lower() == name.strip().lower():
            return r
    return None


def update_destination_climate(name: str, model_aqi: dict, climate: dict,
                               ground_aqi: dict | None,
                               model_typical: dict | None = None,
                               ground_typical: dict | None = None,
                               path=DATA_PATH) -> str:
    """Write the measured series into the destination's row.

    Model AQI -> {Mon} AQI, climate -> {Mon} High/Low/Rain/Rainy Days,
    ground AQI -> '{Mon} AQI (Ground)' columns (all months with data),
    multi-year typicals -> '{Mon} AQI (Typical)' / '{Mon} AQI (Ground
    Typical)' when provided, 'Avg AQI' recomputed, 'AQI Source'
    provenance text. Returns the message.
    """
    dest_clean = str(name).strip()
    sheet_name = _find_destination_sheet(path)
    if sheet_name is None:
        return f"{dest_clean}: could not find destination sheet."
    try:
        wb = load_workbook_for_update(path)
    except PermissionError as exc:
        raise WorkbookLockedError(
            "Destinations workbook is open in another program — close it and retry."
        ) from exc
    ws = wb[sheet_name]

    headers = {}
    for col in range(1, ws.max_column + 1):
        v = ws.cell(1, col).value
        if v is not None:
            headers[str(v).strip()] = col

    dest_col = headers.get("Destination")
    if dest_col is None:
        wb.close()
        return f"{dest_clean}: no 'Destination' column."
    row = _find_row(ws, dest_col, dest_clean)
    if row is None:
        wb.close()
        return f"{dest_clean}: not found in workbook."

    def _ensure_header(nm: str) -> int:
        if nm not in headers:
            col = ws.max_column + 1
            ws.cell(1, col, value=nm)
            headers[nm] = col
        return headers[nm]

    # Every cell written here is collected so it can be journaled for sync
    # (F13): this is the bulk producer the phone never used to see.
    written: dict[str, object] = {}

    def _put(col_name: str, value) -> None:
        ws.cell(row, _ensure_header(col_name), value=value)
        written[col_name] = value

    # Model AQI + climate.
    for m in MONTHS_SHORT:
        if model_aqi.get(m) is not None:
            _put(f"{m} AQI", model_aqi[m])
        for suffix, key in (("High (C)", "High (C)"), ("Low (C)", "Low (C)"),
                            ("Rain (mm)", "Rain (mm)"), ("Rainy Days", "Rainy Days")):
            v = climate.get(key, [None] * 12)[MONTHS_SHORT.index(m)]
            if v is not None:
                _put(f"{m} {suffix}", v)

    # Ground AQI (own columns, only months that actually have data).
    ground_written = 0
    if ground_aqi:
        for m in MONTHS_SHORT:
            v = ground_aqi.get(m)
            if v is not None:
                _put(f"{m} AQI (Ground)", v)
                ground_written += 1

    # Multi-year typical series (hard-coded workbook columns — user decision).
    typ_written = 0
    if model_typical:
        for m in MONTHS_SHORT:
            v = model_typical.get(m)
            if v is not None:
                _put(f"{m} AQI (Typical)", v)
                typ_written += 1
    gtyp_written = 0
    if ground_typical:
        for m in MONTHS_SHORT:
            v = ground_typical.get(m)
            if v is not None:
                _put(f"{m} AQI (Ground Typical)", v)
                gtyp_written += 1

    # Nothing to write: do NOT touch the workbook. A failed fetch used to
    # overwrite the existing "AQI Source" provenance with a claim that data
    # had been written, and the runner then reported success.
    if not written:
        wb.close()
        return (f"{dest_clean}: nothing to write (no model AQI and no climate "
                f"data returned) — workbook left untouched.")

    # Avg AQI from the model series.
    nums = [v for v in (model_aqi.get(m) for m in MONTHS_SHORT) if v is not None]
    if nums:
        _put("Avg AQI", round(sum(nums) / len(nums), 1))

    # Provenance. The divergence note is kept deliberately (option A): it is
    # a workbook-level audit flag for where the two providers disagree,
    # independent of how the chart renders (the chart is always-on now).
    def _series_tag(typical: dict | None, written_count: int) -> str:
        return "12M + typical" if written_count else "12M"

    div = divergent_months(model_aqi, ground_aqi)
    if ground_aqi and ground_written:
        src = (f"open-meteo CAMS ({_series_tag(model_typical, typ_written)})"
               f" + openaq ground ({_series_tag(ground_typical, gtyp_written)}")
        src += (f"; diverges: {', '.join(div)}" if div else "; agree")
    else:
        src = (f"open-meteo CAMS ({_series_tag(model_typical, typ_written)}"
               f"; no ground data)")
    _put("AQI Source", src)

    try:
        save_workbook_atomic(wb, path)
    except PermissionError as exc:
        wb.close()
        raise WorkbookLockedError(
            "Destinations workbook is open in another program — close it and retry."
        ) from exc
    wb.close()
    journal_cell_changes(dest_clean, written, path)
    _clear_destination_cache()

    tag = f", ground months: {ground_written}" if ground_written else ""
    if typ_written:
        tag += f", typical months: {typ_written}"
    if gtyp_written:
        tag += f", ground-typical months: {gtyp_written}"
    return f"{dest_clean}: wrote model AQI + climate{tag}, divergent months: {len(div)}"


# ── Reporting / CLI ──────────────────────────────────────────────────────────

def load_coordinates() -> dict[str, dict]:
    with open(Path(__file__).parent / "city_coordinates.json", encoding="utf-8") as fh:
        raw = json.load(fh)
    out = {}
    for entry in raw.values():
        if isinstance(entry, dict) and "lat" in entry and "lon" in entry:
            out[str(entry.get("destination", "")).strip()] = entry
    return out


def load_workbook_names(path=DATA_PATH) -> dict[str, int]:
    """Destination name -> row index (for validation + --all iteration)."""
    sheet_name = _find_destination_sheet(path)
    wb = openpyxl.load_workbook(path, read_only=True)
    ws = wb[sheet_name]
    headers = {str(c.value).strip(): c.column for c in ws[1] if c.value is not None}
    dest_col = headers.get("Destination")
    names = {}
    for r in range(2, ws.max_row + 1):
        v = ws.cell(r, dest_col).value
        if v is not None and str(v).strip():
            names[str(v).strip()] = r
    wb.close()
    return names


def print_report(name: str, payload: dict, ground_truth: dict | None = None) -> None:
    model, ground = payload["model_aqi"], payload.get("ground_aqi")
    typ = payload.get("model_aqi_typical") or {}
    gtyp = payload.get("ground_aqi_typical") or {}

    def _fmt(v) -> str:
        return str(v) if v is not None else "—"

    print(f"\n=== {name} (lat {payload['lat']}, lon {payload['lon']}) ===")
    print(f"{'Month':<6}{'Model':>7}{'Typ':>6}{'Ground':>8}{'GTyp':>6}{'Divergent':>11}")
    for m in MONTHS_SHORT:
        a, b = model.get(m), (ground or {}).get(m)
        flag = ""
        if a is not None and b is not None:
            diff = abs(a - b)
            rel = diff / max(abs(a), abs(b), 1)
            if diff > DIVERGENCE_ABS and rel > DIVERGENCE_REL:
                flag = "  <-- BOTH"
        print(f"{m:<6}{_fmt(a):>7}{_fmt(typ.get(m)):>6}"
              f"{_fmt(b):>8}{_fmt(gtyp.get(m)):>6}{flag:>11}")
    climate = payload.get("climate") or {}
    print("High (C):", climate.get("High (C)"))
    print("Low  (C):", climate.get("Low (C)"))
    print("Rain mm :", climate.get("Rain (mm)"))
    print("RainDays:", climate.get("Rainy Days"))
    if payload.get("ground_error"):
        print(f"ground provider note: {payload['ground_error']}")
    if ground_truth:
        print("IQAir audit targets:", ground_truth)


def _run_cities(targets: list[str], coords: dict, args, failures: list) -> None:
    """Normal rollout loop (or --ground-full for the ground-typical cities).
    Appends (name, error) tuples to ``failures``."""
    for i, name in enumerate(sorted(targets), 1):
        entry = coords[name]
        slug = _slugify(name)
        print(f"[{i}/{len(targets)}] {name} …", flush=True)
        payload = None
        if args.ground_full:
            # Resumable: per-(sensor, month) disk cache + city cache saved
            # before the workbook write (see refresh_ground_full).
            try:
                payload = refresh_ground_full(entry["lat"], entry["lon"], slug)
            except RuntimeError as exc:
                failures.append((name, str(exc)))
                print(f"   FAILED: {exc}")
                continue
        else:
            for attempt in range(1, 11):
                try:
                    payload = fetch_all_providers(
                        entry["lat"], entry["lon"], slug,
                        want_ground=not args.no_ground,
                        max_age_days=-1 if args.refresh else 30)
                    break
                except WorkbookLockedError as exc:
                    failures.append((name, str(exc)))
                    print(f"   FAILED: {exc}")
                    break
                except RuntimeError as exc:
                    msg = str(exc)
                    if "429" not in msg or attempt >= 10:
                        failures.append((name, msg))
                        print(f"   FAILED: {msg}")
                        break
                    if "Hourly API request limit" in msg:
                        wait = 3600 - (time.time() % 3600) + 120
                        print(f"   Open-Meteo hourly quota hit — waiting "
                              f"{wait / 60:.0f} min (attempt {attempt}/10) …",
                              flush=True)
                        time.sleep(wait)
                    elif "Daily API request limit" in msg:
                        print("   Open-Meteo DAILY quota spent — rerun tomorrow "
                              "(cached cities skip instantly).", flush=True)
                        failures.append((name, msg))
                        break
                    else:
                        print(f"   rate limited — waiting 70 s "
                              f"(attempt {attempt}/10) …", flush=True)
                        time.sleep(70)
        if payload is None:
            continue
        if args.report or args.dry_run:
            print_report(name, payload)
        if not args.dry_run:
            climate = {} if args.aqi_only else (payload.get("climate") or {})
            try:
                msg = update_destination_climate(
                    name, payload["model_aqi"], climate,
                    None if args.no_ground else payload.get("ground_aqi"),
                    model_typical=payload.get("model_aqi_typical"),
                    ground_typical=payload.get("ground_aqi_typical"),
                )
                print("   " + msg)
            except (RuntimeError, WorkbookLockedError) as exc:
                failures.append((name, str(exc)))
                print(f"   FAILED: {exc}")
        time.sleep(2.0)  # gentle pacing between cities


def _run_backfill(targets: list[str], coords: dict, args, failures: list) -> None:
    """Add the model multi-year typical to every cached city — one cheap
    Open-Meteo air-quality request each. Ground data is left untouched;
    already-done cities skip instantly, so the run is fully resumable."""
    done = 0
    for i, name in enumerate(sorted(targets), 1):
        entry = coords[name]
        slug = _slugify(name)
        cached = load_cached(slug)
        if not cached or not cached.get("model_aqi"):
            print(f"[{i}/{len(targets)}] {name}: no cache — needs a normal fetch first")
            continue
        if cached.get("model_aqi_typical"):
            done += 1
            continue
        print(f"[{i}/{len(targets)}] {name} …", flush=True)
        model = None
        daily_stop = False
        for attempt in range(1, 4):  # retry the SAME city across hourly walls
            try:
                model = fetch_openmeteo_aqi(entry["lat"], entry["lon"])
                break
            except RuntimeError as exc:
                msg = str(exc)
                if "Daily API request limit" in msg:
                    print(f"   FAILED: {msg}")
                    print("   Open-Meteo daily quota spent — rerun tomorrow "
                          "(already-done cities skip instantly).", flush=True)
                    failures.append((name, msg))
                    daily_stop = True
                    break
                if "Hourly API request limit" in msg and attempt < 3:
                    wait = 3600 - (time.time() % 3600) + 120
                    print(f"   hourly quota — waiting {wait / 60:.0f} min "
                          f"(attempt {attempt}/3) …", flush=True)
                    time.sleep(wait)
                    continue
                failures.append((name, msg))
                print(f"   FAILED: {msg}")
                break
        if daily_stop:
            break
        if model is None:
            continue
        cached["model_aqi"] = model["monthly"]
        cached["model_aqi_typical"] = model["typical"]
        save_cached(slug, cached)
        try:
            msg = update_destination_climate(
                name, cached["model_aqi"], cached.get("climate") or {},
                cached.get("ground_aqi"),
                model_typical=cached["model_aqi_typical"],
                ground_typical=cached.get("ground_aqi_typical"),
            )
            print("   " + msg)
            done += 1
        except (RuntimeError, WorkbookLockedError) as exc:
            failures.append((name, str(exc)))
            print(f"   FAILED: {exc}")
        time.sleep(2.0)
    print(f"\nBackfill: {done} destinations carry the model typical now.", flush=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("cities", nargs="*", help="destination names (workbook names)")
    parser.add_argument("--all", action="store_true", help="process every destination")
    parser.add_argument("--aqi-only", action="store_true",
                        help="skip High/Low/Rain/Rainy-Days writes")
    parser.add_argument("--dry-run", action="store_true",
                        help="report only; do not write the workbook")
    parser.add_argument("--report", action="store_true",
                        help="print the month-by-month table")
    parser.add_argument("--no-ground", action="store_true",
                        help="skip the OpenAQ ground provider")
    parser.add_argument("--refresh", action="store_true",
                        help="ignore fresh cache entries")
    parser.add_argument("--ground-full", action="store_true",
                        help="fetch the ground series over the FULL archive "
                             "window and add the multi-year typical; resumable "
                             "— safe to interrupt, rerun the same command")
    parser.add_argument("--backfill-typical", action="store_true",
                        help="add the model multi-year typical to every cached "
                             "city (1 Open-Meteo request each; needs fresh quota)")
    args = parser.parse_args(argv)
    if args.ground_full and args.no_ground:
        parser.error("--ground-full conflicts with --no-ground")

    coords = load_coordinates()
    workbook_names = load_workbook_names()

    if args.all:
        targets = [n for n in workbook_names if n in coords]
        missing = [n for n in workbook_names if n not in coords]
        if missing:
            print(f"NOTE: {len(missing)} destinations lack coordinates: {missing}")
    else:
        targets = []
        for n in args.cities:
            if n in coords and n in workbook_names:
                targets.append(n)
            else:
                print(f"Skipping '{n}' (no coordinates or not in workbook)")
        if not targets:
            parser.print_usage()
            return 2

    failures: list[tuple[str, str]] = []
    try:
        if args.backfill_typical:
            _run_backfill(targets, coords, args, failures)
        else:
            _run_cities(targets, coords, args, failures)
    except KeyboardInterrupt:
        print("\nInterrupted — everything fetched so far is cached on disk; "
              "rerun the same command to resume where it stopped.")
        return 130

    if failures:
        print("\nFailures:")
        for name, err in failures:
            print(f"  {name}: {err}")
        return 1
    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
