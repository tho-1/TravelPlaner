"""
Helper script to write monthly climate data into Destinations.xlsx.

Monthly columns added (60 total):
  Jan High (C) .. Dec High (C)      - avg daily high temperature
  Jan Low (C)  .. Dec Low (C)       - avg daily low temperature (optional)
  Jan Rainy Days .. Dec Rainy Days  - avg rainy days per month
  Jan Rain (mm) .. Dec Rain (mm)    - avg rainfall in mm
  Jan AQI      .. Dec AQI           - avg Air Quality Index

Usage:
    from write_climate_data import write_monthly, print_progress

    write_monthly("Bogota", {
        "Jan High (C)": 19, "Feb High (C)": 19, ...
        "Jan Low (C)": 7, ...
        "Jan Rainy Days": 9, ...
        "Jan Rain (mm)": 30, ...
        "Jan AQI": 55, ...
    })
"""
import openpyxl
from pathlib import Path

WORKBOOK = Path(r"c:\Users\Thors\OneDrive\Documents\Gemini - Travel Planner\Destinations.xlsx")

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
    wb = openpyxl.load_workbook(WORKBOOK)
    ws = wb.active
    headers = _get_or_create_headers(ws)

    written = 0
    skipped = 0
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
        written += 1

    wb.save(WORKBOOK)
    wb.close()
    dest = ws.cell(row=row_idx, column=1).value
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
    wb = openpyxl.load_workbook(WORKBOOK)
    ws = wb.active
    headers = _get_or_create_headers(ws)

    dest_col_idx = headers.get("Destination")
    if dest_col_idx is None:
        dest_col_idx = 1

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
            written += 1
        written_total += written
        skipped_total += skipped

    wb.save(WORKBOOK)
    wb.close()
    print(f"[OK] {destination} ({len(matched_rows)} rows): wrote {written_total} cells" +
          (f", skipped {skipped_total} already filled" if skipped_total else ""))



def print_progress():
    """Print fill status for every destination."""
    wb = openpyxl.load_workbook(WORKBOOK, data_only=True)
    ws = wb.active
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


if __name__ == "__main__":
    print_progress()
