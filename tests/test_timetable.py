"""Tests for the flight-data layer: CSV parsing, caching, provider registry.

Runs with or without pytest:
    python -m pytest tests/test_timetable.py
    python tests/test_timetable.py
"""

from __future__ import annotations

import sys
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

def test_csv_is_the_one_usable_provider():
    usable = [p.name for p in tt.available_providers()]
    assert usable == ["csv"], usable


def test_the_unavailable_providers_document_why():
    rows = {row["name"]: row for row in tt.provider_status()}
    # Fraport is NOT unreachable: the JSON endpoint was verified working on
    # 2026-10-07 and the provider is simply not written yet. The wording has to
    # say which of the two it is, or the next agent repeats the false "blocked"
    # conclusion this replaced.
    assert rows["fraport"]["usable"] is False
    assert "verified working" in rows["fraport"]["reason"]
    assert "not implemented" in rows["fraport"]["reason"]
    assert "JavaScript shell" not in rows["fraport"]["reason"]

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
    for provider in (tt.FraportBoardProvider(), tt.FlightStatsProvider()):
        try:
            provider.fetch(FRIDAY, "departures")
        except tt.ProviderUnavailable as exc:
            assert str(exc)
        else:
            raise AssertionError(f"{provider.name} must not look like it worked")


def test_only_csv_supports_dates_further_out():
    rows = {row["name"]: row for row in tt.provider_status()}
    assert rows["csv"]["far_dates"] is True
    assert rows["fraport"]["far_dates"] is False


# ── caching ──────────────────────────────────────────────────────────────────

def test_results_are_cached_and_reused(tmp_path=None):
    import tempfile

    root = Path(tmp_path) if tmp_path else Path(tempfile.mkdtemp())
    cache = root / "weekend_cache"
    cache.mkdir(parents=True, exist_ok=True)

    calls = []

    class Counting(tt.FlightProvider):
        name = "counting"

        def fetch(self, day, direction):
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
        test_csv_is_the_one_usable_provider,
        test_the_unavailable_providers_document_why,
        test_the_fraport_endpoint_is_pinned_in_the_code,
        test_a_blocked_provider_raises_rather_than_returning_nothing,
        test_only_csv_supports_dates_further_out,
        test_results_are_cached_and_reused,
        test_a_cached_result_round_trips_flights,
        test_an_unwritable_cache_degrades_to_a_live_fetch,
        test_a_csv_weekend_produces_cities,
        test_a_non_benefit_airline_is_filtered_end_to_end,
        test_an_empty_upload_is_reported_not_silently_empty,
        test_row_problems_reach_the_notes,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")