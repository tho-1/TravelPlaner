"""One-shot migration of the existing workbook + trips.json + open tabs
into the Turso database.

This is Phase 1 of the native rebuild (see ``NATIVE_HTML_PLAN.md`` §"Phase 1
-- Data layer on Turso"). It:

1. Reads ``Destinations-local.xlsx`` (or the committed ``Destinations-cloud.xlsx``
   seed) with **openpyxl** — not pandas, because pandas collides duplicate
   column names and we must preserve all 145 columns in order as a lossless
   ``[name, value]`` tail.
2. Resolves each typed-core column by the same alias logic the app already uses
   (``data_utils.find_column``), so a mojibake header or a renamed column does
   not silently drop a field.
3. Writes every destination, trip, and open-tab into Turso via
   ``storage_turso`` (atomic per statement, upserts, last-write-wins).
4. Verifies the row counts and a few spot values, and prints a report.

Run once after the Turso token is set; re-running is idempotent (upserts).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import openpyxl

import data_utils
import storage_turso as st
import turso_db

ROOT = Path(__file__).resolve().parent
CANDIDATES = ["Destinations-local.xlsx", "Destinations-cloud.xlsx"]


# ── column resolution ─────────────────────────────────────────────────────────
#: Reuse the app's own alias sets so the migration binds the same columns the
#: Streamlit pages read. ``find_column`` does a normalised exact match first,
#: then a substring match — which is what absorbs the mojibake in "nherer
#: Auswahl".
FIELD_ALIASES = {
    "destination": data_utils.DESTINATION_ALIASES,
    "continent": ["continent", "region"],
    "country": ["country", "land", "nation", "state"],
    "visited": data_utils.VISITED_ALIASES,
    "favourite": data_utils.NEARER_ALIASES,
    "prio": data_utils.PRIO_ALIASES,
    "safety_rating": ["safety", "safetyrating", "security", "risk"],
    "avg_cost_day": ["costday", "costperday", "dailycost", "cost", "costday"],
    "flight_time_fra": ["flighttime", "flight", "tofra", "travel", "duration"],
    "to_be_researched": data_utils.RESEARCH_ALIASES,
    "malaria_risk": ["malaria risk", "malaria", "malariarisk"],
    "data_status": ["data status", "status"],
    "comment": ["comment", "kommentar", "anmerkung"],
}


def _resolve_columns(headers: list[str]) -> dict[str, int]:
    """Return ``{field: column_index}`` for every typed-core field found."""
    index: dict[str, int] = {}
    for field, aliases in FIELD_ALIASES.items():
        found = data_utils.find_column(headers, aliases)
        if found is not None:
            index[field] = headers.index(found)
    return index


def _resolve_state_path(name: str) -> Path:
    import runtime_paths

    return runtime_paths.state_path(name)


def _workbook_path() -> Path | None:
    for name in CANDIDATES:
        path = ROOT / name
        if path.exists():
            return path
    return None


# ── migration steps ────────────────────────────────────────────────────────────

def migrate_destinations(wb_path: Path, dry_run: bool = False) -> tuple[int, list[str]]:
    """Copy every destination row into Turso. Returns (count, problems)."""
    problems: list[str] = []
    wb = openpyxl.load_workbook(wb_path, read_only=True, data_only=True)
    sheet_name = data_utils._find_destination_sheet(wb_path)
    if sheet_name is None:
        wb.close()
        return 0, ["no destination sheet found in workbook"]
    ws = wb[sheet_name]

    rows = list(ws.iter_rows(values_only=True))
    wb.close()
    if not rows:
        return 0, ["workbook has no rows"]

    headers = [str(c).strip() if c is not None else "" for c in rows[0]]
    col_index = _resolve_columns(headers)

    required = {"destination"}
    missing = required - set(col_index)
    if missing:
        return 0, [f"could not resolve columns: {sorted(missing)}"]

    dest_idx = col_index["destination"]
    if dest_idx is None:
        return 0, ["destination column not found"]

    count = 0
    for row in rows[1:]:
        raw_dest = row[dest_idx] if dest_idx < len(row) else None
        name = str(raw_dest).strip() if raw_dest is not None else ""
        if not name or name.lower() in {"none", "nan"}:
            continue

        dest: dict = {"destination": name}
        for field, idx in col_index.items():
            value = row[idx] if idx < len(row) else None
            dest[field] = value

        # The lossless tail: every column as [name, value], in workbook order.
        # Duplicate header names are preserved as separate entries.
        dest["columns"] = [[headers[i], row[i] if i < len(row) else None]
                           for i in range(len(headers))]

        if dry_run:
            count += 1
            continue

        ok, problems_ = st.save_destination(dest)
        if ok:
            count += 1
        else:
            problems.append(f"{name}: {problems_}")

    return count, problems


def migrate_trips() -> tuple[int, list[str]]:
    """Copy every trip from trips.json into Turso. Returns (count, problems)."""
    problems: list[str] = []
    path = _resolve_state_path("trips.json")
    if not path.exists():
        return 0, [f"trips.json not found at {path}"]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return 0, [f"could not read trips.json: {exc}"]

    from itinerary.models import normalize_all

    data = normalize_all(data)
    count = 0
    for trip in data.get("trips", []):
        ok, problems_ = st.save_trip(trip)
        if ok:
            count += 1
        else:
            problems.append(f"{trip.get('id', '?')}: {problems_}")
    return count, problems


def migrate_open_tabs() -> tuple[int, list[str]]:
    """Copy open tabs into Turso. Returns (count, problems)."""
    path = _resolve_state_path("open_destinations.json")
    if not path.exists():
        return 0, [f"open tabs not found at {path}"]
    try:
        tabs = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return 0, [f"could not read open tabs: {exc}"]
    if not isinstance(tabs, list):
        return 0, ["open tabs is not a list"]

    ok, problems = st.save_open_tabs(tabs)
    if ok:
        return len(tabs), problems
    return 0, problems


# ── verification ───────────────────────────────────────────────────────────────

def verify() -> list[str]:
    """Spot-check the migrated data. Returns a list of problem strings."""
    problems: list[str] = []

    dests, p = st.load_destinations()
    if p:
        problems.append(f"load_destinations: {p}")
    else:
        if not dests:
            problems.append("load_destinations: empty result")
        # every destination must have a name
        unnamed = [d for d in dests if not d.get("destination")]
        if unnamed:
            problems.append(f"{len(unnamed)} destinations have no name")
        # column count must be 145 for sources with full tails
        short = [d for d in dests
                 if len(d.get("columns") or []) < 145]
        if short:
            problems.append(
                f"{len(short)} destinations have fewer than 145 columns "
                f"(e.g. {short[0]['destination']})"
            )

    data, p = st.load_trips()
    if p:
        problems.append(f"load_trips: {p}")
    else:
        if not data.get("trips"):
            problems.append("load_trips: empty result (was trips.json non-empty?)")

    return problems


# ── main ───────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    dry_run = "--dry-run" in argv

    if not turso_db.is_configured():
        print("Turso is not configured (TRAVEL_PLANNER_TURSO_URL / _TOKEN "
              "missing). Refusing to migrate.")
        return 2

    problems = turso_db.ensure_schema()
    if problems:
        print("Schema setup failed:", problems)
        return 1

    wb_path = _workbook_path()
    if wb_path is None:
        print("No workbook found (tried Destinations-local.xlsx and "
              "Destinations-cloud.xlsx)")
        return 2
    print(f"Workbook: {wb_path.name}")

    if dry_run:
        print("Dry run — no writes will be made.")

    n_dest, p_dest = migrate_destinations(wb_path, dry_run=dry_run)
    print(f"Destinations: {n_dest}", end="")
    if p_dest:
        print(f"  ({len(p_dest)} errors)")
        for p in p_dest[:5]:
            print(f"  - {p}")
    else:
        print()

    n_trips, p_trips = migrate_trips()
    print(f"Trips: {n_trips}", end="")
    if p_trips:
        print(f"  ({len(p_trips)} errors)")
        for p in p_trips:
            print(f"  - {p}")
    else:
        print()

    n_tabs, p_tabs = migrate_open_tabs()
    print(f"Open tabs: {n_tabs}", end="")
    if p_tabs:
        print(f"  ({len(p_tabs)} errors)")
    else:
        print()

    if not dry_run:
        print("Verifying...")
        problems = verify()
        if problems:
            print("Verification found issues:")
            for p in problems:
                print(f"  - {p}")
            return 1
        print("All checks passed.")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
