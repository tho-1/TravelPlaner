"""Tests for the flight-data layer: CSV parsing, caching, provider registry.

Runs with or without pytest:
    python -m pytest tests/test_timetable.py
    python tests/test_timetable.py
"""

from __future__ import annotations

import json
import sys
from contextlib import contextmanager
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import timetable as tt  # noqa: E402
import weekend_match as wm  # noqa: E402

FRIDAY = date(2026, 10, 9)
SATURDAY = date(2026, 10, 10)
SUNDAY = date(2026, 10, 11)
MONDAY = date(2026, 10, 12)

GOOD_CSV = """flight_no,airline,origin,destination,departure,arrival
LH1000,Lufthansa,FRA,BCN,15:05,17:05
LH1001,Lufthansa,BCN,FRA,16:40,18:35
"""


# ── CSV parsing ──────────────────────────────────────────────────────────────

def test_the_canonical_csv_parses():
    flights, problems = tt.parse_csv_flights(GOOD_CSV, FRIDAY)
    assert problems == []
    assert len(flights) == 2
    first = flights[0]
    assert first.flight_no == "LH1000"
    assert first.origin == "FRA" and first.destination == "BCN"
    assert first.departure == datetime(2026, 10, 9, 15, 5)
    assert first.arrival == datetime(2026, 10, 9, 17, 5)


def test_column_aliases_are_accepted():
    """A board exported with different headers must still import."""
    text = ("Flight,Carrier,From,To,Dep,Arr\n"
            "BA500,British Airways, fra , LHR,09:00,10:10\n")
    flights, problems = tt.parse_csv_flights(text, FRIDAY)
    assert problems == []
    assert flights[0].origin == "FRA" and flights[0].destination == "LHR"
    assert flights[0].airline == "British Airways"


def test_a_date_inside_the_time_field_is_used():
    text = ("flight_no,airline,origin,destination,departure,arrival\n"
            "LH1,Lufthansa,FRA,BCN,09.10.2026 15:05,09.10.2026 17:05\n")
    flights, _ = tt.parse_csv_flights(text, MONDAY)
    assert flights[0].departure.date() == FRIDAY
    assert flights[0].arrival.date() == FRIDAY


def test_a_bare_time_uses_the_requested_day():
    text = ("flight_no,airline,origin,destination,departure,arrival\n"
            "LH1,Lufthansa,FRA,BCN,15:05,17:05\n")
    flights, _ = tt.parse_csv_flights(text, SATURDAY)
    assert flights[0].departure.date() == SATURDAY


def test_an_arrival_before_departure_moves_to_the_next_day():
    text = ("flight_no,airline,origin,destination,departure,arrival\n"
            "LH1,Lufthansa,FRA,NRT,23:30,08:00\n")
    flights, _ = tt.parse_csv_flights(text, FRIDAY)
    assert flights[0].arrival.date() == SATURDAY


def test_the_plus_one_suffix_is_understood():
    text = ("flight_no,airline,origin,destination,departure,arrival\n"
            "LH1,Lufthansa,FRA,BCN,22:30,00:15+1\n")
    flights, _ = tt.parse_csv_flights(text, FRIDAY)
    assert flights[0].arrival.date() == SATURDAY
    assert flights[0].arrival.hour == 0


def test_a_bad_row_is_reported_and_the_rest_survive():
    text = ("flight_no,airline,origin,destination,departure,arrival\n"
            "LH1,Lufthansa,FRA,BCN,15:05,17:05\n"
            "LH2,Lufthansa,FRA,CDG,nonsense,17:05\n"
            "LH3,Lufthansa,FRA,MUC,15:05,16:05\n")
    flights, problems = tt.parse_csv_flights(text, FRIDAY)
    assert len(flights) == 2
    assert len(problems) == 1 and "line 3" in problems[0]


def test_a_missing_required_column_is_reported_clearly():
    text = "flight_no,airline,origin,destination\nLH1,Lufthansa,FRA,BCN\n"
    flights, problems = tt.parse_csv_flights(text, FRIDAY)
    assert flights == []
    assert "Missing required column" in problems[0]
    assert "departure" in problems[0]


def test_an_empty_file_is_handled():
    flights, problems = tt.parse_csv_flights("", FRIDAY)
    assert flights == [] and "header row" in problems[0]
    flights, problems = tt.parse_csv_flights("a,b\n1,2\n", FRIDAY)
    assert flights == [] and "Missing required column" in problems[0]


def test_a_header_only_file_yields_no_flights_and_no_complaint():
    flights, problems = tt.parse_csv_flights(
        "flight_no,airline,origin,destination,departure,arrival\n", FRIDAY)
    assert flights == [] and problems == []


def test_operator_and_terminal_are_read():
    text = ("flight_no,airline,origin,destination,departure,arrival,"
            "operated_by,terminal\n"
            "LH1,Lufthansa,FRA,BCN,15:05,17:05,Vueling,T1\n")
    flights, _ = tt.parse_csv_flights(text, FRIDAY)
    assert flights[0].operator_airline == "Vueling"
    assert flights[0].terminal == "T1"


# ── the provider registry ────────────────────────────────────────────────────

def test_the_usable_providers_are_csv_and_fraport():
    usable = [p.name for p in tt.available_providers()]
    assert usable == ["csv", "fraport"], usable


def test_the_unavailable_providers_document_why():
    rows = {row["name"]: row for row in tt.provider_status()}
    # Fraport is implemented and usable: the JSON endpoint was
    # verified working on 2026-10-07 and the provider was written
    # on 2026-10-08. Only FlightStats is blocked, and the wording
    # has to say which of the two it is, or the next agent repeats
    # the false "blocked" conclusion this replaced.
    assert rows["fraport"]["usable"] is True
    assert rows["fraport"]["far_dates"] is True

    assert rows["flightstats"]["usable"] is False
    assert "WAF" in rows["flightstats"]["reason"]


def test_the_fraport_endpoint_is_pinned_in_the_code():
    """The endpoint is undocumented, so its shape lives in code as well as in
    the plan: if Fraport changes it, the diff is visible."""
    provider = tt.FraportBoardProvider()
    assert provider.endpoint.endswith("/_jcr_content.flights.json/filter")
    assert "flights-and-transfer/departures.html" in provider.page_departures
    assert "flights-and-transfer/arrivals.html" in provider.page_arrivals


def test_a_blocked_provider_raises_rather_than_returning_nothing():
    provider = tt.FlightStatsProvider()
    try:
        provider.fetch(FRIDAY, "departures")
    except tt.ProviderUnavailable as exc:
        assert str(exc)
    else:
        raise AssertionError(f"{provider.name} must not look like it worked")


def test_both_usable_providers_support_dates_further_out():
    rows = {row["name"]: row for row in tt.provider_status()}
    # The Fraport endpoint answers any date ±60 days out and
    # beyond (verified 2026-10-07), so any Friday can be planned,
    # not just the upcoming one.
    assert rows["csv"]["far_dates"] is True
    assert rows["fraport"]["far_dates"] is True


# ── caching ──────────────────────────────────────────────────────────────────

def test_results_are_cached_and_reused(tmp_path=None):
    import tempfile

    root = Path(tmp_path) if tmp_path else Path(tempfile.mkdtemp())
    cache = root / "weekend_cache"
    cache.mkdir(parents=True, exist_ok=True)

    calls = []

    class Counting(tt.FlightProvider):
        name = "counting"

        def fetch(self, day, direction, since=None, until=None):
            calls.append((day, direction))
            return tt.FetchResult(flights=[], source=self.name,
                                  fetched_at=datetime.now().isoformat())

    provider = Counting()
    original = tt.runtime_paths.writable_dir

    def fake_dir(*parts):
        target = cache.joinpath(*parts)
        target.mkdir(parents=True, exist_ok=True)
        return target

    tt.runtime_paths.writable_dir = fake_dir
    try:
        first = tt.fetch_direction(provider, FRIDAY, "departures")
        second = tt.fetch_direction(provider, FRIDAY, "departures")
    finally:
        tt.runtime_paths.writable_dir = original
    assert len(calls) == 1, "the second call must come from the cache"
    assert first.cached is False and second.cached is True


def test_a_cached_result_round_trips_flights(tmp_path=None):
    import tempfile

    root = Path(tmp_path) if tmp_path else Path(tempfile.mkdtemp())
    cache = root / "weekend_cache"
    cache.mkdir(parents=True, exist_ok=True)
    provider = tt.CsvProvider(departures_csv=GOOD_CSV, arrivals_csv="")
    original = tt.runtime_paths.writable_dir

    def fake_dir(*parts):
        target = cache.joinpath(*parts)
        target.mkdir(parents=True, exist_ok=True)
        return target

    tt.runtime_paths.writable_dir = fake_dir
    try:
        fresh = tt.fetch_direction(provider, FRIDAY, "departures")
        stored = tt.fetch_direction(provider, FRIDAY, "departures")
    finally:
        tt.runtime_paths.writable_dir = original
    assert fresh.cached is False and stored.cached is True
    assert len(stored.flights) == len(fresh.flights)
    assert stored.flights[0].flight_no == fresh.flights[0].flight_no
    assert stored.flights[0].arrival == fresh.flights[0].arrival


def test_an_unwritable_cache_degrades_to_a_live_fetch():
    provider = tt.CsvProvider(departures_csv=GOOD_CSV)
    original = tt.runtime_paths.writable_dir
    tt.runtime_paths.writable_dir = lambda *parts: None
    try:
        result = tt.fetch_direction(provider, FRIDAY, "departures")
    finally:
        tt.runtime_paths.writable_dir = original
    assert len(result.flights) == 2


# ── end to end through the finder ────────────────────────────────────────────

def test_a_csv_weekend_produces_cities():
    departures = (
        "flight_no,airline,origin,destination,departure,arrival\n"
        "LH1000,Lufthansa,FRA,BCN,09.10.2026 15:05,09.10.2026 17:05\n"
        "LH1001,Lufthansa,FRA,CDG,10.10.2026 09:30,10.10.2026 11:05\n")
    arrivals = (
        "flight_no,airline,origin,destination,departure,arrival\n"
        "LH1002,Lufthansa,BCN,FRA,11.10.2026 16:40,11.10.2026 18:35\n"
        "LH1003,Lufthansa,CDG,FRA,12.10.2026 06:10,12.10.2026 08:20\n")
    provider = tt.CsvProvider(departures_csv=departures, arrivals_csv=arrivals)
    weekend = wm.Weekend(friday=FRIDAY)
    flags = {"lufthansa": True}

    original = tt.runtime_paths.writable_dir
    tt.runtime_paths.writable_dir = lambda *parts: None
    try:
        report = tt.search_weekend(weekend, wm.Windows(), provider, flags)
    finally:
        tt.runtime_paths.writable_dir = original
    assert report.city_count == 2, [c.city for c in report.cities]
    assert {c.city for c in report.cities} == {"Barcelona", "Paris"}
    assert report.notes == []


def test_a_non_benefit_airline_is_filtered_end_to_end():
    departures = ("flight_no,airline,origin,destination,departure,arrival\n"
                   "VY1,Vueling,FRA,BCN,09.10.2026 15:05,09.10.2026 17:05\n")
    arrivals = ("flight_no,airline,origin,destination,departure,arrival\n"
                "VY2,Vueling,BCN,FRA,11.10.2026 16:40,11.10.2026 18:35\n")
    provider = tt.CsvProvider(departures_csv=departures, arrivals_csv=arrivals)
    weekend = wm.Weekend(friday=FRIDAY)
    original = tt.runtime_paths.writable_dir
    tt.runtime_paths.writable_dir = lambda *parts: None
    try:
        report = tt.search_weekend(weekend, wm.Windows(), provider, {"lufthansa": True})
    finally:
        tt.runtime_paths.writable_dir = original
    assert report.city_count == 0
    assert "Vueling" in report.outbound_rejected_airlines


def test_an_empty_upload_is_reported_not_silently_empty():
    provider = tt.CsvProvider()
    weekend = wm.Weekend(friday=FRIDAY)
    original = tt.runtime_paths.writable_dir
    tt.runtime_paths.writable_dir = lambda *parts: None
    try:
        report = tt.search_weekend(weekend, wm.Windows(), provider, {})
    finally:
        tt.runtime_paths.writable_dir = original
    assert report.city_count == 0
    assert any("No CSV data" in note for note in report.notes)


def test_row_problems_reach_the_notes():
    departures = GOOD_CSV + "LH9,Lufthansa,FRA,CDG,whenever,17:05\n"
    provider = tt.CsvProvider(departures_csv=departures, arrivals_csv="")
    weekend = wm.Weekend(friday=FRIDAY)
    original = tt.runtime_paths.writable_dir
    tt.runtime_paths.writable_dir = lambda *parts: None
    try:
        report = tt.search_weekend(weekend, wm.Windows(), provider, {"lufthansa": True})
    finally:
        tt.runtime_paths.writable_dir = original
    assert any("skipped" in note for note in report.notes), report.notes


# ── the live Fraport board, replayed from recorded responses ───────
#
# The endpoint is undocumented, so one real response per board and
# direction is recorded under tests/fixtures/ and replayed forever:
# if Fraport changes the shape, these tests fail loudly instead of
# the page silently returning zero flights. Nothing in this section
# touches the network.

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _recorded(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class _BoardResponse:
    """The slice of ``requests.Response`` the provider uses."""

    def __init__(self, payload: dict):
        self.status_code = 200
        self._payload = payload

    def json(self) -> dict:
        return self._payload


class _StubRequests:
    """Stands in for the requests module inside ``timetable``.

    It replaces ``timetable.requests`` — the name the provider
    looks the module up by — not ``requests.get`` itself, so no
    other code in the process is affected.
    """

    def __init__(self, router):
        self._router = router

    def get(self, url, params=None, headers=None, timeout=None):
        return self._router(url, params or {})


def _serve_fraport(pages: dict, calls: list | None = None) -> _StubRequests:
    """Route board queries to recorded pages.

    ``pages`` maps ``(flighttype, time-cursor, page)`` -> response
    payload. A query that is not in the map answers an empty board,
    which is how the weekend's remaining queries are served in the
    end-to-end test below.
    """
    def router(url, params):
        if calls is not None:
            calls.append(params)
        key = (params.get("flighttype"), params.get("time"),
               params.get("page"))
        return _BoardResponse(pages.get(key, {"data": []}))

    return _StubRequests(router)


@contextmanager
def _no_throttle():
    """The 5 s rate limit is politeness towards the real board; a
    replayed response must not sleep through it."""
    original = tt.RATE_LIMIT_S
    tt.RATE_LIMIT_S = 0
    try:
        yield
    finally:
        tt.RATE_LIMIT_S = original


@contextmanager
def _fraport_served(pages: dict, calls: list | None = None):
    original = tt.requests
    tt.requests = _serve_fraport(pages, calls)
    try:
        yield
    finally:
        tt.requests = original


def test_the_fraport_parser_reads_a_recorded_board():
    """A recorded departures page parses into flights: the operated
    flight number, the operating carrier, both airports, the
    scheduled departure and the destination's arrival wall-clock."""
    page = _recorded("fraport_departures_page1.json")
    first = page["data"][0]
    pages = {("departures", "2026-10-09T14:00:00+02:00", 1): page}
    with _fraport_served(pages):
        with _no_throttle():
            result = tt.fetch_direction(
                tt.FraportBoardProvider(), FRIDAY, "departures",
                use_cache=False,
                since=datetime(2026, 10, 9, 14, 0),
                until=datetime(2026, 10, 9, 15, 0))
    assert result.source == "fraport"
    assert result.flights
    flight = result.flights[0]
    assert flight.flight_no == first["fnr"].replace(" ", "")
    assert flight.airline == first["al"]
    assert flight.origin == "FRA"
    assert flight.destination == first["iata"]
    assert flight.terminal == first["terminal"]
    assert flight.operated_by == ""      # `al` already is the operator


def test_the_fraport_parser_takes_wall_clocks_not_offsets():
    """The board stamps destination times with a bogus ``+0000``
    offset. The parser must keep the wall-clock as a *naive*
    datetime — the CSV provider's convention — or the matcher's
    comparisons (an outbound's arrival against the return's
    departure) would compare instants in mixed zones."""
    page = _recorded("fraport_departures_page1.json")
    record = page["data"][0]               # LH 908, schedArr 14:40+0000
    pages = {("departures", "2026-10-09T14:00:00+02:00", 1): page}
    with _fraport_served(pages):
        with _no_throttle():
            result = tt.fetch_direction(
                tt.FraportBoardProvider(), FRIDAY, "departures",
                use_cache=False,
                since=datetime(2026, 10, 9, 14, 0),
                until=datetime(2026, 10, 9, 15, 0))
    flight = result.flights[0]
    assert flight.departure.tzinfo is None
    assert flight.arrival.tzinfo is None
    assert flight.departure == datetime(2026, 10, 9, 14, 0)
    # 14:40 is London's wall-clock, not the UTC instant the
    # +0000 offset would suggest (that would be 15:40 Berlin).
    assert flight.arrival == datetime(2026, 10, 9, 14, 40)
    assert record["schedArr"].endswith("+0000")


def test_the_fraport_parser_skips_flights_with_stops():
    """Only nonstop flights qualify. A *missing* ``stops`` is kept:
    the arrivals board never reports stops at all, and the
    departures records without it are Lufthansa's direct train
    connections to FRA."""
    page = _recorded("fraport_departures_page1.json")
    stopped = dict(page["data"][0])
    stopped["stops"] = 1
    stopped["fnr"] = "XX 999"
    pages = {("departures", "2026-10-09T14:00:00+02:00", 1):
             {"data": [stopped, page["data"][0]]}}
    with _fraport_served(pages):
        with _no_throttle():
            result = tt.fetch_direction(
                tt.FraportBoardProvider(), FRIDAY, "departures",
                use_cache=False,
                since=datetime(2026, 10, 9, 14, 0),
                until=datetime(2026, 10, 9, 15, 0))
    assert [f.flight_no for f in result.flights] == ["LH908"]


def test_the_fraport_cursor_carries_the_berlin_offset():
    """The endpoint silently ignores a bare date or a naive
    datetime; the ``time`` cursor must be a full ISO datetime with
    the Berlin offset — computed from the zone, because Berlin is
    +02:00 in summer and +01:00 in winter and a hard-coded offset
    would return the wrong day across a DST change."""
    page = _recorded("fraport_departures_page1.json")
    summer_calls: list = []
    winter_calls: list = []
    summer = {("departures", "2026-10-09T14:00:00+02:00", 1): page}
    winter = {("departures", "2027-01-08T14:00:00+01:00", 1): page}
    with _fraport_served(summer, summer_calls):
        with _no_throttle():
            tt.fetch_direction(tt.FraportBoardProvider(), FRIDAY,
                               "departures", use_cache=False,
                               since=datetime(2026, 10, 9, 14, 0),
                               until=datetime(2026, 10, 9, 15, 0))
    with _fraport_served(winter, winter_calls):
        with _no_throttle():
            tt.fetch_direction(tt.FraportBoardProvider(),
                               date(2027, 1, 8), "departures",
                               use_cache=False,
                               since=datetime(2027, 1, 8, 14, 0),
                               until=datetime(2027, 1, 8, 15, 0))
    assert summer_calls[0]["time"] == "2026-10-09T14:00:00+02:00"
    assert winter_calls[0]["time"] == "2027-01-08T14:00:00+01:00"
    for calls in (summer_calls, winter_calls):
        assert calls[0]["flighttype"] == "departures"
        assert calls[0]["perpage"] == 50
        assert calls[0]["page"] == 1


def test_the_fraport_fetch_pages_and_stops_at_the_window_end():
    """The board is walked page by page from the cursor, and the
    walk stops at the window's end — the verified ~39-requests
    strategy for a whole weekend, not whole days."""
    page1 = _recorded("fraport_departures_page1.json")
    page2 = _recorded("fraport_departures_page2.json")
    pages = {
        ("departures", "2026-10-09T14:00:00+02:00", 1): page1,
        ("departures", "2026-10-09T14:00:00+02:00", 2): page2,
    }
    calls: list = []
    until = datetime(2026, 10, 9, 15, 30)
    with _fraport_served(pages, calls):
        with _no_throttle():
            result = tt.fetch_direction(
                tt.FraportBoardProvider(), FRIDAY, "departures",
                use_cache=False,
                since=datetime(2026, 10, 9, 14, 0), until=until)
    assert len(calls) == 2, "the walk must stop once records pass the end"
    expected = [r for r in page1["data"] + page2["data"]
                if tt._wall_clock(r.get("sched")) <= until]
    assert len(result.flights) == len(expected)
    assert all(f.departure <= until for f in result.flights)
    # Page 2's first record (14:50) is inside the window; the
    # page's later records (up to 16:10) are not.
    assert datetime(2026, 10, 9, 14, 50) in [f.departure
                                             for f in result.flights]


def test_a_fraport_shape_change_fails_loudly():
    """A response without a ``data`` list means the endpoint changed
    shape. That must raise — not look like "nowhere to fly", which
    is the silent failure mode the plan calls out."""
    pages = {("departures", "2026-10-09T14:00:00+02:00", 1):
             {"results": 0}}
    with _fraport_served(pages):
        with _no_throttle():
            try:
                tt.fetch_direction(tt.FraportBoardProvider(), FRIDAY,
                                   "departures", use_cache=False,
                                   since=datetime(2026, 10, 9, 14, 0),
                                   until=datetime(2026, 10, 9, 15, 0))
            except tt.ProviderUnavailable as exc:
                assert "endpoint changed" in str(exc)
            else:
                raise AssertionError("a shape change must fail loudly")


def test_the_fraport_cache_key_includes_the_window():
    """The fetch only walks the window, so a changed window must not
    be served a narrower cached answer."""
    import tempfile

    root = Path(tempfile.mkdtemp())
    cache = root / "weekend_cache"
    cache.mkdir(parents=True, exist_ok=True)
    original_dir = tt.runtime_paths.writable_dir
    original_requests = tt.requests

    def fake_dir(*parts):
        target = cache.joinpath(*parts)
        target.mkdir(parents=True, exist_ok=True)
        return target

    page = _recorded("fraport_departures_page1.json")
    pages = {("departures", "2026-10-09T14:00:00+02:00", 1): page}
    tt.runtime_paths.writable_dir = fake_dir
    tt.requests = _serve_fraport(pages)
    try:
        with _no_throttle():
            narrow = tt.fetch_direction(
                tt.FraportBoardProvider(), FRIDAY, "departures",
                since=datetime(2026, 10, 9, 14, 0),
                until=datetime(2026, 10, 9, 15, 0))
            again = tt.fetch_direction(
                tt.FraportBoardProvider(), FRIDAY, "departures",
                since=datetime(2026, 10, 9, 14, 0),
                until=datetime(2026, 10, 9, 15, 0))
            wide = tt.fetch_direction(
                tt.FraportBoardProvider(), FRIDAY, "departures",
                since=datetime(2026, 10, 9, 14, 0),
                until=datetime(2026, 10, 9, 16, 0))
    finally:
        tt.runtime_paths.writable_dir = original_dir
        tt.requests = original_requests
    assert narrow.cached is False and again.cached is True
    assert wide.cached is False, "a wider window must not reuse the narrow cache"


def test_the_fetch_window_bounds_follow_the_six_inputs():
    """Each of the five board queries covers exactly the range the
    user's six bounds describe."""
    weekend = wm.Weekend(friday=FRIDAY)
    windows = wm.Windows()
    cases = [
        (weekend.friday, "departures",
         datetime(2026, 10, 9, 14, 0), datetime(2026, 10, 10, 0, 0)),
        (weekend.saturday, "departures",
         datetime(2026, 10, 10, 0, 0), datetime(2026, 10, 10, 12, 0)),
        (weekend.saturday, "arrivals",
         datetime(2026, 10, 10, 12, 0), datetime(2026, 10, 11, 0, 0)),
        (weekend.sunday, "arrivals",
         datetime(2026, 10, 11, 0, 0), datetime(2026, 10, 12, 0, 0)),
        (weekend.monday, "arrivals",
         datetime(2026, 10, 12, 0, 0), datetime(2026, 10, 12, 9, 0)),
    ]
    for day, kind, since, until in cases:
        assert tt._fetch_window(weekend, windows, day, kind) == (since, until)


def test_a_fraport_weekend_produces_cities():
    """End to end through the finder on recorded boards: the Friday
    departures and the Sunday returns come from the fixtures, the
    other three queries answer an empty board. A city needs a
    benefit-airline outbound *and* a benefit-airline return —
    London and Barcelona are served by Lufthansa both ways in the
    recordings, Condor's returns in the same window are not."""
    pages = {
        ("departures", "2026-10-09T14:00:00+02:00", 1):
            _recorded("fraport_departures_page1.json"),
        ("departures", "2026-10-09T14:00:00+02:00", 2):
            _recorded("fraport_departures_page2.json"),
        ("arrivals", "2026-10-11T00:00:00+02:00", 1):
            _recorded("fraport_arrivals_page1.json"),
        ("arrivals", "2026-10-11T00:00:00+02:00", 2):
            _recorded("fraport_arrivals_page2.json"),
    }
    weekend = wm.Weekend(friday=FRIDAY)
    original_dir = tt.runtime_paths.writable_dir
    original_requests = tt.requests
    tt.runtime_paths.writable_dir = lambda *parts: None
    tt.requests = _serve_fraport(pages)
    # The flag map is keyed by IATA code *and* canonical name —
    # the rule records_to_flags implements — because the board
    # says "LH" while a CSV export says "Lufthansa".
    flags = {"LH": True, "lufthansa": True}
    try:
        with _no_throttle():
            report = tt.search_weekend(weekend, wm.Windows(),
                                       tt.FraportBoardProvider(),
                                       flags)
    finally:
        tt.runtime_paths.writable_dir = original_dir
        tt.requests = original_requests

    cities = {result.city for result in report.cities}
    assert "London" in cities, cities
    assert "Barcelona" in cities, cities
    assert report.notes == [], report.notes


if __name__ == "__main__":
    tests = [
        test_the_canonical_csv_parses,
        test_column_aliases_are_accepted,
        test_a_date_inside_the_time_field_is_used,
        test_a_bare_time_uses_the_requested_day,
        test_an_arrival_before_departure_moves_to_the_next_day,
        test_the_plus_one_suffix_is_understood,
        test_a_bad_row_is_reported_and_the_rest_survive,
        test_a_missing_required_column_is_reported_clearly,
        test_an_empty_file_is_handled,
        test_a_header_only_file_yields_no_flights_and_no_complaint,
        test_operator_and_terminal_are_read,
        test_the_usable_providers_are_csv_and_fraport,
        test_the_unavailable_providers_document_why,
        test_the_fraport_endpoint_is_pinned_in_the_code,
        test_a_blocked_provider_raises_rather_than_returning_nothing,
        test_both_usable_providers_support_dates_further_out,
        test_results_are_cached_and_reused,
        test_a_cached_result_round_trips_flights,
        test_an_unwritable_cache_degrades_to_a_live_fetch,
        test_a_csv_weekend_produces_cities,
        test_a_non_benefit_airline_is_filtered_end_to_end,
        test_an_empty_upload_is_reported_not_silently_empty,
        test_row_problems_reach_the_notes,
        test_the_fraport_parser_reads_a_recorded_board,
        test_the_fraport_parser_takes_wall_clocks_not_offsets,
        test_the_fraport_parser_skips_flights_with_stops,
        test_the_fraport_cursor_carries_the_berlin_offset,
        test_the_fraport_fetch_pages_and_stops_at_the_window_end,
        test_a_fraport_shape_change_fails_loudly,
        test_the_fraport_cache_key_includes_the_window,
        test_the_fetch_window_bounds_follow_the_six_inputs,
        test_a_fraport_weekend_produces_cities,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")