"""IQAir World Most Polluted Cities ranking — scrape, cache, match, write.

Scrapes https://www.iqair.com/world-most-polluted-cities (the "World Air
Quality Report" city table: annual PM2.5 ug/m3 per city, 2017-2025 columns,
~9.4k cities, 50 per page). The FULL dataset is cached locally so future
lookups — including destinations added later via the add-new-destination
module — never need to re-scrape:

    iqair_cache/world_cities.json  {
      fetched, vintage, total_cities, pages_done: [...],
      cities: [{rank, city, country, pm25: {2025: 112.5, ...}}, ...]
    }

Workbook: writes 'IQAir Rank' (2025 world rank) and 'IQAir PM2.5'
(mean of the up-to-5 most recent year values) to every destination row.
Destination names that are REGIONS, not cities (e.g. "Sri Lanka",
"Kerala"), fall back to the region's capital city per user decision.

Dashboard: the destination page shows a 5th KPI card with the rank
(see pages/destination_detail.py).

Matching rules (user-approved):
  1. try the full destination name, then the name without the
     parenthetical, then the parenthetical itself ("KK (Kota Kinabalu)").
  2. a parenthetical is also tried as a country filter when a base name is
     ambiguous ("Santiago (Chile)").
  3. region rows -> capital city (CAPITAL_FALLBACK map).
  4. still ambiguous/unmatched -> left blank + listed in the report.

Usage:
    python iqair_ranking.py                # scrape (resumable) + write + report
    python iqair_ranking.py --scrape-only  # just build/refresh the cache
    python iqair_ranking.py --refresh      # re-scrape even if cache is fresh
    python iqair_ranking.py --no-write     # scrape + report, skip workbook

Requires: requests, openpyxl (already in requirements.txt).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
import unicodedata
from datetime import datetime, timezone
from html import unescape as _unescape
from pathlib import Path

import openpyxl
import requests

from data_utils import (
    DATA_PATH,
    WorkbookLockedError,
    _clear_destination_cache,
    _find_destination_sheet,
    load_workbook_for_update,
    save_workbook_atomic,
)

BASE_URL = "https://www.iqair.com/world-most-polluted-cities"

CACHE_DIR = Path(__file__).parent / "iqair_cache"
SNAPSHOT_PATH = CACHE_DIR / "world_cities.json"

PER_PAGE = 50
# Value columns on the page, left to right (verified 2026-09-02).
YEARS = [2025, 2024, 2023, 2022, 2021, 2020, 2019, 2018, 2017]
PM25_AVG_YEARS = [2025, 2024, 2023, 2022, 2021]  # "average of up to 5 years"

STALE_DAYS = 200   # the report is annual; no need to scrape more often
PACE_S = 0.75      # polite pacing between page fetches
SAVE_EVERY = 25    # incremental snapshot saves (shutdown-safe)

HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/126.0 Safari/537.36"),
    "Accept-Language": "en",
}

# Region-type workbook entries (not cities in IQAir's table) -> the
# region's capital city, which IS ranked. Extend as new region rows appear.
CAPITAL_FALLBACK = {
    "sri lanka": "Colombo",
    "kerala": "Thiruvananthapuram",
    "brunei": "Bandar Seri Begawan",   # workbook row: "Brunei (capital)"
}

# Workbook name -> the name IQAir actually uses (verified against the
# 2026-09 snapshot). Applied on top of the exact-match chain.
ALIASES = {
    "saigon": "Ho Chi Minh City",
    "bangalore": "Bengaluru",
    "seville": "Sevilla",
    "mallorca": "Palma",
    "bilbao": "Bilbo",
    "samarkand": "Samarqand",
    "pattaya": "Pattaya City",
    "phu quoc": "Phu Quoc City",
}

SESSION = requests.Session()
SESSION.headers.update(HEADERS)

try:
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass


# ── Snapshot io ──────────────────────────────────────────────────────────────

def _load_snapshot() -> dict:
    if not SNAPSHOT_PATH.exists():
        return {}
    try:
        snap = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}
    # format 2: city/country names unescaped (older snapshots hold raw
    # HTML entities like N&#x27;Djamena) — migrate once, in place.
    if snap.get("format") != 2 and snap.get("cities"):
        for c in snap["cities"]:
            c["city"] = _unescape(str(c.get("city", "")))
            c["country"] = _unescape(str(c.get("country", "")))
        snap["format"] = 2
        _save_snapshot(snap)
    return snap


def _save_snapshot(snap: dict) -> None:
    CACHE_DIR.mkdir(exist_ok=True)
    tmp = SNAPSHOT_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(snap, ensure_ascii=False), encoding="utf-8")
    tmp.replace(SNAPSHOT_PATH)  # atomic — never a half-written cache


def snapshot_is_fresh(snap: dict, max_age_days: int = STALE_DAYS) -> bool:
    try:
        fetched = datetime.fromisoformat(snap.get("fetched", ""))
    except (ValueError, TypeError):
        return False
    age = (datetime.now(timezone.utc) - fetched).days
    return age <= max_age_days


# ── HTML parsing ─────────────────────────────────────────────────────────────

_TAG_RE = re.compile(r"<[^>]+>")
_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
_ROW_RE = re.compile(r"<tr[^>]*>(.*?)</tr>", re.S)
_TD_RE = re.compile(r"<td[^>]*>(.*?)</td>", re.S)
_P_RE = re.compile(r"<p[^>]*>(.*?)</p>", re.S)
_TOTAL_RE = re.compile(r"of\s*([\d,]+)")


def _clean(html: str) -> str:
    # IQAir renders special chars as literal entities (e.g. Ya&#x27;an),
    # so unescape AFTER stripping tags/comments.
    return _unescape(_COMMENT_RE.sub("", _TAG_RE.sub("", html))).strip()


def _parse_total_pages(html: str) -> int | None:
    """Number of ranking pages, from the pagination element.

    The page footer reads e.g. '1 - 50 of 9373' followed by the page links
    '1 2 ... 188'. React renders those as separate text nodes, so after
    tag-stripping they GLUE together ('of 937312...188') — parse the raw
    HTML instead: the '...' ellipsis is always followed by the LAST page
    number; fall back to a rank-range + total guess.
    """
    m = re.search(r"\.{2,}(?:\s|<!-- -->)*(\d{1,4})", html)
    if m:
        pages = int(m.group(1))
        if 1 <= pages <= 999:
            return pages
    m = re.search(r"of(?:\s|<!-- -->)*([\d,]{4,})", html)
    if m:
        try:
            total = int(m.group(1).replace(",", ""))
            if total >= 50:
                return math.ceil(total / PER_PAGE)
        except ValueError:
            pass
    return None


def _parse_rows(html: str) -> list[dict]:
    """Data rows of one ranking page -> [{rank, city, country, pm25{}}]."""
    out: list[dict] = []
    for row_html in _ROW_RE.findall(html):
        tds = _TD_RE.findall(row_html)
        if len(tds) < 3:
            continue
        rank_txt = _clean(tds[0])
        if not rank_txt.isdigit():
            continue  # header / spacer rows
        # City cell: desktop <p> holds "City, Country"; the mobile block
        # holds two <p>s ("City", "Country") — the unambiguous one.
        ps = [_clean(p) for p in _P_RE.findall(tds[1]) if _clean(p)]
        if len(ps) >= 3:            # [combined, city, country]
            city, country = ps[1], ps[2]
        elif len(ps) == 1 and ", " in ps[0]:
            city, country = ps[0].rsplit(", ", 1)
        else:
            continue
        values = []
        for td in tds[2:2 + len(YEARS)]:
            txt = _clean(td)
            values.append(float(txt) if re.fullmatch(r"\d+(?:\.\d+)?", txt)
                          else None)
        out.append({
            "rank": int(rank_txt),
            "city": city.strip(),
            "country": country.strip(),
            "pm25": {str(y): v for y, v in zip(YEARS, values) if v is not None},
        })
    return out


# ── Scraping (resumable) ─────────────────────────────────────────────────────

def fetch_page(page: int) -> str:
    last_exc: Exception | None = None
    for attempt in range(1, 4):
        try:
            resp = SESSION.get(BASE_URL, params={"page": page, "cities": ""},
                               timeout=60)
            if resp.status_code == 200:
                return resp.text
            last_exc = RuntimeError(f"HTTP {resp.status_code} on page {page}")
        except requests.RequestException as exc:
            last_exc = exc
        time.sleep(3 * attempt)
    raise RuntimeError(f"page {page} failed after 3 attempts: {last_exc}")


def ensure_snapshot(refresh: bool = False) -> dict:
    """Build/extend the full ranking snapshot. Resumable: pages already in
    the snapshot are skipped, so an interrupted run continues where it
    stopped (or after a PC shutdown — just rerun the same command)."""
    snap = _load_snapshot()
    if snap and not refresh and snapshot_is_fresh(snap) \
            and snap.get("complete"):
        print(f"IQAir snapshot fresh ({snap.get('total_cities')} cities, "
              f"fetched {snap.get('fetched', '')[:10]}) — skipping scrape.",
              flush=True)
        return snap

    pages_done: set[int] = set(snap.get("pages_done") or [])
    cities_by_rank: dict[int, dict] = {c["rank"]: c
                                       for c in snap.get("cities") or []}

    if refresh or not pages_done:
        pages_done, cities_by_rank = set(), {}
        snap = {}

    page = 1
    total_pages = None
    while page <= (total_pages or 400):  # 400 = runaway safety cap
        if page in pages_done:
            page += 1
            continue
        html = fetch_page(page)
        rows = _parse_rows(html)
        if not rows:
            break  # past the end of the table
        if total_pages is None:
            total_pages = _parse_total_pages(html)
        expected = (page - 1) * PER_PAGE + 1
        if rows[0]["rank"] < expected:
            # Out-of-range pages can repeat the LAST page instead of
            # returning an empty table — never wrap data into the snapshot.
            print(f"page {page}: rank {rows[0]['rank']} < expected "
                  f"{expected} — end of table reached.", flush=True)
            break
        for row in rows:
            cities_by_rank[row["rank"]] = row
        pages_done.add(page)
        if rows[0]["rank"] != expected:
            print(f"   WARNING page {page}: first rank {rows[0]['rank']} "
                  f"(expected {expected}) — site layout may have changed.",
                  flush=True)
        print(f"[{page}/{total_pages or '?'}] ranks "
              f"{rows[0]['rank']}–{rows[-1]['rank']} "
              f"({len(cities_by_rank)} cities cached)", flush=True)
        if page % SAVE_EVERY == 0:
            _save_snapshot(_pack(pages_done, cities_by_rank, total_pages))
        page += 1
        time.sleep(PACE_S)

    snap = _pack(pages_done, cities_by_rank, total_pages)
    snap["complete"] = True
    _save_snapshot(snap)
    print(f"Scrape complete: {len(cities_by_rank)} cities, "
          f"{len(pages_done)} pages.", flush=True)
    return snap


def _pack(pages_done: set[int], cities_by_rank: dict[int, dict],
          total_pages: int | None) -> dict:
    return {
        "fetched": datetime.now(timezone.utc).isoformat(),
        "source": BASE_URL,
        "vintage": YEARS[0],
        "format": 2,
        "total_pages": total_pages,
        "total_cities": len(cities_by_rank),
        "pages_done": sorted(pages_done),
        "cities": [cities_by_rank[r] for r in sorted(cities_by_rank)],
    }


# ── Matching ─────────────────────────────────────────────────────────────────

def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", str(s))
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.replace("'", "").replace("\u2019", "")  # Xi'an == Xian
    s = re.sub(r"[^a-z0-9]+", " ", s.casefold())
    return re.sub(r"\s+", " ", s).strip()


# Workbook Country spellings that differ from IQAir's.
COUNTRY_ALIASES = {
    "uae": "united arab emirates",
    "united states": "usa",
    "u s a": "usa",
    "u k": "united kingdom",
}
_COUNTRY_CONNECTORS = {"and", "the", "of", "&"}


def _country_tokens(country: str) -> set[str]:
    cnorm = _norm(COUNTRY_ALIASES.get(_norm(country), country))
    return set(cnorm.split()) - _COUNTRY_CONNECTORS


def _pm25_avg(entry: dict) -> float | None:
    """Mean of the up-to-5 most recent year values (user decision)."""
    vals = [entry["pm25"][str(y)] for y in PM25_AVG_YEARS
            if str(y) in entry["pm25"]]
    return round(sum(vals) / len(vals), 1) if vals else None


def build_matcher(snap: dict) -> dict[str, list[dict]]:
    index: dict[str, list[dict]] = {}
    for entry in snap.get("cities") or []:
        index.setdefault(_norm(entry["city"]), []).append(entry)
    return index


def _country_filter(hits: list[dict], country: str | None) -> list[dict]:
    """Keep hits whose IQAir country matches the workbook's Country cell.
    Token-set containment ignores connector words and abbreviations
    ('Bosnia and Herzegovina' == 'Bosnia Herzegovina', 'UAE' ==
    'United Arab Emirates'). Empty result = candidate exists but in OTHER
    countries (a miss, not a guess source)."""
    if not country:
        return hits
    ct = _country_tokens(country)
    if not ct:
        return hits
    out = []
    for h in hits:
        ht = _country_tokens(h["country"])
        if ht and (ct <= ht or ht <= ct):
            out.append(h)
    return out


def _pick(hits: list[dict]) -> dict:
    """Single hit -> itself; several -> best (lowest) rank, flagged."""
    entry = dict(min(hits, key=lambda h: h["rank"]))
    entry["guessed"] = len(hits) > 1
    return entry


def lookup(name: str, index: dict[str, list[dict]],
           country: str | None = None) -> dict:
    """Resolve one workbook destination name.

    Returns {"status": "city"|"capital", "rank", "pm25_avg", "entry",
    "guessed"} or {"status": "wrong-country"|"ambiguous"|"unmatched",
    "candidates": [...]}.
    """
    raw = str(name).strip()
    m = re.match(r"^(.*?)\s*\((.*?)\)\s*$", raw)
    base, paren = (m.group(1), m.group(2)) if m else (raw, None)
    nb, np_ = _norm(base), (_norm(paren) if paren else None)

    # Candidate names, in try order: full, base, parenthetical
    # ("KK (Kota Kinabalu)"), then their aliases ("Saigon" -> HCMC).
    cands: list[str] = []
    for cand in (raw, base, paren):
        if cand and cand not in cands:
            cands.append(cand)
    for cand in list(cands):
        aliased = ALIASES.get(_norm(cand))
        if aliased and aliased not in cands:
            cands.append(aliased)

    wrong_country: list[dict] = []
    multi_hits: list[dict] = []
    for cand in cands:
        hits = index.get(_norm(cand)) or []
        if not hits:
            continue
        filtered = _country_filter(hits, country)
        if not filtered:
            if not wrong_country:
                wrong_country = sorted(hits, key=lambda h: h["rank"])[:5]
            continue
        if len(filtered) == 1:
            entry = _pick(filtered)
            return {"status": "city", "rank": entry["rank"],
                    "pm25_avg": _pm25_avg(entry), "entry": entry,
                    "guessed": entry["guessed"]}
        if not multi_hits:
            multi_hits = filtered

    # 2) region row -> capital city (user decision), country-filtered.
    cap = CAPITAL_FALLBACK.get(nb) or (CAPITAL_FALLBACK.get(np_)
                                       if np_ else None)
    if cap:
        hits = _country_filter(index.get(_norm(cap)) or [], country)
        if hits:
            entry = _pick(hits)
            return {"status": "capital", "rank": entry["rank"],
                    "pm25_avg": _pm25_avg(entry), "entry": entry,
                    "via": cap, "guessed": entry["guessed"]}

    # 3) renamed city rows: query is a PREFIX of the IQAir name
    # ("Santa Cruz" -> "Santa Cruz de la Sierra"). Needs >=2 tokens to
    # avoid "Salvador" matching "San Salvador".
    qnorm = _norm(base)
    if len(qnorm.split()) >= 2:
        for entry_norm, ehits in index.items():
            if entry_norm.startswith(qnorm + " "):
                filtered = _country_filter(ehits, country)
                if len(filtered) == 1:
                    entry = _pick(filtered)
                    return {"status": "city", "rank": entry["rank"],
                            "pm25_avg": _pm25_avg(entry), "entry": entry,
                            "guessed": entry["guessed"]}

    # 4) several same-country hits (e.g. Suzhou Jiangsu vs Anhui):
    # best rank wins, flagged as a guess in the report.
    if multi_hits:
        entry = _pick(multi_hits)
        return {"status": "city", "rank": entry["rank"],
                "pm25_avg": _pm25_avg(entry), "entry": entry,
                "guessed": True}

    if wrong_country:
        return {"status": "wrong-country", "candidates": wrong_country}
    for cand in (base, raw):
        hits = index.get(_norm(cand)) or []
        if hits:
            return {"status": "ambiguous",
                    "candidates": sorted(hits, key=lambda h: h["rank"])[:5]}
    return {"status": "unmatched", "candidates": []}


def rank_for_destination(name: str, country: str | None = None) -> dict | None:
    """Public one-shot lookup for other modules (add-new-destination flow).

    Uses ONLY the cached snapshot — never triggers a scrape (an interactive
    add must not block for minutes). Returns {"rank", "pm25_avg"} or None.
    If the snapshot is missing/stale, run ``python -m iqair_ranking`` once.
    """
    snap = _load_snapshot()
    if not snap.get("cities"):
        return None
    res = lookup(name, build_matcher(snap), country)
    if res["status"] in ("city", "capital"):
        return {"rank": res["rank"], "pm25_avg": res["pm25_avg"]}
    return None


# ── Workbook ─────────────────────────────────────────────────────────────────

def write_workbook(snap: dict, path=DATA_PATH) -> dict:
    """Write 'IQAir Rank' + 'IQAir PM2.5' for every destination row."""
    index = build_matcher(snap)
    sheet_name = _find_destination_sheet(path)
    if sheet_name is None:
        raise RuntimeError("could not find destination sheet")
    wb = load_workbook_for_update(path)
    ws = wb[sheet_name]

    headers = {}
    for col in range(1, ws.max_column + 1):
        v = ws.cell(1, col).value
        if v is not None:
            headers[str(v).strip()] = col
    dest_col = headers.get("Destination")
    if dest_col is None:
        wb.close()
        raise RuntimeError("no 'Destination' column")

    def _ensure_header(nm: str) -> int:
        if nm not in headers:
            col = ws.max_column + 1
            ws.cell(1, col, value=nm)
            headers[nm] = col
        return headers[nm]

    rank_col, pm_col = _ensure_header("IQAir Rank"), _ensure_header("IQAir PM2.5")
    country_col = headers.get("Country")

    def _fmt_cands(res: dict) -> str:
        cands = res.get("candidates") or []
        if not cands:
            return "no candidates"
        return ", ".join(f"{c['city']} ({c['country']}) #{c['rank']}"
                         for c in cands)

    stats = {"city": 0, "capital": 0, "blank": 0,
             "capital_names": [], "guessed": [], "ambiguous": [],
             "wrong_country": [], "unmatched": []}
    for r in range(2, ws.max_row + 1):
        name = ws.cell(r, dest_col).value
        if name is None or not str(name).strip():
            continue
        name = str(name).strip()
        country = None
        if country_col is not None:
            raw_c = ws.cell(r, country_col).value
            if raw_c is not None and str(raw_c).strip():
                country = str(raw_c).strip()
        res = lookup(name, index, country)
        status = res["status"]
        if status in ("city", "capital"):
            ws.cell(r, rank_col, value=res["rank"])
            if res.get("pm25_avg") is not None:
                ws.cell(r, pm_col, value=res["pm25_avg"])
            stats[status] += 1
            if status == "capital":
                stats["capital_names"].append(
                    f"{name} → {res['via']} #{res['rank']}")
            elif res.get("guessed"):
                e = res["entry"]
                stats["guessed"].append(
                    f"{name} → {e['city']} ({e['country']}) "
                    f"#{res['rank']} (best-rank guess)")
        else:
            stats["blank"] += 1
            key = {"ambiguous": "ambiguous",
                   "wrong-country": "wrong_country"}.get(status, "unmatched")
            stats[key].append(f"{name}: {_fmt_cands(res)}")

    try:
        save_workbook_atomic(wb, path)
    except PermissionError as exc:
        wb.close()
        raise WorkbookLockedError(
            "Destinations workbook is open in another program — close it and retry."
        ) from exc
    wb.close()
    _clear_destination_cache()
    return stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--scrape-only", action="store_true",
                        help="build/refresh the cache; no workbook write")
    parser.add_argument("--refresh", action="store_true",
                        help="re-scrape even if the snapshot is fresh")
    parser.add_argument("--no-write", action="store_true",
                        help="skip the workbook write (report only)")
    args = parser.parse_args(argv)

    try:
        snap = ensure_snapshot(refresh=args.refresh)
    except RuntimeError as exc:
        print(f"FAILED: {exc}")
        return 1
    if args.scrape_only:
        return 0

    try:
        stats = write_workbook(snap)
    except WorkbookLockedError as exc:
        print(f"FAILED: {exc}")
        return 1

    print(f"\nWorkbook: {stats['city']} city matches, "
          f"{stats['capital']} capital fallbacks, {stats['blank']} blank.")
    if stats.get("capital_names"):
        print("Capital fallbacks:")
        for line in stats["capital_names"]:
            print(f"  {line}")
    if stats["guessed"]:
        print("Best-rank guesses (verify manually):")
        for line in stats["guessed"]:
            print(f"  {line}")
    for label, key in (("Ambiguous (left blank)", "ambiguous"),
                       ("Found only in other countries (left blank)",
                        "wrong_country"),
                       ("Unmatched (left blank)", "unmatched")):
        if stats[key]:
            print(f"{label}:")
            for line in stats[key]:
                print(f"  {line}")
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
