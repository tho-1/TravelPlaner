"""The Travel Planner backend API (NATIVE_HTML_PLAN.md, Phase 2).

FastAPI endpoints over the repository layer -- the same
data-access point the Streamlit pages use -- so the native HTML
frontend (Phase 3) and the Flutter app (Phase 5) talk to one
backend instead of each re-implementing the data rules.

This is the first Streamlit-free entry point: it sets
``TRAVEL_PLANNER_API`` before importing the repository, which
turns the repository's Streamlit caching into a passthrough so
every request reads fresh data. The data-safety rules apply
unchanged: writers return True/False, a failed write is
surfaced, and nothing here writes the workbook directly -- the
repository owns the write path.

Run:
    python -m uvicorn api:app --port 8508
    python api.py

The host/port default to loopback. Set TRAVEL_PLANNER_API_HOST
(``0.0.0.0`` to reach the phone over the LAN) and
TRAVEL_PLANNER_API_PORT to change them.
"""

from __future__ import annotations

import os

os.environ.setdefault("TRAVEL_PLANNER_API", "1")

import math
import tempfile
from datetime import date, time
from pathlib import Path

import pandas as pd
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.background import BackgroundTask

import data_utils
import filters
import repository
import storage_turso
import timetable
import weekend_match as wm
from itinerary import models
from itinerary import storage as trip_storage

app = FastAPI(title="Travel Planner API", version="2")

# The native HTML frontend (Phase 3) is served by this same
# process, and the Flutter app (Phase 5) may call it over the
# LAN. Both are trusted clients of a personal app, so CORS is
# open. Tokens never leave this process.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# The slim projection the catalogue view needs; the detail
# endpoint returns every column. Field -> workbook aliases (the
# same alias sets the readers and the writers share, so a
# column the API can read is always a column it can write).
_LIST_FIELDS = {
    "destination": data_utils.DESTINATION_ALIASES,
    "country": ["country", "land", "nation", "state"],
    "continent": ["continent", "region"],
    "visited": data_utils.VISITED_ALIASES,
    "favourite": data_utils.NEARER_ALIASES,
    "prio": data_utils.PRIO_ALIASES,
    "safety_rating": ["safety rating", "safety"],
    "avg_cost_day": ["avg. cost/day", "cost/day", "cost"],
    "flight_time_fra": ["flight time to frankfurt", "flight time"],
    "to_be_researched": data_utils.RESEARCH_ALIASES,
    "comment": ["comment"],
}

_BOOL_FIELDS = ("visited", "favourite", "to_be_researched")


# ── helpers ────────────────────────────────────────────────────

def _resolve_columns(df) -> dict[str, str | None]:
    """Map each list field to its workbook column (or None)."""
    columns = list(df.columns)
    return {
        field: data_utils.find_column(columns, aliases)
        for field, aliases in _LIST_FIELDS.items()
    }


def _bool_mask(series, want: bool):
    """The filter rule as a mask: a filter may only remove rows
    whose field is populated (``filters.py``). ``want=True``
    keeps the truthy rows; ``want=False`` keeps every row that
    is not populated-and-truthy, so a blank never hides."""
    populated = series.notna() & (series.astype(str).str.strip() != "")
    truthy = series.map(storage_turso._truthy).astype(bool)
    return truthy if want else ~(populated & truthy)


def _number(value):
    """A workbook cell as a number, or None (blank)."""
    return filters.coerce_number(value)


def _jsonable(value):
    """A workbook cell as a JSON value.

    Empty cells read as NaN/NaT, which ``json`` refuses
    to serialize, and numpy scalars are not serializable
    either -- the Streamlit UI hid both, a JSON API
    cannot. Everything else passes through unchanged.
    """
    if value is None or isinstance(value, (bool, str)):
        return value
    if isinstance(value, float):
        return None if math.isnan(value) or math.isinf(value) else value
    if isinstance(value, int):
        return value
    try:
        if pd.isna(value):
            return None
    except (TypeError, ValueError):
        pass
    if hasattr(value, "item"):  # a numpy scalar
        return value.item()
    return value


# ── meta ───────────────────────────────────────────────────────

@app.get("/api/health")
def health():
    return {"ok": True,
            "source": "turso" if repository.use_turso() else "workbook"}


@app.get("/api/meta")
def meta():
    df, _metadata = repository.load_destinations()
    trips = trip_storage.ensure_seed()
    return {
        "source": "turso" if repository.use_turso() else "workbook",
        "destinations": int(len(df)),
        "trips": int(len(trips.get("trips") or [])),
        "open_tabs": int(len(repository.load_open_tabs())),
    }


# ── destinations ───────────────────────────────────────────────

@app.get("/api/destinations")
def list_destinations(
    q: str | None = None,
    country: str | None = None,
    continent: str | None = None,
    visited: bool | None = None,
    favourite: bool | None = None,
    researched: bool | None = None,
    limit: int = 0,
):
    """The catalogue in a slim projection, with the shared
    filters. ``limit`` caps the row count (0 = no cap)."""
    df, _metadata = repository.load_destinations()
    if df.empty:
        return {"count": 0, "destinations": []}
    columns = _resolve_columns(df)

    mask = None

    def _and(new_mask):
        nonlocal mask
        mask = new_mask if mask is None else (mask & new_mask)

    if q and columns["destination"]:
        needle = q.strip().lower()
        _and(df[columns["destination"]].astype(str)
             .str.lower().str.contains(needle, regex=False))
    for field, value in (("country", country), ("continent", continent)):
        if value and columns[field]:
            wanted = value.strip().lower()
            _and(df[columns[field]].astype(str)
                 .str.strip().str.lower() == wanted)
    for field, value in (("visited", visited),
                         ("favourite", favourite),
                         ("to_be_researched", researched)):
        if value is not None and columns[field]:
            _and(_bool_mask(df[columns[field]], value))

    if mask is not None:
        df = df[mask]
    if limit > 0:
        df = df.head(limit)

    records = []
    for _, row in df.iterrows():
        record: dict[str, object] = {}
        for field, column in columns.items():
            value = None if column is None else row[column]
            if field in _BOOL_FIELDS:
                value = bool(storage_turso._truthy(value))
            elif field in ("prio", "safety_rating", "avg_cost_day",
                           "flight_time_fra"):
                value = _number(value)
            record[field] = _jsonable(value)
        records.append(record)
    return {"count": len(records), "destinations": records}


@app.get("/api/destinations/{name}")
def get_destination(name: str):
    """One destination with every column. ``columns`` is the
    lossless ordered ``[name, value]`` tail (the workbook has
    duplicate column names, so the ``fields`` dict alone would
    drop them); ``fields`` is the same data as a dict."""
    dest, _problems = repository.get_destination(name)
    if dest is None:
        raise HTTPException(404, f"no destination named {name!r}")
    columns = [[column, _jsonable(value)]
               for column, value in (dest.get("columns") or [])]
    return {
        "destination": dest.get("destination") or name,
        "columns": columns,
        "fields": {str(column): value for column, value in columns},
    }


class DestinationPatch(BaseModel):
    """The editable destination flags. Absent fields are not
    written; every write is reported individually."""

    favourite: bool | None = None
    visited: bool | None = None
    to_be_researched: bool | None = None
    prio: int | None = None
    comment: str | None = None


@app.patch("/api/destinations/{name}")
def patch_destination(name: str, patch: DestinationPatch):
    results: dict[str, bool] = {}
    if patch.favourite is not None:
        results["favourite"] = repository.update_favorite_status(
            name, patch.favourite)
    if patch.visited is not None:
        results["visited"] = repository.update_visited_status(
            name, patch.visited)
    if patch.to_be_researched is not None:
        results["to_be_researched"] = \
            repository.update_to_be_researched_status(
                name, patch.to_be_researched)
    if patch.prio is not None:
        results["prio"] = repository.update_prio_thorsten(
            name, patch.prio)
    if patch.comment is not None:
        results["comment"] = repository.update_comment(
            name, patch.comment)
    if not results:
        raise HTTPException(400, "nothing to write")
    return {"written": all(results.values()), "results": results}


# ── trips (still trips.json at runtime; the Turso cutover is
#    Phase 4 -- the storage layer already speaks both) ──────────

@app.get("/api/trips")
def list_trips():
    data = trip_storage.ensure_seed()
    return {"schema_version": data.get("schema_version", 1),
            "trips": data.get("trips") or []}


class TripCreate(BaseModel):
    name: str
    variants: list[dict] | None = None


def _save_trips(data: dict) -> None:
    """Save, mapping the stale-file guard to a 409 the
    client can act on (reload and retry) and a failed
    write to a 500 -- a write that was not made is
    never reported as success."""
    try:
        written = trip_storage.save_trips(data)
    except trip_storage.TripsFileChanged as exc:
        raise HTTPException(
            409, "trips.json changed on disk -- reload and retry"
        ) from exc
    error = trip_storage.last_write_error()
    if not written or error:
        raise HTTPException(
            500, f"the trips were not written: {error}")


@app.post("/api/trips", status_code=201)
def create_trip(trip: TripCreate):
    data = trip_storage.ensure_seed()
    new_trip = models.make_trip(trip.name, trip.variants)
    data.setdefault("trips", []).append(new_trip)
    _save_trips(data)
    return new_trip


@app.get("/api/trips/{trip_id}")
def get_trip(trip_id: str):
    data = trip_storage.ensure_seed()
    found = models.find_trip(data, trip_id)
    if found is None:
        raise HTTPException(404, f"no trip {trip_id!r}")
    return found


@app.put("/api/trips/{trip_id}")
def replace_trip(trip_id: str, trip: dict):
    data = trip_storage.ensure_seed()
    found = models.find_trip(data, trip_id)
    if found is None:
        raise HTTPException(404, f"no trip {trip_id!r}")
    normalized = models.normalize_trip(trip)
    normalized["id"] = trip_id
    data["trips"] = [
        normalized if t.get("id") == trip_id else t
        for t in (data.get("trips") or [])
    ]
    _save_trips(data)
    return normalized


@app.delete("/api/trips/{trip_id}")
def delete_trip(trip_id: str):
    data = trip_storage.ensure_seed()
    if models.find_trip(data, trip_id) is None:
        raise HTTPException(404, f"no trip {trip_id!r}")
    data["trips"] = [
        t for t in (data.get("trips") or [])
        if t.get("id") != trip_id
    ]
    _save_trips(data)
    return {"deleted": True, "id": trip_id}


# ── open tabs ──────────────────────────────────────────────────

@app.get("/api/tabs")
def list_tabs():
    return {"tabs": repository.load_open_tabs()}


class TabsWrite(BaseModel):
    tabs: list[str]


@app.put("/api/tabs")
def replace_tabs(write: TabsWrite):
    written = repository.save_open_tabs(write.tabs)
    return {"written": written, "tabs": write.tabs}


# ── weekend finder ─────────────────────────────────────────────

def _parse_clock(text: str, field: str) -> time:
    try:
        return time.fromisoformat(text.strip())
    except ValueError as exc:
        raise HTTPException(400, f"{field} must be HH:MM") from exc


@app.get("/api/weekend")
def weekend(
    friday: str | None = None,
    friday_from: str = "14:00",
    saturday_before: str = "12:00",
    saturday_return_after: str = "12:00",
    monday_return_before: str = "09:00",
    use_cache: bool = True,
):
    """Weekend possibilities from FRA for one Friday (default:
    the next one). Flights come from the live Fraport board
    (``timetable.py``); ``use_cache=false`` forces a re-fetch."""
    try:
        day = (date.fromisoformat(friday.strip()) if friday
               else wm.next_friday(date.today()))
    except ValueError as exc:
        raise HTTPException(400, "friday must be YYYY-MM-DD") from exc
    weekend_ = wm.Weekend(friday=day)
    windows = wm.Windows(
        friday_from=_parse_clock(friday_from, "friday_from"),
        saturday_before=_parse_clock(saturday_before,
                                     "saturday_before"),
        saturday_return_after=_parse_clock(
            saturday_return_after, "saturday_return_after"),
        monday_return_before=_parse_clock(
            monday_return_before, "monday_return_before"),
    )
    provider = timetable.FraportBoardProvider()
    report = timetable.search_weekend(
        weekend_, windows, provider, use_cache=use_cache)
    return _report_dict(report)


def _flight_dict(flight: wm.Flight) -> dict:
    return {
        "flight_no": flight.flight_no,
        "airline": flight.airline,
        "operated_by": flight.operated_by,
        "origin": flight.origin,
        "destination": flight.destination,
        "departure": flight.departure.isoformat(),
        "arrival": flight.arrival.isoformat(),
    }


def _option_dict(option: wm.TripOption) -> dict:
    return {
        "city": option.city,
        "country": option.country,
        "nights": option.nights,
        "notes": option.notes,
        "outbound_airline": option.outbound_airline,
        "return_airline": option.return_airline,
        "outbound": _flight_dict(option.out_flight),
        "return": _flight_dict(option.back_flight),
    }


def _city_dict(city: wm.CityResult) -> dict:
    return {
        "city": city.city,
        "country": city.country,
        "label": city.label,
        "options": [_option_dict(option)
                    for option in city.options],
        "airports": sorted(city.airports),
        "out_only": len(city.out_only),
        "back_only": len(city.back_only),
        "unmapped_airports": sorted(city.unmapped_airports),
    }


def _report_dict(report: wm.MatchReport) -> dict:
    return {
        "weekend": report.weekend.describe(),
        "windows": report.windows.describe(),
        "city_count": report.city_count,
        "option_count": report.option_count,
        "outbound_total": report.outbound_total,
        "return_total": report.return_total,
        "cities": [_city_dict(city) for city in report.cities],
        "one_way_only": [_city_dict(city)
                         for city in report.one_way_only],
        "outbound_rejected_airlines":
            report.outbound_rejected_airlines,
        "notes": report.notes,
    }


@app.get("/api/providers")
def providers():
    """Which flight providers are usable right now, or why not."""
    return {"providers": timetable.provider_status()}


# ── workbook export ────────────────────────────────────────────

@app.get("/api/export.xlsx")
def export_workbook():
    """The destinations as an openable ``.xlsx`` (Turso is the
    source of truth; the workbook is the convenience artifact)."""
    if not repository.use_turso():
        raise HTTPException(
            409, "workbook export requires Turso as the source")
    handle, path = tempfile.mkstemp(
        suffix=".xlsx", prefix="travel-planner-export-")
    os.close(handle)
    written, problems = repository.export_workbook(path)
    if not written:
        return JSONResponse(
            status_code=500,
            content={"written": False, "problems": problems})
    return FileResponse(
        path,
        media_type=("application/vnd.openxmlformats-officedocument"
                    ".spreadsheetml.sheet"),
        filename="Destinations.xlsx",
        background=BackgroundTask(os.remove, path),
    )


# ── legacy sync trigger (the journal stack stays until the
#    Phase 4/6 cutover; Turso sync is push/pull, done by the
#    clients themselves) ────────────────────────────────────────

@app.post("/api/sync")
def sync(dry_run: bool = False):
    """Run the PC<->phone journal sync (pull, merge, push).

    Conflicts are saved for review, never silently resolved.
    Offline or auth failures return ``ok=false`` with the queued
    changes left intact.
    """
    from sync.sync import sync_now

    return sync_now(dry_run=dry_run)


# ── the native HTML frontend (Phase 3) ─────────────────────────

WEB_DIR = Path(__file__).resolve().parent / "web"
if (WEB_DIR / "index.html").is_file():
    # Registered last so every /api route above keeps precedence.
    app.mount("/", StaticFiles(directory=WEB_DIR, html=True),
              name="web")


if __name__ == "__main__":  # pragma: no cover - manual run
    import uvicorn

    uvicorn.run(
        "api:app",
        host=os.environ.get("TRAVEL_PLANNER_API_HOST", "127.0.0.1"),
        port=int(os.environ.get("TRAVEL_PLANNER_API_PORT", "8508")),
    )
