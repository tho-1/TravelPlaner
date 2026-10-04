"""Atomic trips.json persistence + rolling backups + ui state.

The file lives next to app.py. Every save is atomic (unique tmp file + retry +
replace), so an interruption, a crash or two browser tabs saving at the same
time can never leave a half-written trips.json behind — and can never
silently overwrite an edit made by another session (see ``TripsFileChanged``).
Before each save the previous content is kept as a timestamped snapshot so an
accidental deletion can be undone (see ``list_backups`` / ``restore_backup``).
"""

from __future__ import annotations

import copy
import json
import os
import time
import uuid
from pathlib import Path

import runtime_paths

from . import models, sample

ROOT = Path(__file__).resolve().parent.parent
TRIPS_PATH = runtime_paths.state_path("trips.json")
# Immutable live-file identity: tests reassign TRIPS_PATH above, so journal
# guards must compare against this constant, never the mutable global.
_LIVE_TRIPS_PATH = ROOT / "trips.json"
CACHE_DIR = runtime_paths.state_path("itinerary_cache")
UI_STATE_PATH = CACHE_DIR / "ui_state.json"
BACKUP_DIR = runtime_paths.state_path("trips_backups")
BACKUP_KEEP = 12

# Number of attempts (and delay) when Windows refuses the atomic replace
# because another process briefly holds a handle on the file.
REPLACE_ATTEMPTS = 4
REPLACE_RETRY_SECONDS = 0.25

# Key used to carry "what the file looked like when this payload was loaded"
# through the load -> mutate -> save round trip.
_SIGNATURE_KEY = "_loaded_signature"

_last_write_error: str | None = None


class TripsFileChanged(RuntimeError):
    """The live trips.json changed after this session loaded it.

    Saving now would silently discard the other session's edit (two browser
    tabs, or the phone and the PC), so the write is refused instead.
    """


def last_write_error() -> str | None:
    """Message of the most recent failed runtime-state write, if any."""
    return _last_write_error


def _note_write_error(message: str | None) -> None:
    global _last_write_error
    _last_write_error = message


def _file_signature(path: Path) -> tuple[int, int] | None:
    try:
        stat = Path(path).stat()
    except OSError:
        return None
    return (stat.st_mtime_ns, stat.st_size)


def file_signature(path: Path | None = None) -> tuple[int, int] | None:
    """(mtime_ns, size) of the live trips file — use as a cache key."""
    return _file_signature(path or TRIPS_PATH)


def _assert_not_stale(path: Path, data: dict) -> None:
    """Refuse a save whose in-memory base is older than the file on disk."""
    if Path(path) != _LIVE_TRIPS_PATH:
        return  # only the live file is shared between sessions
    loaded = data.get(_SIGNATURE_KEY) if isinstance(data, dict) else None
    if not loaded:
        return  # freshly built payload (seed / restore / import) — nothing to compare
    current = _file_signature(path)
    if current is None or current == tuple(loaded):
        return
    raise TripsFileChanged(
        "trips.json was modified by another window or device after this page "
        "was loaded. Saving now would silently discard that change. Reload the "
        "itinerary page and re-apply your edit (the other change stays intact)."
    )


def _atomic_write_text(path: Path, text: str) -> None:
    """Write ``text`` to ``path`` atomically, retrying transient Windows locks.

    The temp file name is unique per process/write, so two concurrent sessions
    can never interleave writes into the same scratch file and then replace
    the live file with a mixture of both payloads.
    """
    target = Path(path)
    tmp = target.with_name(f".{target.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    last_error: OSError | None = None
    try:
        tmp.write_text(text, encoding="utf-8")
        for attempt in range(REPLACE_ATTEMPTS):
            try:
                os.replace(tmp, target)
                return
            except PermissionError as exc:  # file momentarily locked (Excel, AV, sync)
                last_error = exc
                if attempt < REPLACE_ATTEMPTS - 1:
                    time.sleep(REPLACE_RETRY_SECONDS)
        raise OSError(
            f"{target.name} could not be replaced after {REPLACE_ATTEMPTS} "
            f"attempts: {last_error}"
        )
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def load_from(path: Path) -> dict:
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema_version": models.SCHEMA_VERSION, "trips": [],
                _SIGNATURE_KEY: None}
    except Exception:
        # Corrupt file: keep a backup so nothing is silently lost, then start
        # from an empty structure.
        try:
            Path(path).replace(Path(path).with_suffix(".corrupt.bak"))
        except OSError:
            pass
        return {"schema_version": models.SCHEMA_VERSION, "trips": [],
                _SIGNATURE_KEY: None}
    data = models.normalize_all(raw)
    data[_SIGNATURE_KEY] = _file_signature(path)
    return data


def save_to(data: dict, path: Path) -> None:
    payload = models.normalize_all(data)
    _assert_not_stale(Path(path), data)
    diffs = _collect_trips_diffs(path, payload)
    text = json.dumps(payload, ensure_ascii=False, indent=1)
    _snapshot_before_replace(Path(path), text)
    _atomic_write_text(Path(path), text)
    _journal_trips_safe(path, diffs)
    _note_write_error(None)
    # Refresh the caller's base signature: saving the same in-memory payload
    # twice in a row (e.g. two edits in one interaction) must stay possible,
    # while a *different* session's save still trips the guard.
    if isinstance(data, dict):
        data[_SIGNATURE_KEY] = _file_signature(Path(path))


def _collect_trips_diffs(path: Path, new_payload: dict) -> list[tuple[str, str, object, str]]:
    """Compare live file vs new payload.

    Returns ``[(trip_id, variant_id, part, value, op), ...]`` — or 4-tuples
    ``(trip_id, variant_id, value, op)`` for the legacy whole-variant entries
    that older journals still contain.

    Variants are diffed at **stop granularity** (decision 2026-10-04): one
    entry per stop, per leg, plus one for the variant's own fields and one for
    the stop order. A whole-variant key made "keep cloud" discard the PC's
    edit to a *different* stop of the same trip, because there was no way to
    say which parts each side had actually changed.
    """
    try:
        if Path(path) != _LIVE_TRIPS_PATH:
            return []
        old = load_from(path)
    except Exception:
        return []
    old.pop(_SIGNATURE_KEY, None)
    try:
        old_map = {
            (t["id"], v["id"]): v
            for t in old.get("trips", [])
            for v in t.get("variants", [])
        }
        new_map = {
            (t["id"], v["id"]): v
            for t in new_payload.get("trips", [])
            for v in t.get("variants", [])
        }
        diffs: list[tuple] = []

        for key, variant in new_map.items():
            old_variant = old_map.get(key)
            if old_variant is None:
                # Brand new variant: one entry per stop/leg plus the meta.
                diffs.extend(_variant_parts(key, variant, {}, is_new=True))
                continue
            diffs.extend(_variant_parts(key, variant, old_variant,
                                        is_new=False))

        # Anything that disappeared entirely (deleted variant/trip).
        for key in old_map:
            if key not in new_map:
                diffs.append((key[0], key[1], None, "delete"))
        return diffs
    except Exception:
        return []


#: Journal key parts for a variant (see ``_collect_trips_diffs``).
PART_META = "meta"
PART_ORDER = "order"
STOP_PREFIX = "stop:"
LEG_PREFIX = "leg:"

_META_FIELDS = ("name", "notes", "rating", "months", "comment")


def _variant_parts(key: tuple[str, str], variant: dict, old: dict,
                   is_new: bool) -> list[tuple[str, str, str, object, str]]:
    """Per-part diff of one variant between ``old`` and ``variant``."""
    trip_id, variant_id = key
    out: list[tuple[str, str, str, object, str]] = []

    old_stops = {s.get("id"): s for s in (old.get("stops") or []) if isinstance(s, dict)}
    new_stops = [s for s in (variant.get("stops") or []) if isinstance(s, dict)]
    new_stop_ids = {s.get("id") for s in new_stops}

    # 1) variant-level fields
    meta = {field: variant.get(field) for field in _META_FIELDS}
    old_meta = {field: old.get(field) for field in _META_FIELDS} if old else {}
    if is_new or meta != old_meta:
        out.append((trip_id, variant_id, PART_META, meta, "upsert"))

    # 2) stop order (only the ids: the content is diffed per stop)
    order = [s.get("id") for s in new_stops]
    old_order = [s.get("id") for s in (old.get("stops") or [])] if old else []
    if is_new or order != old_order:
        out.append((trip_id, variant_id, PART_ORDER, order, "upsert"))

    # 3) each stop: added / changed
    for stop in new_stops:
        stop_id = stop.get("id")
        if is_new or stop_id not in old_stops or \
                _json(stop) != _json(old_stops[stop_id]):
            out.append((trip_id, variant_id, f"{STOP_PREFIX}{stop_id}",
                        copy.deepcopy(stop), "upsert"))

    # 4) each stop that disappeared
    for stop_id in old_stops:
        if stop_id not in new_stop_ids:
            out.append((trip_id, variant_id, f"{STOP_PREFIX}{stop_id}",
                        None, "delete"))

    # 5) legs, positional: identified by their index
    new_legs = [leg for leg in (variant.get("legs") or []) if isinstance(leg, dict)]
    old_legs = [leg for leg in (old.get("legs") or []) if isinstance(leg, dict)]
    for index, leg in enumerate(new_legs):
        if is_new or index >= len(old_legs) or _json(leg) != _json(old_legs[index]):
            out.append((trip_id, variant_id, f"{LEG_PREFIX}{index}",
                        copy.deepcopy(leg), "upsert"))
    for index in range(len(new_legs), len(old_legs)):
        out.append((trip_id, variant_id, f"{LEG_PREFIX}{index}", None, "delete"))

    return out


def _json(value) -> str:
    try:
        return json.dumps(value, sort_keys=True, ensure_ascii=False, default=str)
    except Exception:
        return repr(value)


def _journal_trips_safe(path: Path, diffs: list[tuple]) -> None:
    if not diffs:
        return
    try:
        if os.environ.get("SYNC_MERGE_APPLY") == "1":
            return
        if Path(path) != _LIVE_TRIPS_PATH:
            return
        from sync import journal as _journal

        _journal.ensure_baseline(trips_path=TRIPS_PATH)
        for diff in diffs:
            if len(diff) == 5:
                trip_id, variant_id, part, value, op = diff
                _journal.record_trips_change(trip_id, variant_id, value,
                                             op=op, key_part=part)
            else:
                # Legacy whole-variant entry (journals written before
                # 2026-10-04) — still replayable.
                trip_id, variant_id, value, op = diff
                _journal.record_trips_change(trip_id, variant_id, value, op=op)
    except Exception:
        pass


def load_trips(path: Path | None = None) -> dict:
    return load_from(path or TRIPS_PATH)


def save_trips(data: dict, path: Path | None = None) -> None:
    save_to(data, path or TRIPS_PATH)


# ── backups ─────────────────────────────────────────────────────────────────

def _snapshot_before_replace(path: Path, new_text: str) -> None:
    """Keep the outgoing trips.json as a timestamped snapshot.

    Skipped when the file is missing/empty or already identical to the newest
    snapshot, so repeated saves don't flood the backup folder.
    """
    if path != TRIPS_PATH:
        return  # only back up the live file, never test paths
    try:
        old = path.read_text(encoding="utf-8")
    except OSError:
        return
    if not old.strip() or old == new_text:
        return
    try:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        newest = _newest_backup()
        if newest is not None and newest.read_text(encoding="utf-8") == old:
            return
        stamp = time.strftime("%Y%m%d-%H%M%S")
        millis = int(time.time() * 1000) % 1000
        target = BACKUP_DIR / f"trips-{stamp}-{millis:03d}.json"
        n = 1
        while target.exists():
            target = BACKUP_DIR / f"trips-{stamp}-{millis:03d}-{n}.json"
            n += 1
        target.write_text(old, encoding="utf-8")
        _prune_backups()
    except OSError:
        pass  # backing up must never block a save


def _backup_paths() -> list[Path]:
    """Oldest first — ordered by mtime, so same-second snapshots can never
    sort out of order."""
    try:
        found = list(BACKUP_DIR.glob("trips-*.json"))
    except OSError:
        return []

    def key(path: Path):
        try:
            return (path.stat().st_mtime, path.name)
        except OSError:
            return (0.0, path.name)

    return sorted(found, key=key)


def _newest_backup() -> Path | None:
    found = _backup_paths()
    return found[-1] if found else None


def _prune_backups() -> None:
    for stale in _backup_paths()[:-BACKUP_KEEP]:
        try:
            stale.unlink()
        except OSError:
            pass


def list_backups() -> list[dict]:
    """Newest first: {path, label, trips} for each snapshot."""
    out = []
    for path in reversed(_backup_paths()):
        try:
            data = models.normalize_all(
                json.loads(path.read_text(encoding="utf-8")))
            names = [
                f"{t['name']} ({len(t['variants'])} variant"
                f"{'s' if len(t['variants']) != 1 else ''})"
                for t in data.get("trips", [])
            ]
        except Exception:
            names = []
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        out.append({"path": str(path),
                    "label": time.strftime("%Y-%m-%d %H:%M:%S",
                                           time.localtime(mtime)),
                    "trips": names})
    return out


def restore_backup(path: str | Path) -> dict:
    """Copy a snapshot over the live file (the current one is snapshotted
    first, so a restore is itself undoable). Returns the restored data."""
    source = Path(path)
    data = models.normalize_all(
        json.loads(source.read_text(encoding="utf-8")))
    save_to(data, TRIPS_PATH)  # snapshots the outgoing state
    return data


# ── ui state (which trip was open last) ─────────────────────────────────────

def load_ui_state() -> dict:
    try:
        raw = json.loads(UI_STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return raw if isinstance(raw, dict) else {}


def save_ui_state(state: dict) -> bool:
    """Persist the convenience UI state. Returns False when it could not be
    written (e.g. a read-only data directory) so the app can say so instead
    of silently forgetting the setting."""
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        _atomic_write_text(
            UI_STATE_PATH,
            json.dumps(state, ensure_ascii=False, indent=1),
        )
    except OSError as exc:
        _note_write_error(str(exc))
        return False
    return True


def ensure_seed(path: Path | None = None) -> dict:
    """First run: create trips.json with the bundled sample trip."""
    target = path or TRIPS_PATH
    if target.exists():
        return load_trips(target)
    data = {"schema_version": models.SCHEMA_VERSION,
            "trips": [sample.make_sample_trip()]}
    save_to(data, target)
    return data


def export_trip(trip: dict) -> str:
    """One trip (all variants/stops/legs) as pretty JSON for download."""
    return json.dumps(models.normalize_trip(trip), ensure_ascii=False, indent=2)
