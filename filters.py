"""Shared, testable filter helpers for the Overview and World Map pages.

Two rules that used to be implemented (differently) inside both pages and
caused real data loss in the UI:

1. **A filter may only remove a row when the field it filters on is
   populated.** A destination with no safety rating must not disappear just
   because the safety slider sits at 3.5 — that silently hid destinations
   (Mumbai, Delhi) and *every freshly added placeholder*.
2. **The vocabulary for "good month" is defined once.** Overview, World Map
   and the itinerary planner previously used three different rules, so a
   month could be "ideal" on one page and "unknown" on another.

All functions are pure (DataFrame in -> DataFrame out) and Streamlit-free so
they can be unit-tested headlessly.
"""

from __future__ import annotations

import re

import pandas as pd

#: First numeric token in a cell ("8/10" -> 8, "22 °C" -> 22, "1,234" -> 1234).
_NUMBER_RE = re.compile(r"[-+]?\d[\d.,]*")

#: "Weather at least ok in" — used by the Overview / World Map month filter.
WEATHER_AT_LEAST_OK = frozenset({
    "ideal", "good", "great", "best", "green", "ok", "okay", "medium", "yellow",
})

#: "The workbook says this month is a good month to visit" — used by the
#: itinerary planner's month suggestions (``itinerary.suggested_months``).
WEATHER_GOOD_ONLY = frozenset({"ideal", "good", "great", "best", "green"})

#: Values that mean "the cell is empty / not filled in yet".
BLANK_TOKENS = frozenset({"", "-", "--", "—", "n/a", "na", "nan", "none",
                          "null", "?", "unknown", "tbd", "tbd?"})


def is_blank(value: object) -> bool:
    """True when a cell carries no usable value."""
    if value is None:
        return True
    try:
        if pd.isna(value):
            return True
    except (TypeError, ValueError):
        pass
    return str(value).strip().lower() in BLANK_TOKENS


def coerce_number(value: object) -> float | None:
    """Parse a numeric cell, tolerating "8", "8.0", "8,5", " 7 ", "22 °C", "8/10".

    Returns None for blanks and for anything that holds no number at all, so
    callers can distinguish "no data" from zero. Only the *first* number in a
    string is read, so "8/10" is 8 (a rating out of ten) and never 810.
    """
    if is_blank(value):
        return None
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    match = _NUMBER_RE.search(str(value))
    if not match:
        return None
    token = match.group(0)
    if "," in token and "." in token:
        # 1,234.56 -> thousands separator is a comma
        token = token.replace(",", "")
    elif "," in token:
        # 1,234 -> thousands; 8,5 -> decimal comma
        head, _, tail = token.partition(",")
        token = token.replace(",", "") if len(tail) == 3 and head.lstrip("+-").isdigit() \
            else token.replace(",", ".")
    try:
        return float(token)
    except ValueError:
        return None


def _column(frame: pd.DataFrame, column: str | None) -> bool:
    return bool(column) and column in frame.columns


def apply_numeric_minimum(frame: pd.DataFrame, column: str | None,
                          minimum: float) -> pd.DataFrame:
    """Keep rows whose value is >= ``minimum`` **or whose value is blank**.

    Blank cells are never treated as a failing value: a destination that has
    not been rated yet stays visible (flagged in the UI instead).
    """
    if not _column(frame, column):
        return frame
    values = [coerce_number(v) for v in frame[column]]
    keep = [v is None or v >= minimum for v in values]
    return frame[pd.Series(keep, index=frame.index)]


def apply_numeric_maximum(frame: pd.DataFrame, column: str | None,
                          maximum: float) -> pd.DataFrame:
    """Inverse of :func:`apply_numeric_minimum` (blank cells are kept)."""
    if not _column(frame, column):
        return frame
    values = [coerce_number(v) for v in frame[column]]
    keep = [v is None or v <= maximum for v in values]
    return frame[pd.Series(keep, index=frame.index)]


def apply_month_quality(frame: pd.DataFrame, column: str | None,
                        allowed: frozenset[str] = WEATHER_AT_LEAST_OK) -> pd.DataFrame:
    """Keep rows whose month cell is one of ``allowed`` **or is blank**.

    A month that was never filled in is not evidence of bad weather, so it is
    shown rather than hidden.
    """
    if not _column(frame, column):
        return frame
    keep = []
    for value in frame[column]:
        if is_blank(value):
            keep.append(True)
            continue
        keep.append(str(value).strip().casefold() in allowed)
    return frame[pd.Series(keep, index=frame.index)]


def apply_category(frame: pd.DataFrame, column: str | None,
                   wanted: str | None, positives: frozenset[str],
                   negatives: frozenset[str]) -> pd.DataFrame:
    """Filter a Yes/No column; blank cells are always kept.

    ``wanted`` is compared case-insensitively: the pages pass the selectbox
    label ("Yes"), while the cell values are lower-cased.
    """
    if not wanted or wanted.strip().casefold() == "all" or not _column(frame, column):
        return frame
    want_yes = wanted.strip().casefold() == "yes"
    keep = []
    for value in frame[column]:
        if is_blank(value):
            keep.append(True)
            continue
        text = str(value).strip().casefold()
        if text in positives:
            keep.append(want_yes)
        elif text in negatives:
            keep.append(not want_yes)
        else:
            keep.append(True)
    return frame[pd.Series(keep, index=frame.index)]


EU_POSITIVE = frozenset({"true", "yes", "ja", "y", "1", "1.0", "eu",
                         "european union"})
EU_NEGATIVE = frozenset({"false", "no", "nein", "n", "0", "0.0", "non-eu"})


def apply_eu(frame: pd.DataFrame, column: str | None,
             wanted: str) -> pd.DataFrame:
    return apply_category(frame, column, wanted, EU_POSITIVE, EU_NEGATIVE)


def apply_unvisited(frame: pd.DataFrame, column: str | None,
                    only_unvisited: bool) -> pd.DataFrame:
    """Hide destinations already visited. A blank cell counts as *not*
    visited (the pre-rating default), so nothing is hidden by accident."""
    if not only_unvisited or not _column(frame, column):
        return frame
    keep = []
    for value in frame[column]:
        if is_blank(value):
            keep.append(True)
            continue
        if isinstance(value, bool):
            keep.append(not value)
            continue
        text = str(value).strip().casefold()
        if text in {"true", "yes", "y", "1", "1.0", "ja", "j", "x"}:
            keep.append(False)
        else:
            keep.append(True)
    return frame[pd.Series(keep, index=frame.index)]


def missing_value_count(frame: pd.DataFrame, column: str | None) -> int:
    """How many rows have no value for ``column`` (for the UI caption)."""
    if not _column(frame, column):
        return 0
    return sum(1 for v in frame[column] if is_blank(v))


def numeric_bounds(values, default: tuple[float, float] = (0.0, 10.0),
                   *, top: float = 10.0) -> tuple[float, float]:
    """Slider bounds for a column, tolerant of blanks and junk values.

    Guarantees ``min < max`` (Streamlit's slider rejects equal bounds) and
    never returns NaN, which previously crashed the filter panels whenever a
    cell held text such as ``"8/10"``.
    """
    numbers = [n for n in (coerce_number(v) for v in values) if n is not None]
    if not numbers:
        low, high = default
    else:
        low, high = min(numbers), max(numbers)
    # Keep both bounds inside the scale so the slider never offers a rating
    # above the maximum, then guarantee a usable (min < max) range.
    low = min(max(0.0, float(low)), float(top))
    high = min(max(float(high), float(low)), float(top))
    if high <= low:
        high = min(float(top), low + 1.0)
        if high <= low:
            low = max(0.0, float(top) - 1.0)
    return low, high


def apply_text_equals(frame: pd.DataFrame, column: str | None,
                      wanted: str) -> pd.DataFrame:
    """Case-insensitive equality filter used for continent/country."""
    if not wanted or wanted == "All" or not _column(frame, column):
        return frame
    values = frame[column].astype(str).str.strip().str.casefold()
    return frame[values == wanted.strip().casefold()]
