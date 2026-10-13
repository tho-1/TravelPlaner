"""Tests for the repository layer (``repository.py``).

The repository routes every call through a fallback ladder:
Turso when configured, the workbook otherwise. These tests pin
both branches:

* **Workbook branch** (Turso not configured): the repository must
  return exactly what ``data_utils`` returns — the pages cannot
  tell which source supplied the data.
* **Turso branch** (configured, faked): the repository must build
  the same ``(DataFrame, metadata)`` pair from the lossless
  ``columns`` tails, and route writes to ``storage_turso``.

No network: the Turso branch is faked by monkeypatching
``turso_db.is_configured`` and the ``storage_turso`` functions.
"""

from __future__ import annotations

import pandas as pd
import pytest

import data_utils
import repository
import storage_turso
import turso_db

# ── fixtures ───────────────────────────────────────────────────────

@pytest.fixture
def workbook_branch(monkeypatch):
    """Force the repository onto the workbook (Turso not configured)."""
    monkeypatch.setattr(turso_db, "is_configured", lambda: False)
    monkeypatch.setattr(repository, "use_turso", lambda: False)
    return None


@pytest.fixture
def turso_branch(monkeypatch):
    """Force the repository onto Turso (configured, faked)."""
    monkeypatch.setattr(turso_db, "is_configured", lambda: True)
    monkeypatch.setattr(repository, "use_turso", lambda: True)
    return None


def _make_dest(name, continent="Europe", country="Testland",
                  visited=False, favourite=False, prio=None,
                  safety=None, cost=None, flight=None,
                  researched=False, malaria=False,
                  status="complete", comment=None,
                  extra_columns=None):
    """A destination dict shaped like ``storage_turso`` returns."""
    columns = [
        ["Destination", name],
        ["In n\u00e4herer Auswahl 2025?", "x" if favourite else ""],
        ["Continent", continent],
        ["Country", country],
        ["Visited?", "x" if visited else ""],
        ["Prio Thorsten", prio],
        ["Safety Rating (10 = safest)", safety],
        ["Avg. Cost/Day (3* Hotel & Food)", cost],
        ["Flight Time to Frankfurt (hours)", flight],
        ["To be researched", "x" if researched else ""],
        ["Malaria risk?", "x" if malaria else ""],
        ["Data Status", status],
        ["Comment", comment],
    ]
    if extra_columns:
        columns.extend(extra_columns)
    return {
        "destination": name,
        "continent": continent,
        "country": country,
        "visited": 1 if visited else 0,
        "favourite": 1 if favourite else 0,
        "prio": prio,
        "safety_rating": safety,
        "avg_cost_day": cost,
        "flight_time_fra": flight,
        "to_be_researched": 1 if researched else 0,
        "malaria_risk": 1 if malaria else 0,
        "data_status": status,
        "comment": comment,
        "columns": columns,
    }


# ── source selection ─────────────────────────────────────────────

def test_use_turso_reflects_configuration(monkeypatch):
    monkeypatch.setattr(turso_db, "is_configured", lambda: True)
    assert repository.use_turso() is True
    monkeypatch.setattr(turso_db, "is_configured", lambda: False)
    assert repository.use_turso() is False


# ── workbook branch (fallback) ───────────────────────────────────

def test_workbook_branch_matches_data_utils(workbook_branch, sandbox):
    """With Turso off, the repository returns what data_utils returns."""
    df_repo, meta_repo = repository.load_destinations()
    df_direct, meta_direct = data_utils.load_destinations()
    assert list(df_repo.columns) == list(df_direct.columns)
    assert len(df_repo) == len(df_direct)
    assert meta_repo["destination_col"] == meta_direct["destination_col"]
    assert meta_repo["safety_col"] == meta_direct["safety_col"]


def test_workbook_branch_open_tabs(workbook_branch, sandbox):
    data_utils.save_open_destinations(["Naples", "Rome"])
    tabs = repository.load_open_tabs()
    assert tabs == ["Naples", "Rome"]


def test_workbook_branch_save_open_tabs(workbook_branch, sandbox):
    ok = repository.save_open_tabs(["Paris"])
    assert ok is True
    assert data_utils.load_open_destinations() == ["Paris"]


def test_workbook_branch_update_favorite(workbook_branch, sandbox):
    # Use a destination that exists in the workbook (the sandbox copy).
    df, metadata = data_utils.load_destinations()
    name = str(df[metadata["destination_col"]].iloc[0])
    ok = repository.update_favorite_status(name, True)
    assert ok is True


# ── Turso branch (faked) ─────────────────────────────────────────

def test_turso_branch_load_destinations(turso_branch, monkeypatch):
    dests = [
        _make_dest("Alpha", continent="Europe", country="A",
                      safety=8, cost=50, flight=2.5),
        _make_dest("Beta", continent="Asia", country="B",
                      safety=5, cost=30, flight=10.0),
    ]
    monkeypatch.setattr(storage_turso, "load_destinations",
                        lambda: (dests, []))
    df, metadata = repository.load_destinations()
    assert len(df) == 2
    assert metadata["destination_col"] == "Destination"
    assert metadata["safety_col"] == "Safety Rating (10 = safest)"
    assert metadata["cost_col"] == "Avg. Cost/Day (3* Hotel & Food)"
    assert metadata["flight_col"] == "Flight Time to Frankfurt (hours)"
    # the typed columns are coerced to numbers
    assert df["Safety Rating (10 = safest)"].tolist() == [8.0, 5.0]
    assert df["Avg. Cost/Day (3* Hotel & Food)"].tolist() == [50.0, 30.0]


def test_turso_branch_empty_falls_back_to_workbook(turso_branch,
                                                       monkeypatch,
                                                       sandbox):
    """An empty Turso read is a failure, not an empty catalogue."""
    monkeypatch.setattr(storage_turso, "load_destinations",
                        lambda: ([], ["database offline"]))
    df, metadata = repository.load_destinations()
    # fell back to the workbook (the sandbox copy)
    assert len(df) > 0
    assert metadata["destination_col"] == "Destination"


def test_turso_branch_problems_fall_back(turso_branch, monkeypatch,
                                           sandbox):
    monkeypatch.setattr(storage_turso, "load_destinations",
                        lambda: ([], ["no such table"]))
    df, _ = repository.load_destinations()
    assert len(df) > 0


def test_turso_branch_get_destination(turso_branch, monkeypatch):
    dest = _make_dest("Alpha", comment="nice")
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (dest if name == "Alpha" else None, []))
    got, problems = repository.get_destination("Alpha")
    assert problems == []
    assert got["destination"] == "Alpha"
    assert got["comment"] == "nice"


def test_turso_branch_open_tabs(turso_branch, monkeypatch):
    monkeypatch.setattr(storage_turso, "load_open_tabs",
                        lambda: (["Rome", "Paris"], []))
    assert repository.load_open_tabs() == ["Rome", "Paris"]


def test_turso_branch_save_open_tabs(turso_branch, monkeypatch):
    captured = {}

    def fake_save(tabs):
        captured["tabs"] = tabs
        return True, []

    monkeypatch.setattr(storage_turso, "save_open_tabs", fake_save)
    ok = repository.save_open_tabs(["Berlin"])
    assert ok is True
    assert captured["tabs"] == ["Berlin"]


# ── Turso write paths ────────────────────────────────────────────

def test_turso_update_favorite(turso_branch, monkeypatch):
    dest = _make_dest("Alpha", favourite=False)
    saved = {}

    def fake_get(name):
        return (dest if name == "Alpha" else None), []

    def fake_save(d):
        saved["dest"] = d
        return True, []

    monkeypatch.setattr(storage_turso, "get_destination", fake_get)
    monkeypatch.setattr(storage_turso, "save_destination", fake_save)
    ok = repository.update_favorite_status("Alpha", True)
    assert ok is True
    assert saved["dest"]["favourite"] == 1
    # the tail stays in sync
    fav = [p for p in saved["dest"]["columns"]
           if p[0] == "In n\u00e4herer Auswahl 2025?"]
    assert fav[0][1]


def test_turso_update_visited(turso_branch, monkeypatch):
    dest = _make_dest("Alpha", visited=False)
    saved = {}
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (dest, []))
    monkeypatch.setattr(storage_turso, "save_destination",
                        lambda d: (saved.update(dest=d), (True, []))[1])
    ok = repository.update_visited_status("Alpha", True)
    assert ok is True
    assert saved["dest"]["visited"] == 1


def test_turso_update_prio(turso_branch, monkeypatch):
    dest = _make_dest("Alpha", prio=None)
    saved = {}
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (dest, []))
    monkeypatch.setattr(storage_turso, "save_destination",
                        lambda d: (saved.update(dest=d), (True, []))[1])
    ok = repository.update_prio_thorsten("Alpha", 3)
    assert ok is True
    assert saved["dest"]["prio"] == 3


def test_turso_update_comment(turso_branch, monkeypatch):
    dest = _make_dest("Alpha", comment=None)
    saved = {}
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (dest, []))
    monkeypatch.setattr(storage_turso, "save_destination",
                        lambda d: (saved.update(dest=d), (True, []))[1])
    ok = repository.update_comment("Alpha", "must visit")
    assert ok is True
    assert saved["dest"]["comment"] == "must visit"
    tail = [p for p in saved["dest"]["columns"] if p[0] == "Comment"]
    assert tail[0][1] == "must visit"


def test_turso_update_reviews(turso_branch, monkeypatch):
    dest = _make_dest("Alpha")
    saved = {}
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (dest, []))
    monkeypatch.setattr(storage_turso, "save_destination",
                        lambda d: (saved.update(dest=d), (True, []))[1])
    ok = repository.update_reviews("Alpha", 4.5, "1200", "food", "crowds")
    assert ok is True
    cols = {p[0]: p[1] for p in saved["dest"]["columns"]}
    assert cols["Reviews"] == 4.5
    assert cols["Tourist Reviews"] == "1200"
    assert cols["What do the reviews praise?"] == "food"
    assert cols["What do they dislike?"] == "crowds"


def test_turso_update_food(turso_branch, monkeypatch):
    dest = _make_dest("Alpha")
    saved = {}
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (dest, []))
    monkeypatch.setattr(storage_turso, "save_destination",
                        lambda d: (saved.update(dest=d), (True, []))[1])
    ok = repository.update_food("Alpha", 2.5, "spicy", ["pasta", "pizza"])
    assert ok is True
    cols = {p[0]: p[1] for p in saved["dest"]["columns"]}
    assert cols["Food - Spicyness"] == 2.5
    assert cols["Food - Description"] == "spicy"
    assert cols["Food - Main Dishes"] == "pasta, pizza"


def test_turso_add_new_destination(turso_branch, monkeypatch):
    saved = {}
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (None, []))
    monkeypatch.setattr(storage_turso, "save_destination",
                        lambda d: (saved.update(dest=d), (True, []))[1])
    ok, msg = repository.add_new_destination("New City", "Narnia", "Fantasy")
    assert ok is True
    assert "New City" in msg
    assert saved["dest"]["destination"] == "New City"
    assert saved["dest"]["country"] == "Narnia"
    assert saved["dest"]["data_status"] == "PLACEHOLDER - UPDATE REQUIRED"
    assert saved["dest"]["to_be_researched"] == 1


def test_turso_add_duplicate_is_refused(turso_branch, monkeypatch):
    existing = _make_dest("Alpha")
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (existing, []))
    ok, msg = repository.add_new_destination("Alpha")
    assert ok is False
    assert "already exists" in msg


def test_turso_write_failure_returns_false(turso_branch, monkeypatch):
    dest = _make_dest("Alpha")
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (dest, []))
    monkeypatch.setattr(storage_turso, "save_destination",
                        lambda d: (False, ["constraint failed"]))
    ok = repository.update_favorite_status("Alpha", True)
    assert ok is False


def test_turso_write_missing_destination_returns_false(turso_branch,
                                                         monkeypatch):
    monkeypatch.setattr(storage_turso, "get_destination",
                        lambda name: (None, []))
    ok = repository.update_favorite_status("Nowhere", True)
    assert ok is False


# ── DataFrame construction ───────────────────────────────────────

def test_destinations_to_dataframe_preserves_column_order(turso_branch):
    dests = [
        _make_dest("A", extra_columns=[["Zebra", 1], ["Apple", 2]]),
        _make_dest("B", extra_columns=[["Zebra", 3], ["Apple", 4]]),
    ]
    df = repository._destinations_to_dataframe(dests)
    assert list(df.columns)[:2] == ["Destination",
                                      "In n\u00e4herer Auswahl 2025?"]
    assert "Zebra" in df.columns
    assert "Apple" in df.columns
    assert df["Zebra"].tolist() == [1, 3]


def test_destinations_to_dataframe_empty(turso_branch):
    df = repository._destinations_to_dataframe([])
    assert df.empty


def test_destinations_to_dataframe_missing_column_is_none(turso_branch):
    """A destination lacking a column the first one has reads as None."""
    dests = [
        _make_dest("A", extra_columns=[["Zebra", 1]]),
        _make_dest("B"),  # no Zebra column
    ]
    df = repository._destinations_to_dataframe(dests)
    values = df["Zebra"].tolist()
    assert values[0] == 1
    assert pd.isna(values[1])


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
