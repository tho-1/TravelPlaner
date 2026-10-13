"""Tests for the Turso-backed storage layer (``storage_turso.py``).

No network and no credentials: the remote path is exercised by monkeypatching
``turso_db.run_pipeline`` to execute the generated SQL against an in-memory
SQLite file built to the real schema (``turso_db.SCHEMA_SQL``). The storage
layer never touches the network directly, so this tests the real SQL it emits:
escaping, upserts, the typed-core/JSON-tail split, and the writer contract
(returns True/False, never raises on a quiet failure).

Every test starts from an empty database (the tables exist but hold no rows),
so round-trip tests exercise save -> load without interference from other rows.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import openpyxl
import pytest

import storage_turso as st
import turso_db

SAMPLE_COLUMNS = [
    ["Destination", "Test City"],
    ["Continent", "Europe"],
    ["Country", "Testland"],
    ["Visited?", "x"],
    ["In nherer Auswahl 2025?", "yes"],
    ["Prio Thorsten", "high"],
    ["Safety Rating (10 = safest)", 8],
    ["Avg. Cost/Day (3* Hotel & Food)", 50],
    ["Flight Time to Frankfurt (hours)", 2.5],
    ["To be researched", ""],
    ["Malaria risk?", "no"],
    ["Data Status", "complete"],
    ["Comment", "nice place"],
]


class _FakeTurso:
    """An in-memory SQLite backend that speaks the pipeline shape.

    Monkeypatching ``turso_db.run_pipeline`` (the single network entry point)
    routes every ``query`` / ``execute`` / ``run_pipeline`` call in the storage
    layer here. SELECTs return rows in the ``{"cols", "rows"}`` envelope that
    ``turso_db.query`` expects; writes are committed immediately.
    """

    def __init__(self):
        self._conn = sqlite3.connect(":memory:")
        self._conn.executescript(turso_db.SCHEMA_SQL)
        self.executed: list[str] = []

    def run_pipeline(self, statements, url=None, token=None, timeout=None):
        results = []
        problems = []
        for sql in statements:
            self.executed.append(sql)
            try:
                cur = self._conn.execute(sql)
            except Exception as exc:
                problems.append(str(exc))
                results.append({"cols": [], "rows": []})
                continue
            if cur.description:
                cols = [d[0] for d in cur.description]
                rows = cur.fetchall()
                results.append({"cols": cols, "rows": rows})
            else:
                results.append({"cols": [], "rows": []})
        self._conn.commit()
        return results, problems


@pytest.fixture
def fake_db(monkeypatch):
    """A clean in-memory Turso with the real schema, wired into turso_db.

    Monkeypatching ``turso_db.run_pipeline`` (the single network entry point
    used by ``query``, ``execute`` and direct callers alike) routes every SQL
    the storage layer emits into the fake backend, so the real SQL is exercised.
    """
    fdb = _FakeTurso()
    monkeypatch.setattr(turso_db, "run_pipeline", fdb.run_pipeline)
    return fdb


# ── pure helpers ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize("value,expected", [
    (True, 1), (False, 0), (1, 1), (0, 0),
    ("x", 1), ("X", 1), ("yes", 1), ("YES", 1),
    ("y", 1), ("ja", 1), ("j", 1), ("true", 1),
    ("no", 0), ("unknown", 0), ("", 0), (None, 0),
    ("abc", 0), ("2", 0), (42, 0),
])
def test_truthy(value, expected):
    assert st._truthy(value) == expected


@pytest.mark.parametrize("value,expected", [
    (None, None), ("", None), ("  ", None),
    ("1,5", 1.5), ("1.5", 1.5), (42, 42), (3.14, 3.14),
    ("abc", None), ("12,34", 12.34),
])
def test_number(value, expected):
    assert st._number(value) == expected


@pytest.mark.parametrize("value,expected", [
    (None, None), ("", None), ("  ", "  "),
    ("foo", "foo"), (123, "123"), ("  x  ", "  x  "),
])
def test_text(value, expected):
    assert st._text(value) == expected


@pytest.mark.parametrize("value,expected", [
    (None, "NULL"),
    (True, "1"), (False, "0"),
    (42, "42"), (3.14, "3.14"),
    ("foo", "'foo'"),
    ("O'Brien", "'O''Brien'"),
])
def test_sql_value(value, expected):
    assert st._sql_value(value) == expected


def test_truthy_string_containing_x_counts_as_yes():
    assert st._truthy("box") == 1


# ── destination round-trip ────────────────────────────────────────────────────

def _sample_dest() -> dict:
    return {
        "destination": "Test City",
        "continent": "Europe",
        "country": "Testland",
        "visited": True,
        "favourite": "yes",
        "prio": "high",
        "safety_rating": 8,
        "avg_cost_day": 50,
        "flight_time_fra": 2.5,
        "to_be_researched": False,
        "malaria_risk": "no",
        "data_status": "complete",
        "comment": "nice place",
        "columns": list(SAMPLE_COLUMNS),
    }


def test_save_and_load_destination_round_trip(fake_db):
    dest = _sample_dest()
    ok, problems = st.save_destination(dest)
    assert ok is True
    assert problems == []

    dests, problems = st.load_destinations()
    assert problems == []
    assert len(dests) == 1
    got = dests[0]
    assert got["destination"] == "Test City"
    assert got["continent"] == "Europe"
    assert got["country"] == "Testland"
    assert got["visited"] == 1
    assert got["favourite"] == 1
    assert got["safety_rating"] == 8.0
    assert got["avg_cost_day"] == 50.0
    assert got["flight_time_fra"] == 2.5
    assert got["malaria_risk"] == 0


def test_destination_tail_preserves_duplicate_columns(fake_db):
    """The workbook has duplicate column names (positions 139/143,
    140/144). The JSON tail stores every column as an ordered pair so
    duplicates are not collapsed."""
    columns = [
        ["Destination", "Twin City"],
        ["Col", "first"],
        ["Col", "second"],
    ]
    dest = _sample_dest()
    dest["columns"] = columns
    dest["destination"] = "Twin City"
    st.save_destination(dest)

    dests, _ = st.load_destinations()
    cols = dests[0]["columns"]
    assert cols == columns  # duplicates preserved, order intact


def test_get_destination_by_exact_name(fake_db):
    st.save_destination(_sample_dest())
    dest, problems = st.get_destination("Test City")
    assert problems == []
    assert dest is not None
    assert dest["destination"] == "Test City"


def test_get_destination_missing_returns_none(fake_db):
    dest, problems = st.get_destination("Nowhere")
    assert dest is None
    assert problems == []


def test_get_destination_name_with_quote(fake_db):
    """Names containing a single quote must be escaped, not break the SQL."""
    dest = _sample_dest()
    dest["destination"] = "O'Brien"
    dest["columns"] = [["Destination", "O'Brien"]] + dest["columns"][1:]
    ok, _ = st.save_destination(dest)
    assert ok is True
    got, problems = st.get_destination("O'Brien")
    assert problems == []
    assert got is not None
    assert got["destination"] == "O'Brien"


def test_save_destination_returns_false_on_error(fake_db, monkeypatch):
    def broken_run_pipeline(statements, **kw):
        return [], ["table missing: destinations"]

    monkeypatch.setattr(turso_db, "run_pipeline", broken_run_pipeline)
    dest, problems = _sample_dest(), None
    ok, problems = st.save_destination(dest)
    assert ok is False
    assert problems == ["table missing: destinations"]


def test_load_destinations_propagates_problems(fake_db, monkeypatch):
    def broken_run_pipeline(statements, **kw):
        return [], ["database offline"]

    monkeypatch.setattr(turso_db, "run_pipeline", broken_run_pipeline)
    dests, problems = st.load_destinations()
    assert dests == []
    assert problems == ["database offline"]


def test_core_fields_built_from_typed_core_when_no_tail(fake_db):
    """A destination with only core fields (no ``columns``) still round-trips:
    the tail is built from CORE_COLUMNS."""
    dest = {
        "destination": "Bare City",
        "continent": "Asia",
        "country": "Nowhere",
        "visited": 1,
        "favourite": 0,
        "prio": "low",
        "safety_rating": 5,
        "avg_cost_day": 30,
        "flight_time_fra": 1.0,
        "to_be_researched": 1,
        "malaria_risk": 1,
        "data_status": "partial",
        "comment": "work in progress",
    }
    st.save_destination(dest)
    dests, _ = st.load_destinations()
    assert len(dests) == 1
    assert dests[0]["destination"] == "Bare City"
    assert dests[0]["visited"] == 1
    assert dests[0]["to_be_researched"] == 1
    # the tail was synthesised from core columns
    assert ["Destination", "Bare City"] in dests[0]["columns"]


# ── trips ──────────────────────────────────────────────────────────────────────

def _sample_trip() -> dict:
    return {
        "id": "trip-test01",
        "name": "Test Trip",
        "created": "2026-09-19T17:15:04",
        "active_variant_id": "variant-v01",
        "variants": [
            {
                "id": "variant-v01",
                "name": "Variant 1",
                "notes": "first try",
                "rating": 4,
                "months": ["April", "May"],
                "comment": "nice weather",
                "stops": [
                    {
                        "id": "stop-001",
                        "ref": {"kind": "gateway", "name": "Frankfurt",
                                "country": "Germany", "lat": 50.1, "lon": 8.6},
                        "arrival_date": None, "departure_date": "2026-10-01",
                        "arrival_time": None, "departure_time": "10:00",
                        "nights": None, "role": "origin", "notes": "",
                    },
                    {
                        "id": "stop-002",
                        "ref": {"kind": "destination", "name": "Rom",
                                "country": "Italy", "lat": 41.9, "lon": 12.5},
                        "arrival_date": "2026-10-01", "departure_date": "2026-10-03",
                        "arrival_time": "05:00", "departure_time": None,
                        "nights": 2, "role": "stop", "notes": "see the Colosseum",
                    },
                ],
                "legs": [
                    {"mode": "flight", "note": "LH123"},
                ],
            },
        ],
    }


def test_save_and_load_trip_round_trip(fake_db):
    trip = _sample_trip()
    ok, problems = st.save_trip(trip)
    assert ok is True
    assert problems == []

    data, problems = st.load_trips()
    assert problems == []
    assert len(data["trips"]) == 1
    got = data["trips"][0]
    assert got["id"] == "trip-test01"
    assert got["name"] == "Test Trip"
    assert got["active_variant_id"] == "variant-v01"

    variant = got["variants"][0]
    assert variant["name"] == "Variant 1"
    assert variant["rating"] == 4
    assert variant["months"] == ["April", "May"]
    assert len(variant["stops"]) == 2
    assert variant["stops"][0]["ref"]["name"] == "Frankfurt"
    assert variant["stops"][0]["role"] == "origin"
    assert variant["stops"][1]["ref"]["name"] == "Rom"
    assert variant["stops"][1]["nights"] == 2

    # positional legs: 1 leg between 2 stops
    assert len(variant["legs"]) == 1
    assert variant["legs"][0]["mode"] == "flight"
    assert variant["legs"][0]["note"] == "LH123"


def test_load_trips_empty(fake_db):
    data, problems = st.load_trips()
    assert problems == []
    assert data == {"schema_version": 1, "trips": []}


def test_delete_trip(fake_db):
    st.save_trip(_sample_trip())
    ok, problems = st.delete_trip("trip-test01")
    assert ok is True
    assert problems == []
    data, _ = st.load_trips()
    assert data["trips"] == []


def test_save_trip_atomic_all_or_nothing(fake_db, monkeypatch):
    """If a pipeline statement fails, the writer reports problems."""
    trip = _sample_trip()

    def flaky(statements, **kw):
        return [], ["constraint failed: duplicate key"]

    monkeypatch.setattr(turso_db, "run_pipeline", flaky)
    ok, problems = st.save_trip(trip)
    assert ok is False
    assert problems == ["constraint failed: duplicate key"]


def test_leg_position_is_preserved(fake_db):
    trip = _sample_trip()
    variant = trip["variants"][0]
    variant["stops"].append({
        "id": "stop-003",
        "ref": {"kind": "destination", "name": "Venice", "country": "Italy"},
        "arrival_date": "2026-10-03", "departure_date": None,
        "arrival_time": None, "departure_time": None,
        "nights": None, "role": "stop", "notes": "",
    })
    variant["legs"].append({"mode": "train", "note": "nightjet"})
    st.save_trip(trip)
    data, _ = st.load_trips()
    stops = data["trips"][0]["variants"][0]["stops"]
    legs = data["trips"][0]["variants"][0]["legs"]
    assert [s["ref"]["name"] for s in stops] == ["Frankfurt", "Rom", "Venice"]
    assert [leg["mode"] for leg in legs] == ["flight", "train"]


def test_delete_trip_id_with_quote(fake_db):
    trip = _sample_trip()
    trip["id"] = "trip-O'Brien"
    st.save_trip(trip)
    # should not raise
    ok, _ = st.delete_trip("trip-O'Brien")
    assert ok


# ── open tabs ─────────────────────────────────────────────────────────────────

def test_open_tabs_round_trip(fake_db):
    st.save_destination(_sample_dest())
    ok, problems = st.save_open_tabs(["Test City", "Other"])
    assert ok is True
    assert problems == []
    tabs, problems = st.load_open_tabs()
    assert problems == []
    assert tabs == ["Other", "Test City"]  # ORDER BY destination


def test_open_tabs_empty(fake_db):
    tabs, problems = st.load_open_tabs()
    assert tabs == []
    assert problems == []


def test_open_tabs_replaces_not_appends(fake_db):
    st.save_open_tabs(["A", "B"])
    st.save_open_tabs(["C"])
    tabs, _ = st.load_open_tabs()
    assert tabs == ["C"]


def test_open_tabs_rejects_duplicates(fake_db):
    ok, _ = st.save_open_tabs(["A", "A", "B"])
    assert ok is True
    tabs, _ = st.load_open_tabs()
    assert sorted(tabs) == ["A", "B"]


# ── workbook export ────────────────────────────────────────────────────────────

def test_export_workbook_round_trip(fake_db, tmp_path):
    dest1 = _sample_dest()
    dest2 = _sample_dest()
    dest2["destination"] = "Second City"
    dest2["continent"] = "Africa"
    dest2["country"] = "Nowhere"
    # Rebuild the column tail so the overridden values appear there too.
    dest2["columns"] = [
        [name, new] if name in ("Destination", "Continent", "Country") else pair
        for pair in SAMPLE_COLUMNS
        for name, new in [(pair[0], {
            "Destination": "Second City",
            "Continent": "Africa",
            "Country": "Nowhere",
        }.get(pair[0], pair[1]))]
    ]
    st.save_destination(dest1)
    st.save_destination(dest2)

    out = tmp_path / "export.xlsx"
    ok, problems = st.export_workbook(str(out))
    assert ok is True
    assert problems == []
    assert out.exists()

    wb = openpyxl.load_workbook(out, read_only=True)
    ws = wb["Result sheet"]
    rows = list(ws.iter_rows(values_only=True))
    wb.close()
    header = list(rows[0])
    assert header == [name for name, _v in SAMPLE_COLUMNS]
    dest_row1 = rows[1]  # "Second City" sorts before "Test City"
    dest_row2 = rows[2]
    dest_col = header.index("Destination")
    assert dest_row1[dest_col] == "Second City"
    assert dest_row2[dest_col] == "Test City"


def test_export_workbook_no_destinations(fake_db, tmp_path):
    ok, problems = st.export_workbook(str(tmp_path / "x.xlsx"))
    assert ok is False
    assert "no destinations" in problems[0]


def test_export_workbook_no_columns(fake_db, tmp_path):
    dest = {"destination": "Bare City", "columns": []}
    st.save_destination(dest)
    ok, problems = st.export_workbook(str(tmp_path / "x.xlsx"))
    assert ok is False
    assert "no column data" in problems[0]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
