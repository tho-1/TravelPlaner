"""The Turso branch of the trips persistence
(NATIVE_HTML_PLAN.md, Phase 4).

The suite's autouse fixtures force the file branch,
so these tests patch ``turso_db.is_configured``
themselves -- the same pattern the repository tests
use. The Turso calls are faked: no network, no
credentials.
"""

from __future__ import annotations

import pytest

from itinerary import models, storage


@pytest.fixture()
def turso_branch(monkeypatch):
    """Force the trips onto Turso (configured, faked)."""
    import turso_db

    monkeypatch.setattr(turso_db, "is_configured", lambda: True)
    return None


def _structure(trips: list[dict]) -> dict:
    return {"schema_version": models.SCHEMA_VERSION,
            "trips": trips}


def test_load_trips_reads_the_database(turso_branch, monkeypatch):
    trip = models.make_trip("Turso trip")
    monkeypatch.setattr(storage.storage_turso, "load_trips",
                          lambda: (_structure([trip]), []))
    assert storage.load_trips()["trips"][0]["name"] == "Turso trip"


def test_load_trips_falls_back_to_the_file(turso_branch, monkeypatch,
                                              sandbox):
    """An unreachable database degrades to the old
    behaviour instead of an empty trip list."""
    monkeypatch.setattr(
        storage.storage_turso, "load_trips",
        lambda: (_structure([]), ["Turso is unavailable (500)"]))
    storage.save_to(_structure([models.make_trip("File trip")]),
                      storage.TRIPS_PATH)
    assert storage.load_trips()["trips"][0]["name"] == "File trip"


def test_save_trips_upserts_and_deletes(turso_branch, monkeypatch):
    """A full save round-trips: every trip is
    upserted, and a trip the structure no longer
    lists is deleted from the database."""
    kept = models.make_trip("Kept")
    removed = models.make_trip("Removed")
    written: dict[str, dict] = {}
    deleted: list[str] = []

    monkeypatch.setattr(
        storage.storage_turso, "load_trips",
        lambda: (_structure([kept, removed]), []))
    monkeypatch.setattr(
        storage.storage_turso, "save_trip",
        lambda trip: written.update({trip["id"]: trip})
        or (True, []))
    monkeypatch.setattr(
        storage.storage_turso, "delete_trip",
        lambda trip_id: deleted.append(trip_id) or (True, []))

    assert storage.save_trips(_structure([kept])) is True
    assert set(written) == {kept["id"]}
    assert deleted == [removed["id"]]
    assert storage.last_write_error() is None


def test_save_trips_reports_a_failed_write(turso_branch, monkeypatch):
    trip = models.make_trip("Failing")
    monkeypatch.setattr(
        storage.storage_turso, "load_trips",
        lambda: (_structure([]), []))
    monkeypatch.setattr(
        storage.storage_turso, "save_trip",
        lambda trip: (False, ["the database denied the write"]))

    assert storage.save_trips(_structure([trip])) is False
    assert "denied" in (storage.last_write_error() or "")


def test_ensure_seed_reads_a_populated_database(turso_branch,
                                                   monkeypatch, sandbox):
    """On the Turso path the database is the store: a
    populated database is read and the file is never
    touched."""
    trip = models.make_trip("Existing")
    monkeypatch.setattr(storage.storage_turso, "load_trips",
                          lambda: (_structure([trip]), []))
    monkeypatch.setattr(storage.storage_turso, "save_trip",
                          lambda trip: (True, []))
    monkeypatch.setattr(storage.storage_turso, "delete_trip",
                          lambda trip_id: (True, []))

    data = storage.ensure_seed()
    assert data["trips"][0]["name"] == "Existing"
    assert not storage.TRIPS_PATH.exists()


def test_ensure_seed_seeds_an_empty_database(turso_branch, monkeypatch,
                                                sandbox):
    saved: dict[str, dict] = {}
    monkeypatch.setattr(storage.storage_turso, "load_trips",
                          lambda: (_structure([]), []))
    monkeypatch.setattr(
        storage.storage_turso, "save_trip",
        lambda trip: saved.update({trip["id"]: trip})
        or (True, []))
    monkeypatch.setattr(storage.storage_turso, "delete_trip",
                          lambda trip_id: (True, []))

    data = storage.ensure_seed()
    assert data["trips"]
    assert saved[data["trips"][0]["id"]]["name"] == \
        data["trips"][0]["name"]
