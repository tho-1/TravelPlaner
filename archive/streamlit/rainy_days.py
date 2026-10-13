"""One definition of "rainy day" for the whole project.

Why this module exists
----------------------
``{Mon} Rainy Days`` is written into the workbook by two independent paths:

* ``aqi_api.py`` counts a **WMO rain day**: daily precipitation >= 1 mm,
  computed from ERA5/Open-Meteo climate normals.
* ``write_climate_data.py`` wrote hardcoded tables transcribed from published
  climate normals, which use a *lower* threshold (they count trace
  precipitation).

So the same column could hold two different meanings, and comparing a curated
row against a fetched one compared 0.1 mm days with 1 mm days.

Decision (2026-10-04): **1.0 mm is the definition for everything written from
now on.** The existing curated numbers are deliberately *not* regenerated — that
would mean re-fetching climate data for those rows, which the user declined.
The affected rows are listed by::

    python write_climate_data.py --list-legacy-rainy-days

so the column can be made uniform later, deliberately and cheaply, whenever
someone wants to spend the API calls.

Nothing else in the app should hardcode a precipitation threshold; import
``RAINY_DAY_THRESHOLD_MM`` from here instead.
"""

from __future__ import annotations

#: A day counts as rainy when its total precipitation is >= this many mm.
#: WMO "rain day" convention.
RAINY_DAY_THRESHOLD_MM = 1.0

#: Human-readable form, used in docs and CLI output.
DEFINITION = f"daily precipitation >= {RAINY_DAY_THRESHOLD_MM:g} mm (WMO rain day)"


def is_rain_day(daily_precipitation_mm: float | None) -> bool:
    """True when a day's precipitation reaches the canonical threshold.

    ``None`` and empty cells are not rain days: an unfilled cell must never
    inflate a count.
    """
    if daily_precipitation_mm is None or daily_precipitation_mm == "":
        return False
    try:
        return float(daily_precipitation_mm) >= RAINY_DAY_THRESHOLD_MM
    except (TypeError, ValueError):
        return False


def count_rain_days(values) -> int:
    """Count the rain days in an iterable of daily precipitation totals."""
    return sum(1 for value in values if is_rain_day(value))