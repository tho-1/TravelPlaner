"""Repository layer — the single data-access point for the app.

Phase 1 of the native rebuild (``NATIVE_HTML_PLAN.md``): the pages call
this module instead of ``data_utils`` directly, so a future UI swap is
mechanical. The repository routes every call through a fallback ladder:

* **Turso** (``storage_turso``) when ``TRAVEL_PLANNER_TURSO_URL`` and
  ``TRAVEL_PLANNER_TURSO_TOKEN`` are set and the database answers.
* **The workbook** (``data_utils``) otherwise — the same code path the
  app used before Turso, so a missing token or an outage degrades to
  the old behaviour instead of an empty catalogue.

The read path returns the same ``(DataFrame, metadata)`` pair the pages
already consume, built from each destination's lossless ``columns``
tail and passed through ``data_utils._prepare_dataframe`` so the column
resolution, type coercion and metadata are identical on both sources.

Writes go to Turso as a read-modify-write (load the destination, set
the field in both the typed core and the tail, upsert). The workbook
writers keep their atomic-save + journal contract; the Turso writers
keep the True/False contract. Neither raises on a quiet failure.

Trips stay on ``itinerary/storage.py`` (``trips.json``) for now: the
migration copied them into Turso, but the runtime path follows once the
destination/tab round-trip is proven. See ``NATIVE_HTML_PLAN.md`` §7.
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd

import data_utils
import storage_turso
import turso_db

try:
    import streamlit as st
except ImportError:  # the API server runs without Streamlit
    st = None


def _cache_data(func):
    """``st.cache_data`` in the Streamlit app, a passthrough elsewhere.

    The backend API (``api.py``) sets ``TRAVEL_PLANNER_API`` and
    imports this module in its own process: there the decorator must
    not cache, so every request reads fresh data. In the Streamlit
    app the caching behaviour is unchanged.
    """
    if st is None or os.environ.get("TRAVEL_PLANNER_API"):
        return func
    return st.cache_data(show_spinner=False)(func)

# ── source selection ───────────────────────────────────────────────────

def use_turso() -> bool:
    """True when Turso is configured (URL + token both present)."""
    return turso_db.is_configured()


def _clear_cache() -> None:
    for cached in (_load_destinations_from_turso,
                   _load_open_tabs_from_turso):
        # A cached function carries .clear(); the API
        # process's passthrough does not (and needs
        # nothing cleared).
        clear = getattr(cached, "clear", None)
        if clear is not None:
            clear()
    data_utils._clear_destination_cache()


# ── destinations: read ─────────────────────────────────────────────────

def _destinations_to_dataframe(dests: list[dict]) -> pd.DataFrame:
    """Build a DataFrame from Turso destinations' ``columns`` tails.

    The first destination's column order is canonical; every other
    destination is aligned to it by name. A column a destination lacks
    (it was added later) reads as ``None`` — the same as a blank cell.
    """
    if not dests:
        return pd.DataFrame()
    columns = [name for name, _value in (dests[0].get("columns") or [])]
    if not columns:
        return pd.DataFrame()
    rows = []
    for dest in dests:
        values = {name: value for name, value in
                  (dest.get("columns") or [])}
        rows.append([values.get(name) for name in columns])
    return pd.DataFrame(rows, columns=columns)


@_cache_data
def _load_destinations_from_turso() -> tuple[pd.DataFrame, dict] | None:
    """Read all destinations from Turso.

    Returns ``(df, metadata)`` or ``None`` when Turso is unreachable or
    empty — the caller then falls back to the workbook. ``None`` (not
    an empty frame) is the signal, because an empty catalogue is a
    legitimate state the caller must not mistake for a failure.
    """
    dests, problems = storage_turso.load_destinations()
    if problems or not dests:
        return None
    df = _destinations_to_dataframe(dests)
    if df.empty:
        return None
    df.columns = [str(col) for col in df.columns]
    return data_utils._prepare_dataframe(df)


def load_destinations(path: Path | None = None) -> tuple[pd.DataFrame, dict]:
    """All destinations as ``(DataFrame, metadata)``.

    An explicit ``path`` that differs from the live workbook means the
    caller wants *that specific file* — the page-smoke tests point the
    pages at a disposable copy, and the sidebar download serves the
    workbook on disk. Only the default path (``None`` or the live
    ``DATA_PATH``) routes through Turso, so a test copy is never
    shadowed by the remote database.
    """
    if path is not None:
        try:
            explicit = Path(path).resolve()
            live = Path(data_utils.DATA_PATH).resolve()
        except OSError:
            explicit = None
            live = None
        if explicit is not None and explicit != live:
            return data_utils.load_destinations(path)
    if use_turso():
        result = _load_destinations_from_turso()
        if result is not None:
            return result
    return data_utils.load_destinations(path or data_utils.DATA_PATH)


def get_destination(name: str) -> tuple[dict | None, list[str]]:
    """One destination by exact name, from Turso when configured."""
    if use_turso():
        return storage_turso.get_destination(name)
    # Workbook fallback: scan the cached frame.
    df, metadata = load_destinations()
    col = metadata["destination_col"]
    matches = df[df[col].astype(str).str.strip().str.lower()
                 == str(name).strip().lower()]
    if matches.empty:
        return None, []
    row = matches.iloc[0]
    return {"destination": str(row[col]), "columns": [
        [str(c), row[c]] for c in df.columns]}, []


# ── destinations: write ────────────────────────────────────────────────

def _set_field(dest: dict, field: str, value) -> None:
    """Set a typed-core field and keep the ``columns`` tail in sync."""
    dest[field] = value
    column = storage_turso.CORE_COLUMNS[field]
    for pair in dest.get("columns") or []:
        if pair[0] == column:
            pair[1] = value
            return
    dest.setdefault("columns", []).append([column, value])


def _modify_destination(name: str, field: str, value) -> bool:
    """Read-modify-write one field of one destination in Turso."""
    dest, problems = storage_turso.get_destination(name)
    if problems or dest is None:
        return False
    _set_field(dest, field, value)
    ok, problems = storage_turso.save_destination(dest)
    if ok:
        _clear_cache()
    return ok


# Every write helper resolves its workbook path at CALL time, never as a
# def-time default: `path: Path = data_utils.DATA_PATH` would capture the
# real workbook at import, and conftest's sandbox rebind (and any runtime
# retarget) could not reach it — a CI test then silently wrote the repo's
# committed cloud seed while reading back the sandbox copy.

def update_favorite_status(destination_name: str, add: bool,
                           path: Path | None = None) -> bool:
    path = path or data_utils.DATA_PATH
    if use_turso():
        return _modify_destination(destination_name, "favourite", add)
    return data_utils.update_favorite_status(destination_name, add, path)


def update_visited_status(destination_name: str, visited: bool,
                          path: Path | None = None) -> bool:
    path = path or data_utils.DATA_PATH
    if use_turso():
        return _modify_destination(destination_name, "visited", visited)
    return data_utils.update_visited_status(destination_name, visited, path)


def update_to_be_researched_status(destination_name: str,
                                   to_be_researched: bool,
                                   path: Path | None = None) -> bool:
    path = path or data_utils.DATA_PATH
    if use_turso():
        return _modify_destination(destination_name, "to_be_researched",
                                   to_be_researched)
    return data_utils.update_to_be_researched_status(
        destination_name, to_be_researched, path)


def update_prio_thorsten(destination_name: str, value: int,
                         path: Path | None = None) -> bool:
    path = path or data_utils.DATA_PATH
    if use_turso():
        return _modify_destination(destination_name, "prio", value)
    return data_utils.update_prio_thorsten(destination_name, value, path)


def update_comment(destination_name: str, value: str,
                   path: Path | None = None) -> bool:
    path = path or data_utils.DATA_PATH
    if use_turso():
        return _modify_destination(destination_name, "comment", value)
    return data_utils.update_comment(destination_name, value, path)


def update_reviews(destination_name: str, review_score: float,
                   tourist_reviews: str, praise: str, dislikes: str,
                   path: Path | None = None) -> bool:
    """Write the review fields. Turso path updates the tail columns."""
    path = path or data_utils.DATA_PATH
    if use_turso():
        dest, problems = storage_turso.get_destination(destination_name)
        if problems or dest is None:
            return False
        _set_field(dest, "comment", dest.get("comment"))
        # The review columns are not typed-core fields; set them in the
        # tail directly so the detail page's review boxes round-trip.
        for column, new_value in (
                ("Reviews", review_score),
                ("Tourist Reviews", tourist_reviews),
                ("What do the reviews praise?", praise),
                ("What do they dislike?", dislikes)):
            for pair in dest.get("columns") or []:
                if pair[0] == column:
                    pair[1] = new_value
                    break
            else:
                dest.setdefault("columns", []).append(
                    [column, new_value])
        ok, problems = storage_turso.save_destination(dest)
        if ok:
            _clear_cache()
        return ok
    return data_utils.update_reviews(
        destination_name, review_score, tourist_reviews, praise,
        dislikes, path)


def update_food(destination_name: str, spiciness: float, description: str,
                dishes=None, path: Path | None = None) -> bool:
    """Write the food fields. Turso path updates the tail columns."""
    path = path or data_utils.DATA_PATH
    if use_turso():
        dest, problems = storage_turso.get_destination(destination_name)
        if problems or dest is None:
            return False
        for column, new_value in (
                ("Food - Spicyness", spiciness),
                ("Food - Description", description)):
            for pair in dest.get("columns") or []:
                if pair[0] == column:
                    pair[1] = new_value
                    break
            else:
                dest.setdefault("columns", []).append(
                    [column, new_value])
        if dishes is not None:
            dishes_str = (", ".join(str(d).strip() for d in dishes
                                    if str(d).strip())
                          if isinstance(dishes, list) else str(dishes).strip())
            for pair in dest.get("columns") or []:
                if pair[0] == "Food - Main Dishes":
                    pair[1] = dishes_str
                    break
            else:
                dest.setdefault("columns", []).append(
                    ["Food - Main Dishes", dishes_str])
        ok, problems = storage_turso.save_destination(dest)
        if ok:
            _clear_cache()
        return ok
    return data_utils.update_food(
        destination_name, spiciness, description, dishes, path)


def add_new_destination(destination_name: str, country: str = "Unknown",
                        continent: str = "Unknown",
                        path: Path | None = None) -> tuple[bool, str]:
    """Append a new destination. Turso path inserts a new row."""
    path = path or data_utils.DATA_PATH
    if use_turso():
        name = str(destination_name).strip()
        if not name:
            return False, "Destination name cannot be empty."
        existing, problems = storage_turso.get_destination(name)
        if problems:
            return False, f"Could not check for duplicates: {problems}"
        if existing is not None:
            return False, f"Destination '{name}' already exists."
        dest = {
            "destination": name,
            "continent": continent,
            "country": country,
            "visited": False,
            "favourite": False,
            "prio": None,
            "safety_rating": None,
            "avg_cost_day": None,
            "flight_time_fra": None,
            "to_be_researched": True,
            "malaria_risk": False,
            "data_status": "PLACEHOLDER - UPDATE REQUIRED",
            "comment": None,
            "columns": [
                ["Destination", name],
                ["Continent", continent],
                ["Country", country],
                ["Data Status", "PLACEHOLDER - UPDATE REQUIRED"],
                ["To be researched", True],
            ],
        }
        ok, problems = storage_turso.save_destination(dest)
        if ok:
            _clear_cache()
            return True, f"Destination '{name}' has been successfully added to the catalog!"
        return False, f"Could not save: {problems}"
    return data_utils.add_new_destination(
        destination_name, country, continent, path)


# ── open tabs ──────────────────────────────────────────────────────────

@_cache_data
def _load_open_tabs_from_turso() -> list[str] | None:
    """Read the open-tabs list from Turso, or ``None`` on failure."""
    tabs, problems = storage_turso.load_open_tabs()
    if problems:
        return None
    return tabs


def load_open_tabs() -> list[str]:
    """The persisted list of open destination tabs."""
    if use_turso():
        tabs = _load_open_tabs_from_turso()
        if tabs is not None:
            return tabs
    return data_utils.load_open_destinations()


def save_open_tabs(tabs: list[str]) -> bool:
    """Persist the open-tabs list. Returns True when written."""
    if use_turso():
        ok, _problems = storage_turso.save_open_tabs(tabs)
        if ok:
            _clear_cache()
        return ok
    data_utils.save_open_destinations(tabs)
    return True


# Names the pages already use (data_utils compatibility), so a
# page switches its import without renaming every call site.
load_open_destinations = load_open_tabs
save_open_destinations = save_open_tabs


# ── workbook export ────────────────────────────────────────────────────

def export_workbook(path: str | Path) -> tuple[bool, list[str]]:
    """Write the destinations back to an .xlsx file (Turso source of
    truth, workbook as a convenience artifact)."""
    if use_turso():
        return storage_turso.export_workbook(str(path))
    return False, ["workbook export requires Turso as the source"]
