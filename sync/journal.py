"""Append-only change journals for local <-> Cloud sync (Phase 2).

Design (PLAN.md Phase 2):
- Every successful write records one JSONL entry per changed key.
- Workbook key: (destination, column header). Trips key: (trip_id, variant_id).
- Entry: ts (UTC) + device id + store + op + key + value.
- Files: sync_journals/<device>-<YYYYMMDD>.jsonl (gitignored, transported via
  data-sync branch later). Baseline in sync_journals/baseline.json marks the
  starting point; journals only record changes after the baseline.

This module implements journal + baseline + round-trip only. Transport
(GitHub), merge, and UI arrive in later steps and will need the GitHub PAT.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

import runtime_paths

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_JOURNAL_DIR = runtime_paths.state_path("sync_journals")
BASELINE_FILENAME = "baseline.json"


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def get_device_id() -> str:
    """Stable per-device id. Override with SYNC_DEVICE_ID env var (tests)."""
    override = os.environ.get("SYNC_DEVICE_ID")
    if override and override.strip():
        return override.strip()
    try:
        from environment import detect_environment

        return detect_environment()
    except Exception:
        return "local"


def _journal_dir(journal_dir: Path | str | None) -> Path:
    return Path(journal_dir) if journal_dir else DEFAULT_JOURNAL_DIR


def _journal_file(device: str, journal_dir: Path, timestamp: str | None = None) -> Path:
    day = (timestamp or _utcnow_iso())[:10]
    safe_device = "".join(c if c.isalnum() or c in "-_" else "_" for c in device)
    return journal_dir / f"{safe_device}-{day}.jsonl"


def ensure_baseline(
    journal_dir: Path | str | None = None,
    workbook_path: Path | str | None = None,
    trips_path: Path | str | None = None,
) -> dict:
    """Create baseline.json once; return it. Never overwrites an existing one."""
    jdir = _journal_dir(journal_dir)
    jdir.mkdir(parents=True, exist_ok=True)
    baseline_path = jdir / BASELINE_FILENAME
    if baseline_path.exists():
        try:
            return json.loads(baseline_path.read_text(encoding="utf-8"))
        except Exception:
            pass
    baseline = {
        "created_utc": _utcnow_iso(),
        "device": get_device_id(),
        "workbook": _file_fingerprint(workbook_path),
        "trips": _file_fingerprint(trips_path),
    }
    baseline_path.write_text(
        json.dumps(baseline, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return baseline


def get_baseline(journal_dir: Path | str | None = None) -> dict | None:
    path = _journal_dir(journal_dir) / BASELINE_FILENAME
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _file_fingerprint(path: Path | str | None) -> dict | None:
    if not path:
        return None
    try:
        p = Path(path)
        st = p.stat()
        return {"path": p.name, "mtime_ns": st.st_mtime_ns, "size": st.st_size}
    except OSError:
        return None


def _make_entry(
    store: str,
    key: list,
    value,
    op: str = "upsert",
    device: str | None = None,
    timestamp: str | None = None,
) -> dict:
    return {
        "ts": timestamp or _utcnow_iso(),
        "device": device or get_device_id(),
        "store": store,
        "op": op,
        "key": list(key),
        "value": value,
    }


def append_entry(
    entry: dict, journal_dir: Path | str | None = None
) -> Path:
    """Append one entry to a JSONL file and return it.

    The FILE is always owned by the device that performs the write
    (``get_device_id()``), never by ``entry["device"]``. The entry keeps its
    original ``device`` field, which is what the merge uses.

    Why this matters: when a device applied another device's winning entry it
    used to append into that device's file name and then upload it, replacing
    the other device's journal on the shared ``data-sync`` branch with a
    partial copy. Journal files are per-writer; merges happen at read time.
    """
    jdir = _journal_dir(journal_dir)
    jdir.mkdir(parents=True, exist_ok=True)
    for field in ("ts", "device", "store", "op", "key"):
        if field not in entry:
            raise ValueError(f"journal entry missing {field!r}")
    target = _journal_file(get_device_id(), jdir, str(entry["ts"]))
    with target.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return target


def append_entries(entries: list[dict],
                   journal_dir: Path | str | None = None) -> Path | None:
    """Append several entries to this device's journal file(s)."""
    written: Path | None = None
    for entry in entries:
        written = append_entry(entry, journal_dir)
    return written


#: Reserved key part for the "this destination row now exists" entry. A cell
#: entry is ``(destination, column)``; the row entry is ``(destination, ROW_KEY)``
#: so the receiving device can append the row before the cell changes land.
ROW_KEY = "#row"


def record_destination_row(
    destination: str,
    country: str | None = None,
    continent: str | None = None,
    data_status: str | None = None,
    device: str | None = None,
    journal_dir: Path | str | None = None,
    timestamp: str | None = None,
) -> Path:
    """Journal the *creation* of a destination row.

    Without this, a destination added on the PC could never reach the phone: the
    sync can only write cells into a row that already exists there, so the new
    destination's climate/cost cells were silently reported as "skipped".
    """
    value = {
        "Destination": str(destination).strip(),
        "Country": (str(country).strip() if country else None),
        "Continent": (str(continent).strip() if continent else None),
    }
    if data_status:
        value["Data Status"] = str(data_status)
    entry = _make_entry("workbook", [str(destination).strip(), ROW_KEY], value,
                        "row", device, timestamp)
    return append_entry(entry, journal_dir)


def record_workbook_change(
    destination: str,
    column: str,
    value,
    op: str = "upsert",
    device: str | None = None,
    journal_dir: Path | str | None = None,
    timestamp: str | None = None,
) -> Path:
    entry = _make_entry(
        "workbook", [str(destination), str(column)], value, op, device, timestamp
    )
    return append_entry(entry, journal_dir)


def record_trips_change(
    trip_id: str,
    variant_id: str,
    value,
    op: str = "upsert",
    device: str | None = None,
    journal_dir: Path | str | None = None,
    timestamp: str | None = None,
    key_part: str | None = None,
) -> Path:
    """Journal one change to a trip variant.

    ``key_part`` selects the granularity (decision 2026-10-04): ``"meta"``,
    ``"order"``, ``"stop:<id>"``, ``"leg:<index>"``. Without it the legacy
    2-element key (whole variant) is written, which older journals still use.
    """
    key = [str(trip_id), str(variant_id)]
    if key_part:
        key.append(str(key_part))
    entry = _make_entry("trips", key, value, op, device, timestamp)
    return append_entry(entry, journal_dir)


def read_entries(journal_dir: Path | str | None = None) -> list[dict]:
    """Read all *.jsonl entries sorted by (ts, device). Skips blank lines."""
    jdir = _journal_dir(journal_dir)
    entries: list[dict] = []
    if not jdir.exists():
        return entries
    for path in sorted(jdir.glob("*.jsonl")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                entries.append(json.loads(line))
            except Exception:
                continue
    entries.sort(key=lambda e: (str(e.get("ts", "")), str(e.get("device", ""))))
    return entries
