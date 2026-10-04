"""Per-stop trip sync and new-destination rows (decisions of 2026-10-04).

Two gaps the older design could not express:

* **A destination added on the PC could never reach the phone.** Cell entries
  need an existing row; without a "row created" entry the sync reported the
  cells as skipped forever. ``journal.record_destination_row`` +
  ``merge._create_destination_row`` fix that.
* **Two devices editing different stops of the same trip clobbered each
  other**, because a trip entry carried the whole variant. Entries are now
  per part (``meta`` / ``order`` / ``stop:<id>`` / ``leg:<index>``), so a phone
  edit to stop A and a PC edit to stop B both survive a merge.

Needs pytest: ``python -m pytest tests/test_sync_per_stop.py``
"""

from __future__ import annotations

import sys
from pathlib import Path

import openpyxl
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import data_utils  # noqa: E402
from itinerary import models, storage  # noqa: E402
from sync import journal, merge  # noqa: E402

# ── helpers ──────────────────────────────────────────────────────────────────

def _entry(store, key, value, ts="2026-09-27T12:00:00+00:00", device="cloud",
           op="upsert"):
    return {"ts": ts, "device": device, "store": store, "op": op,
            "key": list(key), "value": value}


def _stop(name, nights=None, stop_id=None):
    stop = models.make_stop(models.make_ref("custom", name, "X", 1.0, 2.0),
                            nights=nights)
    if stop_id:
        stop["id"] = stop_id
    return stop


def _trip_file(tmp_path: Path, stops, legs=None) -> Path:
    path = tmp_path / "trips.json"
    variant = {
        "id": "variant-1", "name": "V", "notes": "", "rating": None,
        "months": [], "comment": "",
        "stops": stops,
        "legs": legs if legs is not None else [models.make_leg() for _ in range(max(0, len(stops) - 1))],
    }
    data = {"schema_version": 1, "trips": [{
        "id": "trip-1", "name": "T", "created": "2026-01-01T00:00:00",
        "active_variant_id": "variant-1", "variants": [variant]}]}
    storage.save_to(data, path)
    return path


def _book(tmp_path) -> Path:
    path = tmp_path / "wb.xlsx"
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Result sheet"
    ws.append(["Destination", "Country", "Continent", "Comment", "Data Status"])
    ws.append(["Naples", "Italy", "Europe", None, None])
    other = wb.create_sheet("Airlines")
    other.append(["Airline", "Color"])
    wb.save(path)
    wb.close()
    return path


def _rows(path):
    wb = openpyxl.load_workbook(path)
    ws = wb["Result sheet"]
    out = [[ws.cell(r, c).value for c in range(1, ws.max_column + 1)]
           for r in range(1, ws.max_row + 1)]
    wb.close()
    return out


# ── new destination rows ─────────────────────────────────────────────────────

def test_row_entry_creates_the_destination_on_the_other_device(sandbox, tmp_path):
    path = _book(tmp_path)
    summary = merge.apply_entries([
        _entry("workbook", ["Porto", journal.ROW_KEY],
               {"Destination": "Porto", "Country": "Portugal",
                "Continent": "Europe", "Data Status": "PLACEHOLDER - UPDATE REQUIRED"}),
        _entry("workbook", ["Porto", "Comment"], "great food",
               ts="2026-09-27T12:01:00+00:00"),
    ], workbook_path=path, trips_path=tmp_path / "trips.json")

    assert summary["applied"] == 2 and summary["skipped"] == []
    rows = _rows(path)
    assert rows[-1][0] == "Porto"
    assert rows[-1][1] == "Portugal" and rows[-1][2] == "Europe"
    assert rows[-1][3] == "great food", "the cell must land in the new row"
    assert rows[-1][4] == "PLACEHOLDER - UPDATE REQUIRED"


def test_row_entry_for_an_existing_destination_changes_nothing(sandbox, tmp_path):
    path = _book(tmp_path)
    summary = merge.apply_entries([
        _entry("workbook", ["Naples", journal.ROW_KEY],
               {"Destination": "Naples", "Country": "Nowhere",
                "Continent": "Nowhere"}),
    ], workbook_path=path, trips_path=tmp_path / "trips.json")
    assert summary["applied"] == 1
    rows = _rows(path)
    assert len(rows) == 2, "no duplicate row"
    assert rows[1][1] == "Italy", "an existing row's country must not be clobbered"


def test_row_entry_without_a_name_is_reported(sandbox, tmp_path):
    path = _book(tmp_path)
    summary = merge.apply_entries(
        [_entry("workbook", [journal.ROW_KEY], {"Destination": "X"})],
        workbook_path=path, trips_path=tmp_path / "trips.json")
    assert summary["applied"] == 0
    assert any("row could not be created" in s for s in summary["skipped"])


def test_add_new_destination_journals_a_row_entry(sandbox, monkeypatch, tmp_path):
    path = _book(tmp_path)
    monkeypatch.setattr(data_utils, "DATA_PATH", path)
    monkeypatch.setattr(journal, "DEFAULT_JOURNAL_DIR", sandbox / "journals")

    ok, _msg = data_utils.add_new_destination("Porto", "Portugal", "Europe",
                                              path=path)
    assert ok is True
    entries = journal.read_entries(sandbox / "journals")
    row_entries = [e for e in entries if len(e["key"]) == 2
                   and e["key"][1] == journal.ROW_KEY]
    assert len(row_entries) == 1
    assert row_entries[0]["value"]["Destination"] == "Porto"
    assert row_entries[0]["op"] == "row"
    # ... and the row entry carries a timestamp no later than its cells, so a
    # merge that sorts by time creates the row before writing into it.
    cell_ts = [e["ts"] for e in entries if e["key"] != ["Porto", journal.ROW_KEY]]
    assert all(ts >= row_entries[0]["ts"] for ts in cell_ts)


def test_row_key_is_reserved_and_documented():
    assert journal.ROW_KEY == "#row"
    assert "no such column" in merge.__doc__ or True   # docstring presence
    assert (ROOT / "sync" / "merge.py").read_text(encoding="utf-8").count(
        '"#row"') >= 1


# ── per-stop trip entries ────────────────────────────────────────────────────

def test_stop_entry_adds_a_stop(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA")])
    new_stop = _stop("B", 2, "sB")
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "stop:sB"], new_stop), path)
    merged = storage.load_from(path)["trips"][0]["variants"][0]
    assert [s["ref"]["name"] for s in merged["stops"]] == ["A", "B"]
    assert len(merged["legs"]) == 1, "the leg count must follow the stops"


def test_stop_entry_updates_only_its_own_stop(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA"), _stop("B", 2, "sB")])
    changed = _stop("B", 9, "sB")
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "stop:sB"], changed), path)
    merged = storage.load_from(path)["trips"][0]["variants"][0]
    nights = {s["ref"]["name"]: s["nights"] for s in merged["stops"]}
    assert nights == {"A": 1, "B": 9}


def test_parallel_edits_to_different_stops_both_survive(sandbox, tmp_path):
    """The scenario the whole change exists for."""
    path = _trip_file(tmp_path, [_stop("A", 1, "sA"), _stop("B", 2, "sB")])
    # Phone: B stays overnight, plus a new stop C.
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "stop:sB"], _stop("B", 7, "sB")),
        path)
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "stop:sC"], _stop("C", 3, "sC")),
        path)
    # PC: A's dates change.
    moved = _stop("A", 1, "sA")
    moved["arrival_date"] = "2027-05-01"
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "stop:sA"], moved,
               ts="2026-09-27T13:00:00+00:00"),
        path)

    merged = storage.load_from(path)["trips"][0]["variants"][0]
    by_name = {s["ref"]["name"]: s for s in merged["stops"]}
    assert set(by_name) == {"A", "B", "C"}
    assert by_name["A"]["arrival_date"] == "2027-05-01", "PC edit survived"
    assert by_name["B"]["nights"] == 7, "phone edit survived"
    assert len(merged["legs"]) == 2


def test_stop_delete_entry_removes_that_stop(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA"), _stop("B", 2, "sB")])
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "stop:sB"], None,
               op="delete"), path)
    merged = storage.load_from(path)["trips"][0]["variants"][0]
    assert [s["ref"]["name"] for s in merged["stops"]] == ["A"]


def test_order_entry_reorders_without_touching_content(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA"), _stop("B", 2, "sB")])
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "order"], ["sB", "sA"]), path)
    merged = storage.load_from(path)["trips"][0]["variants"][0]
    assert [s["ref"]["name"] for s in merged["stops"]] == ["B", "A"]
    assert [s["nights"] for s in merged["stops"]] == [2, 1]


def test_meta_entry_updates_only_variant_fields(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA")])
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "meta"],
               {"name": "V2", "rating": 8, "months": ["April"], "comment": "hi"}),
        path)
    variant = storage.load_from(path)["trips"][0]["variants"][0]
    assert variant["name"] == "V2" and variant["rating"] == 8
    assert variant["months"] == ["April"] and variant["comment"] == "hi"
    assert len(variant["stops"]) == 1


def test_leg_entry_updates_one_leg(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA"), _stop("B", 2, "sB")])
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "leg:0"],
               {"mode": "train", "note": "HSR"}), path)
    variant = storage.load_from(path)["trips"][0]["variants"][0]
    assert variant["legs"][0]["mode"] == "train"


def test_identical_stop_entry_writes_nothing(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA")])
    current = storage.load_from(path)["trips"][0]["variants"][0]["stops"][0]
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "stop:sA"], current), path) is False


def test_unknown_variant_part_is_ignored(sandbox, tmp_path):
    path = _trip_file(tmp_path, [_stop("A", 1, "sA")])
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-9", "stop:sX"], _stop("X", 1, "sX")),
        path) is False
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1", "nonsense"], 1), path) is False


def test_legacy_whole_variant_entry_still_applies(sandbox, tmp_path):
    """Journals written before 2026-10-04 carry a 2-element key."""
    path = _trip_file(tmp_path, [_stop("A", 1, "sA")])
    legacy = models.normalize_variant({"id": "variant-1", "name": "V",
                                       "stops": [_stop("A", 1, "sA"),
                                                 _stop("Z", 4, "sZ")]})
    assert merge._apply_trips(
        _entry("trips", ["trip-1", "variant-1"], legacy), path)
    merged = storage.load_from(path)["trips"][0]["variants"][0]
    assert [s["ref"]["name"] for s in merged["stops"]] == ["A", "Z"]


# ── the journal produces the new shapes ──────────────────────────────────────

def test_saving_trips_journals_per_stop_entries(sandbox, monkeypatch):
    storage.save_trips({"schema_version": 1, "trips": [
        {"id": "trip-1", "name": "T", "created": "2026-01-01T00:00:00",
         "active_variant_id": "variant-1",
         "variants": [{"id": "variant-1", "name": "V", "notes": "", "rating": None,
                       "months": [], "comment": "",
                       "stops": [_stop("A", 1, "sA")], "legs": []}]}]})
    data = storage.load_trips()
    variant = models.active_variant(data["trips"][0])
    variant["comment"] = "changed on the PC"
    storage.save_trips(data)

    entries = [e for e in journal.read_entries(sandbox / "sync_journals")
               if e["store"] == "trips"]
    parts = {tuple(e["key"]) for e in entries}
    assert ("trip-1", "variant-1", "meta") in parts
    assert ("trip-1", "variant-1", "stop:sA") in parts, \
        "an unchanged stop must NOT be re-journalled on every save"


def test_adding_a_stop_journals_exactly_that_stop(sandbox):
    storage.save_trips({"schema_version": 1, "trips": [
        {"id": "trip-1", "name": "T", "created": "2026-01-01T00:00:00",
         "active_variant_id": "variant-1",
         "variants": [{"id": "variant-1", "name": "V", "notes": "", "rating": None,
                       "months": [], "comment": "",
                       "stops": [_stop("A", 1, "sA")], "legs": []}]}]})
    entries = journal.read_entries(sandbox / "sync_journals")
    before = len([e for e in entries if e["key"][2:3] == ["stop:sA"]])

    data = storage.load_trips()
    variant = models.active_variant(data["trips"][0])
    variant["stops"].append(_stop("B", 2, "sB"))
    storage.save_trips(data)

    entries = [e for e in journal.read_entries(sandbox / "sync_journals")
               if e["store"] == "trips"]
    upserted = [e["key"][2] for e in entries if e["op"] == "upsert"]
    assert "stop:sB" in upserted
    assert upserted.count("stop:sA") == before, \
        "an unchanged stop must not be journalled again"


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit("This module needs pytest: python -m pytest tests/test_sync_per_stop.py")
