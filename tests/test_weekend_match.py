"""Tests for the weekend matcher (pure logic, no network, no workbook).

Runs with or without pytest:
    python -m pytest tests/test_weekend_match.py
    python tests/test_weekend_match.py
"""

from __future__ import annotations

import sys
from datetime import date, datetime, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import weekend_match as wm  # noqa: E402

# 2026-10-09 is a Friday; the weekend runs to Monday 2026-10-12.
FRIDAY = date(2026, 10, 9)
SATURDAY = date(2026, 10, 10)
SUNDAY = date(2026, 10, 11)
MONDAY = date(2026, 10, 12)
WEEKEND = wm.Weekend(friday=FRIDAY)
WINDOWS = wm.Windows()


def at(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute))


def flight(out_day, out_h, out_m=0, arr_day=None, arr_h=0, arr_m=0,
           origin="FRA", dest="BCN", airline="Lufthansa", no="LH1",
           operated="") -> wm.Flight:
    return wm.Flight(
        flight_no=no, airline=airline, origin=origin, destination=dest,
        departure=at(out_day, out_h, out_m),
        arrival=at(arr_day or out_day, arr_h, arr_m),
        operated_by=operated,
    )


def only_benefit(airline: str) -> bool:
    return airline.strip().lower() == "lufthansa"


def lookup(code: str):
    table = {"BCN": ("Barcelona", "ES"), "CDG": ("Paris", "FR"),
             "FCO": ("Rome", "IT"), "LGW": ("London", "GB"),
             "MXP": ("Milan", "IT"), "NCE": ("Nice", "FR"),
             "AMS": ("Amsterdam", "NL"), "ZZZ": None}
    return table.get(code.upper())


# ── the weekend a day belongs to ─────────────────────────────────────────────

def test_a_monday_maps_to_the_coming_friday():
    assert wm.weekend_containing(date(2026, 10, 5)).friday == FRIDAY


def test_saturday_and_sunday_map_back_to_their_friday():
    assert wm.weekend_containing(SATURDAY).friday == FRIDAY
    assert wm.weekend_containing(SUNDAY).friday == FRIDAY


def test_friday_maps_to_itself_and_tuesday_to_this_week():
    assert wm.weekend_containing(FRIDAY).friday == FRIDAY
    assert wm.weekend_containing(date(2026, 10, 6)).friday == FRIDAY


def test_the_weekend_days_are_consecutive():
    assert WEEKEND.saturday == SATURDAY
    assert WEEKEND.sunday == SUNDAY
    assert WEEKEND.monday == MONDAY
    assert WEEKEND.days == (FRIDAY, SATURDAY, SUNDAY, MONDAY)


def test_next_friday_skips_today_when_asked_to():
    assert wm.next_friday(FRIDAY) == date(2026, 10, 16)
    assert wm.next_friday(date(2026, 10, 5)) == FRIDAY


def test_next_friday_respects_a_minimum_lead_time():
    """A weekend's schedule only becomes useful once published, so asking for
    too little lead time must move on to the following Friday. Exactly the
    threshold is still accepted."""
    # MONDAY here is the weekend's own Monday (Oct 12); "now" for the finder
    # would be an earlier date such as Oct 5.
    assert wm.next_friday(date(2026, 10, 5), minimum_days_ahead=4) == FRIDAY
    assert wm.next_friday(date(2026, 10, 5), minimum_days_ahead=5) == date(2026, 10, 16)


# ── the outbound window ──────────────────────────────────────────────────────

def test_friday_outbound_uses_the_lower_bound():
    assert wm.is_outbound_candidate(
        flight(FRIDAY, 14, 0, arr_h=16), WEEKEND, WINDOWS) is True
    assert wm.is_outbound_candidate(
        flight(FRIDAY, 13, 59, arr_h=16), WEEKEND, WINDOWS) is False


def test_saturday_outbound_uses_an_upper_bound():
    assert wm.is_outbound_candidate(
        flight(SATURDAY, 11, 59, arr_h=14), WEEKEND, WINDOWS) is True
    assert wm.is_outbound_candidate(
        flight(SATURDAY, 12, 0, arr_h=14), WEEKEND, WINDOWS) is False


def test_thursday_sunday_and_monday_are_never_outbound():
    for day in (date(2026, 10, 8), SUNDAY, MONDAY):
        assert wm.is_outbound_candidate(
            flight(day, 9, 0, arr_h=11), WEEKEND, WINDOWS) is False


def test_outbound_must_depart_from_frankfurt():
    assert wm.is_outbound_candidate(
        flight(FRIDAY, 15, origin="MUC", dest="BCN", arr_h=17),
        WEEKEND, WINDOWS) is False


def test_custom_windows_are_honoured():
    windows = wm.Windows(friday_from=time(18, 0), saturday_before=time(9, 0))
    assert wm.is_outbound_candidate(
        flight(FRIDAY, 17, 0, arr_h=19), WEEKEND, windows) is False
    assert wm.is_outbound_candidate(
        flight(FRIDAY, 18, 0, arr_h=20), WEEKEND, windows) is True
    assert wm.is_outbound_candidate(
        flight(SATURDAY, 9, 0, arr_h=11), WEEKEND, windows) is False
    assert wm.is_outbound_candidate(
        flight(SATURDAY, 8, 59, arr_h=11), WEEKEND, windows) is True


# ── the return window ────────────────────────────────────────────────────────

def test_saturday_return_uses_the_lower_bound():
    assert wm.is_return_candidate(
        flight(SATURDAY, 17, dest="FRA", origin="BCN", arr_h=19),
        WEEKEND, WINDOWS) is True
    assert wm.is_return_candidate(
        flight(SATURDAY, 10, dest="FRA", origin="BCN", arr_h=11),
        WEEKEND, WINDOWS) is False


def test_sunday_return_is_unbounded_by_default():
    assert wm.is_return_candidate(
        flight(SUNDAY, 9, dest="FRA", origin="BCN", arr_h=10),
        WEEKEND, WINDOWS) is True
    assert wm.is_return_candidate(
        flight(SUNDAY, 23, dest="FRA", origin="BCN", arr_h=23, arr_m=30),
        WEEKEND, WINDOWS) is True


def test_sunday_return_honours_an_explicit_cutoff():
    windows = wm.Windows(sunday_return_until=time(20, 0))
    assert wm.is_return_candidate(
        flight(SUNDAY, 17, dest="FRA", origin="BCN", arr_h=19),
        WEEKEND, windows) is True
    assert wm.is_return_candidate(
        flight(SUNDAY, 21, dest="FRA", origin="BCN", arr_h=22),
        WEEKEND, windows) is False


def test_monday_return_must_land_before_the_cutoff():
    assert wm.is_return_candidate(
        flight(MONDAY, 6, dest="FRA", origin="BCN", arr_h=8, arr_m=59),
        WEEKEND, WINDOWS) is True
    assert wm.is_return_candidate(
        flight(MONDAY, 8, dest="FRA", origin="BCN", arr_h=9, arr_m=0),
        WEEKEND, WINDOWS) is False


def test_a_friday_return_is_not_a_weekend():
    assert wm.is_return_candidate(
        flight(FRIDAY, 6, dest="FRA", origin="BCN", arr_h=8),
        WEEKEND, WINDOWS) is False


def test_return_must_land_in_frankfurt():
    assert wm.is_return_candidate(
        flight(SUNDAY, 10, origin="BCN", dest="MUC", arr_h=12),
        WEEKEND, WINDOWS) is False


# ── nights ───────────────────────────────────────────────────────────────────

def test_nights_are_counted_between_landing_and_taking_off():
    out = flight(FRIDAY, 15, arr_day=FRIDAY, arr_h=17)
    back = flight(SUNDAY, 16, origin="BCN", dest="FRA", arr_h=18)
    assert wm.nights_away(out, back) == 2


def test_a_same_day_trip_is_zero_nights_not_negative():
    out = flight(FRIDAY, 6, arr_day=FRIDAY, arr_h=8)
    back = flight(FRIDAY, 20, origin="BCN", dest="FRA", arr_h=22)
    assert wm.nights_away(out, back) == 0


def test_overnight_arrival_counts_the_next_day():
    out = flight(FRIDAY, 23, arr_day=SATURDAY, arr_h=1)
    back = flight(SUNDAY, 10, origin="BCN", dest="FRA", arr_h=12)
    assert wm.nights_away(out, back) == 1


# ── the full search ──────────────────────────────────────────────────────────

def test_a_simple_round_trip_produces_one_city():
    report = wm.find_weekends(
        outbound=[flight(FRIDAY, 15, arr_h=17, dest="BCN", no="LH1000")],
        returns=[flight(SUNDAY, 16, origin="BCN", dest="FRA", arr_h=18,
                        no="LH1001")],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert report.city_count == 1
    city = report.cities[0]
    assert city.label == "Barcelona (ES)"
    assert city.count == 1
    assert city.options[0].nights == 2
    assert city.options[0].outbound_airline == "Lufthansa"


def test_an_airline_without_benefits_is_filtered_out():
    report = wm.find_weekends(
        outbound=[flight(FRIDAY, 15, arr_h=17, dest="BCN", no="VY1",
                         airline="Vueling")],
        returns=[flight(SUNDAY, 16, origin="BCN", dest="FRA", arr_h=18,
                        no="VY2", airline="Vueling")],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert report.city_count == 0
    assert "Vueling" in report.outbound_rejected_airlines


def test_the_operator_carrier_decides_benefits_not_the_marketing_one():
    """A Lufthansa-numbered flight operated by Vueling does not qualify."""
    report = wm.find_weekends(
        outbound=[flight(FRIDAY, 15, arr_h=17, dest="BCN", no="LH1000",
                         airline="Lufthansa", operated="Vueling")],
        returns=[flight(SUNDAY, 16, origin="BCN", dest="FRA", arr_h=18,
                        no="LH1001", airline="Lufthansa",
                        operated="Vueling")],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert report.city_count == 0


def test_a_city_needing_both_legs_qualifies_only_when_both_do():
    out_only = [flight(FRIDAY, 15, arr_h=17, dest="NCE", no="LH1")]
    back_only = [flight(SUNDAY, 16, origin="CDG", dest="FRA", arr_h=18, no="LH2")]

    report = wm.find_weekends(out_only, [], WEEKEND, WINDOWS,
                              only_benefit, lookup)
    assert report.city_count == 0
    assert [c.city for c in report.one_way_only] == ["Nice"]
    assert report.one_way_only[0].out_only and not report.one_way_only[0].back_only

    report = wm.find_weekends([], back_only, WEEKEND, WINDOWS,
                              only_benefit, lookup)
    assert report.city_count == 0
    assert [c.city for c in report.one_way_only] == ["Paris"]
    assert report.one_way_only[0].back_only


def test_two_airports_of_one_city_collapse_into_one_result_row():
    """LGW and LHR are both London, so the result must say London once."""
    report = wm.find_weekends(
        outbound=[
            flight(FRIDAY, 15, arr_h=17, dest="CDG", no="LH1"),
            flight(FRIDAY, 16, arr_h=17, dest="LGW", no="LH2"),
        ],
        returns=[
            flight(SUNDAY, 16, origin="CDG", dest="FRA", arr_h=18, no="LH3"),
            flight(SUNDAY, 17, origin="LGW", dest="FRA", arr_h=19, no="LH4"),
        ],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert report.city_count == 2
    cities = {c.city: c for c in report.cities}
    assert cities["Paris"].airports == {"CDG"}
    assert cities["London"].airports == {"LGW"}
    assert cities["London"].count == 1


def test_an_unmapped_airport_is_reported_not_dropped():
    report = wm.find_weekends(
        outbound=[flight(FRIDAY, 15, arr_h=17, dest="ZZZ", no="LH1")],
        returns=[flight(SUNDAY, 16, origin="ZZZ", dest="FRA", arr_h=18,
                        no="LH2")],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert report.city_count == 1
    city = report.cities[0]
    assert city.unmapped_airports == {"ZZZ"}
    assert city.city == "?ZZZ"


def test_a_return_before_the_outbound_arrival_is_not_paired():
    """You cannot leave Barcelona before the outbound has landed there.

    The Saturday-morning outbound below lands at 23:00 on the Saturday, while
    the return departs at 20:00 the same day: both legs pass their time
    windows, but the pairing is impossible and must not be offered.
    """
    report = wm.find_weekends(
        outbound=[flight(SATURDAY, 10, arr_day=SATURDAY, arr_h=23,
                         dest="BCN", no="LH1")],
        returns=[flight(SATURDAY, 20, origin="BCN", dest="FRA", arr_h=22,
                        no="LH2")],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert report.city_count == 0
    assert [c.city for c in report.one_way_only] == ["Barcelona"]


def test_an_overnight_friday_flight_can_be_paired_with_a_saturday_return():
    """Landing Saturday 01:00 and coming back at 14:00 is a real, if short,
    weekend — it must appear rather than be rejected as zero nights."""
    report = wm.find_weekends(
        outbound=[flight(FRIDAY, 20, arr_day=SATURDAY, arr_h=1,
                         dest="BCN", no="LH1")],
        returns=[flight(SATURDAY, 14, origin="BCN", dest="FRA", arr_h=16,
                        no="LH2")],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert report.city_count == 1
    assert report.cities[0].options[0].nights == 0


def test_results_are_sorted_by_earliest_departure():
    report = wm.find_weekends(
        outbound=[
            flight(FRIDAY, 18, arr_h=20, dest="CDG", no="LH2"),
            flight(FRIDAY, 15, arr_h=17, dest="NCE", no="LH1"),
        ],
        returns=[
            flight(SUNDAY, 16, origin="CDG", dest="FRA", arr_h=18, no="LH4"),
            flight(SUNDAY, 16, origin="NCE", dest="FRA", arr_h=18, no="LH3"),
        ],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    assert [c.city for c in report.cities] == ["Nice", "Paris"]


def test_a_sunday_return_is_preferred_over_a_monday_one():
    monday_back = flight(MONDAY, 6, origin="CDG", dest="FRA", arr_h=8,
                         no="LH9")
    sunday_back = flight(SUNDAY, 16, origin="CDG", dest="FRA", arr_h=18,
                         no="LH8")
    report = wm.find_weekends(
        outbound=[flight(FRIDAY, 15, arr_h=17, dest="CDG", no="LH1")],
        returns=[monday_back, sunday_back],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    option = report.cities[0].options[0]
    assert option.back_flight.flight_no == "LH8", "Sunday should win"


def test_a_saturday_evening_return_is_preferred_over_sunday():
    saturday_back = flight(SATURDAY, 18, origin="CDG", dest="FRA", arr_h=20,
                           no="LH7")
    sunday_back = flight(SUNDAY, 16, origin="CDG", dest="FRA", arr_h=18,
                         no="LH8")
    report = wm.find_weekends(
        outbound=[flight(FRIDAY, 15, arr_h=17, dest="CDG", no="LH1")],
        returns=[sunday_back, saturday_back],
        weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    option = report.cities[0].options[0]
    assert option.nights == 1
    assert option.back_flight.flight_no == "LH7"


def test_options_per_city_are_capped():
    outs = [flight(FRIDAY, 14 + i, arr_h=17, dest="CDG", no=f"LH1{i}")
            for i in range(6)]
    backs = [flight(SUNDAY, 10 + i, origin="CDG", dest="FRA", arr_h=18,
                    no=f"LH2{i}") for i in range(6)]
    report = wm.find_weekends(outs, backs, WEEKEND, WINDOWS,
                              only_benefit, lookup, max_options_per_city=3)
    assert report.cities[0].count == 3


def test_no_flights_produce_an_empty_report():
    report = wm.find_weekends([], [], WEEKEND, WINDOWS,
                              only_benefit, lookup)
    assert report.city_count == 0
    assert report.one_way_only == []
    assert report.outbound_total == 0


def test_the_rejection_line_names_the_airlines():
    report = wm.find_weekends(
        outbound=[
            flight(FRIDAY, 15, arr_h=17, dest="BCN", no="V1", airline="Vueling"),
            flight(FRIDAY, 16, arr_h=18, dest="CDG", no="W1", airline="Wizz Air"),
        ],
        returns=[], weekend=WEEKEND, windows=WINDOWS,
        benefit_check=only_benefit, city_lookup=lookup)
    text = wm.describe_rule(report.outbound_rejected_airlines)
    assert "Vueling" in text and "Wizz Air" in text
    assert wm.describe_rule({}) == ""


def test_the_windows_describe_themselves_for_the_ui():
    text = WINDOWS.describe()
    assert "Fri from 14:00" in text and "Mon before 09:00" in text
    bounded = wm.Windows(sunday_return_until=time(20, 0)).describe()
    assert "before 20:00" in bounded


# ── time parsing from board feeds ────────────────────────────────────────────

def test_board_times_parse():
    assert wm.parse_flight_time("14:05", FRIDAY) == at(FRIDAY, 14, 5)
    assert wm.parse_flight_time("7:30", FRIDAY) == at(FRIDAY, 7, 30)
    assert wm.parse_flight_time("14:05+1", FRIDAY) == at(SATURDAY, 14, 5)


def test_unparseable_board_times_are_dropped_not_guessed():
    for value in ("", "-", "--", "n/a", "closed", "23:70", "99:00", "abc"):
        assert wm.parse_flight_time(value, FRIDAY) is None, value


if __name__ == "__main__":
    tests = [
        test_a_monday_maps_to_the_coming_friday,
        test_saturday_and_sunday_map_back_to_their_friday,
        test_friday_maps_to_itself_and_tuesday_to_this_week,
        test_the_weekend_days_are_consecutive,
        test_next_friday_skips_today_when_asked_to,
        test_next_friday_respects_a_minimum_lead_time,
        test_friday_outbound_uses_the_lower_bound,
        test_saturday_outbound_uses_an_upper_bound,
        test_thursday_sunday_and_monday_are_never_outbound,
        test_outbound_must_depart_from_frankfurt,
        test_custom_windows_are_honoured,
        test_saturday_return_uses_the_lower_bound,
        test_sunday_return_is_unbounded_by_default,
        test_sunday_return_honours_an_explicit_cutoff,
        test_monday_return_must_land_before_the_cutoff,
        test_a_friday_return_is_not_a_weekend,
        test_return_must_land_in_frankfurt,
        test_nights_are_counted_between_landing_and_taking_off,
        test_a_same_day_trip_is_zero_nights_not_negative,
        test_overnight_arrival_counts_the_next_day,
        test_a_simple_round_trip_produces_one_city,
        test_an_airline_without_benefits_is_filtered_out,
        test_the_operator_carrier_decides_benefits_not_the_marketing_one,
        test_a_city_needing_both_legs_qualifies_only_when_both_do,
        test_two_airports_of_one_city_collapse_into_one_result_row,
        test_an_unmapped_airport_is_reported_not_dropped,
        test_a_return_before_the_outbound_arrival_is_not_paired,
        test_an_overnight_friday_flight_can_be_paired_with_a_saturday_return,
        test_results_are_sorted_by_earliest_departure,
        test_a_sunday_return_is_preferred_over_a_monday_one,
        test_a_saturday_evening_return_is_preferred_over_sunday,
        test_options_per_city_are_capped,
        test_no_flights_produce_an_empty_report,
        test_the_rejection_line_names_the_airlines,
        test_the_windows_describe_themselves_for_the_ui,
        test_board_times_parse,
        test_unparseable_board_times_are_dropped_not_guessed,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")