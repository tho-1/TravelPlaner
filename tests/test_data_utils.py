from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

import openpyxl

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import data_utils


def _make_workbook(path: Path, value: str = "base") -> None:
    workbook = openpyxl.Workbook()
    workbook.active["A1"] = value
    workbook.save(path)
    workbook.close()


def _read_value(path: Path) -> str:
    workbook = openpyxl.load_workbook(path, read_only=True)
    value = workbook.active["A1"].value
    workbook.close()
    return value


def test_atomic_save_snapshots_outgoing_workbook():
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "sample.xlsx"
        _make_workbook(path)
        workbook = data_utils.load_workbook_for_update(path)
        workbook.active["A1"] = "updated"
        data_utils.save_workbook_atomic(workbook, path)
        workbook.close()

        backups = list((Path(td) / "workbook_backups").glob("sample-*.xlsx"))
        assert len(backups) == 1
        assert _read_value(backups[0]) == "base"
        assert _read_value(path) == "updated"


def test_update_comment_uses_atomic_writer():
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "sample.xlsx"
        workbook = openpyxl.Workbook()
        sheet = workbook.active
        sheet.append(["Destination", "Comment"])
        sheet.append(["Example", None])
        workbook.save(path)
        workbook.close()

        data_utils.update_comment("Example", "saved through writer", path=path)

        check = openpyxl.load_workbook(path, read_only=True)
        assert check.active["B2"].value == "saved through writer"
        check.close()
        backups = list((Path(td) / "workbook_backups").glob("sample-*.xlsx"))
        assert len(backups) == 1
        assert _read_value_from_cell(backups[0], "B2") is None


def _read_value_from_cell(path: Path, cell: str):
    workbook = openpyxl.load_workbook(path, read_only=True)
    value = workbook.active[cell].value
    workbook.close()
    return value


def test_stale_workbook_cannot_overwrite_newer_save():
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "sample.xlsx"
        _make_workbook(path)
        stale = data_utils.load_workbook_for_update(path)
        current = data_utils.load_workbook_for_update(path)
        stale.active["A1"] = "stale"
        current.active["A1"] = "current"
        data_utils.save_workbook_atomic(current, path)
        current.close()

        try:
            data_utils.save_workbook_atomic(stale, path)
        except data_utils.WorkbookChangedError:
            pass
        else:
            raise AssertionError("stale workbook save was not rejected")
        finally:
            stale.close()
        assert _read_value(path) == "current"


def test_workbook_backups_keep_newest_twelve():
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "sample.xlsx"
        _make_workbook(path)
        for value in range(14):
            workbook = data_utils.load_workbook_for_update(path)
            workbook.active["A1"] = str(value)
            data_utils.save_workbook_atomic(workbook, path)
            workbook.close()

        backups = sorted((Path(td) / "workbook_backups").glob("sample-*.xlsx"))
        assert len(backups) == data_utils.WORKBOOK_BACKUP_KEEP
        assert _read_value(backups[0]) == "1"
        assert _read_value(backups[-1]) == "12"
        assert _read_value(path) == "13"


def test_replace_failure_preserves_original_and_raises_friendly_error():
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "sample.xlsx"
        _make_workbook(path)
        workbook = data_utils.load_workbook_for_update(path)
        workbook.active["A1"] = "not installed"
        try:
            with patch("data_utils.os.replace", side_effect=PermissionError("locked")):
                try:
                    data_utils.save_workbook_atomic(workbook, path)
                except data_utils.WorkbookLockedError:
                    pass
                else:
                    raise AssertionError("replace failure did not raise a friendly error")
        finally:
            workbook.close()
        assert _read_value(path) == "base"
        assert list((Path(td) / "workbook_backups").glob("sample-*.xlsx"))


if __name__ == "__main__":
    tests = [
        test_atomic_save_snapshots_outgoing_workbook,
        test_update_comment_uses_atomic_writer,
        test_stale_workbook_cannot_overwrite_newer_save,
        test_workbook_backups_keep_newest_twelve,
        test_replace_failure_preserves_original_and_raises_friendly_error,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")