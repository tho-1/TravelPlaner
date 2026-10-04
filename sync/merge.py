"""Deterministic merge for sync journals (Phase 2).

Newer-wins per key, with conflicts surfaced — never silently resolved.

- Key: (store, key...). Workbook: ("workbook", destination, column).
  Trips: ("trips", trip_id, variant_id).
- last_sync.json tracks per-key applied timestamps. An entry with ts newer
  than the last applied ts for its key is a change since last sync.
- If both local and remote changed the same key since last sync to different
  values -> conflict, written to conflicts.json for UI review. Nothing is
  applied for that key until the user resolves it.
- If only one side changed -> that side wins and is applied.
- Idempotent re-sync: re-running with no new entries applies nothing.
- Offline accumulation: entries queue in local JSONL until a sync runs.
- Safety: snapshot both stores before applying anything; dry_run previews.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

#: Key part of the "this destination row now exists" journal entry. Kept as a
#: literal so merge.py does not import journal.py at module level (the import
#: graph stays one-directional).
_ROW_KEY = "#row"


def _create_destination_row(entry: dict, ws, headers: dict, dest_idx: int) -> int | None:
    """Append a destination row described by a ``row`` journal entry.

    Returns the new row index, or ``None`` when the entry is unusable. An
    existing row is left untouched: the entry records a *creation*, so applying
    it to a workbook that already has the destination must not overwrite the
    other device's newer edits.
    """
    key = entry.get("key", [])
    if len(key) < 2:
        # A key that is nothing but the marker: there is no destination to
        # create. Applying it would append a row literally named "#row".
        return None
    destination = str(key[0]).strip()
    if not destination or destination == _ROW_KEY:
        return None
    if len(destination) > 200 or "\n" in destination or "\r" in destination:
        return None                      # corrupt entry: never write this
    existing = next(
        (
            r for r in range(2, ws.max_row + 1)
            if ws.cell(r, dest_idx).value is not None
            and str(ws.cell(r, dest_idx).value).strip().casefold() == destination.casefold()
        ),
        None,
    )
    if existing is not None:
        return existing          # already there: nothing to create

    value = entry.get("value") or {}
    if not isinstance(value, dict):
        return None
    new_row = ws.max_row + 1
    ws.cell(new_row, dest_idx).value = destination
    for field in ("Country", "Continent", "Data Status"):
        column = next((i for h, i in headers.items()
                       if h.strip().casefold() == field.casefold()), None)
        if column is not None and value.get(field):
            ws.cell(new_row, column).value = value[field]
    return new_row


def _key_of(entry: dict) -> tuple:
    return (str(entry.get("store")), *[str(k) for k in entry.get("key", [])])


def _entry_sort_key(entry: dict) -> tuple:
    return (str(entry.get("ts", "")), str(entry.get("device", "")))


def _values_equal(a, b) -> bool:
    try:
        return json.dumps(a, sort_keys=True, ensure_ascii=False) == json.dumps(
            b, sort_keys=True, ensure_ascii=False
        )
    except Exception:
        return a == b


def plan_merge(
    local_entries: list[dict],
    remote_entries: list[dict],
    last_applied: dict[str, str] | None = None,
) -> dict:
    """Pure merge planner. Returns {apply, conflicts}.

    apply: list of winning entries to apply (sorted by ts).
    conflicts: list of {key, local, remote} for keys changed on both sides
      since last sync with different values.
    """
    last_applied = last_applied or {}
    by_key: dict[tuple, dict[str, list[dict]]] = {}
    for entry in list(local_entries) + list(remote_entries):
        by_key.setdefault(_key_of(entry), {"local": [], "remote": []})
    for entry in local_entries:
        by_key[_key_of(entry)]["local"].append(entry)
    for entry in remote_entries:
        by_key[_key_of(entry)]["remote"].append(entry)

    apply: list[dict] = []
    conflicts: list[dict] = []
    for key, sides in by_key.items():
        locals_sorted = sorted(sides["local"], key=_entry_sort_key)
        remotes_sorted = sorted(sides["remote"], key=_entry_sort_key)
        key_str = json.dumps(key, ensure_ascii=False)
        since = last_applied.get(key_str)
        local_new = [e for e in locals_sorted if since is None or e["ts"] > since]
        remote_new = [e for e in remotes_sorted if since is None or e["ts"] > since]
        if local_new and remote_new:
            if _values_equal(local_new[-1]["value"], remote_new[-1]["value"]) and local_new[
                -1
            ].get("op") == remote_new[-1].get("op"):
                winner = max(
                    [local_new[-1], remote_new[-1]], key=_entry_sort_key
                )
                apply.append(winner)
            else:
                conflicts.append(
                    {"key": list(key), "local": local_new[-1], "remote": remote_new[-1]}
                )
        elif local_new:
            apply.append(local_new[-1])
        elif remote_new:
            apply.append(remote_new[-1])
    apply.sort(key=_entry_sort_key)
    return {"apply": apply, "conflicts": conflicts}


def _snapshot_file(path: Path, backup_dir: Path, prefix: str) -> Path | None:
    try:
        if not path.exists():
            return None
        backup_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        millis = int(time.time() * 1000) % 1000
        target = backup_dir / f"{prefix}-{stamp}-{millis:03d}{path.suffix}"
        shutil.copy2(path, target)
        return target
    except OSError:
        return None


def apply_entries(
    entries: list[dict],
    workbook_path: Path | None = None,
    trips_path: Path | None = None,
    dry_run: bool = False,
) -> dict:
    """Apply winning entries to both stores. Snapshots first. Returns summary.

    Sets SYNC_MERGE_APPLY=1 so the apply itself is not re-journaled.
    """
    from environment import get_workbook_path

    wb_path = Path(workbook_path) if workbook_path else get_workbook_path()
    tr_path = Path(trips_path) if trips_path else (ROOT / "trips.json")
    ordered = sorted(entries, key=_entry_sort_key)
    if dry_run:
        return {"would_apply": len(ordered), "snapshots": [], "applied": 0}

    workbook_entries = [e for e in ordered if e.get("store") == "workbook"]
    trips_entries = [e for e in ordered if e.get("store") == "trips"]

    # Snapshot ONLY the store that is about to be written. The old code always
    # snapshotted the workbook, so a trips-only sync (and every test that called
    # apply_entries without a workbook_path) filled the 12-deep workbook backup
    # rotation with copies nobody would ever restore. trips.json is snapshotted
    # by storage.save_to() itself, so it needs nothing here.
    snapshots: list[str] = []
    if workbook_entries:
        snap = _snapshot_file(wb_path, wb_path.parent / "workbook_backups",
                              wb_path.stem)
        if snap is not None:
            snapshots.append(str(snap))

    previous_flag = os.environ.get("SYNC_MERGE_APPLY")
    os.environ["SYNC_MERGE_APPLY"] = "1"
    try:
        applied = 0
        skipped: list[str] = []
        if workbook_entries:
            applied, skipped = _apply_workbook_entries(workbook_entries, wb_path)
        for entry in trips_entries:
            if _apply_trips(entry, tr_path):
                applied += 1
            else:
                key = entry.get("key", [])
                skipped.append("trips / " + " / ".join(str(k) for k in key))
    finally:
        if previous_flag is None:
            os.environ.pop("SYNC_MERGE_APPLY", None)
        else:
            os.environ["SYNC_MERGE_APPLY"] = previous_flag
    return {"applied": applied, "skipped": skipped, "snapshots": snapshots}


def _apply_workbook_entries(entries: list[dict], wb_path: Path) -> tuple[int, list[str]]:
    """Apply every workbook cell entry in ONE load/save cycle.

    Returns ``(applied, skipped)``. The old code loaded, edited, saved and
    snapshotted the workbook per entry: a 30-cell sync meant 30 serialisations
    of a 300 KB workbook, and because ``_snapshot_workbook`` keeps only the
    newest 12, the pre-sync snapshot taken just before the apply was deleted by
    the 12th write.
    """
    from data_utils import (
        _find_destination_sheet,
        load_workbook_for_update,
        save_workbook_atomic,
    )

    sheet = _find_destination_sheet(wb_path)
    if sheet is None:
        return 0, [f"{wb_path.name}: no destinations sheet"]
    try:
        wb = load_workbook_for_update(wb_path)
    except Exception:
        return 0, [f"{wb_path.name}: could not be opened for writing"]

    applied = 0
    skipped: list[str] = []
    try:
        ws = wb[sheet]
        headers: dict[str, int] = {}
        for idx in range(1, ws.max_column + 1):
            header_value = ws.cell(row=1, column=idx).value
            if header_value is not None:
                headers[str(header_value)] = idx
        dest_idx = next(
            (i for h, i in headers.items() if "destination" in h.lower()), None
        )
        if dest_idx is None:
            return 0, [f"{wb_path.name}: no Destination column"]

        row_cache: dict[str, int | None] = {}
        col_cache: dict[str, int | None] = {}
        missing_rows: set[str] = set()

        def _row_for(destination: str) -> int | None:
            key = destination.strip().lower()
            if key not in row_cache:
                row_cache[key] = next(
                    (
                        r
                        for r in range(2, ws.max_row + 1)
                        if ws.cell(r, dest_idx).value is not None
                        and str(ws.cell(r, dest_idx).value).strip().lower() == key
                    ),
                    None,
                )
            return row_cache[key]

        def _col_for(column: str) -> int | None:
            if column not in col_cache:
                lowered = column.strip().lower()
                col_cache[column] = headers.get(column) or next(
                    (i for h, i in headers.items() if h.strip().lower() == lowered),
                    None,
                )
            return col_cache[column]

        for entry in entries:
            key = entry.get("key", [])
            # A row entry carries the ROW_KEY marker anywhere in its key; a
            # truncated key (just the marker) is reported, not applied as a
            # cell write to a column called "#row".
            if _ROW_KEY in [str(part) for part in key]:
                created = _create_destination_row(entry, ws, headers, dest_idx)
                if created is None:
                    skipped.append(
                        f"{key[0] if key else '?'} (row could not be created)")
                else:
                    row_cache[str(key[0]).strip().lower()] = created
                    applied += 1
                continue
            if len(key) != 2:
                skipped.append("malformed key " + repr(key))
                continue
            destination, column = str(key[0]), str(key[1])
            row_idx = _row_for(destination)
            col_idx = _col_for(column)
            if row_idx is None:
                # The destination's row entry has not arrived yet (or arrived
                # after these cells). Say so instead of dropping it silently.
                if destination not in missing_rows:
                    missing_rows.add(destination)
                    skipped.append(f"{destination} (row not in this workbook)")
                continue
            if col_idx is None:
                skipped.append(f"{destination} / {column} (no such column)")
                continue
            ws.cell(row_idx, column=col_idx).value = copy.deepcopy(entry.get("value"))
            applied += 1
        if applied:
            save_workbook_atomic(wb, wb_path)
    except Exception as exc:
        applied = 0
        skipped.append(f"{wb_path.name}: apply failed ({type(exc).__name__})")
    finally:
        try:
            wb.close()
        except Exception:
            pass
    return applied, skipped


def _apply_trips(entry: dict, tr_path: Path) -> bool:
    """Apply one trips entry to trips.json.

    Three key shapes are supported:

    * ``(trip_id, variant_id, part)`` — the current per-stop granularity:
      ``meta``, ``order``, ``stop:<id>``, ``leg:<index>``. Two devices editing
      *different* stops of the same trip therefore both keep their change.
    * ``(trip_id, variant_id)`` — the legacy whole-variant entry written before
      2026-10-04; still replayed for journals created back then.
    * ``op == "delete"`` without a part — the variant (and, if it was the last
      one, the trip) is removed.
    """
    from itinerary import storage

    key = entry.get("key", [])
    if len(key) not in (2, 3):
        return False
    trip_id, variant_id = str(key[0]), str(key[1])
    part = str(key[2]) if len(key) == 3 else None

    data = storage.load_from(tr_path)
    trips = {t["id"]: t for t in data.get("trips", [])}
    trip = trips.get(trip_id)
    if trip is None:
        return False

    if entry.get("op") == "delete" and part is None:
        before = len(trip.get("variants", []))
        trip["variants"] = [v for v in trip.get("variants", [])
                            if v.get("id") != variant_id]
        changed = len(trip["variants"]) != before
        if not trip["variants"]:
            data["trips"] = [t for t in data.get("trips", []) if t["id"] != trip_id]
            changed = True
        if changed:
            storage.save_to(data, tr_path)
        return changed

    existing = next((v for v in trip.get("variants", [])
                     if v.get("id") == variant_id), None)

    if part is None:
        # Legacy whole-variant upsert: the winner is authoritative.
        variant = copy.deepcopy(entry.get("value"))
        if not isinstance(variant, dict):
            return False
        variant["id"] = variant_id
        if existing is None:
            trip["variants"].append(variant)
            storage.save_to(data, tr_path)
            return True
        merged = _merge_variant(existing, variant)
        if _values_equal(existing, merged):
            return False
        trip["variants"][trip["variants"].index(existing)] = merged
        storage.save_to(data, tr_path)
        return True

    # ── per-part entries ────────────────────────────────────────────────────
    if existing is None:
        # The variant's own creation entry (meta) is what creates it; any
        # other part for an unknown variant is ignored.
        if part != _PART_META:
            return False
        meta = entry.get("value")
        if not isinstance(meta, dict):
            return False
        variant = {field: meta.get(field) for field in _META_FIELDS}
        variant.update({"id": variant_id, "stops": [], "legs": [],
                        "notes": "", "months": [], "comment": ""})
        trip["variants"].append(variant)
        storage.save_to(data, tr_path)
        return True

    before = _json(existing)
    stops = [s for s in existing.get("stops", []) if isinstance(s, dict)]

    if part == _PART_META:
        meta = entry.get("value")
        if isinstance(meta, dict):
            for field in _META_FIELDS:
                if field in meta:
                    existing[field] = meta[field]
    elif part == _PART_ORDER:
        order = entry.get("value") or []
        by_id = {s.get("id"): s for s in stops}
        ordered = [by_id[i] for i in order if i in by_id]
        # A stop the order entry does not mention keeps its relative position.
        stops = ordered + [s for s in stops if s not in ordered]
    elif part.startswith(_STOP_PREFIX):
        stop_id = part[len(_STOP_PREFIX):]
        if entry.get("op") == "delete":
            stops = [s for s in stops if s.get("id") != stop_id]
        else:
            stop = entry.get("value")
            if not isinstance(stop, dict):
                return False
            stop = copy.deepcopy(stop)
            stop["id"] = stop_id
            for index, existing_stop in enumerate(stops):
                if existing_stop.get("id") == stop_id:
                    stops[index] = stop
                    break
            else:
                stops.append(stop)
    elif part.startswith(_LEG_PREFIX):
        index_text = part[len(_LEG_PREFIX):]
        if not index_text.isdigit():
            return False
        index = int(index_text)
        legs = [leg for leg in existing.get("legs", []) if isinstance(leg, dict)]
        while len(legs) <= index:
            legs.append({})
        if entry.get("op") == "delete":
            if index < len(legs):
                legs.pop(index)
        else:
            leg = copy.deepcopy(entry.get("value"))
            if isinstance(leg, dict):
                legs[index] = leg
        existing["legs"] = legs
    else:
        return False

    existing["stops"] = stops
    existing["legs"] = [leg for leg in (existing.get("legs") or [])
                       if isinstance(leg, dict)]
    # Keep the positional-legs invariant after a partial merge.
    if len(existing["legs"]) != max(0, len(existing["stops"]) - 1):
        existing["legs"] = _resize_legs(existing["legs"],
                                        max(0, len(existing["stops"]) - 1))
    if _json(existing) == before:
        return False
    storage.save_to(data, tr_path)
    return True


_PART_META = "meta"
_PART_ORDER = "order"
_STOP_PREFIX = "stop:"
_LEG_PREFIX = "leg:"
_META_FIELDS = ("name", "notes", "rating", "months", "comment")


def _resize_legs(legs: list, wanted: int) -> list:
    """Trim or extend a leg list to ``wanted`` entries, keeping known modes."""
    out = [leg for leg in legs if isinstance(leg, dict)][:wanted]
    while len(out) < wanted:
        out.append({"mode": "flight", "note": ""})
    return out


def _json(value) -> str:
    try:
        return json.dumps(value, sort_keys=True, ensure_ascii=False, default=str)
    except Exception:
        return repr(value)


def _merge_variant(local: dict, remote: dict) -> dict:
    """Apply the winning variant, repairing the positional-legs invariant.

    The journal key is (trip_id, variant_id) and its value is the whole
    variant, so the winner is authoritative for that variant: its stop list,
    its order and its fields. A union with the local stops was tried and
    rejected — it cannot express a *deletion*, so a stop the user removed on
    the phone reappeared from the PC's stale copy.

    Consequence (deliberate, and stated in the conflict UI): "keep cloud"
    replaces the variant, so an unsynced PC edit to a *different* stop of the
    same variant is discarded. Removing that limitation needs per-stop journal
    keys (``_collect_trips_diffs`` emitting one entry per stop), which is the
    planned next step — see PLAN.md.
    """
    merged = copy.deepcopy(remote)
    stops = [copy.deepcopy(s) for s in merged.get("stops", []) if isinstance(s, dict)]
    legs = merged.get("legs")
    if not isinstance(legs, list) or len(legs) != max(0, len(stops) - 1):
        legs = copy.deepcopy(local.get("legs") or [])
    if len(legs) != max(0, len(stops) - 1):
        from itinerary import models

        legs = [models.make_leg() for _ in range(max(0, len(stops) - 1))]
    merged["stops"] = stops
    merged["legs"] = legs
    return merged


def load_last_applied(journal_dir: Path | str | None = None) -> dict[str, str]:
    from sync import journal as _journal

    jdir = Path(journal_dir) if journal_dir else _journal.DEFAULT_JOURNAL_DIR
    path = jdir / "last_sync.json"
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("applied", {})
    except Exception:
        return {}


def save_last_applied(
    applied_entries: list[dict],
    journal_dir: Path | str | None = None,
) -> None:
    from sync import journal as _journal

    jdir = Path(journal_dir) if journal_dir else _journal.DEFAULT_JOURNAL_DIR
    jdir.mkdir(parents=True, exist_ok=True)
    current = load_last_applied(jdir)
    for entry in applied_entries:
        current[json.dumps(_key_of(entry), ensure_ascii=False)] = str(entry["ts"])
    (jdir / "last_sync.json").write_text(
        json.dumps(
            {"last_sync_utc": _journal._utcnow_iso(), "applied": current},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


def load_conflicts(journal_dir: Path | str | None = None) -> list[dict]:
    from sync import journal as _journal

    jdir = Path(journal_dir) if journal_dir else _journal.DEFAULT_JOURNAL_DIR
    try:
        return json.loads((jdir / "conflicts.json").read_text(encoding="utf-8"))
    except Exception:
        return []


def save_conflicts(conflicts: list[dict], journal_dir: Path | str | None = None) -> None:
    from sync import journal as _journal

    jdir = Path(journal_dir) if journal_dir else _journal.DEFAULT_JOURNAL_DIR
    jdir.mkdir(parents=True, exist_ok=True)
    (jdir / "conflicts.json").write_text(
        json.dumps(conflicts, ensure_ascii=False, indent=2), encoding="utf-8"
    )
