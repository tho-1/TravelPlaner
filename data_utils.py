from __future__ import annotations

import re
from pathlib import Path
from typing import Optional, Tuple

import openpyxl
import pandas as pd
import streamlit as st


DATA_PATH = Path(__file__).resolve().parent / "Destinations.xlsx"


def normalize_text(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value).strip().lower())


def find_column(columns, aliases) -> Optional[str]:
    normalized_aliases = [normalize_text(alias) for alias in aliases]
    for column in columns:
        if normalize_text(column) in normalized_aliases:
            return column
    for column in columns:
        normalized = normalize_text(column)
        if any(alias in normalized for alias in normalized_aliases):
            return column
    for column in columns:
        normalized = normalize_text(column)
        for alias in normalized_aliases:
            if alias in normalized or normalized in alias:
                return column
    return None


def parse_numeric(series: pd.Series) -> pd.Series:
    cleaned = series.astype(str).str.replace(r"[^0-9,.-]", "", regex=True)
    cleaned = cleaned.replace("", pd.NA)
    cleaned = cleaned.str.replace(",", "", regex=False)
    return pd.to_numeric(cleaned, errors="coerce")


def classify_bool(series: pd.Series) -> pd.Series:
    result = []
    for value in series:
        if pd.isna(value):
            result.append(pd.NA)
            continue
        text = str(value).strip().lower().rstrip(",.").strip()
        if text in {"yes", "y", "true", "1", "ja", "j", "x"} or "x" in text:
            result.append(True)
        elif text in {"no", "n", "false", "0", "nein"}:
            result.append(False)
        else:
            result.append(pd.NA)
    return pd.Series(result, dtype="object")


def discover_destination_sheet(path: Path) -> pd.DataFrame:
    excel_file = pd.ExcelFile(path, engine="openpyxl")
    for sheet_name in excel_file.sheet_names:
        try:
            df = pd.read_excel(path, sheet_name=sheet_name, engine="openpyxl")
        except Exception:
            continue
        if df is None or df.empty:
            continue
        columns = [str(col) for col in df.columns]
        if not columns:
            continue
        if any(
            keyword in " ".join(columns).lower()
            for keyword in ["destination", "continent", "safety", "cost", "flight", "population", "month"]
        ):
            return df
    return pd.read_excel(path, engine="openpyxl")


@st.cache_data(show_spinner=False)
def load_destinations(path: Path = DATA_PATH) -> Tuple[pd.DataFrame, dict]:
    df = discover_destination_sheet(path)
    df = df.copy()
    df.columns = [str(col) for col in df.columns]

    destination_col = find_column(df.columns, ["destination", "destinations", "city", "place", "name"])
    country_col = find_column(df.columns, ["country", "land", "nation", "state"])
    continent_col = find_column(df.columns, ["continent", "region"])
    eu_col = find_column(df.columns, ["eu", "eu?", "europeanunion", "in europe", "yes", "yes?"])
    if eu_col is None:
        # Some workbooks use a column header like "Yes?" for EU membership.
        for col in df.columns:
            if normalize_text(str(col)) in {"yes", "yes?", "yesquestion"}:
                eu_col = col
                break
    nearer_col = find_column(df.columns, ["näherer", "auswahl", "nahe", "nearer", "selection"])
    safety_col = find_column(df.columns, ["safety", "safetyrating", "security", "risk"])
    cost_col = find_column(df.columns, ["costday", "costperday", "dailycost", "cost", "costday"])
    flight_col = find_column(df.columns, ["flighttime", "flight", "tofra", "travel", "duration"])
    population_col = find_column(df.columns, ["population", "inhabitants", "inhabitant"])
    reviews_col = find_column(df.columns, ["reviews", "reviewcount", "review score"])
    prio_col = find_column(df.columns, ["prio thorsten", "prio", "thorsten"])
    visa_requirement_col = find_column(df.columns, ["visa requirement", "visarequirement", "visareq"])
    highlights_col = find_column(df.columns, ["highlights", "whygo", "notes", "pros", "bestfor"])
    intro_col = find_column(df.columns, ["introduction sentence", "introduction", "intro sentence", "intro"])
    why_col = find_column(df.columns, ["why to go there", "why go there", "whytogothere", "whygo"])
    expect_col = find_column(df.columns, ["what to expect", "whattoexpect", "expectations", "expect"])
    tourist_reviews_col = find_column(df.columns, ["tourist reviews", "tourist review", "touristreviews", "touristreview"])

    if destination_col is None:
        destination_col = df.columns[0]
    if continent_col is None:
        continent_col = df.columns[1] if len(df.columns) > 1 else destination_col

    if cost_col:
        df[cost_col] = parse_numeric(df[cost_col])
    if flight_col:
        df[flight_col] = parse_numeric(df[flight_col])
    if safety_col:
        df[safety_col] = parse_numeric(df[safety_col])
    if population_col:
        df[population_col] = parse_numeric(df[population_col])
    if eu_col:
        df[eu_col] = classify_bool(df[eu_col])
    if nearer_col:
        df[nearer_col] = classify_bool(df[nearer_col])

    _month_names = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
    ]
    _climate_tokens = ["high", "low", "rain", "aqi", "temp", "day", "days", "cost", "prio", "mm"]

    month_columns = [
        col for col in df.columns
        if any(normalize_text(col) == m or normalize_text(col).startswith(m) for m in _month_names)
        and not any(token in normalize_text(col) for token in _climate_tokens)
    ]
    metadata = {
        "destination_col": destination_col,
        "country_col": country_col,
        "continent_col": continent_col,
        "eu_col": eu_col,
        "nearer_col": nearer_col,
        "safety_col": safety_col,
        "cost_col": cost_col,
        "flight_col": flight_col,
        "population_col": population_col,
        "reviews_col": reviews_col,
        "prio_col": prio_col,
        "visa_requirement_col": visa_requirement_col,
        "highlights_col": highlights_col,
        "intro_col": intro_col,
        "why_col": why_col,
        "expect_col": expect_col,
        "tourist_reviews_col": tourist_reviews_col,
        "month_columns": month_columns,
    }
    return df, metadata


def _find_destination_sheet(path: Path) -> Optional[str]:
    """Return the name of the sheet that contains the destination data."""
    excel_file = pd.ExcelFile(path, engine="openpyxl")
    for sheet_name in excel_file.sheet_names:
        try:
            df = pd.read_excel(path, sheet_name=sheet_name, engine="openpyxl", nrows=0)
        except Exception:
            continue
        columns = [str(col) for col in df.columns]
        if any(
            keyword in " ".join(columns).lower()
            for keyword in ["destination", "continent", "safety", "cost", "flight", "population", "month"]
        ):
            return sheet_name
    return None


def update_favorite_status(destination_name: str, add: bool, path: Path = DATA_PATH) -> None:
    """Set or clear the 'In nähererer Auswahl 2025?' cell for a destination.

    Uses openpyxl to modify the cell in-place so that formatting,
    formulas, and other sheets in the workbook are preserved.
    """
    sheet_name = _find_destination_sheet(path)
    if sheet_name is None:
        return

    wb = openpyxl.load_workbook(path)
    ws = wb[sheet_name]

    # Build a header map: column name -> 1-based column index
    headers = {}
    for col_idx in range(1, ws.max_column + 1):
        cell_value = ws.cell(row=1, column=col_idx).value
        if cell_value is not None:
            headers[str(cell_value)] = col_idx

    # Find the destination column and nearer column by fuzzy matching
    dest_col_idx = None
    nearer_col_idx = None
    for header_name, col_idx in headers.items():
        lower = header_name.lower()
        if dest_col_idx is None and "destination" in lower:
            dest_col_idx = col_idx
        if nearer_col_idx is None and "auswahl" in lower:
            nearer_col_idx = col_idx

    if dest_col_idx is None or nearer_col_idx is None:
        wb.close()
        return

    # Find the row for this destination
    target_row = None
    for row_idx in range(2, ws.max_row + 1):
        cell_value = ws.cell(row=row_idx, column=dest_col_idx).value
        if cell_value is not None and str(cell_value).strip().lower() == destination_name.strip().lower():
            target_row = row_idx
            break

    if target_row is None:
        wb.close()
        return

    # Write "x" or clear the cell
    ws.cell(row=target_row, column=nearer_col_idx).value = "x" if add else None
    wb.save(path)
    wb.close()

    # Clear the cached data so the app picks up the change
    load_destinations.clear()


def update_prio_thorsten(destination_name: str, value: int, path: Path = DATA_PATH) -> None:
    """Update the Prio Thorsten value for a destination in the workbook."""
    sheet_name = _find_destination_sheet(path)
    if sheet_name is None:
        return

    wb = openpyxl.load_workbook(path)
    ws = wb[sheet_name]

    headers = {}
    for col_idx in range(1, ws.max_column + 1):
        cell_value = ws.cell(row=1, column=col_idx).value
        if cell_value is not None:
            headers[str(cell_value)] = col_idx

    dest_col_idx = None
    prio_col_idx = None
    for header_name, col_idx in headers.items():
        lower = header_name.strip().lower()
        if dest_col_idx is None and "destination" in lower:
            dest_col_idx = col_idx
        if prio_col_idx is None and ("prio" in lower and "thorsten" in lower or lower == "prio thorsten" or "thorsten" in lower):
            prio_col_idx = col_idx

    if dest_col_idx is None or prio_col_idx is None:
        wb.close()
        return

    target_row = None
    for row_idx in range(2, ws.max_row + 1):
        cell_value = ws.cell(row=row_idx, column=dest_col_idx).value
        if cell_value is not None and str(cell_value).strip().lower() == destination_name.strip().lower():
            target_row = row_idx
            break

    if target_row is None:
        wb.close()
        return

    ws.cell(row=target_row, column=prio_col_idx).value = int(value)
    wb.save(path)
    wb.close()

    load_destinations.clear()


def get_selected_destination(df: pd.DataFrame, metadata: dict, fallback: Optional[str] = None) -> Optional[pd.Series]:
    destination_col = metadata["destination_col"]
    selected_name = st.session_state.get("selected_destination")
    if not selected_name:
        selected_name = fallback
    if not selected_name:
        return None
    matches = df[df[destination_col].astype(str).str.strip().str.lower() == str(selected_name).strip().lower()]
    if matches.empty:
        return None
    return matches.iloc[0]


def add_new_destination(
    destination_name: str,
    country: str = "Unknown",
    continent: str = "Unknown",
    path: Path = DATA_PATH
) -> Tuple[bool, str]:
    """
    Append a new destination to the Excel workbook with placeholder values.
    Returns (success: bool, message: str).
    """
    dest_clean = destination_name.strip()
    if not dest_clean:
        return False, "Destination name cannot be empty."

    sheet_name = _find_destination_sheet(path)
    if sheet_name is None:
        return False, "Could not find destination sheet in workbook."

    wb = openpyxl.load_workbook(path)
    ws = wb[sheet_name]

    # Header lookup
    headers = {}
    for col_idx in range(1, ws.max_column + 1):
        cell_value = ws.cell(row=1, column=col_idx).value
        if cell_value is not None:
            headers[str(cell_value)] = col_idx

    # Check for destination column
    dest_col_idx = 1
    for h, col_idx in headers.items():
        if "destination" in h.lower():
            dest_col_idx = col_idx
            break

    # Check for existing destination
    for row_idx in range(2, ws.max_row + 1):
        val = ws.cell(row=row_idx, column=dest_col_idx).value
        if val is not None and str(val).strip().lower() == dest_clean.lower():
            wb.close()
            return False, f"Destination '{dest_clean}' already exists in the workbook (Row {row_idx})."

    # Determine next empty row
    new_row_idx = ws.max_row + 1

    # Populate destination, country, continent
    ws.cell(row=new_row_idx, column=dest_col_idx, value=dest_clean)

    for h, col_idx in headers.items():
        h_lower = h.lower()
        if "country" in h_lower:
            ws.cell(row=new_row_idx, column=col_idx, value=country.strip() or "Unknown")
        elif "continent" in h_lower:
            ws.cell(row=new_row_idx, column=col_idx, value=continent.strip() or "Unknown")
        elif h in [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]:
            ws.cell(row=new_row_idx, column=col_idx, value="ok")
        elif h == "Rent a Car?":
            ws.cell(row=new_row_idx, column=col_idx, value="No")
        elif h == "Yes?":
            ws.cell(row=new_row_idx, column=col_idx, value="No")
        elif h == "Safety Rating (10 = safest)":
            ws.cell(row=new_row_idx, column=col_idx, value=5)
        elif h == "Prio Thorsten":
            ws.cell(row=new_row_idx, column=col_idx, value=0)
        elif h == "Avg. Cost/Day (3* Hotel & Food)":
            ws.cell(row=new_row_idx, column=col_idx, value=50)
        elif h == "Recommended Stay":
            ws.cell(row=new_row_idx, column=col_idx, value="3-5 days")
        elif h == "Why to Go There":
            ws.cell(row=new_row_idx, column=col_idx, value=f"To explore the sights, culture, and cuisine of {dest_clean}.")
        elif h == "What to Expect":
            ws.cell(row=new_row_idx, column=col_idx, value="Cultural landmarks, local neighborhoods, and diverse attractions.")
        elif h == "Introduction Sentence":
            ws.cell(row=new_row_idx, column=col_idx, value=f"{dest_clean} is an exciting destination in {country.strip() or 'the world'} offering rich cultural experiences.")
        elif h == "Highlights":
            ws.cell(row=new_row_idx, column=col_idx, value=f"Historic city center, local markets, and scenic surroundings of {dest_clean}.")
        elif h == "Tourist Reviews":
            ws.cell(row=new_row_idx, column=col_idx, value=f"Travelers appreciate {dest_clean} for its unique atmosphere, friendly locals, and sightseeing opportunities.")
        elif h == "What do the reviews praise?":
            ws.cell(row=new_row_idx, column=col_idx, value="Atmosphere, sights, and friendly locals.")
        elif h == "What do they dislike?":
            ws.cell(row=new_row_idx, column=col_idx, value="Peak season crowds and transit navigation.")

    wb.save(path)
    wb.close()

    # Clear cached dataframe so it immediately reloads all rows on next run
    load_destinations.clear()
    return True, f"Destination '{dest_clean}' has been successfully added to the catalog!"

