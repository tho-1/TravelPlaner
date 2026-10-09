"""Turso-backed storage for the Travel Planner.

Implements the project's data-access contract over the
``travel-tz123`` Turso database (see ``turso_db.py``):

* **Writers return True/False.** ``False`` means "nothing was
  written" -- surface it, never report it as success.
* Writes are batched into a single pipeline request so a
  trip (trip + variants + stops + legs) is written atomically.
* **Last-write-wins** (the user's decision, 2026-10-08): every
  row carries ``updated_at`` (UTC ISO). There is no conflict
  list -- a simultaneous edit on two devices keeps the later
  one. This is the trade-off the user accepted.

The destination row keeps a **typed core** (the fields the app
filters/sorts/searches on) plus a lossless ``data`` JSON tail
holding every workbook column as an ordered ``[name, value]``
array. The workbook has 145 columns including duplicate names
and object-typed cells, so a flat typed table would be brittle
and would drop data; the tail preserves it exactly and lets the
detail page render any column without a schema change.

This module is Streamlit-free and pure (data in -> data out),
so it is unit-testable against a local SQLite file with no
network or credentials (see ``tests/test_storage_turso.py``).
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

import turso_db

# Workbook column -> typed-core field. These are the fields the
# app filters, sorts, or searches on; everything else lives in
# the lossless JSON tail.
CORE_COLUMNS = {
    "destination": "Destination",
    "continent": "Continent",
    "country": "Country",
    "visited": "Visited?",
    "favourite": "In n\u00e4herer Auswahl 2025?",
    "prio": "Prio Thorsten",
    "safety_rating": "Safety Rating (10 = safest)",
    "avg_cost_day": "Avg. Cost/Day (3* Hotel & Food)",
    "flight_time_fra": "Flight Time to Frankfurt (hours)",
    "to_be_researched": "To be researched",
    "malaria_risk": "Malaria risk?",
    "data_status": "Data Status",
    "comment": "Comment",
}

# The typed-core fields that are booleans in the workbook
# (True / "x" / "yes" / ...). Stored as 0/1.
BOOL_FIELDS = ("visited", "favourite", "to_be_researched",
               "malaria_risk")

# The typed-core fields that are numbers.
NUM_FIELDS = ("safety_rating", "avg_cost_day", "flight_time_fra")


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _truthy(value: object) -> int:
    """The app's truthiness convention, as 0/1.

    Mirrors ``data_utils.to_be_researched_mask``: True / 1 /
    "x" / "yes" / "y" / "ja" / "j", or any string containing
    an "x", counts as yes.
    """
    if value is None:
        return 0
    if isinstance(value, bool):
        return 1 if value else 0
    if isinstance(value, (int, float)):
        return 1 if value == 1 else 0
    text = str(value).strip().lower()
    if text in {"x", "yes", "y", "ja", "j", "true", "1"}:
        return 1
    if "x" in text:
        return 1
    return 0


def _number(value: object) -> float | int | None:
    """Coerce a workbook cell to a number, or None if blank."""
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip().replace(",", ".")
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        try:
            return float(text)
        except ValueError:
            return None


def _text(value: object) -> str | None:
    if value is None:
        return None
    text = str(value)
    return text if text else None


# ── destinations ───────────────────────────────────────────────

def _row_to_destination(row: dict) -> dict:
    """Turn a ``destinations`` table row into a destination dict."""
    dest = {field: row.get(field) for field in CORE_COLUMNS}
    raw = row.get("data")
    columns: list[list] = []
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                columns = parsed
        except (TypeError, ValueError):
            columns = []
    dest["columns"] = columns
    return dest


def _destination_to_params(dest: dict) -> dict:
    """Flatten a destination dict into SQL parameters."""
    params: dict[str, Any] = {}
    for field, column in CORE_COLUMNS.items():
        value = dest.get(field)
        if field in BOOL_FIELDS:
            params[field] = _truthy(value)
        elif field in NUM_FIELDS:
            params[field] = _number(value)
        else:
            params[field] = _text(value)
    # The tail: every column as an ordered [name, value] array.
    # Prefer an explicit ``columns`` list; otherwise build one
    # from the typed core so a save never loses the tail.
    columns = dest.get("columns")
    if not isinstance(columns, list):
        columns = [[column, dest.get(field)]
                   for field, column in CORE_COLUMNS.items()]
    params["data"] = json.dumps(columns, ensure_ascii=False,
                                default=str)
    params["destination"] = _text(dest.get("destination")) or ""
    params["updated_at"] = _utcnow()
    return params


def load_destinations() -> tuple[list[dict], list[str]]:
    """All destinations, ordered by name. Returns (list, problems)."""
    rows, problems = turso_db.query(
        "SELECT * FROM destinations ORDER BY destination")
    if problems:
        return [], problems
    return [_row_to_destination(row) for row in rows], []


def get_destination(name: str) -> tuple[dict | None, list[str]]:
    """One destination by exact name. Returns (dest|None, problems).

    The pipeline API takes raw SQL, so the name is escaped
    (single quotes doubled) rather than parameterised.
    """
    safe = str(name).replace("'", "''")
    rows, problems = turso_db.query(
        f"SELECT * FROM destinations WHERE destination = '{safe}'")
    if problems:
        return None, problems
    if not rows:
        return None, []
    return _row_to_destination(rows[0]), []


def save_destination(dest: dict) -> tuple[bool, list[str]]:
    """Upsert one destination. Returns (written, problems)."""
    params = _destination_to_params(dest)
    sql = (
        "INSERT INTO destinations ("
        "destination, continent, country, visited, favourite, prio, "
        "safety_rating, avg_cost_day, flight_time_fra, "
        "to_be_researched, malaria_risk, data_status, comment, "
        "data, updated_at) VALUES ("
        f"'{str(params['destination']).replace(chr(39), chr(39)+chr(39))}', "
        f"{_sql_value(params['continent'])}, "
        f"{_sql_value(params['country'])}, "
        f"{params['visited']}, {params['favourite']}, "
        f"{_sql_value(params['prio'])}, "
        f"{_sql_value(params['safety_rating'])}, "
        f"{_sql_value(params['avg_cost_day'])}, "
        f"{_sql_value(params['flight_time_fra'])}, "
        f"{params['to_be_researched']}, {params['malaria_risk']}, "
        f"{_sql_value(params['data_status'])}, "
        f"{_sql_value(params['comment'])}, "
        f"{_sql_value(params['data'])}, "
        f"{_sql_value(params['updated_at'])}) "
        "ON CONFLICT(destination) DO UPDATE SET "
        "continent = excluded.continent, country = excluded.country, "
        "visited = excluded.visited, favourite = excluded.favourite, "
        "prio = excluded.prio, safety_rating = excluded.safety_rating, "
        "avg_cost_day = excluded.avg_cost_day, "
        "flight_time_fra = excluded.flight_time_fra, "
        "to_be_researched = excluded.to_be_researched, "
        "malaria_risk = excluded.malaria_risk, "
        "data_status = excluded.data_status, comment = excluded.comment, "
        "data = excluded.data, updated_at = excluded.updated_at"
    )
    problems = turso_db.execute(sql)
    return (not problems), problems


def _sql_value(value: object) -> str:
    """Render a Python value as a SQL literal (NULL-safe)."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value).replace("'", "''")
    return f"'{text}'"


# ── trips ──────────────────────────────────────────────────────

def load_trips() -> tuple[dict, list[str]]:
    """The full trips structure (the trips.json shape).

    Returns ({"schema_version": 1, "trips": [...]}, problems).
    """
    trips_rows, problems = turso_db.query(
        "SELECT * FROM trips ORDER BY created")
    if problems:
        return {"schema_version": 1, "trips": []}, problems
    variants_rows, problems = turso_db.query(
        "SELECT * FROM variants ORDER BY trip_id, rowid")
    if problems:
        return {"schema_version": 1, "trips": []}, problems
    stops_rows, problems = turso_db.query(
        "SELECT * FROM stops ORDER BY variant_id, position")
    if problems:
        return {"schema_version": 1, "trips": []}, problems
    legs_rows, problems = turso_db.query(
        "SELECT * FROM legs ORDER BY variant_id, position")
    if problems:
        return {"schema_version": 1, "trips": []}, problems

    variants_by_trip: dict[str, list[dict]] = {}
    for row in variants_rows:
        variants_by_trip.setdefault(row.get("trip_id"), []).append(row)
    stops_by_variant: dict[str, list[dict]] = {}
    for row in stops_rows:
        stops_by_variant.setdefault(row.get("variant_id"), []).append(row)
    legs_by_variant: dict[str, list[dict]] = {}
    for row in legs_rows:
        legs_by_variant.setdefault(row.get("variant_id"), []).append(row)

    trips: list[dict] = []
    for trip_row in trips_rows:
        trip_id = trip_row.get("id")
        variants = []
        for variant_row in variants_by_trip.get(trip_id, []):
            variant_id = variant_row.get("id")
            stops = [_stop_to_dict(s)
                     for s in stops_by_variant.get(variant_id, [])]
            legs = [_leg_to_dict(leg)
                    for leg in legs_by_variant.get(variant_id, [])]
            months = variant_row.get("months") or "[]"
            try:
                months_list = json.loads(months)
            except (TypeError, ValueError):
                months_list = []
            variants.append({
                "id": variant_id,
                "name": variant_row.get("name") or "Variant",
                "notes": variant_row.get("notes") or "",
                "rating": variant_row.get("rating"),
                "months": months_list,
                "comment": variant_row.get("comment") or "",
                "stops": stops,
                "legs": legs,
            })
        trips.append({
            "id": trip_id,
            "name": trip_row.get("name") or "Untitled trip",
            "created": trip_row.get("created"),
            "active_variant_id": trip_row.get("active_variant_id"),
            "variants": variants,
        })
    return {"schema_version": 1, "trips": trips}, []


def _stop_to_dict(row: dict) -> dict:
    return {
        "id": row.get("id"),
        "ref": {
            "kind": row.get("kind") or "custom",
            "name": row.get("name") or "Unnamed stop",
            "country": row.get("country"),
            "lat": row.get("lat"),
            "lon": row.get("lon"),
        },
        "arrival_date": row.get("arrival_date"),
        "departure_date": row.get("departure_date"),
        "arrival_time": row.get("arrival_time"),
        "departure_time": row.get("departure_time"),
        "nights": row.get("nights"),
        "role": row.get("role") or "stop",
        "notes": row.get("notes") or "",
    }


def _leg_to_dict(row: dict) -> dict:
    return {
        "mode": row.get("mode") or "flight",
        "note": row.get("note") or "",
    }


def save_trip(trip: dict) -> tuple[bool, list[str]]:
    """Upsert a trip and all its variants, stops and legs.

    The whole trip is written in one pipeline request (atomic).
    A variant's stops and legs are deleted and re-inserted, so
    the stored order always matches the in-memory order.
    """
    statements: list[str] = []
    trip_id = str(trip.get("id") or "")
    if not trip_id:
        return False, ["trip has no id"]
    now = _utcnow()
    statements.append(
        "INSERT INTO trips (id, name, created, active_variant_id, "
        "updated_at) VALUES ("
        f"{_sql_value(trip_id)}, {_sql_value(trip.get('name'))}, "
        f"{_sql_value(trip.get('created'))}, "
        f"{_sql_value(trip.get('active_variant_id'))}, "
        f"{_sql_value(now)}) "
        "ON CONFLICT(id) DO UPDATE SET name = excluded.name, "
        "created = excluded.created, "
        "active_variant_id = excluded.active_variant_id, "
        "updated_at = excluded.updated_at")

    for variant in trip.get("variants") or []:
        variant_id = str(variant.get("id") or "")
        if not variant_id:
            continue
        statements.append(
            "INSERT INTO variants (id, trip_id, name, notes, rating, "
            "months, comment, updated_at) VALUES ("
            f"{_sql_value(variant_id)}, {_sql_value(trip_id)}, "
            f"{_sql_value(variant.get('name'))}, "
            f"{_sql_value(variant.get('notes'))}, "
            f"{_sql_value(variant.get('rating'))}, "
            f"{_sql_value(json.dumps(variant.get('months') or [], ensure_ascii=False))}, "
            f"{_sql_value(variant.get('comment'))}, "
            f"{_sql_value(now)}) "
            "ON CONFLICT(id) DO UPDATE SET trip_id = excluded.trip_id, "
            "name = excluded.name, notes = excluded.notes, "
            "rating = excluded.rating, months = excluded.months, "
            "comment = excluded.comment, updated_at = excluded.updated_at")
        # Replace this variant's stops and legs so the stored
        # order always matches the in-memory order.
        statements.append(
            f"DELETE FROM stops WHERE variant_id = {_sql_value(variant_id)}")
        statements.append(
            f"DELETE FROM legs WHERE variant_id = {_sql_value(variant_id)}")
        for position, stop in enumerate(variant.get("stops") or []):
            ref = stop.get("ref") or {}
            statements.append(
                "INSERT INTO stops (id, variant_id, position, kind, name, "
                "country, lat, lon, role, arrival_date, departure_date, "
                "arrival_time, departure_time, nights, notes, updated_at) "
                "VALUES ("
                f"{_sql_value(stop.get('id'))}, {_sql_value(variant_id)}, "
                f"{position}, {_sql_value(ref.get('kind'))}, "
                f"{_sql_value(ref.get('name'))}, "
                f"{_sql_value(ref.get('country'))}, "
                f"{_sql_value(ref.get('lat'))}, "
                f"{_sql_value(ref.get('lon'))}, "
                f"{_sql_value(stop.get('role'))}, "
                f"{_sql_value(stop.get('arrival_date'))}, "
                f"{_sql_value(stop.get('departure_date'))}, "
                f"{_sql_value(stop.get('arrival_time'))}, "
                f"{_sql_value(stop.get('departure_time'))}, "
                f"{_sql_value(stop.get('nights'))}, "
                f"{_sql_value(stop.get('notes'))}, "
                f"{_sql_value(now)})")
        for position, leg in enumerate(variant.get("legs") or []):
            statements.append(
                "INSERT INTO legs (variant_id, position, mode, note, "
                "updated_at) VALUES ("
                f"{_sql_value(variant_id)}, {position}, "
                f"{_sql_value(leg.get('mode'))}, "
                f"{_sql_value(leg.get('note'))}, "
                f"{_sql_value(now)})")

    problems = turso_db.run_pipeline(statements)[1]
    return (not problems), problems


def delete_trip(trip_id: str) -> tuple[bool, list[str]]:
    """Delete a trip and its variants, stops and legs."""
    safe = str(trip_id).replace("'", "''")
    statements = [
        f"DELETE FROM legs WHERE variant_id IN "
        f"(SELECT id FROM variants WHERE trip_id = '{safe}')",
        f"DELETE FROM stops WHERE variant_id IN "
        f"(SELECT id FROM variants WHERE trip_id = '{safe}')",
        f"DELETE FROM variants WHERE trip_id = '{safe}'",
        f"DELETE FROM trips WHERE id = '{safe}'",
    ]
    problems = turso_db.run_pipeline(statements)[1]
    return (not problems), problems


# ── open tabs ──────────────────────────────────────────────────

def load_open_tabs() -> tuple[list[str], list[str]]:
    """The persisted list of open destination tabs."""
    rows, problems = turso_db.query(
        "SELECT destination FROM open_tabs ORDER BY destination")
    if problems:
        return [], problems
    return [row.get("destination") for row in rows
            if row.get("destination")], []


def save_open_tabs(tabs: list[str]) -> tuple[bool, list[str]]:
    """Replace the open-tabs list. Returns (written, problems)."""
    now = _utcnow()
    statements = ["DELETE FROM open_tabs"]
    for tab in tabs:
        safe = str(tab).replace("'", "''")
        statements.append(
            "INSERT OR IGNORE INTO open_tabs (destination, updated_at) VALUES "
            f"('{safe}', {_sql_value(now)})")
    problems = turso_db.run_pipeline(statements)[1]
    return (not problems), problems


# ── workbook export ────────────────────────────────────────────

def export_workbook(path: str) -> tuple[bool, list[str]]:
    """Write the destinations back to an .xlsx file.

    The workbook stays an openable artifact (the user's decision,
    2026-10-08): Turso is the source of truth, but you can still
    open the data in Excel. Column order follows the original
    workbook header, recovered from each row's ``data`` tail.
    """
    destinations, problems = load_destinations()
    if problems:
        return False, problems
    if not destinations:
        return False, ["no destinations to export"]

    # Recover the column order from the first destination's tail.
    header = [name for name, _value in
              (destinations[0].get("columns") or [])]
    if not header:
        return False, ["first destination has no column data"]

    try:
        import openpyxl
    except ImportError:
        return False, ["openpyxl is required to export .xlsx"]

    workbook = openpyxl.Workbook()
    sheet = workbook.active
    sheet.title = "Result sheet"
    sheet.append(header)
    for dest in destinations:
        values = {name: value for name, value in
                  (dest.get("columns") or [])}
        sheet.append([values.get(name) for name in header])
    try:
        workbook.save(path)
    except OSError as exc:
        return False, [f"could not write {path}: {exc}"]
    return True, []
