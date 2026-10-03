"""Filter semantics — a filter may only hide rows whose field is *populated*.

Regression tests for the bug where destinations with a blank safety rating
(Mumbai, Delhi — and every freshly added placeholder) disappeared from the
Overview and the World Map as soon as a slider moved, because the code
compared ``NaN >= minimum`` and read the result as "fails the filter".

Dual-mode: runs under pytest and as ``python tests/test_filters.py``.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import filters  # noqa: E402


def _frame() -> pd.DataFrame:
    """Fixture data with blanks, NaN and text cells mixed in."""
    return pd.DataFrame({
        "Destination": ["Naples", "Mumbai", "Delhi", "Oslo", "Lagos"],
        "Safety": [7.0, None, float("nan"), 9.0, "8/10"],
        "Reviews": [8.1, 7.0, None, "9/10", 6.5],
        "Visited?": [True, False, None, "yes", ""],
        "Yes?": ["False", "No", None, "Yes", "EU"],
        "January": ["ideal", "bad", None, "OK", ""],
        "Continent": ["Europe", "Asia", "Asia", "Europe", "Africa"],
    })


# ── numeric parsing ──────────────────────────────────────────────────────────

def test_coerce_number_reads_common_shapes():
    cases = [
        (8, 8.0), (8.5, 8.5), ("7", 7.0), (" 6 ", 6.0), ("7,5", 7.5),
        ("1,234", 1234.0), ("1,234.56", 1234.56), ("22 °C", 22.0),
        ("8/10", 8.0),          # a rating out of ten is 8, never 810
        ("~12", 12.0), ("-3", -3.0), ("0", 0.0),
    ]
    for raw, expected in cases:
        got = filters.coerce_number(raw)
        assert got == expected, f"{raw!r} -> {got!r}, expected {expected!r}"


def test_coerce_number_returns_none_for_blanks():
    blanks = [None, "", "  ", "—", "-", "n/a", "NA", "nan", "none", "null",
              "TBD", "unknown", float("nan")]
    for raw in blanks:
        assert filters.coerce_number(raw) is None, f"{raw!r} should be blank"


def test_is_blank_matches_the_ui_vocabulary():
    assert filters.is_blank("") and filters.is_blank("N/A") and filters.is_blank("—")
    assert not filters.is_blank("0") and not filters.is_blank(0)
    assert not filters.is_blank(0.0)


# ── "only populated rows may be filtered out" ────────────────────────────────

def test_blank_safety_survives_the_highest_slider_value():
    filtered = filters.apply_numeric_minimum(_frame(), "Safety", 10.0)
    names = set(filtered["Destination"])
    assert "Naples" not in names        # 7.0  < 10  -> hidden
    assert "Oslo" not in names          # 9.0  < 10  -> hidden
    assert "Lagos" not in names         # "8/10" -> 8 -> hidden
    assert "Mumbai" in names           # blank    -> kept
    assert "Delhi" in names            # NaN      -> kept


def test_populated_values_are_still_filtered():
    filtered = filters.apply_numeric_minimum(_frame(), "Safety", 7.0)
    assert set(filtered["Destination"]) == {"Naples", "Mumbai", "Delhi",
                                           "Oslo", "Lagos"}


def test_raising_the_threshold_only_removes_rows_that_fail_it():
    frame = _frame()
    assert len(filters.apply_numeric_minimum(frame, "Safety", 0.0)) == 5
    high = filters.apply_numeric_minimum(frame, "Safety", 9.0)
    assert set(high["Destination"]) == {"Mumbai", "Delhi", "Oslo"}


def test_blank_review_score_is_not_treated_as_zero():
    filtered = filters.apply_numeric_minimum(_frame(), "Reviews", 8.0)
    names = set(filtered["Destination"])
    assert "Delhi" in names             # blank  -> kept
    assert "Naples" in names            # 8.1    -> kept
    assert "Oslo" in names              # "9/10" -> 9 -> kept
    assert "Lagos" not in names         # 6.5    -> hidden


def test_blank_month_is_not_treated_as_bad_weather():
    frame = _frame()
    at_least_ok = filters.apply_month_quality(frame, "January")
    # "bad" (Mumbai) is the only value that fails; the blank month (Lagos) and
    # the blank cell (Delhi) stay visible.
    assert set(at_least_ok["Destination"]) == {"Naples", "Delhi", "Oslo", "Lagos"}
    good_only = filters.apply_month_quality(frame, "January",
                                            allowed=filters.WEATHER_GOOD_ONLY)
    # "bad" (Mumbai), "OK" (Oslo) fail; "ideal" and the two blanks stay.
    assert set(good_only["Destination"]) == {"Naples", "Delhi", "Lagos"}


def test_blank_eu_value_is_kept_by_the_eu_filter():
    names = set(filters.apply_eu(_frame(), "Yes?", "Yes")["Destination"])
    assert "Oslo" in names              # "Yes"
    assert "Mumbai" not in names        # "No"
    assert "Delhi" in names             # blank -> kept
    assert "Lagos" in names             # "EU"


def test_blank_research_value_is_kept_by_a_yes_filter():
    frame = pd.DataFrame({"Destination": ["A", "B", "C"],
                          "To be researched": [True, False, None]})
    only_yes = filters.apply_category(
        frame, "To be researched", "Yes",
        positives=frozenset({"true", "yes", "x", "1"}),
        negatives=frozenset({"false", "no", "0"}))
    assert set(only_yes["Destination"]) == {"A", "C"}


def test_unvisited_filter_hides_only_visited():
    frame = _frame()
    unvisited = filters.apply_unvisited(frame, "Visited?", only_unvisited=True)
    # Naples is explicitly True and "yes" (Oslo) counts as visited; blanks and
    # False are unvisited and stay.
    assert set(unvisited["Destination"]) == {"Mumbai", "Delhi", "Lagos"}
    assert filters.apply_unvisited(frame, "Visited?", False).equals(frame)


def test_unknown_or_missing_column_is_a_no_op():
    frame = _frame()
    for column in (None, "does-not-exist"):
        assert filters.apply_numeric_minimum(frame, column, 9).equals(frame)
        assert filters.apply_numeric_maximum(frame, column, 1).equals(frame)
        assert filters.apply_month_quality(frame, column).equals(frame)
        assert filters.apply_eu(frame, column, "Yes").equals(frame)
        assert filters.apply_unvisited(frame, column, True).equals(frame)
        assert filters.apply_category(frame, column, "Yes",
                                      frozenset({"true"}), frozenset({"false"})).equals(frame)


def test_apply_text_equals_is_case_insensitive():
    frame = _frame()
    assert set(filters.apply_text_equals(frame, "Continent", "europe")["Destination"]) == \
        {"Naples", "Oslo"}
    assert filters.apply_text_equals(frame, "Continent", "All").equals(frame)


def test_missing_value_count():
    assert filters.missing_value_count(_frame(), "Safety") == 2   # None + NaN
    assert filters.missing_value_count(_frame(), "Nope") == 0


# ── slider bounds ────────────────────────────────────────────────────────────

def test_numeric_bounds_never_collapses():
    low, high = filters.numeric_bounds(["5", "5", "5"])
    assert low < high


def test_numeric_bounds_ignores_blanks_and_junk():
    assert filters.numeric_bounds(["8/10", "n/a", None, "6"]) == (6.0, 8.0)


def test_numeric_bounds_defaults_when_column_is_empty():
    assert filters.numeric_bounds([]) == (0.0, 10.0)
    assert filters.numeric_bounds([], default=(0.0, 5.0), top=5.0) == (0.0, 5.0)


def test_numeric_bounds_caps_at_the_scale_maximum():
    assert filters.numeric_bounds([12.0], top=10.0)[1] <= 10.0


def test_apply_numeric_maximum_keeps_blanks():
    frame = _frame()
    capped = filters.apply_numeric_maximum(frame, "Safety", 7.0)
    # Oslo (9.0) and Lagos ("8/10" -> 8.0) exceed the cap; blanks stay.
    assert set(capped["Destination"]) == {"Naples", "Mumbai", "Delhi"}


def main() -> int:
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    failed = 0
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            failed += 1
            print(f"FAIL {test.__name__}: {exc}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"ERROR {test.__name__}: {type(exc).__name__}: {exc}")
        else:
            print(f"PASS {test.__name__}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
