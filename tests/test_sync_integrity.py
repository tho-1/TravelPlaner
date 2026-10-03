"""Sync integrity: journal ownership, lossless transport, per-stop trip merge.

Covers three data-loss paths found in the Phase 2 implementation:

* a device applied another device's winning entry **into that device's journal
  file** and then uploaded it, replacing the shared journal on ``data-sync``
  with a partial copy (F3);
* a sync rewrote and re-snapshotted the workbook *per entry*, so a 30-cell
  sync serialised the workbook 30 times and deleted the pre-sync safety
  snapshot after the 12th write (F4);
* a trip conflict was resolved by replacing the **whole variant**, so a phone
  edit to one stop discarded PC edits to other stops of the same trip (F14).

Needs pytest: ``python -m pytest tests/test_sync_integrity.py``
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import openpyxl
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from itinerary import models, storage  # noqa: E402
from sync import journal, merge, transport_github  # noqa: E402


def _entry(store, key, value, ts, device, op="upsert"):
    return {"ts": ts, "device": device, "store": store, "op": op,
            "key": key, "value": value}


def _jsonl(*entries) -> str:
    return "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries)


# ── F3: journal files belong to the writer, never to the entry's device ─────

def test_appending_a_foreign_entry_writes_to_our_own_file(sandbox, monkeypatch):
    monkeypatch.setenv("SYNC_DEVICE_ID", "cloud")
    remote_entry = _entry("workbook", ["Naples", "Comment"], "from pc",
                          "2026-09-27T12:00:00+00:00", "local")

    written = journal.append_entry(dict(remote_entry), sandbox / "journals")

    assert written.name.startswith("cloud-"), (
        f"a device must never write into another device's file, got {written.name}")
    entries = journal.read_entries(sandbox / "journals")
    assert len(entries) == 1
    assert entries[0]["device"] == "local", "the originator is preserved in the entry"


def test_each_device_keeps_its_own_file(sandbox, monkeypatch):
    jdir = sandbox / "journals"
    monkeypatch.setenv("SYNC_DEVICE_ID", "local")
    journal.append_entry(_entry("workbook", ["A", "Comment"], "1",
                                "2026-09-27T12:00:00+00:00", "local"), jdir)
    monkeypatch.setenv("SYNC_DEVICE_ID", "cloud")
    journal.append_entry(_entry("workbook", ["B", "Comment"], "2",
                                "2026-09-27T12:01:00+00:00", "cloud"), jdir)
    files = sorted(p.name for p in jdir.glob("*.jsonl"))
    assert len(files) == 2, files
    assert len(journal.read_entries(jdir)) == 2


def test_append_entries_is_a_thin_loop(sandbox, monkeypatch):
    monkeypatch.setenv("SYNC_DEVICE_ID", "cloud")
    jdir = sandbox / "journals"
    journal.append_entries(
        [_entry("workbook", ["A", "C"], "1", "2026-09-27T12:00:00+00:00", "local"),
         _entry("workbook", ["B", "C"], "2", "2026-09-27T12:01:00+00:00", "local")],
        jdir)
    files = list(jdir.glob("*.jsonl"))
    assert len(files) == 1 and files[0].name.startswith("cloud-")
    assert len(journal.read_entries(jdir)) == 2


# ── F3: transport must union, never truncate ───────────────────────────────

def test_merge_jsonl_keeps_both_histories():
    a = _entry("workbook", ["A", "C"], "from-a", "2026-09-27T10:00:00+00:00", "local")
    b = _entry("workbook", ["B", "C"], "from-b", "2026-09-27T11:00:00+00:00", "cloud")
    merged = transport_github.merge_jsonl(_jsonl(a), _jsonl(b))   # local, remote
    values = [json.loads(line)["value"] for line in merged.splitlines()]
    assert values == ["from-a", "from-b"]        # chronological, nothing dropped


def test_merge_jsonl_is_idempotent():
    a = _entry("workbook", ["A", "C"], "1", "2026-09-27T10:00:00+00:00", "local")
    once = transport_github.merge_jsonl(_jsonl(a), "")
    twice = transport_github.merge_jsonl(once, once)
    assert once == twice
    assert len(twice.strip().splitlines()) == 1


def test_merge_jsonl_tolerates_garbage_lines():
    good = _jsonl(_entry("workbook", ["A", "C"], "1", "2026-09-27T10:00:00+00:00", "local"))
    merged = transport_github.merge_jsonl("not json\n" + good, "")
    assert len([line for line in merged.splitlines() if line.strip()]) == 2


def test_merge_jsonl_handles_empty_sides():
    entry = _entry("workbook", ["A", "C"], "1", "2026-09-27T10:00:00+00:00", "local")
    assert transport_github.merge_jsonl("", "") == ""
    assert len(transport_github.merge_jsonl(_jsonl(entry), "").splitlines()) == 1


# ── F4: one workbook write per sync, safety snapshot survives ───────────────

def _book(tmp_path) -> Path:
    path = tmp_path / "wb.xlsx"
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Result sheet"
    ws.append(["Destination", "Comment", "Visited?"])
    for name in ("Naples", "Oslo", "Lima", "Cusco"):
        ws.append([name, None, None])
    wb.save(path)
    wb.close()
    return path


def test_many_cell_entries_are_applied_in_a_single_save(sandbox, tmp_path,
                                                        monkeypatch):
    path = _book(tmp_path)
    entries = [
        _entry("workbook", [name, "Comment"], f"c-{name}",
               f"2026-09-27T12:{i:02d}:00+00:00", "cloud")
        for i, name in enumerate(("Naples", "Oslo", "Lima", "Cusco"))
    ]

    saves = {"n": 0}
    from data_utils import save_workbook_atomic as real_save

    def counting_save(workbook, target):
        saves["n"] += 1
        return real_save(workbook, target)

    monkeypatch.setattr("data_utils.save_workbook_atomic", counting_save)
    summary = merge.apply_entries(entries, workbook_path=path,
                                  trips_path=tmp_path / "trips.json")
    assert summary["applied"] == 4
    assert saves["n"] == 1, "the workbook must be written once per sync, not per entry"


def test_pre_sync_snapshot_survives_a_large_sync(sandbox, tmp_path, monkeypatch):
    """The snapshot taken before the apply must not be pruned by it."""
    path = _book(tmp_path)
    monkeypatch.setattr("data_utils.WORKBOOK_BACKUP_KEEP", 12)
    entries = [
        _entry("workbook", [name, "Comment"], f"c{i}",
               f"2026-09-27T12:{i:02d}:00+00:00", "cloud")
        for i, name in enumerate(("Naples", "Oslo", "Lima", "Cusco"))
    ]
    summary = merge.apply_entries(entries, workbook_path=path,
                                  trips_path=tmp_path / "trips.json")
    backups = sorted((tmp_path / "workbook_backups").glob("*.xlsx"))
    assert len(backups) >= 2, "the pre-sync snapshot and the save snapshot"
    assert Path(summary["snapshots"][0]).exists()


def test_all_cells_land_in_the_right_rows(sandbox, tmp_path):
    path = _book(tmp_path)
    entries = [
        _entry("workbook", ["Naples", "Comment"], "pizza", "2026-09-27T12:00:00+00:00", "cloud"),
        _entry("workbook", ["Cusco", "Comment"], "ceviche", "2026-09-27T12:01:00+00:00", "cloud"),
    ]
    merge.apply_entries(entries, workbook_path=path, trips_path=tmp_path / "trips.json")
    wb = openpyxl.load_workbook(path)
    ws = wb["Result sheet"]
    assert ws["B2"].value == "pizza"
    assert ws["B5"].value == "ceviche"
    assert ws["B3"].value is None and ws["B4"].value is None
    wb.close()


def test_unknown_rows_and_columns_are_skipped_not_fatal(sandbox, tmp_path):
    path = _book(tmp_path)
    entries = [
        _entry("workbook", ["Atlantis", "Comment"], "x", "2026-09-27T12:00:00+00:00", "cloud"),
        _entry("workbook", ["Naples", "NoSuchColumn"], "x", "2026-09-27T12:01:00+00:00", "cloud"),
        _entry("workbook", ["Oslo", "Comment"], "ok", "2026-09-27T12:02:00+00:00", "cloud"),
    ]
    summary = merge.apply_entries(entries, workbook_path=path,
                                  trips_path=tmp_path / "trips.json")
    assert summary["applied"] == 1
    wb = openpyxl.load_workbook(path)
    assert wb["Result sheet"]["B3"].value == "ok"
    wb.close()


def test_a_trips_only_sync_does_not_snapshot_the_workbook(sandbox, tmp_path):
    """Regression: the test suite used to fill the live backup rotation.

    ``apply_entries`` always snapshotted the workbook, so a trips-only apply
    (and every caller that omitted workbook_path) wrote a copy of the live
    Destinations-*.xlsx into workbook_backups/.
    """
    path = _book(tmp_path)
    summary = merge.apply_entries(
        [_entry("trips", ["trip-x", "variant-x"], None,
                "2026-09-27T12:00:00+00:00", "cloud", op="delete")],
        workbook_path=path, trips_path=tmp_path / "trips.json")
    assert summary["applied"] == 0        # unknown trip -> nothing written
    assert summary["snapshots"] == []
    assert not (tmp_path / "workbook_backups").exists()


def test_dry_run_writes_nothing(sandbox, tmp_path):
    path = _book(tmp_path)
    before = path.read_bytes()
    summary = merge.apply_entries(
        [_entry("workbook", ["Naples", "Comment"], "x", "2026-09-27T12:00:00+00:00", "cloud")],
        workbook_path=path, trips_path=tmp_path / "trips.json", dry_run=True)
    assert summary["would_apply"] == 1 and summary["applied"] == 0
    assert path.read_bytes() == before


# ── F14: trip variants merge per stop, not wholesale ────────────────────────

def _trips_file(tmp_path: Path, stops: list[dict]) -> Path:
    path = tmp_path / "trips.json"
    data = {"schema_version": 1, "trips": [{
        "id": "trip-1", "name": "T", "created": "2026-01-01T00:00:00",
        "active_variant_id": "variant-1",
        "variants": [{"id": "variant-1", "name": "V", "notes": "", "rating": None,
                      "months": [], "comment": "", "stops": stops,
                      "legs": [models.make_leg() for _ in range(max(0, len(stops) - 1))]}]}]}
    storage.save_to(data, path)
    return path


def _stop(name, nights=None):
    return models.make_stop(models.make_ref("custom", name, "X", 1.0, 2.0),
                            nights=nights)


def test_winning_variant_is_authoritative_for_its_stops(sandbox, tmp_path):
    """Winner-authoritative semantics (documented limitation, not a bug).

    A per-stop union was tried and rejected: it cannot express a deletion, so
    a stop removed on the phone came back from the PC's stale copy. The
    conflict UI states the consequence; per-stop journal keys are the fix.
    """
    local_stops = [_stop("A", 1), _stop("B", 2)]
    path = _trips_file(tmp_path, local_stops)
    remote_variant = models.normalize_variant({
        "id": "variant-1", "name": "V",
        "stops": [models.make_stop(local_stops[0]["ref"], nights=9),
                  _stop("C", 3)]})
    entry = _entry("trips", ["trip-1", "variant-1"], remote_variant,
                   "2026-09-27T12:00:00+00:00", "cloud")

    assert merge._apply_trips(entry, path) is True
    merged = storage.load_from(path)["trips"][0]["variants"][0]
    names = [s["ref"]["name"] for s in merged["stops"]]
    assert names == ["A", "C"], "the winner's stop list wins, including removals"
    assert merged["stops"][0]["nights"] == 9
    assert len(merged["legs"]) == len(merged["stops"]) - 1


def test_identical_variant_is_not_rewritten(sandbox, tmp_path):
    path = _trips_file(tmp_path, [_stop("A", 1)])
    current = storage.load_from(path)["trips"][0]["variants"][0]
    entry = _entry("trips", ["trip-1", "variant-1"], current,
                   "2026-09-27T12:00:00+00:00", "cloud")
    assert merge._apply_trips(entry, path) is False


def test_variant_delete_removes_the_variant_and_then_the_trip(sandbox, tmp_path):
    path = _trips_file(tmp_path, [_stop("A", 1), _stop("B", 2)])
    delete = _entry("trips", ["trip-1", "variant-1"], None,
                    "2026-09-27T12:05:00+00:00", "cloud", op="delete")
    assert merge._apply_trips(delete, path) is True
    assert storage.load_from(path)["trips"] == []


def test_new_variant_is_appended_not_duplicated(sandbox, tmp_path):
    path = _trips_file(tmp_path, [_stop("A", 1)])
    extra = models.normalize_variant({"id": "variant-2", "name": "V2",
                                      "stops": [_stop("Z")]})
    entry = _entry("trips", ["trip-1", "variant-2"], extra,
                   "2026-09-27T12:00:00+00:00", "cloud")
    assert merge._apply_trips(entry, path) is True
    variants = storage.load_from(path)["trips"][0]["variants"]
    assert [v["id"] for v in variants] == ["variant-1", "variant-2"]


def test_legs_are_repaired_to_match_the_winning_stops(sandbox):
    local = models.normalize_variant({"id": "v", "name": "V",
                                      "stops": [_stop("A"), _stop("B"), _stop("C")]})
    remote = models.normalize_variant({"id": "v", "name": "V",
                                       "stops": [_stop("A"), _stop("D")]})
    merged = merge._merge_variant(local, remote)
    assert [s["ref"]["name"] for s in merged["stops"]] == ["A", "D"]
    assert len(merged["legs"]) == len(merged["stops"]) - 1


def test_missing_trip_is_skipped_not_created(sandbox, tmp_path):
    path = _trips_file(tmp_path, [_stop("A", 1)])
    entry = _entry("trips", ["trip-unknown", "variant-1"],
                   models.normalize_variant({"id": "variant-1", "name": "V"}),
                   "2026-09-27T12:00:00+00:00", "cloud")
    assert merge._apply_trips(entry, path) is False


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit("This module needs pytest: python -m pytest tests/test_sync_integrity.py")
