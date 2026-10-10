"""API tests (NATIVE_HTML_PLAN.md, Phase 2).

The suite's autouse fixtures force the repository onto the
workbook branch and redirect all runtime state into a
sandbox, so these tests exercise the same code path a
fresh checkout does: no Turso, no network, a disposable
workbook copy. The weekend finder's flight fetch and the
sync transport are patched out.
"""

from __future__ import annotations

import os
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

import api
import repository
import storage_turso
import timetable
import turso_db
import weekend_match as wm


@pytest.fixture()
def client():
    return TestClient(api.app)


# ── meta ─────────────────────────────────────────────────

def test_health(client):
    response = client.get("/api/health")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    # Turso is isolated by the suite's autouse fixture, so
    # the API reports the workbook branch -- the same
    # fallback a fresh checkout without a token takes.
    assert body["source"] == "workbook"


def test_meta_counts(client):
    response = client.get("/api/meta")
    assert response.status_code == 200
    body = response.json()
    assert body["destinations"] > 0
    assert body["trips"] >= 1          # seeded on first read
    assert isinstance(body["open_tabs"], int)


# ── destinations: list, filters, detail ──────────────────

def test_destinations_list(client):
    response = client.get("/api/destinations")
    assert response.status_code == 200
    body = response.json()
    assert body["count"] > 0
    first = body["destinations"][0]
    assert first["destination"]
    assert first["country"]
    assert first["continent"]
    assert isinstance(first["visited"], bool)
    assert isinstance(first["favourite"], bool)


def test_destinations_country_filter(client):
    listing = client.get("/api/destinations").json()
    country = listing["destinations"][0]["country"]
    response = client.get("/api/destinations",
                           params={"country": country})
    assert response.status_code == 200
    rows = response.json()["destinations"]
    assert rows
    assert all(row["country"] == country for row in rows)


def test_destinations_search(client):
    listing = client.get("/api/destinations").json()
    name = listing["destinations"][0]["destination"]
    response = client.get("/api/destinations",
                           params={"q": name[:4]})
    assert response.status_code == 200
    rows = response.json()["destinations"]
    assert rows
    assert any(name in row["destination"] for row in rows)


def test_destinations_visited_filter(client):
    response = client.get("/api/destinations",
                           params={"visited": True})
    assert response.status_code == 200
    rows = response.json()["destinations"]
    assert all(row["visited"] is True for row in rows)


def test_destinations_limit(client):
    response = client.get("/api/destinations", params={"limit": 3})
    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 3
    assert len(body["destinations"]) == 3


def test_destination_detail(client):
    listing = client.get("/api/destinations").json()
    name = listing["destinations"][0]["destination"]
    response = client.get(f"/api/destinations/{name}")
    assert response.status_code == 200
    body = response.json()
    assert body["destination"] == name
    # The lossless ordered tail: every workbook column,
    # duplicate names included.
    assert body["columns"]
    assert body["fields"]
    assert len(body["columns"]) >= len(body["fields"])


def test_destination_detail_unknown(client):
    response = client.get("/api/destinations/No%20Such%20City")
    assert response.status_code == 404


def test_patch_favourite_roundtrip(client, sandbox):
    listing = client.get("/api/destinations").json()
    name = listing["destinations"][0]["destination"]
    response = client.patch(f"/api/destinations/{name}",
                             json={"favourite": True})
    assert response.status_code == 200
    assert response.json()["written"] is True
    favourited = client.get("/api/destinations",
                             params={"favourite": True})
    assert name in [row["destination"]
                    for row in favourited.json()["destinations"]]


def test_patch_nothing_to_write(client):
    response = client.patch("/api/destinations/Anywhere", json={})
    assert response.status_code == 400


# ── trips CRUD ───────────────────────────────────────────

def test_trips_crud(client, sandbox):
    listed = client.get("/api/trips")
    assert listed.status_code == 200
    body = listed.json()
    assert body["schema_version"] == 1
    assert isinstance(body["trips"], list)

    created = client.post("/api/trips", json={"name": "API test"})
    assert created.status_code == 201
    trip = created.json()
    assert trip["name"] == "API test"
    assert trip["id"]
    assert trip["variants"]          # a default variant is built

    fetched = client.get(f"/api/trips/{trip['id']}")
    assert fetched.status_code == 200
    assert fetched.json()["id"] == trip["id"]

    trip["name"] = "API test (renamed)"
    replaced = client.put(f"/api/trips/{trip['id']}", json=trip)
    assert replaced.status_code == 200
    assert replaced.json()["name"] == "API test (renamed)"

    deleted = client.delete(f"/api/trips/{trip['id']}")
    assert deleted.status_code == 200
    assert client.get(f"/api/trips/{trip['id']}").status_code == 404


def test_trips_unknown_id(client, sandbox):
    assert client.get("/api/trips/nope").status_code == 404
    assert client.delete("/api/trips/nope").status_code == 404
    assert client.put("/api/trips/nope",
                      json={"name": "x"}).status_code == 404


# ── open tabs ────────────────────────────────────────────

def test_tabs_roundtrip(client, sandbox):
    response = client.get("/api/tabs")
    assert response.status_code == 200
    assert isinstance(response.json()["tabs"], list)

    written = client.put("/api/tabs", json={"tabs": ["Naples", "Tokyo"]})
    assert written.status_code == 200
    assert written.json()["written"] is True
    assert client.get("/api/tabs").json()["tabs"] == ["Naples", "Tokyo"]


# ── weekend finder (flight fetch patched out) ────────────

def _fake_search_weekend(weekend, windows, provider,
                          benefit_flags=None, city_lookup=None,
                          use_cache=True):
    friday = wm.midnight(weekend.friday)
    monday = wm.midnight(weekend.monday)
    outbound = wm.Flight(
        flight_no="LH 1234", airline="Lufthansa", origin="FRA",
        destination="VIE",
        departure=friday.replace(hour=15),
        arrival=friday.replace(hour=16, minute=30),
        operated_by="Lufthansa")
    back = wm.Flight(
        flight_no="LH 1235", airline="Lufthansa", origin="VIE",
        destination="FRA",
        departure=monday.replace(hour=7),
        arrival=monday.replace(hour=8, minute=15),
        operated_by="Lufthansa")
    option = wm.TripOption(city="Vienna", country="Austria",
                            out_flight=outbound, back_flight=back,
                            nights=2)
    city = wm.CityResult(city="Vienna", country="Austria",
                          options=[option], airports={"VIE"})
    return wm.MatchReport(weekend=weekend, windows=windows,
                           cities=[city], outbound_total=1,
                           return_total=1)


def test_weekend_endpoint(client, monkeypatch):
    monkeypatch.setattr(timetable, "search_weekend",
                        _fake_search_weekend)
    response = client.get("/api/weekend",
                           params={"friday": "2026-10-16"})
    assert response.status_code == 200
    body = response.json()
    assert body["weekend"] == "2026-10-16 to 2026-10-19"
    assert body["city_count"] == 1
    assert body["option_count"] == 1
    city = body["cities"][0]
    assert city["city"] == "Vienna"
    assert city["airports"] == ["VIE"]
    option = city["options"][0]
    assert option["nights"] == 2
    assert option["outbound_airline"] == "Lufthansa"
    assert option["outbound"]["flight_no"] == "LH 1234"
    assert option["return"]["flight_no"] == "LH 1235"


def test_weekend_default_is_next_friday(client, monkeypatch):
    seen = {}

    def _capture(weekend, windows, provider, **kwargs):
        seen["weekend"] = weekend
        return _fake_search_weekend(weekend, windows, provider)

    monkeypatch.setattr(timetable, "search_weekend", _capture)
    response = client.get("/api/weekend")
    assert response.status_code == 200
    # The default search is the next Friday (today or later).
    assert seen["weekend"].friday >= wm.next_friday(
        __import__("datetime").date.today())


def test_weekend_bad_date(client):
    response = client.get("/api/weekend",
                           params={"friday": "not-a-date"})
    assert response.status_code == 400


def test_weekend_bad_clock(client):
    response = client.get("/api/weekend",
                           params={"friday_from": "25:99"})
    assert response.status_code == 400


def test_providers(client):
    response = client.get("/api/providers")
    assert response.status_code == 200
    providers = response.json()["providers"]
    assert isinstance(providers, list)
    assert providers
    assert all("name" in row and "usable" in row
               for row in providers)


# ── export and sync (preconditions, no network) ──────────

def test_export_requires_turso(client):
    # Turso is isolated in tests, so the export reports the
    # precondition instead of pretending to write a workbook.
    response = client.get("/api/export.xlsx")
    assert response.status_code == 409


def test_sync_trigger(client, monkeypatch):
    calls = {}

    def _fake_sync_now(dry_run=False, journal_dir=None):
        calls["dry_run"] = dry_run
        return {"ok": True, "applied": 0, "conflicts": 0}

    import sync.sync

    monkeypatch.setattr(sync.sync, "sync_now", _fake_sync_now)
    response = client.post("/api/sync")
    assert response.status_code == 200
    assert response.json()["ok"] is True
    assert calls["dry_run"] is False

    dry = client.post("/api/sync", params={"dry_run": "true"})
    assert dry.status_code == 200
    assert calls["dry_run"] is True


# ── the repository's cache is a passthrough here ─────────

def test_repository_cache_is_passthrough_in_api_mode(monkeypatch):
    """``TRAVEL_PLANNER_API`` turns the repository's Streamlit
    cache into a passthrough, so every API request reads
    fresh data instead of a cached snapshot."""
    assert os.environ.get("TRAVEL_PLANNER_API") == "1"
    calls = []

    def _fake_load():
        calls.append(1)
        return ([{"destination": "X", "columns": []}], [])

    monkeypatch.setattr(storage_turso, "load_destinations",
                        _fake_load)
    monkeypatch.setattr(turso_db, "is_configured", lambda: True)
    repository._load_destinations_from_turso()
    repository._load_destinations_from_turso()
    assert len(calls) == 2


def test_frontend_mounted_when_present(client):
    """The Phase 3 frontend is served at ``/`` once
    ``web/index.html`` exists (it does by the time this
    runs -- see ``web/``)."""
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
