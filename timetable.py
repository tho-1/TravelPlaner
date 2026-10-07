"""Flight data providers for the weekend finder.

Two jobs, kept separate on purpose:

* **Board providers** read a live departure/arrival board. They cover "this
  weekend" but nothing further out.
* **Timetable providers** read published schedules for a given date, so any
  Friday can be planned.

Status of each provider
----------------------
``csv``         **works.** Manual data source; the guarantee that the feature is
                never dead. See :func:`parse_csv_flights`.
``fraport``     **endpoint found and verified** (2026-10-07). The rendered page
                is a JavaScript shell with no flight rows, but the board's own
                JSON endpoint is advertised in the page markup and answers
                plain GETs. Implementation is pending — see
                ``WEEKEND_FINDER_PLAN.md`` §"Fraport endpoint (verified)".
``flightstats`` **blocked.** The v2 board is Next.js and sits behind AWS WAF
                with a captcha challenge; the JSON routes return 404 without
                the challenge cookie.

Correction worth keeping: the first attempt concluded Fraport was unusable
because only the *rendered HTML* was inspected and ``/api/...`` was guessed.
The endpoint is not under ``/api`` at all — it is named by a ``data-api-url``
attribute in the markup. Lesson: read the markup for ``data-`` attributes
before concluding a page is client-side only.

Every provider is rate-limited and cached: a failed fetch must never turn into
a request storm, and a slow source must not be hit on every page rerun.
"""

from __future__ import annotations

import csv
import io
import json
import re
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Callable, Iterable

import runtime_paths
import weekend_match as wm

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0 Safari/537.36 travel-planner/1.0"
)

#: Cache lifetime per (provider, direction, date).
CACHE_TTL = timedelta(hours=6)
#: Minimum seconds between two requests to the same provider.
RATE_LIMIT_S = 5.0

_last_request: dict[str, float] = {}


class ProviderUnavailable(RuntimeError):
    """A provider could not be used. The page shows this, never a traceback."""


@dataclass
class FetchResult:
    """What a provider returned, plus what the user needs to know about it."""

    flights: list[wm.Flight]
    source: str
    cached: bool = False
    fetched_at: str = ""
    warning: str = ""

    def __len__(self) -> int:
        return len(self.flights)


class FlightProvider:
    """Base class: a named source of flights for one airport and date."""

    name = "base"
    #: False when plain-HTTP fetching is known not to work.
    available = True
    #: Shown on the page when ``available`` is False.
    unavailable_reason = ""
    #: True when the source can answer for a date beyond the live board.
    supports_far_dates = False

    def fetch(self, day: date, direction: str) -> FetchResult:
        raise NotImplementedError

    # -- shared plumbing ---------------------------------------------------
    def _throttle(self) -> None:
        previous = _last_request.get(self.name)
        now = time.monotonic()
        if previous is not None:
            wait = RATE_LIMIT_S - (now - previous)
            if wait > 0:
                time.sleep(wait)
        _last_request[self.name] = time.monotonic()

    def _cache_path(self, day: date, direction: str) -> Path | None:
        directory = runtime_paths.writable_dir("weekend_cache")
        if directory is None:
            return None
        return directory / f"{self.name}_{direction}_{day.isoformat()}.json"

    def cached(self, day: date, direction: str) -> FetchResult | None:
        path = self._cache_path(day, direction)
        if path is None or not path.exists():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            stamp = datetime.fromisoformat(payload["fetched_at"])
        except (OSError, KeyError, ValueError):
            return None
        if datetime.now() - stamp > CACHE_TTL:
            return None
        flights = [_flight_from_dict(item) for item in payload.get("flights", [])]
        return FetchResult(flights=flights, source=self.name, cached=True,
                           fetched_at=payload["fetched_at"],
                           warning=payload.get("warning", ""))

    def store(self, day: date, direction: str, result: FetchResult) -> None:
        path = self._cache_path(day, direction)
        if path is None:
            return
        try:
            path.write_text(json.dumps({
                "fetched_at": result.fetched_at or datetime.now().isoformat(),
                "warning": result.warning,
                "flights": [_flight_to_dict(f) for f in result.flights],
            }, ensure_ascii=False), encoding="utf-8")
        except OSError:
            pass                      # a cache we cannot write is not an error


def _flight_to_dict(flight: wm.Flight) -> dict:
    return {
        "flight_no": flight.flight_no, "airline": flight.airline,
        "origin": flight.origin, "destination": flight.destination,
        "departure": flight.departure.isoformat(),
        "arrival": flight.arrival.isoformat(),
        "operated_by": flight.operated_by, "terminal": flight.terminal,
    }


def _flight_from_dict(payload: dict) -> wm.Flight:
    return wm.Flight(
        flight_no=str(payload.get("flight_no", "")),
        airline=str(payload.get("airline", "")),
        origin=str(payload.get("origin", "")),
        destination=str(payload.get("destination", "")),
        departure=datetime.fromisoformat(payload["departure"]),
        arrival=datetime.fromisoformat(payload["arrival"]),
        operated_by=str(payload.get("operated_by", "")),
        terminal=str(payload.get("terminal", "")),
    )


# ── the working provider: CSV ────────────────────────────────────────────────

CSV_COLUMNS = {
    "flight_no": ("flightno", "flightnumber", "flight", "number", "nr"),
    "airline": ("airline", "carrier"),
    "origin": ("origin", "from", "departureairport", "fromairport"),
    "destination": ("destination", "to", "arrivalairport", "toairport"),
    "departure": ("departure", "dep", "departuretime", "scheduleddeparture", "std"),
    "arrival": ("arrival", "arr", "arrivaltime", "scheduledarrival", "sta"),
    "operated_by": ("operatedby", "operator", "operatedbyairline",
                    "operatingcarrier", "operatedbyairlinecode"),
    "terminal": ("terminal", "term"),
}

_TIME_FORMATS = ("%H:%M", "%H:%M:%S", "%d.%m.%Y %H:%M", "%Y-%m-%d %H:%M",
                 "%d/%m/%Y %H:%M", "%H:%M %d.%m.%Y")


def parse_csv_flights(text: str, default_day: date) -> tuple[list[wm.Flight], list[str]]:
    """Parse the CSV upload into flights plus a list of rejected lines.

    Header names are matched case-insensitively against a set of aliases, so a
    board exported as ``Flight,Airline,From,To,Dep,Arr`` works as well as the
    canonical spelling. A date may be embedded in the time field
    (``09.10.2026 14:05``); otherwise ``default_day`` is used. Rows that cannot
    be read are returned as warnings rather than raising, so one bad line does
    not discard an otherwise good upload.
    """
    flights: list[wm.Flight] = []
    problems: list[str] = []
    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames:
        return [], ["The file has no header row."]
    columns = _map_columns(reader.fieldnames)
    missing = [name for name in ("departure", "arrival")
               if name not in columns]
    if missing:
        return [], [f"Missing required column(s): {', '.join(missing)}. "
                    f"Expected at least: flight_no, airline, origin, "
                    f"destination, departure, arrival."]

    for number, row in enumerate(reader, start=2):
        try:
            flight = _flight_from_row(row, columns, default_day)
        except ValueError as exc:
            problems.append(f"line {number}: {exc}")
            continue
        if flight is not None:
            flights.append(flight)
    return flights, problems


def _map_columns(fieldnames: Iterable[str]) -> dict[str, int]:
    mapping: dict[str, int] = {}
    for index, raw in enumerate(fieldnames or []):
        # Underscores and spaces are dropped so "operated_by", "Operated By"
        # and "operatedby" all reach the same alias.
        name = re.sub(r"[\s_]+", "", str(raw or "")).strip().lower()
        for field, aliases in CSV_COLUMNS.items():
            if name in aliases and field not in mapping:
                mapping[field] = index
    return mapping


def _cell(row: dict, mapping: dict[str, int], field: str) -> str:
    index = mapping.get(field)
    if index is None:
        return ""
    values = list(row.values())
    if index >= len(values):
        return ""
    return str(values[index] or "").strip()


def _parse_stamp(text: str, default_day: date) -> datetime:
    raw = str(text or "").strip()
    if not raw:
        raise ValueError("empty time")
    for pattern in _TIME_FORMATS:
        try:
            parsed = datetime.strptime(raw, pattern)
        except ValueError:
            continue
        if "%d" not in pattern:      # a bare time needs the day's date
            return datetime.combine(default_day, parsed.time())
        return parsed
    cleaned = re.sub(r"[+\-]\d$", "", raw)          # "14:05+1" -> next day
    next_day = cleaned != raw
    stamp = wm.parse_flight_time(cleaned, default_day)
    if stamp is None:
        raise ValueError(f"unreadable time {raw!r}")
    return stamp + timedelta(days=1) if next_day else stamp


def _flight_from_row(row: dict, mapping: dict[str, int],
                     default_day: date) -> wm.Flight | None:
    departure = _parse_stamp(_cell(row, mapping, "departure"), default_day)
    arrival_text = _cell(row, mapping, "arrival")
    arrival = _parse_stamp(arrival_text, default_day) if arrival_text else departure
    if arrival < departure:
        arrival += timedelta(days=1)
    origin = _cell(row, mapping, "origin").upper()
    destination = _cell(row, mapping, "destination").upper()
    if not origin or not destination:
        raise ValueError("origin or destination missing")
    return wm.Flight(
        flight_no=_cell(row, mapping, "flight_no") or "n/a",
        airline=_cell(row, mapping, "airline"),
        origin=origin, destination=destination,
        departure=departure, arrival=arrival,
        operated_by=_cell(row, mapping, "operated_by"),
        terminal=_cell(row, mapping, "terminal"),
    )


class CsvProvider(FlightProvider):
    """Reads flights the user supplies. No network, always available."""

    name = "csv"
    supports_far_dates = True

    def __init__(self, departures_csv: str = "", arrivals_csv: str = ""):
        self.departures_csv = departures_csv
        self.arrivals_csv = arrivals_csv

    def fetch(self, day: date, direction: str) -> FetchResult:
        text = self.departures_csv if direction == "departures" else self.arrivals_csv
        if not text.strip():
            return FetchResult(flights=[], source=self.name,
                               fetched_at=datetime.now().isoformat(),
                               warning="No CSV data loaded.")
        flights, problems = parse_csv_flights(text, day)
        warning = ""
        if problems:
            warning = (f"{len(problems)} row(s) skipped: "
                       + "; ".join(problems[:3]))
        return FetchResult(flights=flights, source=self.name,
                           fetched_at=datetime.now().isoformat(),
                           warning=warning)


# ── documented-but-blocked providers ─────────────────────────────────────────

class FraportBoardProvider(FlightProvider):
    """frankfurt-airport.com's own board. Not reachable from plain HTTP.

    Kept in the registry so the finding is recorded and testable: a future
    change on their side (a public JSON endpoint) only requires implementing
    :meth:`fetch`. Do not "fix" this by scraping rendered HTML.
    """

    name = "fraport"
    available = False
    #: The endpoint works; the provider does not exist yet. Kept as a class so
    #: the finding is testable and so `provider_status()` can say "not
    #: implemented" rather than the earlier, wrong "not reachable".
    unavailable_reason = (
        "Endpoint verified working on 2026-10-07 "
        "(frankfurt-airport.com/en/_jcr_content.flights.json/filter) but the "
        "provider is not implemented yet — see WEEKEND_FINDER_PLAN.md."
    )

    #: Verified request shape, kept here so the implementation has a spec.
    endpoint = "https://www.frankfurt-airport.com/en/_jcr_content.flights.json/filter"
    page_departures = "https://www.frankfurt-airport.com/en/flights-and-transfer/departures.html"
    page_arrivals = "https://www.frankfurt-airport.com/en/flights-and-transfer/arrivals.html"

    def fetch(self, day: date, direction: str) -> FetchResult:
        raise ProviderUnavailable(self.unavailable_reason)


class FlightStatsProvider(FlightProvider):
    """flightstats.com v2 board. Blocked by AWS WAF / captcha.

    The site's JSON routes return 404 without a WAF challenge cookie, so this
    needs an authenticated API subscription rather than a scrape.
    """

    name = "flightstats"
    available = False
    unavailable_reason = (
        "The FlightStats board sits behind AWS WAF with a captcha challenge; "
        "its JSON endpoints return 404 to a plain client. It would need an API "
        "subscription, which is a decision for the user, not a scraper."
    )

    def fetch(self, day: date, direction: str) -> FetchResult:
        raise ProviderUnavailable(self.unavailable_reason)


PROVIDERS: dict[str, Callable[[], FlightProvider]] = {
    CsvProvider.name: CsvProvider,
    FraportBoardProvider.name: FraportBoardProvider,
    FlightStatsProvider.name: FlightStatsProvider,
}


def available_providers() -> list[FlightProvider]:
    """Instantiated providers that can actually be used right now."""
    out: list[FlightProvider] = []
    for factory in PROVIDERS.values():
        try:
            provider = factory()
        except Exception:
            continue
        if provider.available:
            out.append(provider)
    return out


def provider_status() -> list[dict]:
    """One row per provider for the UI: usable, or why not."""
    rows: list[dict] = []
    for name, factory in PROVIDERS.items():
        try:
            provider = factory()
        except Exception as exc:
            rows.append({"name": name, "usable": False,
                         "reason": f"could not start: {exc}", "far_dates": False})
            continue
        rows.append({
            "name": name,
            "usable": provider.available,
            "reason": provider.unavailable_reason,
            "far_dates": provider.supports_far_dates,
        })
    return rows


def fetch_direction(provider: FlightProvider, day: date,
                    direction: str, use_cache: bool = True) -> FetchResult:
    """Fetch one direction, using the cache unless asked not to."""
    if use_cache:
        hit = provider.cached(day, direction)
        if hit is not None:
            return hit
    try:
        result = provider.fetch(day, direction)
    except ProviderUnavailable:
        raise
    except Exception as exc:
        raise ProviderUnavailable(f"{provider.name}: {exc}") from exc
    if not result.fetched_at:
        result.fetched_at = datetime.now().isoformat()
    if use_cache:
        provider.store(day, direction, result)
    return result


def search_weekend(weekend: wm.Weekend, windows: wm.Windows,
                   provider: FlightProvider,
                   benefit_flags: dict[str, bool] | None = None,
                   city_lookup: Callable[[str], tuple | None] | None = None,
                   use_cache: bool = True) -> wm.MatchReport:
    """Run the four board queries for one weekend and match them.

    A provider that cannot answer for the Saturday return is not fatal: the
    outbound legs are still collected, and the report explains the gap in
    ``notes`` instead of pretending there were no return flights.
    """
    import airline_benefits
    import airport_city

    flags = benefit_flags if benefit_flags is not None else airline_benefits.load_benefit_flags()
    lookup = city_lookup or airport_city.city_for_airport

    def benefit(airline: str) -> bool:
        return airline_benefits.has_benefits(airline, flags)

    outbound: list[wm.Flight] = []
    returns: list[wm.Flight] = []
    notes: list[str] = []

    for day, kind, sink in ((weekend.friday, "departures", outbound),
                            (weekend.saturday, "departures", outbound),
                            (weekend.saturday, "arrivals", returns),
                            (weekend.sunday, "arrivals", returns),
                            (weekend.monday, "arrivals", returns)):
        try:
            result = fetch_direction(provider, day, kind, use_cache=use_cache)
        except ProviderUnavailable as exc:
            notes.append(str(exc))
            break
        if result.warning:
            notes.append(f"{day.isoformat()} {kind}: {result.warning}")
        sink.extend(result.flights)

    report = wm.find_weekends(outbound, returns, weekend, windows,
                              benefit, lookup)
    report.notes = notes
    return report


SAMPLE_CSV = """flight_no,airline,origin,destination,departure,arrival
LH1000,Lufthansa,FRA,BCN,09.10.2026 15:05,09.10.2026 17:05
LH1001,Lufthansa,FRA,CDG,10.10.2026 09:30,10.10.2026 11:05
LH1002,Lufthansa,BCN,FRA,11.10.2026 16:40,11.10.2026 18:35
LH1003,Lufthansa,CDG,FRA,12.10.2026 06:10,12.10.2026 08:20
"""


if __name__ == "__main__":  # pragma: no cover - manual helper
    for row in provider_status():
        print(f"{row['name']:12} usable={row['usable']}  {row['reason'][:70]}")
    parsed, bad = parse_csv_flights(SAMPLE_CSV, date(2026, 10, 9))
    print(f"\nsample CSV: {len(parsed)} flights, {len(bad)} problems")
    for f in parsed:
        print(f"  {f.flight_no} {f.origin}->{f.destination} "
              f"{f.departure:%a %H:%M} -> {f.arrival:%a %H:%M} {f.airline}")