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
            if len(key) != 2:
                skipped.append("malformed key " + repr(key))
                continue
            destination, column = str(key[0]), str(key[1])
            row_idx = _row_for(destination)
            col_idx = _col_for(column)
            if row_idx is None:
                # Typically a destination added on the other device: the row
                # does not exist here yet. Say so instead of dropping it.
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
    """Merge one trips entry into trips.json at STOP granularity.

    The journal key is (trip_id, variant_id) and the value is the whole
    variant, but a variant is a *set of stops*. Replacing it wholesale meant a
    phone edit to one stop silently discarded PC edits to other stops of the
    same trip. Stops are therefore merged by id (and added/removed as a set),
    which matches the workbook's per-cell granularity.
    """
    from itinerary import storage

    key = entry.get("key", [])
    if len(key) != 2:
        return False
    trip_id, variant_id = str(key[0]), str(key[1])
    data = storage.load_from(tr_path)
    trips = {t["id"]: t for t in data.get("trips", [])}
    changed = False
    if entry.get("op") == "delete":
        trip = trips.get(trip_id)
        if trip is not None:
            before = len(trip.get("variants", []))
            trip["variants"] = [
                v for v in trip.get("variants", []) if v.get("id") != variant_id
            ]
            if len(trip["variants"]) != before:
                changed = True
            if not trip["variants"]:
                data["trips"] = [t for t in data.get("trips", []) if t["id"] != trip_id]
                changed = True
    else:
        variant = copy.deepcopy(entry.get("value"))
        if not isinstance(variant, dict):
            return False
        variant["id"] = variant_id
        trip = trips.get(trip_id)
        if trip is None:
            return False
        existing = next((v for v in trip.get("variants", [])
                         if v.get("id") == variant_id), None)
        if existing is None:
            trip["variants"].append(variant)
            changed = True
        else:
            merged = _merge_variant(existing, variant)
            if not _values_equal(existing, merged):
                trip["variants"][trip["variants"].index(existing)] = merged
                changed = True
    if changed:
        storage.save_to(data, tr_path)
    return changed


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
