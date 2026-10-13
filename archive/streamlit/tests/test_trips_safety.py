"""Data-safety tests for ``trips.json`` persistence.

Covers the silent-data-loss bug: two browser tabs (or the phone and the PC)
both load the file, and the second save rewrote the whole file from its stale
in-memory copy, destroying the first tab's stop with no error at all.

These tests need pytest (they use the ``sandbox`` fixture). Run with:
    python -m pytest tests/test_trips_safety.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from itinerary import itinerary as ops  # noqa: E402
from itinerary import models, sample, storage


def _trip(name: str = "China Trip 2027") -> dict:
    trip = sample.make_sample_trip()
    trip["name"] = name
    return trip


def _stop_names(data: dict) -> list[str]:
    trip = data["trips"][0]
    variant = models.active_variant(trip)
    return [s["ref"]["name"] for s in variant["stops"]]


def _add(data: dict, name: str, lat: float = 35.0, lon: float = 135.0) -> None:
    variant = models.active_variant(data["trips"][0])
    ops.add_stop(variant, models.make_ref("custom", name, "Japan", lat, lon))


# ── the core regression: a stale save must be refused, not applied ───────────

def test_second_tab_cannot_silently_overwrite_the_first(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})

    tab_a = storage.load_trips()
    tab_b = storage.load_trips()          # both tabs see the same file

    _add(tab_a, "Kyoto")
    storage.save_trips(tab_a)             # tab A saves

    _add(tab_b, "Osaka")                  # tab B still has the old copy
    with pytest.raises(storage.TripsFileChanged):
        storage.save_trips(tab_b)         # <- used to succeed and lose Kyoto

    names = _stop_names(storage.load_trips())
    assert "Kyoto" in names, "tab A's stop must survive"
    assert "Osaka" not in names, "the refused write must not be applied"


def test_stale_error_message_explains_the_recovery(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    first = storage.load_trips()
    second = storage.load_trips()
    _add(first, "Kyoto")
    storage.save_trips(first)
    with pytest.raises(storage.TripsFileChanged) as excinfo:
        _add(second, "Osaka") or storage.save_trips(second)
    message = str(excinfo.value)
    assert "Reload" in message and "another" in message


def test_reload_lets_the_edit_be_applied_afterwards(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    tab_a = storage.load_trips()
    _add(tab_a, "Kyoto")
    storage.save_trips(tab_a)

    fresh = storage.load_trips()          # what "Reload latest data" does
    _add(fresh, "Osaka")
    storage.save_trips(fresh)

    names = _stop_names(storage.load_trips())
    assert {"Kyoto", "Osaka"} <= set(names)


def test_fresh_payload_without_signature_may_write(sandbox):
    """Seed / restore / import payloads carry no signature and must save."""
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    payload = {"schema_version": 1, "trips": [_trip("Imported")]}
    storage.save_trips(payload)           # must not raise
    assert storage.load_trips()["trips"][0]["name"] == "Imported"


def test_signature_is_not_persisted_into_the_json(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    raw = json.loads(storage.TRIPS_PATH.read_text(encoding="utf-8"))
    assert "_loaded_signature" not in raw
    assert storage.load_trips()["trips"]      # normalizes cleanly


def test_guard_only_applies_to_the_shared_live_file(sandbox, tmp_path):
    """A non-live path (tests, exports) is never shared, so never blocked."""
    other = sandbox / "other.json"
    data = storage.load_trips()
    storage.save_to(data, other)
    data2 = storage.load_from(other)
    data2["trips"] = []
    storage.save_to(data2, other)         # same "stale" signature, still fine
    assert storage.load_from(other)["trips"] == []


# ── atomic write mechanics ───────────────────────────────────────────────────

def test_temp_file_names_are_unique_per_write(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    data = storage.load_trips()
    _add(data, "Kyoto")
    storage.save_trips(data)
    _add(data, "Nara")
    storage.save_trips(data)
    leftovers = [p.name for p in sandbox.iterdir() if p.name.endswith(".tmp")]
    assert leftovers == [], f"temp files must be cleaned up: {leftovers}"


def test_locked_target_is_retried_then_reported(sandbox, monkeypatch):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    data = storage.load_trips()
    _add(data, "Kyoto")

    attempts = {"n": 0}
    real_replace = os.replace

    def flaky_replace(src, dst, *args, **kwargs):
        attempts["n"] += 1
        if attempts["n"] < 3:
            raise PermissionError("file is locked by another program")
        return real_replace(src, dst, *args, **kwargs)

    monkeypatch.setattr(storage.os, "replace", flaky_replace)
    monkeypatch.setattr(storage, "REPLACE_RETRY_SECONDS", 0.0)
    storage.save_trips(data)                      # succeeds on the 3rd attempt
    assert attempts["n"] >= 3
    assert "Kyoto" in _stop_names(storage.load_trips())


def test_permanently_locked_target_raises_and_keeps_the_file(sandbox, monkeypatch):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    before = storage.TRIPS_PATH.read_text(encoding="utf-8")
    data = storage.load_trips()
    _add(data, "Kyoto")

    def always_locked(src, dst, *args, **kwargs):
        raise PermissionError("locked")

    monkeypatch.setattr(storage.os, "replace", always_locked)
    monkeypatch.setattr(storage, "REPLACE_RETRY_SECONDS", 0.0)
    with pytest.raises(OSError):
        storage.save_trips(data)
    assert storage.TRIPS_PATH.read_text(encoding="utf-8") == before


# ── backups still work through the new write path ────────────────────────────

def test_backup_is_taken_and_restore_round_trips(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    data = storage.load_trips()
    data["trips"][0]["name"] = "Renamed"
    storage.save_trips(data)
    backups = storage.list_backups()
    assert backups, "a snapshot must exist before the replace"
    storage.restore_backup(backups[0]["path"])
    assert storage.load_trips()["trips"][0]["name"] == "China Trip 2027"


def test_ui_state_reports_failure_instead_of_swallowing(sandbox, monkeypatch):
    assert storage.save_ui_state({"active_trip_id": "x"}) is True

    def boom(*args, **kwargs):
        raise OSError("read-only file system")

    monkeypatch.setattr(storage, "_atomic_write_text", boom)
    assert storage.save_ui_state({"active_trip_id": "y"}) is False
    assert storage.last_write_error()


def test_file_signature_changes_with_content(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [_trip()]})
    first = storage.file_signature()
    data = storage.load_trips()
    _add(data, "Kyoto")
    storage.save_trips(data)
    assert storage.file_signature() != first


def test_public_file_signature_helper_handles_missing_files(tmp_path):
    assert storage.file_signature(tmp_path / "nope.json") is None


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit("This module needs pytest: python -m pytest tests/test_trips_safety.py")
