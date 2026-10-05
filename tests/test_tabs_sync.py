"""Open-tabs sync (F33): one tab = one journal entry.

Tabs are ephemeral UI state, not data. Each tab gets its own key
``("tabs", "tab", destination)`` so a tab opened on the PC and another opened
on the phone are different keys and both survive a merge with no conflict to
resolve. An open and a close of the *same* tab resolve to the newest change,
never to a conflict entry.

Needs pytest only for collection; the module also runs as a script:
``python tests/test_tabs_sync.py``.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import data_utils  # noqa: E402
from sync import journal, merge  # noqa: E402
from sync.merge import _key_of  # noqa: E402  (key encoding used by last_sync)

# ── helpers ──────────────────────────────────────────────────────────────────

class _TabsEnv:
    """A disposable tabs file + journal dir, patched in as the live ones."""

    def __init__(self, tmp: Path):
        self.tabs = tmp / "open_destinations.json"
        self.jdir = tmp / "journals"
        self._patches = [
            patch.object(data_utils, "OPEN_TABS_PATH", self.tabs),
            patch.object(journal, "DEFAULT_JOURNAL_DIR", self.jdir),
        ]

    def __enter__(self):
        for p in self._patches:
            p.start()
        return self

    def __exit__(self, *exc):
        for p in reversed(self._patches):
            p.stop()
        return False

    def entries(self):
        return journal.read_entries(self.jdir)

    def tabs_now(self):
        return json.loads(self.tabs.read_text(encoding="utf-8"))


def _entry(device, name, op, ts):
    return {"ts": ts, "device": device, "store": "tabs", "op": op,
            "key": ["tab", name], "value": True if op == "upsert" else None}


# ── journal shape ────────────────────────────────────────────────────────────

def test_tabs_journal_entry_shape():
    with tempfile.TemporaryDirectory() as td:
        jdir = Path(td)
        journal.record_tabs_change("Naples", op="upsert",
                                   device="pc", journal_dir=jdir,
                                   timestamp="2026-10-05T10:00:00+00:00")
        journal.record_tabs_change("Rome", op="delete",
                                   device="pc", journal_dir=jdir,
                                   timestamp="2026-10-05T10:01:00+00:00")
        entries = journal.read_entries(jdir)
        assert [(e["store"], e["key"], e["op"]) for e in entries] == [
            ("tabs", ["tab", "Naples"], "upsert"),
            ("tabs", ["tab", "Rome"], "delete"),
        ]
        assert entries[0]["value"] is True
        try:
            journal.record_tabs_change("X", op="replace", journal_dir=jdir)
        except ValueError:
            pass
        else:
            raise AssertionError("an unknown tabs op must be rejected")


# ── save journals deltas + one backfill ──────────────────────────────────────

def test_first_save_asserts_the_whole_list_then_only_deltas_travel():
    with tempfile.TemporaryDirectory() as td:
        with _TabsEnv(Path(td)) as env:
            assert data_utils.save_open_destinations(["Naples", "Rome"]) is True
            first = {(e["key"][1], e["op"]) for e in env.entries()}
            assert first == {("Naples", "upsert"), ("Rome", "upsert")}, \
                "pre-existing tabs must reach the other device, not just new ones"
            assert (env.jdir / "tabs_backfill_v1.json").exists()

            assert data_utils.save_open_destinations(["Rome", "Paris"]) is True
            second = [(e["key"][1], e["op"]) for e in env.entries()]
            assert second.count(("Paris", "upsert")) == 1
            assert second.count(("Naples", "delete")) == 1
            assert second.count(("Rome", "upsert")) == 1, \
                "an unchanged tab must not be re-journalled after the backfill"
            assert env.tabs_now() == ["Rome", "Paris"]


def test_closing_every_tab_journals_only_deletes():
    with tempfile.TemporaryDirectory() as td:
        with _TabsEnv(Path(td)) as env:
            data_utils.save_open_destinations(["Naples"])
            before = len(env.entries())
            data_utils.save_open_destinations([])
            ops = [e["op"] for e in env.entries()[before:]]
            assert ops == ["delete"]
            assert env.tabs_now() == []


def test_save_does_not_journal_during_a_sync_apply():
    with tempfile.TemporaryDirectory() as td:
        with _TabsEnv(Path(td)) as env:
            with patch.dict(os.environ, {"SYNC_MERGE_APPLY": "1"}):
                assert data_utils.save_open_destinations(["Naples"]) is True
            assert env.entries() == []
            assert not (env.jdir / "tabs_backfill_v1.json").exists()
            assert env.tabs_now() == ["Naples"]


def test_save_cleans_the_list_before_writing_and_journaling():
    with tempfile.TemporaryDirectory() as td:
        with _TabsEnv(Path(td)) as env:
            data_utils.save_open_destinations([" Naples ", "", "Naples", "Rome"])
            assert env.tabs_now() == ["Naples", "Rome"]
            names = [e["key"][1] for e in env.entries()]
            assert "" not in names and " Naples " not in names


# ── merge planning: tabs never conflict ──────────────────────────────────────

def test_concurrent_opens_on_both_devices_both_survive():
    local = [_entry("pc", "Naples", "upsert", "2026-10-05T10:00:00+00:00")]
    remote = [_entry("phone", "Rome", "upsert", "2026-10-05T10:01:00+00:00")]
    plan = merge.plan_merge(local, remote, {})
    assert plan["conflicts"] == []
    assert {(e["key"][1], e["op"]) for e in plan["apply"]} == \
        {("Naples", "upsert"), ("Rome", "upsert")}


def test_open_against_close_resolves_to_the_newest_change():
    opened = _entry("phone", "Naples", "upsert", "2026-10-05T10:00:00+00:00")
    closed = _entry("pc", "Naples", "delete", "2026-10-05T11:00:00+00:00")
    plan = merge.plan_merge([closed], [opened], {})
    assert plan["conflicts"] == [], "tabs must never ask the user to choose"
    assert len(plan["apply"]) == 1
    assert plan["apply"][0]["op"] == "delete", "the newer close wins"

    plan = merge.plan_merge([opened], [closed], {})
    assert plan["conflicts"] == []
    assert plan["apply"][0]["op"] == "delete"

    reopened = _entry("phone", "Naples", "upsert", "2026-10-05T12:00:00+00:00")
    plan = merge.plan_merge([closed], [reopened], {})
    assert plan["conflicts"] == []
    assert plan["apply"][0]["op"] == "upsert", "a newer open re-opens the tab"


def test_identical_opens_on_both_sides_apply_once():
    local = [_entry("pc", "Naples", "upsert", "2026-10-05T10:00:00+00:00")]
    remote = [_entry("phone", "Naples", "upsert", "2026-10-05T10:01:00+00:00")]
    plan = merge.plan_merge(local, remote, {})
    assert plan["conflicts"] == []
    assert len(plan["apply"]) == 1


# ── apply ────────────────────────────────────────────────────────────────────

def test_apply_opens_closes_and_keeps_order():
    with tempfile.TemporaryDirectory() as td:
        tabs = Path(td) / "tabs.json"
        trips = Path(td) / "trips.json"
        wb = Path(td) / "wb.xlsx"
        wb.write_bytes(b"")  # never touched: no workbook entries below
        summary = merge.apply_entries([
            _entry("phone", "Rome", "upsert", "2026-10-05T10:00:00+00:00"),
            _entry("phone", "Naples", "upsert", "2026-10-05T10:01:00+00:00"),
        ], workbook_path=wb, trips_path=trips, tabs_path=tabs)
        assert summary["applied"] == 2 and summary["skipped"] == []
        assert json.loads(tabs.read_text(encoding="utf-8")) == ["Rome", "Naples"]

        summary = merge.apply_entries([
            _entry("pc", "Rome", "delete", "2026-10-05T11:00:00+00:00"),
        ], workbook_path=wb, trips_path=trips, tabs_path=tabs)
        assert summary["applied"] == 1
        assert json.loads(tabs.read_text(encoding="utf-8")) == ["Naples"]


def test_apply_is_idempotent_and_rejects_garbage():
    with tempfile.TemporaryDirectory() as td:
        tabs = Path(td) / "tabs.json"
        kw = {"workbook_path": Path(td) / "wb.xlsx",
              "trips_path": Path(td) / "trips.json", "tabs_path": tabs}
        upsert = _entry("phone", "Naples", "upsert", "2026-10-05T10:00:00+00:00")
        assert merge.apply_entries([upsert], **kw)["applied"] == 1
        # Already open: satisfied, not a problem — and still exactly one tab.
        assert merge.apply_entries([upsert], **kw)["applied"] == 1
        assert json.loads(tabs.read_text(encoding="utf-8")) == ["Naples"]
        # Closing a tab that is not open changes nothing but is not an error.
        delete = _entry("pc", "Rome", "delete", "2026-10-05T11:00:00+00:00")
        assert merge.apply_entries([delete], **kw)["applied"] == 1

        bad = [
            {"ts": "2026-10-05T12:00:00+00:00", "device": "pc",
             "store": "tabs", "op": "upsert", "key": ["tab"], "value": True},
            {"ts": "2026-10-05T12:01:00+00:00", "device": "pc",
             "store": "tabs", "op": "upsert", "key": ["tab", "   "], "value": True},
            {"ts": "2026-10-05T12:02:00+00:00", "device": "pc",
             "store": "tabs", "op": "upsert", "key": ["tab", "X\ny"], "value": True},
            {"ts": "2026-10-05T12:03:00+00:00", "device": "pc",
             "store": "tabs", "op": "upsert", "key": ["other", "Naples"],
             "value": True},
        ]
        summary = merge.apply_entries(bad, **kw)
        assert summary["applied"] == 0, summary
        assert len(summary["skipped"]) == 4


# ── end to end across two devices ────────────────────────────────────────────

def test_two_devices_converge_on_the_union_then_on_closes():
    with tempfile.TemporaryDirectory() as td:
        tabs = Path(td) / "tabs.json"
        kw = {"workbook_path": Path(td) / "wb.xlsx",
              "trips_path": Path(td) / "trips.json", "tabs_path": tabs}
        # PC had Naples + Rome open, the phone had Rome + Paris: both backfills.
        pc = [_entry("pc", "Naples", "upsert", "2026-10-05T10:00:00+00:00"),
              _entry("pc", "Rome", "upsert", "2026-10-05T10:01:00+00:00")]
        phone = [_entry("phone", "Rome", "upsert", "2026-10-05T10:02:00+00:00"),
                 _entry("phone", "Paris", "upsert", "2026-10-05T10:03:00+00:00")]
        plan = merge.plan_merge(pc, phone, {})
        assert plan["conflicts"] == []
        merge.apply_entries(plan["apply"], **kw)
        assert sorted(json.loads(tabs.read_text(encoding="utf-8"))) == \
            ["Naples", "Paris", "Rome"]

        # The phone closes Rome; the PC opens nothing. The close must stick on
        # both sides and must not be resurrected by a later unrelated open.
        last = {}
        for e in plan["apply"]:
            last[json.dumps(_key_of(e), ensure_ascii=False)] = e["ts"]
        close = [_entry("phone", "Rome", "delete", "2026-10-05T11:00:00+00:00")]
        plan = merge.plan_merge([], close, last)
        merge.apply_entries(plan["apply"], **kw)
        assert sorted(json.loads(tabs.read_text(encoding="utf-8"))) == \
            ["Naples", "Paris"]


# ── suite hygiene ──────────────────────────────────────────────────────────────

def test_suite_redirects_live_tabs_and_journals_to_temp():
    """Regression: a full suite run used to overwrite the real
    ``open_destinations.json`` with test tabs and journal ~10k test entries
    into the real ``sync_journals/`` (the page smoke tests render through
    ``save_open_destinations`` without the ``sandbox`` fixture, and one of them
    mocks ``Path.exists`` globally). The session fixture in conftest.py must
    keep both paths off the repository; if this fails, every test after it is
    writing to the user's live state.
    """
    import runtime_paths

    live_tabs = runtime_paths.state_path("open_destinations.json").resolve()
    live_journals = runtime_paths.state_path("sync_journals").resolve()
    current_tabs = Path(data_utils.OPEN_TABS_PATH).resolve()
    current_journals = Path(journal.DEFAULT_JOURNAL_DIR).resolve()
    assert current_tabs != live_tabs, \
        "OPEN_TABS_PATH must be redirected to a temp copy during tests"
    assert current_journals != live_journals, \
        "DEFAULT_JOURNAL_DIR must be redirected to a temp dir during tests"


if __name__ == "__main__":
    tests = [
        test_tabs_journal_entry_shape,
        test_first_save_asserts_the_whole_list_then_only_deltas_travel,
        test_closing_every_tab_journals_only_deletes,
        test_save_does_not_journal_during_a_sync_apply,
        test_save_cleans_the_list_before_writing_and_journaling,
        test_concurrent_opens_on_both_devices_both_survive,
        test_open_against_close_resolves_to_the_newest_change,
        test_identical_opens_on_both_sides_apply_once,
        test_apply_opens_closes_and_keeps_order,
        test_apply_is_idempotent_and_rejects_garbage,
        test_two_devices_converge_on_the_union_then_on_closes,
        # test_suite_redirects_live_tabs_and_journals_to_temp needs the pytest
        # session fixture from conftest.py, so it is pytest-only by design.
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")
