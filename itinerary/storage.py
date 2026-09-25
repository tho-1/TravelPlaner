"""Atomic trips.json persistence + rolling backups + ui state.

The file lives next to app.py. Every save is atomic (tmp file + replace), so
an interruption or crash can never leave a half-written trips.json behind.
Before each save the previous content is kept as a timestamped snapshot so an
accidental deletion can be undone (see ``list_backups`` / ``restore_backup``).
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from . import models, sample

ROOT = Path(__file__).resolve().parent.parent
TRIPS_PATH = ROOT / "trips.json"
CACHE_DIR = ROOT / "itinerary_cache"
UI_STATE_PATH = CACHE_DIR / "ui_state.json"
BACKUP_DIR = ROOT / "trips_backups"
BACKUP_KEEP = 12


def load_from(path: Path) -> dict:
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema_version": models.SCHEMA_VERSION, "trips": []}
    except Exception:
        # Corrupt file: keep a backup so nothing is silently lost, then start
        # from an empty structure.
        try:
            Path(path).replace(Path(path).with_suffix(".corrupt.bak"))
        except OSError:
            pass
        return {"schema_version": models.SCHEMA_VERSION, "trips": []}
    return models.normalize_all(raw)


def save_to(data: dict, path: Path) -> None:
    payload = models.normalize_all(data)
    tmp = Path(path).with_suffix(".tmp")
    text = json.dumps(payload, ensure_ascii=False, indent=1)
    tmp.write_text(text, encoding="utf-8")
    _snapshot_before_replace(Path(path), text)
    tmp.replace(path)  # atomic


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


def save_ui_state(state: dict) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = UI_STATE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1),
                       encoding="utf-8")
        tmp.replace(UI_STATE_PATH)
    except OSError:
        pass  # pure convenience state — never break the app over it


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
