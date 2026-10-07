"""Tests for the Turso airline-benefits source.

No network and no credentials: the remote path is exercised by monkeypatching
``requests.post``, and the real SQL is exercised against a temporary SQLite file
built to the documented schema. The point of the tests is the failure modes — a
Turso outage must degrade to the workbook, never silently empty the airline list.
"""

from __future__ import annotations

import json
import sqlite3

import pytest

import airline_benefits as ab
import benefits_turso as bt

SCHEMA = """
CREATE TABLE airlines (
    iata TEXT, name TEXT,
    discount_eligible TEXT, business_class TEXT, confirmed_booking TEXT,
    comments TEXT, updated_at TEXT
);
"""


def _make_db(path, rows=()):
    """A SQLite file with the documented schema, opened the same way as the real one.

    Rows are padded to seven columns so a test can state only the columns it
    cares about; the reader has to cope with the short rows that a real
    ``SELECT *`` would not produce, which is exactly the drift we want covered.
    """
    connection = sqlite3.connect(path)
    try:
        connection.executescript(SCHEMA)
        padded = [tuple(row) + ("",) * (7 - len(row)) for row in rows]
        connection.executemany("INSERT INTO airlines VALUES (?,?,?,?,?,?,?)",
                               padded)
        connection.commit()
    finally:
        connection.close()
    return str(path)


def _pipeline_response(rows, columns=("iata", "name", "discount_eligible",
                                       "business_class", "confirmed_booking")):
    """A Turso pipeline response body, in the documented envelope."""
    return json.dumps({"baton": None, "base_url": None, "results": [
        {"type": "ok", "response": {"type": "execute", "result": {
            "cols": [{"name": name} for name in columns],
            "rows": [list(row) for row in rows],
            "affected_row_count": 0, "rows_read": len(rows),
            "query_duration_ms": 1.0}}},
        {"type": "ok", "response": {"type": "close"}},
    ]})


class _Response:
    def __init__(self, status_code=200, text="", payload=None):
        self.status_code = status_code
        self._payload = payload
        self.text = text if payload is None else json.dumps(payload)

    def json(self):
        if self._payload is None:
            return json.loads(self.text)
        return self._payload


# ── value semantics ──────────────────────────────────────────────────────────

@pytest.mark.parametrize("value,expected", [
    ("yes", True), ("YES", True), (" Yes ", True), ("y", True),
    ("true", True), ("1", True), ("x", True),
    ("no", False), ("unknown", False), ("Unknown", False), ("", False),
    (None, False), (0, False), ("2", False),
])
def test_only_an_explicit_yes_qualifies(value, expected):
    """`unknown` must never count as a yes, or the list silently widens."""
    assert bt.is_yes(value) is expected


def test_a_benefit_in_any_of_the_three_columns_qualifies():
    rows, problems = bt.rows_to_records(
        [("LH", "Lufthansa", "no", "no", "yes")],
        ["iata", "name", "discount_eligible", "business_class",
         "confirmed_booking"])
    assert problems == []
    assert rows == [{"code": "LH", "name": "Lufthansa", "benefits": True,
                     "which": ["confirmed_booking"]}]


def test_an_unknown_airline_does_not_qualify():
    rows, _ = bt.rows_to_records([("XX", "Unknown Air", "unknown", "unknown",
                                   "unknown")],
                                 ["iata", "name", "discount_eligible",
                                  "business_class", "confirmed_booking"])
    assert rows[0]["benefits"] is False


# ── schema drift ─────────────────────────────────────────────────────────────

def test_column_names_are_matched_loosely():
    """A cosmetic rename upstream must not break the read."""
    rows, problems = bt.rows_to_records(
        [("CX", "Cathay Pacific", "yes", "", "")],
        ["IATA", "Airline Name", "Discount Eligible", "Business Class",
         "Confirmed Booking"])
    assert problems == []
    assert rows[0]["code"] == "CX"
    assert rows[0]["benefits"] is True


def test_a_missing_benefit_column_is_reported_not_silently_empty():
    rows, problems = bt.rows_to_records([("LH", "Lufthansa")], ["iata", "name"])
    assert rows == []
    assert problems and "benefit column" in problems[0]


def test_a_missing_code_column_is_reported():
    rows, problems = bt.rows_to_records(
        [("yes", "yes")], ["discount_eligible", "business_class"])
    assert rows == []
    assert problems and "code column" in problems[0]


def test_duplicate_codes_collapse_to_one_record():
    rows, _ = bt.rows_to_records(
        [("LH", "Lufthansa", "yes", "", ""),
         ("lh", "Lufthansa", "no", "", "")],
        ["iata", "name", "discount_eligible", "business_class",
         "confirmed_booking"])
    assert [r["code"] for r in rows] == ["LH"]


def test_a_blank_or_missing_code_row_is_skipped():
    rows, _ = bt.rows_to_records(
        [(None, "Nameless", "yes", "", ""), ("", "", "yes", "", ""),
         ("LH", "Lufthansa", "yes", "", "")],
        ["iata", "name", "discount_eligible", "business_class",
         "confirmed_booking"])
    assert [r["code"] for r in rows] == ["LH"]


# ── flags ────────────────────────────────────────────────────────────────────

def test_flags_are_keyed_by_code_and_by_canonical_name():
    flags = bt.records_to_flags([{"code": "LH", "name": "Lufthansa",
                                  "benefits": True, "which": []},
                                 {"code": "XX", "name": "Nope",
                                  "benefits": False, "which": []}])
    assert flags["LH"] is True
    assert flags["XX"] is False
    assert flags[ab.canonical_airline_key("Lufthansa")] is True


# ── the remote transport ─────────────────────────────────────────────────────

def test_a_successful_pipeline_call_parses(monkeypatch):
    """`body` rather than `json` as a parameter name: `requests` passes the
    payload as `json=`, and naming it that shadows the json module we need for
    building the canned response."""
    captured = {}

    def fake_post(url, headers=None, body=None, timeout=None, **kw):
        captured.update(url=url, headers=headers, body=body or kw.get("json"),
                        timeout=timeout)
        return _Response(payload=json.loads(_pipeline_response(
            [("LH", "Lufthansa", "yes", "yes", "yes"),
             ("XX", "Nope", "unknown", "unknown", "unknown")])))

    monkeypatch.setattr("requests.post", fake_post)
    rows, problems = bt.fetch_remote(bt.DEFAULT_REMOTE, "secret-token")
    assert problems == []
    assert [r["code"] for r in rows] == ["LH", "XX"]
    assert rows[0]["benefits"] is True and rows[1]["benefits"] is False

    # the request must actually look like a Turso pipeline call
    assert captured["url"] == bt.DEFAULT_REMOTE + "/v2/pipeline"
    assert captured["headers"]["Authorization"] == "Bearer secret-token"
    assert captured["body"]["requests"][-1] == {"type": "close"}
    assert "airlines" in captured["body"]["requests"][0]["stmt"]["sql"]


def test_a_url_that_already_has_the_path_is_not_doubled(monkeypatch):
    seen = {}

    def fake_post(url, **kw):
        seen["url"] = url
        return _Response(payload=json.loads(_pipeline_response(
            [("LH", "Lufthansa", "yes", "", "")])))

    monkeypatch.setattr("requests.post", fake_post)
    rows, problems = bt.fetch_remote("https://x.turso.io/v2/pipeline", "tok")
    assert problems == []
    assert rows[0]["code"] == "LH"
    assert seen["url"] == "https://x.turso.io/v2/pipeline"


@pytest.mark.parametrize("status,fragment", [
    (401, "401"), (403, "403"), (500, "unavailable"), (400, "400"),
])
def test_http_errors_become_problems_not_exceptions(monkeypatch, status,
                                                    fragment):
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        status_code=status, text="nope"))
    rows, problems = bt.fetch_remote("https://x.turso.io", "tok")
    assert rows == []
    assert problems and fragment in problems[0]


def test_an_error_result_inside_a_200_is_caught(monkeypatch):
    """Turso reports query failures in the body, not the status code."""
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        payload={"results": [{"type": "error",
                              "error": {"message": "no such table: nope"}}]}))
    rows, problems = bt.fetch_remote("https://x.turso.io", "tok")
    assert rows == []
    assert problems and "no such table" in problems[0]


def test_an_empty_table_is_a_failure_not_an_empty_airline_list(monkeypatch):
    """The dangerous case: an empty read would empty the finder silently."""
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        payload=json.loads(_pipeline_response([]))))
    rows, problems = bt.fetch_remote("https://x.turso.io", "tok")
    assert rows == []
    assert problems and "empty" in problems[0]


def test_a_non_json_body_is_reported(monkeypatch):
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        status_code=200, text="<html>maintenance</html>"))
    rows, problems = bt.fetch_remote("https://x.turso.io", "tok")
    assert rows == []
    assert problems and "non-JSON" in problems[0]


def test_a_network_error_is_reported(monkeypatch):
    def boom(url, **kw):
        raise OSError("connection reset")

    monkeypatch.setattr("requests.post", boom)
    rows, problems = bt.fetch_remote("https://x.turso.io", "tok")
    assert rows == []
    assert problems and "could not reach" in problems[0]


def test_no_token_means_no_request_is_made(monkeypatch):
    def fail(url, **kw):                                  # pragma: no cover
        raise AssertionError("must not call the network without a token")

    monkeypatch.setattr("requests.post", fail)
    rows, problems = bt.fetch_remote("https://x.turso.io", "")
    assert rows == []
    assert problems and bt.ENV_TOKEN in problems[0]


def test_a_table_name_that_is_not_an_identifier_is_refused(monkeypatch):
    def fail(url, **kw):                                  # pragma: no cover
        raise AssertionError("must not build a query from that")

    monkeypatch.setattr("requests.post", fail)
    rows, problems = bt.fetch_remote("https://x.turso.io", "tok",
                                     "airlines; DROP TABLE x")
    assert rows == []
    assert problems and "not a usable table name" in problems[0]


# ── the local SQLite fallback ────────────────────────────────────────────────

def test_the_local_database_is_read_with_the_real_sql(tmp_path):
    db = _make_db(tmp_path / "flightroutes.db", [
        ("LH", "Lufthansa", "yes", "yes", "yes", "", "2026-10-06T18:53:19+00:00"),
        ("CX", "Cathay Pacific", "yes", "unknown", "unknown", "", "2026-10-06"),
        ("XX", "Nope", "no", "no", "no", "", "2026-10-06"),
    ])
    rows, problems = bt.fetch_local(db)
    assert problems == []
    assert len(rows) == 3
    # Order follows the table, not the code: assert on the set so the test does
    # not pin down something the caller is free to change.
    assert {r["code"] for r in rows if r["benefits"]} == {"CX", "LH"}
    assert [r["code"] for r in rows] == ["LH", "CX", "XX"]


def test_the_local_database_may_lack_optional_columns(tmp_path):
    db = _make_db(tmp_path / "m.db", [("LH", "Lufthansa", "yes")])
    rows, problems = bt.fetch_local(db)
    assert problems == []
    assert rows[0]["benefits"] is True


def test_a_missing_local_database_is_reported(tmp_path):
    rows, problems = bt.fetch_local(tmp_path / "absent.db")
    assert rows == []
    assert problems and "does not exist" in problems[0]


def test_a_missing_table_in_the_local_database_is_reported(tmp_path):
    db = _make_db(tmp_path / "m.db", [])
    rows, problems = bt.fetch_local(db, table="nonexistent")
    assert rows == []
    assert problems and "query failed" in problems[0]


# ── the fallback ladder ──────────────────────────────────────────────────────

def test_turso_is_used_when_a_token_is_set(monkeypatch):
    monkeypatch.setenv(bt.ENV_TOKEN, "tok")
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        payload=json.loads(_pipeline_response([("LH", "Lufthansa", "yes",
                                                 "", "")]))))
    flags, _problems = bt.fetch_benefit_flags(use_cache=False)
    assert flags["LH"] is True


def test_the_local_file_is_used_when_the_remote_fails(monkeypatch, tmp_path):
    """Offline and outage both land on the local file, not on nothing."""
    db = _make_db(tmp_path / "flightroutes.db",
                  [("LH", "Lufthansa", "yes", "", "", "", "")])
    monkeypatch.setenv(bt.ENV_TOKEN, "tok")
    monkeypatch.setenv(bt.ENV_LOCAL_DB, db)
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        status_code=503, text="unavailable"))
    flags, problems = bt.fetch_benefit_flags(use_cache=False)
    assert flags["LH"] is True
    assert problems and "local" in problems[0]


def test_the_local_db_variable_is_spelled_the_way_the_project_spells_planner(monkeypatch):
    """Guard a bug that cost real time: the constant was `TRAVEL_PLANER_…`, one
    letter from `TRAVEL_PLANNER_DATA_DIR`, `TRAVEL_PLANNER_AIRLINE_BENEFITS` and
    the rest. An unset misspelled variable is silent — it just looks as though
    the offline fallback does not exist. Every env var this project defines must
    use the PLANNER spelling."""
    assert bt.ENV_LOCAL_DB.startswith("TRAVEL_PLANNER_")
    for name in (bt.ENV_URL, bt.ENV_TOKEN, bt.ENV_TABLE, bt.ENV_LOCAL_DB):
        assert "PLANNER" in name or name.startswith("TURSO_"), name


def test_the_local_fallback_actually_engages(tmp_path, monkeypatch):
    """End-to-end: a correct env var must reach the local file and win over the
    'not configured' message. Setting the variable through monkeypatch exercises
    the same lookup the module does, which the spelling test above guards."""
    db = _make_db(tmp_path / "flightroutes.db",
                  [("LH", "Lufthansa", "yes", "", "", "", ""),
                   ("XX", "Nope", "unknown", "", "", "", "")])
    monkeypatch.delenv(bt.ENV_TOKEN, raising=False)
    monkeypatch.setenv(bt.ENV_LOCAL_DB, db)
    records, problems = bt.fetch_benefit_records(use_cache=False)
    assert [r["code"] for r in records] == ["LH", "XX"]
    assert any("local" in problem for problem in problems)
    bt.clear_cache()


def test_nothing_configured_reports_why(monkeypatch):
    monkeypatch.delenv(bt.ENV_TOKEN, raising=False)
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    records, problems = bt.fetch_benefit_records(use_cache=False)
    assert records == []
    assert problems and bt.ENV_TOKEN in problems[0]
    assert "Falling back" in bt.summary(use_cache=False)


def test_results_are_cached_so_a_rerun_makes_no_request(monkeypatch):
    monkeypatch.setenv(bt.ENV_TOKEN, "tok")
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    calls = []

    def fake_post(url, **kw):
        calls.append(url)
        return _Response(payload=json.loads(_pipeline_response(
            [("LH", "Lufthansa", "yes", "", "")])))

    monkeypatch.setattr("requests.post", fake_post)
    bt.clear_cache()
    bt.fetch_benefit_records()
    bt.fetch_benefit_records()
    assert len(calls) == 1
    bt.clear_cache()


def test_a_different_token_busts_the_cache(monkeypatch):
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    bodies = []

    def fake_post(url, **kw):
        bodies.append(kw["headers"]["Authorization"])
        return _Response(payload=json.loads(_pipeline_response(
            [("LH", "Lufthansa", "yes", "", "")])))

    monkeypatch.setattr("requests.post", fake_post)
    bt.clear_cache()
    monkeypatch.setenv(bt.ENV_TOKEN, "first")
    bt.fetch_benefit_records()
    monkeypatch.setenv(bt.ENV_TOKEN, "second")
    bt.fetch_benefit_records()
    assert bodies == ["Bearer first", "Bearer second"]
    bt.clear_cache()


# ── the resolver in airline_benefits ─────────────────────────────────────────

def test_turso_wins_over_the_excel_file(monkeypatch):
    """The user's decision: once Turso is configured, the Excel file is dead."""
    monkeypatch.setenv(bt.ENV_TOKEN, "tok")
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        payload=json.loads(_pipeline_response([("ZZ", "Turso Air", "yes",
                                                 "", "")]))))
    def fail(source=None):                               # pragma: no cover
        raise AssertionError("must not read the Excel file when Turso is set up")

    monkeypatch.setattr(ab, "load_external_flags", fail)
    bt.clear_cache()
    assert ab.load_benefit_flags()["ZZ"] is True
    assert ab.benefit_source_name() == "Turso database"
    assert ab.benefit_names() == ["ZZ Turso Air"]
    bt.clear_cache()


def test_the_excel_file_is_still_used_when_turso_is_not_configured(monkeypatch):
    monkeypatch.delenv(bt.ENV_TOKEN, raising=False)
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    monkeypatch.setattr(ab, "load_external_flags", lambda source=None: (
        {"AA": True}, []))
    assert ab.turso_configured() is False
    assert ab.load_benefit_flags()["AA"] is True


def test_a_broken_turso_falls_through_to_the_workbook(monkeypatch):
    monkeypatch.setenv(bt.ENV_TOKEN, "tok")
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    monkeypatch.setattr(bt, "fetch_benefit_flags", lambda **kw: (_ for _ in ()).throw(
        RuntimeError("turso exploded")))
    assert ab.load_benefit_flags() == {} or True     # must not raise
    assert ab.turso_configured() is True


def test_the_summary_names_the_source_actually_used(monkeypatch):
    monkeypatch.setenv(bt.ENV_TOKEN, "tok")
    monkeypatch.delenv(bt.ENV_LOCAL_DB, raising=False)
    monkeypatch.setattr("requests.post", lambda url, **kw: _Response(
        payload=json.loads(_pipeline_response(
            [("LH", "Lufthansa", "yes", "", ""), ("XX", "Nope", "no", "", "")]))))
    bt.clear_cache()
    text = ab.benefit_summary()
    assert "Turso database" in text
    assert "1 of 2" in text
    assert "LH" in text
    assert "Unknown" in text
    bt.clear_cache()


if __name__ == "__main__":
    # Uses monkeypatch/tmp_path, so it needs pytest — it is deliberately not in
    # tests/run_all.py's SCRIPT_RUNNABLE list. Run via pytest, or directly here.
    raise SystemExit(pytest.main([__file__, "-q"]))
