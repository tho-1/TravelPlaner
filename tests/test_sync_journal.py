from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sync import journal


def test_journal_roundtrip_workbook_and_trips():
    with tempfile.TemporaryDirectory() as td:
        jdir = Path(td)
        journal.ensure_baseline(journal_dir=jdir)
        journal.record_workbook_change(
            "Naples", "Comment", "hello", device="local", journal_dir=jdir
        )
        journal.record_trips_change(
            "trip-1",
            "variant-1",
            {"name": "Variant 1"},
            device="local",
            journal_dir=jdir,
        )
        entries = journal.read_entries(jdir)
        assert len(entries) == 2
        wb = next(e for e in entries if e["store"] == "workbook")
        assert wb["key"] == ["Naples", "Comment"]
        assert wb["value"] == "hello"
        assert wb["device"] == "local"
        tr = next(e for e in entries if e["store"] == "trips")
        assert tr["key"] == ["trip-1", "variant-1"]
        assert tr["value"] == {"name": "Variant 1"}


def test_baseline_is_created_once():
    with tempfile.TemporaryDirectory() as td:
        jdir = Path(td)
        first = journal.ensure_baseline(journal_dir=jdir)
        second = journal.ensure_baseline(journal_dir=jdir)
        assert first["created_utc"] == second["created_utc"]


if __name__ == "__main__":
    test_journal_roundtrip_workbook_and_trips()
    print("PASS test_journal_roundtrip_workbook_and_trips")
    test_baseline_is_created_once()
    print("PASS test_baseline_is_created_once")
    print("2/2 passed")
