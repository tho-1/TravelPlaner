"""Shared pytest fixtures.

Every test runs against a *copy* of the real workbook in a temporary
directory: the suite must never write to ``Destinations-local.xlsx``,
``trips.json`` or the sync journals (an earlier version snapshotted the live
workbook on every run and quietly ate slots in the 12-deep backup rotation).
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

LIVE_WORKBOOK = ROOT / "Destinations-local.xlsx"
CLOUD_WORKBOOK = ROOT / "Destinations-cloud.xlsx"


def _source_workbook() -> Path | None:
    for candidate in (LIVE_WORKBOOK, CLOUD_WORKBOOK):
        if candidate.exists():
            return candidate
    return None


@pytest.fixture(scope="session")
def workbook_source() -> Path | None:
    if not _source_workbook():
        pytest.skip("no destinations workbook available")
    return _source_workbook()


@pytest.fixture()
def sandbox(tmp_path, monkeypatch, workbook_source):
    """Isolated runtime state: trips, journals, backups, tabs, caches.

    Returns the sandbox directory. ``TRAVEL_PLANNER_DATA_DIR`` is set *before*
    anything imports ``runtime_paths``-derived paths, so no test can touch the
    real files.
    """
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    monkeypatch.setenv("TRAVEL_PLANNER_DATA_DIR", str(data_dir))
    monkeypatch.setenv("SYNC_DEVICE_ID", "test-device")
    monkeypatch.delenv("SYNC_MERGE_APPLY", raising=False)

    from itinerary import storage
    from sync import journal

    monkeypatch.setattr(storage, "TRIPS_PATH", data_dir / "trips.json")
    monkeypatch.setattr(storage, "_LIVE_TRIPS_PATH", data_dir / "trips.json")
    monkeypatch.setattr(storage, "CACHE_DIR", data_dir / "itinerary_cache")
    monkeypatch.setattr(storage, "UI_STATE_PATH",
                        data_dir / "itinerary_cache" / "ui_state.json")
    monkeypatch.setattr(storage, "BACKUP_DIR", data_dir / "trips_backups")
    monkeypatch.setattr(journal, "DEFAULT_JOURNAL_DIR", data_dir / "sync_journals")

    import data_utils

    monkeypatch.setattr(data_utils, "OPEN_TABS_PATH", data_dir / "open_destinations.json")
    monkeypatch.setattr(data_utils, "_clear_destination_cache", lambda: None)
    storage._note_write_error(None)
    return data_dir


@pytest.fixture()
def workbook_copy(tmp_path, workbook_source):
    """A writable copy of the real destinations workbook."""
    target = tmp_path / "wb.xlsx"
    shutil.copy2(workbook_source, target)
    return target


@pytest.fixture()
def no_network(monkeypatch):
    """Make every outbound HTTP call fail loudly instead of hanging a test."""

    class _Blocked(RuntimeError):
        pass

    def _blocked(*args, **kwargs):
        raise _Blocked("network access is disabled in tests")

    import requests

    monkeypatch.setattr(requests, "get", _blocked)
    monkeypatch.setattr(requests, "post", _blocked)
    monkeypatch.setattr(requests.Session, "request", _blocked)
    return _blocked


@pytest.fixture(autouse=True)
def _no_streamlit_runtime_leaks():
    """Keep Streamlit's cache from leaking state between tests."""
    yield
    try:
        import data_utils

        data_utils._clear_destination_cache()
    except Exception:
        pass
