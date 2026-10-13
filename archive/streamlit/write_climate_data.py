"""
Helper script to write monthly climate data into Destinations.xlsx.

Monthly columns added (60 total):
  Jan High (C) .. Dec High (C)      - avg daily high temperature
  Jan Low (C)  .. Dec Low (C)       - avg daily low temperature (optional)
  Jan Rainy Days .. Dec Rainy Days  - avg rainy days per month
  Jan Rain (mm) .. Dec Rain (mm)    - avg rainfall in mm
  Jan AQI      .. Dec AQI           - avg Air Quality Index

.. note::
   **"Rainy days" now means one thing everywhere: >= 1 mm of daily
   precipitation** (the WMO rain day). The threshold lives in
   ``rainy_days.RAINY_DAY_THRESHOLD_MM`` and both writers import it, so future
   updates are comparable by construction.

   The hardcoded tables below were transcribed from published climate normals
   that count *trace* precipitation, so those rows hold slightly higher
   numbers than a fetch would produce. They are intentionally **not**
   regenerated (that would cost API calls for no immediate gain). The rows
   that would change are listed, without any API call, by::

       python write_climate_data.py --list-legacy-rainy-days

   Use the same command's output as the worklist when you decide to spend the
   calls: every listed destination gets re-fetched by ``aqi_api.py`` under the
   unified definition.

Usage:
    python write_climate_data.py                     # write the curated rows
    python write_climate_data.py --progress         # per-destination fill status
    python write_climate_data.py --list-legacy-rainy-days   # provenance only

Usage:
    from write_climate_data import write_monthly, print_progress

    write_monthly("Bogotá", {
        "Jan High (C)": 19, "Feb High (C)": 19, ...
        "Jan Low (C)": 7, ...
        "Jan Rainy Days": 9, ...
        "Jan Rain (mm)": 30, ...
        "Jan AQI": 55, ...
    })
"""

import argparse
import sys
from pathlib import Path

import openpyxl

import rainy_days
from data_utils import (
    DATA_PATH,
    _find_destination_sheet,
    journal_cell_changes,
    load_workbook_for_update,
    save_workbook_atomic,
)

WORKBOOK = DATA_PATH

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# Annual summary columns (already written for first 15 destinations — keep as-is)
ANNUAL_COLS = [
    "Avg High Temp (°C)",
    "Avg Low Temp (°C)",
    "Avg Rainy Days/Month",
    "Avg Rain (mm/Month)",
    "Avg AQI",
]

# Monthly columns — 60 total
MONTHLY_COLS = (
    [f"{m} High (C)" for m in MONTHS] +
    [f"{m} Low (C)"  for m in MONTHS] +
    [f"{m} Rainy Days" for m in MONTHS] +
    [f"{m} Rain (mm)" for m in MONTHS] +
    [f"{m} AQI"      for m in MONTHS]
)

ALL_CLIMATE_COLS = ANNUAL_COLS + MONTHLY_COLS

#: How many of the 12 months must equal the curated table before a row counts
#: as a *partial* overwrite. Two or three equal months are common by accident
#: (small integers), so a low bar would list almost every destination and teach
#: the user to ignore the report.
PARTIAL_MATCH_MIN = 6

# 2025 monthly aggregates fetched from Open-Meteo for Bogotá (4.7110, -74.0721).
# High/low are means of daily maxima/minima; rain is monthly precipitation sum;
# AQI is the mean of hourly US AQI.
#
# NOTE: this block's rainy days were counted with the pre-2026-10-04 rule
# (>= 0.1 mm). Kept as-is on purpose: the values are not regenerated. Every
# *future* write uses rainy_days.RAINY_DAY_THRESHOLD_MM (1.0 mm) instead. See
# this module's docstring and `--list-legacy-rainy-days`.
BOGOTA_CLIMATE = {
    "Avg High Temp (°C)": 19.6,
    "Avg Low Temp (°C)": 9.5,
    "Avg Rainy Days/Month": 29.1,
    "Avg Rain (mm/Month)": 128.6,
    "Avg AQI": 66.5,
    "Jan High (C)": 21.0, "Feb High (C)": 20.5, "Mar High (C)": 19.8,
    "Apr High (C)": 20.1, "May High (C)": 18.9, "Jun High (C)": 18.5,
    "Jul High (C)": 18.1, "Aug High (C)": 19.0, "Sep High (C)": 19.4,
    "Oct High (C)": 19.4, "Nov High (C)": 20.7, "Dec High (C)": 20.2,
    "Jan Low (C)": 8.1, "Feb Low (C)": 10.3, "Mar Low (C)": 9.8,
    "Apr Low (C)": 10.1, "May Low (C)": 10.1, "Jun Low (C)": 9.3,
    "Jul Low (C)": 9.5, "Aug Low (C)": 8.8, "Sep Low (C)": 8.9,
    "Oct Low (C)": 9.7, "Nov Low (C)": 10.0, "Dec Low (C)": 9.5,
    "Jan Rainy Days": 27, "Feb Rainy Days": 28, "Mar Rainy Days": 30,
    "Apr Rainy Days": 28, "May Rainy Days": 31, "Jun Rainy Days": 29,
    "Jul Rainy Days": 31, "Aug Rainy Days": 29, "Sep Rainy Days": 28,
    "Oct Rainy Days": 31, "Nov Rainy Days": 29, "Dec Rainy Days": 28,
    "Jan Rain (mm)": 92.3, "Feb Rain (mm)": 200.4, "Mar Rain (mm)": 256.6,
    "Apr Rain (mm)": 223.8, "May Rain (mm)": 127.3, "Jun Rain (mm)": 161.9,
    "Jul Rain (mm)": 60.4, "Aug Rain (mm)": 64.8, "Sep Rain (mm)": 71.0,
    "Oct Rain (mm)": 95.4, "Nov Rain (mm)": 124.0, "Dec Rain (mm)": 65.8,
    "Jan AQI": 70.5, "Feb AQI": 79.2, "Mar AQI": 84.0,
    "Apr AQI": 69.5, "May AQI": 62.7, "Jun AQI": 54.8,
    "Jul AQI": 49.9, "Aug AQI": 57.7, "Sep AQI": 61.5,
    "Oct AQI": 67.0, "Nov AQI": 68.3, "Dec AQI": 73.6,
}

# Monthly means of hourly US AQI for 2025, fetched from the Open-Meteo
# historical air-quality endpoint using each city-center coordinate. The
# endpoint reports CAMS global model/reanalysis estimates outside Europe,
# rather than direct local monitoring-station observations.
LAST_SIX_AQI = {
    "Panama City": [39.5, 45.2, 50.3, 44.0, 43.5, 40.1, 43.8, 43.3, 36.5, 30.5, 33.8, 38.0],
    "San José": [31.5, 38.0, 46.9, 42.4, 46.3, 46.5, 43.1, 51.4, 50.6, 48.3, 34.9, 38.0],
    "Yogyakarta": [138.3, 133.9, 147.5, 114.1, 128.8, 133.5, 112.8, 120.0, 119.3, 129.8, 138.9, 131.1],
    "Bishkek": [72.7, 71.3, 65.1, 55.7, 50.4, 60.7, 62.8, 55.2, 55.4, 60.5, 67.7, 68.7],
    "Dubai": [89.4, 100.8, 99.1, 113.1, 114.8, 128.5, 149.5, 149.0, 128.2, 110.6, 109.7, 105.5],
    "Montevideo": [36.7, 42.5, 41.0, 33.9, 38.2, 45.4, 54.3, 42.9, 42.6, 38.4, 41.2, 47.9],
}


#: Curated climate normals for the six destinations whose AQI was preserved
#: from the earlier station-based script. Recovered from
#: ``populate_destination_details.py`` (deleted as broken in 89b777c, which had
#: left this import dangling) and kept here because this module is its only
#: consumer. These values use the pre-2026-10-04 lower threshold; they are
#: provenance, not a recommendation — see the module docstring.
CURATED_CLIMATE = {
    "Panama City": {
        "high": [32.2, 32.7, 33.2, 33.4, 32.4, 31.8, 31.8, 31.9, 31.4, 31.1, 31.1, 31.7],
        "low": [21.4, 21.5, 21.8, 22.6, 22.9, 22.7, 22.6, 22.5, 22.4, 22.2, 22.1, 21.8],
        "rainy_days": [2.4, 1.6, 1.9, 5.2, 15.4, 16.8, 15.1, 16.0, 17.4, 19.5, 16.8, 7.5],
        "rain": [24.1, 12.3, 14.2, 71.0, 221.8, 242.0, 189.5, 221.0, 268.4, 311.2, 258.9, 124.6],
    },
    "San José": {
        "high": [28.2, 29.1, 29.9, 30.3, 28.8, 28.2, 28.2, 28.3, 27.8, 27.1, 27.2, 27.9],
        "low": [18.5, 18.7, 18.8, 19.1, 19.2, 19.0, 19.0, 18.8, 18.3, 18.5, 18.3, 18.3],
        "rainy_days": [3, 3, 5, 10, 23, 22, 20, 22, 26, 25, 17, 8],
        "rain": [6.3, 10.2, 13.8, 79.9, 267.6, 280.1, 181.5, 276.9, 355.1, 330.6, 135.5, 33.5],
    },
    "Yogyakarta": {
        "high": [29.8, 30.5, 31.3, 31.5, 31.1, 31.0, 30.3, 30.7, 31.5, 31.6, 30.9, 30.1],
        "low": [22.9, 22.8, 22.9, 23.0, 22.7, 21.5, 20.6, 20.6, 21.7, 22.7, 23.0, 22.8],
        "rainy_days": [18, 16, 15, 12, 8, 6, 5, 4, 5, 10, 15, 18],
        "rain": [392, 299, 363, 149, 141, 68, 29, 16, 49, 136, 237, 278],
    },
    "Bishkek": {
        "high": [2.9, 5.1, 12.1, 18.7, 24.1, 29.5, 32.4, 31.4, 25.6, 18.5, 10.3, 4.6],
        "low": [-7.1, -4.9, 1.0, 6.9, 11.2, 16.1, 18.4, 16.9, 11.7, 5.6, -0.5, -5.2],
        "rainy_days": [3, 5, 9, 12, 13, 10, 10, 6, 6, 8, 7, 4],
        "rain": [28, 36, 48, 71, 59, 34, 19, 15, 18, 37, 45, 37],
    },
    "Dubai": {
        "high": [24.0, 25.0, 30.0, 34.0, 37.5, 39.9, 41.7, 42.1, 39.5, 36.5, 31.0, 26.0],
        "low": [14.3, 15.5, 18.3, 21.7, 25.1, 26.9, 30.0, 30.4, 27.7, 24.1, 20.1, 16.3],
        "rainy_days": [5.5, 4.7, 5.8, 2.6, 0.3, 0.2, 0.5, 0.5, 0.1, 0.2, 1.3, 3.8],
        "rain": [18.8, 25.0, 22.1, 7.2, 0.4, 0.2, 0.8, 0.2, 0.0, 1.1, 2.7, 16.2],
    },
    "Montevideo": {
        "high": [27.8, 27.0, 25.3, 22.0, 18.5, 15.6, 14.7, 16.7, 17.9, 20.7, 23.7, 26.4],
        "low": [18.8, 18.6, 17.1, 14.1, 11.0, 8.1, 7.3, 8.5, 9.9, 12.4, 14.7, 17.1],
        "rainy_days": [6, 6, 6, 7, 6, 7, 6, 7, 7, 7, 7, 7],
        "rain": [94.6, 93.8, 105.8, 111.1, 83.4, 89.4, 93.2, 89.9, 92.1, 102.2, 95.9, 91.3],
    },
}


def preserved_destination_climate(destination: str) -> dict:
    """Build writer fields from the preserved six-destination climate table."""
    climate = CURATED_CLIMATE[destination]
    data = {}
    for month, high, low, rainy, rain, aqi in zip(
        MONTHS,
        climate["high"],
        climate["low"],
        climate["rainy_days"],
        climate["rain"],
        LAST_SIX_AQI[destination],
    ):
        data[f"{month} High (C)"] = high
        data[f"{month} Low (C)"] = low
        data[f"{month} Rainy Days"] = rainy
        data[f"{month} Rain (mm)"] = rain
        data[f"{month} AQI"] = aqi

    data["Avg High Temp (°C)"] = round(sum(climate["high"]) / 12, 1)
    data["Avg Low Temp (°C)"] = round(sum(climate["low"]) / 12, 1)
    data["Avg Rainy Days/Month"] = round(sum(climate["rainy_days"]) / 12, 1)
    data["Avg Rain (mm/Month)"] = round(sum(climate["rain"]) / 12, 1)
    data["Avg AQI"] = round(sum(LAST_SIX_AQI[destination]) / 12, 1)
    return data


def _get_or_create_headers(ws) -> dict:
    """Return {header_name: 1-based column index}, adding missing climate columns."""
    headers = {cell.value: cell.column for cell in ws[1] if cell.value is not None}
    next_col = ws.max_column + 1

    for col_name in ALL_CLIMATE_COLS:
        if col_name not in headers:
            ws.cell(row=1, column=next_col, value=col_name)
            headers[col_name] = next_col
            next_col += 1
    return headers


def _find_dest_row(ws, destination: str, dest_col_idx: int):
    """Return the row index for the given destination name."""
    for row in ws.iter_rows(min_row=2):
        if row[dest_col_idx - 1].value == destination:
            return row[0].row
    return None


def write_monthly_row(row_idx: int, data: dict, overwrite: bool = False):
    """
    Write monthly (or annual) climate data for a specific 1-based row index.
    """
    sheet = _find_destination_sheet(WORKBOOK)
    if sheet is None:
        print("[ERROR] Could not find the destinations sheet.")
        return
    wb = load_workbook_for_update(WORKBOOK)
    ws = wb[sheet]
    headers = _get_or_create_headers(ws)

    written = 0
    skipped = 0
    journal: dict = {}
    for col_name, value in data.items():
        col_idx = headers.get(col_name)
        if col_idx is None:
            print(f"[WARN] Column not found: {col_name!r}")
            continue
        cell = ws.cell(row=row_idx, column=col_idx)
        if not overwrite and cell.value is not None:
            skipped += 1
            continue
        cell.value = value
        journal[col_name] = value
        written += 1

    dest = ws.cell(row=row_idx, column=1).value   # read BEFORE closing
    save_workbook_atomic(wb, WORKBOOK)
    wb.close()
    if journal:
        journal_cell_changes(str(dest).strip(), journal, WORKBOOK)
    print(f"[OK] Row {row_idx} ({dest}): wrote {written} cells" +
          (f", skipped {skipped} already filled" if skipped else ""))


def write_monthly(destination: str, data: dict, overwrite: bool = False):
    """
    Write monthly (or annual) climate data for one destination.

    Args:
        destination: exact name as in spreadsheet col A
        data: dict mapping column names (from MONTHLY_COLS or ANNUAL_COLS) to values
        overwrite: if False, skip cells that already have a value
    """
    sheet = _find_destination_sheet(WORKBOOK)
    if sheet is None:
        print("[ERROR] Could not find the destinations sheet.")
        return
    wb = load_workbook_for_update(WORKBOOK)
    ws = wb[sheet]
    headers = _get_or_create_headers(ws)

    dest_col_idx = headers.get("Destination")
    if dest_col_idx is None:
        print("[ERROR] No 'Destination' column in the destinations sheet.")
        wb.close()
        return

    # find all matching rows
    matched_rows = []
    for row in ws.iter_rows(min_row=2):
        if row[dest_col_idx - 1].value == destination:
            matched_rows.append(row[0].row)

    if not matched_rows:
        wb.close()
        print(f"[WARN] Destination not found in spreadsheet: {destination!r}")
        return

    written_total = 0
    skipped_total = 0
    journal: dict = {}
    for row_idx in matched_rows:
        written = 0
        skipped = 0
        for col_name, value in data.items():
            col_idx = headers.get(col_name)
            if col_idx is None:
                continue
            cell = ws.cell(row=row_idx, column=col_idx)
            if not overwrite and cell.value is not None:
                skipped += 1
                continue
            cell.value = value
            journal[col_name] = value
            written += 1
        written_total += written
        skipped_total += skipped

    save_workbook_atomic(wb, WORKBOOK)
    wb.close()
    if journal:
        journal_cell_changes(destination.strip(), journal, WORKBOOK)
    print(f"[OK] {destination} ({len(matched_rows)} rows): wrote {written_total} cells" +
          (f", skipped {skipped_total} already filled" if skipped_total else ""))



def print_progress():
    """Print fill status for every destination."""
    wb = openpyxl.load_workbook(WORKBOOK, data_only=True)
    sheet = _find_destination_sheet(WORKBOOK)
    ws = wb[sheet] if sheet else wb.active
    headers = {cell.value: (cell.column - 1)  # 0-indexed for values tuple
               for cell in ws[1] if cell.value is not None}

    monthly_indices = [headers.get(c) for c in MONTHLY_COLS]
    total = len(MONTHLY_COLS)

    print(f"{'Destination':<30} {'Monthly':>10}  {'Annual':>8}")
    print("-" * 55)
    for row in ws.iter_rows(min_row=2, values_only=True):
        dest = row[0]
        if not dest:
            continue
        monthly_filled = sum(
            1 for idx in monthly_indices
            if idx is not None and idx < len(row) and row[idx] is not None
        )
        annual_indices = [headers.get(c) for c in ANNUAL_COLS]
        annual_filled = sum(
            1 for idx in annual_indices
            if idx is not None and idx < len(row) and row[idx] is not None
        )
        pct = int(100 * monthly_filled / total) if total else 0
        print(f"{str(dest):<30} {monthly_filled:>4}/{total}  ({pct:3}%)   {annual_filled}/{len(ANNUAL_COLS)} annual")

    wb.close()


def curated_rainy_day_destinations() -> dict:
    """Every destination whose rainy days came from a curated table.

    Returns ``{destination: source}``. No API call, no workbook write: this is
    pure provenance, read from the hardcoded tables that still live in this
    repo. Those tables use the pre-2026-10-04 lower threshold, so their rows
    are the worklist for making the column uniform under
    ``rainy_days.RAINY_DAY_THRESHOLD_MM``.
    """
    sources: dict[str, str] = {
        name: "write_climate_data.CURATED_CLIMATE"
        for name in CURATED_CLIMATE
    }
    sources["Bogotá"] = "write_climate_data.BOGOTA_CLIMATE"
    try:
        from populate_all_climate import ALL_REMAINING_CLIMATE

        for name in ALL_REMAINING_CLIMATE:
            sources.setdefault(str(name), "populate_all_climate.ALL_REMAINING_CLIMATE")
    except Exception as exc:  # the batch table is optional
        print(f"[WARN] populate_all_climate unavailable: {type(exc).__name__}",
              file=sys.stderr)
    return sources


def list_legacy_rainy_days(path: Path = WORKBOOK) -> dict:
    """Report which rainy-day rows are curated vs canonical. No API calls.

    Returns ``{"curated": [...], "canonical": [...], "review": [...],
    "no_data": [...]}``:

    * ``curated``   - all 12 values still equal a curated table, so the
      pre-2026-10-04 lower-threshold numbers are still in the workbook. This
      is the list to re-fetch to make the column uniform.
    * ``canonical`` - the values no longer match any curated table: fetched
      under the unified definition (or filled by something else entirely).
    * ``review``    - only *some* months match the curated table, which means
      a partial overwrite or a hand edit. A human should look before
      regenerating, because re-fetching would silently discard those edits.
    * ``no_data``   - no rainy-day values at all
    """
    wb = openpyxl.load_workbook(path, data_only=True)
    try:
        sheet = _find_destination_sheet(path)
        ws = wb[sheet] if sheet else wb.active
        headers = {str(c.value).strip(): c.column for c in ws[1]
                   if c.value is not None}
        cols = [headers.get(f"{month} Rainy Days") for month in MONTHS]

        curated_expected = {}
        for destination in CURATED_CLIMATE:
            data = preserved_destination_climate(destination)
            curated_expected[destination] = [
                float(data[f"{month} Rainy Days"]) for month in MONTHS]
        curated_expected["Bogotá"] = [
            float(BOGOTA_CLIMATE[f"{month} Rainy Days"]) for month in MONTHS]
        try:
            from populate_all_climate import ALL_REMAINING_CLIMATE

            for name, climate in ALL_REMAINING_CLIMATE.items():
                curated_expected.setdefault(
                    str(name), [float(v) for v in climate["RainyDays"]])
        except Exception:
            pass

        result = {"curated": [], "canonical": [], "review": [], "no_data": []}
        for row in ws.iter_rows(min_row=2, values_only=True):
            name = row[0]
            if not name:
                continue
            name = str(name).strip()
            values = [row[c - 1] if c and c <= len(row) else None for c in cols]
            if all(v is None for v in values):
                result["no_data"].append(name)
                continue
            expected = curated_expected.get(name)
            if expected is None:
                result["canonical"].append(name)
                continue
            try:
                current = [float(v) if v is not None else None for v in values]
            except (TypeError, ValueError):
                result["review"].append(name)
                continue
            agreeing = sum(
                1 for a, b in zip(current, expected)
                if a is not None and abs(a - b) < 0.05)
            if agreeing == 12:
                result["curated"].append(name)
            elif agreeing >= PARTIAL_MATCH_MIN:
                result["review"].append(
                    f"{name} ({agreeing}/12 months match the curated table)")
            else:
                # 1-2 coincidentally equal months (e.g. both 2) are not evidence
                # of a partial overwrite, so they count as canonical.
                result["canonical"].append(name)
        for key in result:
            result[key] = sorted(set(result[key]))
        return result
    finally:
        wb.close()


def _print_legacy_rainy_days() -> None:
    report = list_legacy_rainy_days()
    print(f'Rainy day = {rainy_days.DEFINITION} (rainy_days.py)')
    print("Provenance of {Mon} Rainy Days - nothing changed, no API call made.\n")
    print(f"Curated, older lower threshold ({len(report['curated'])}): "
          f"still hold pre-unification values")
    for name in report["curated"]:
        print(f"  {name}")
    print(f"\nCanonical ({len(report['canonical'])}): match no curated table")
    print(f"Review ({len(report['review'])}): partly match a curated table - "
          f"a re-fetch would overwrite")
    for name in report["review"]:
        print(f"  {name}")
    print(f"No rainy-day data ({len(report['no_data'])})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Write curated monthly climate rows / report data provenance.")
    parser.add_argument(
        "--list-legacy-rainy-days", action="store_true",
        help="print which {Mon} Rainy Days rows came from the curated "
             "tables (older, lower-threshold definition) and exit; no writes, "
             "no API calls")
    parser.add_argument(
        "--progress", action="store_true",
        help="print the climate fill status per destination")
    args = parser.parse_args()

    if args.list_legacy_rainy_days:
        _print_legacy_rainy_days()
    elif args.progress:
        print_progress()
    else:
        write_monthly("Bogotá", BOGOTA_CLIMATE, overwrite=True)
        for destination in LAST_SIX_AQI:
            write_monthly(destination,
                          preserved_destination_climate(destination),
                          overwrite=True)
        print_progress()
