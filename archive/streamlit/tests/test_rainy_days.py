"""One definition of "rainy day", and the provenance report (2026-10-04).

Decision: the unified definition (>= 1 mm/day, WMO) governs everything written
from now on, and the existing curated rows are deliberately *not* regenerated.
That is only safe if the remaining inconsistency is knowable, so
``list_legacy_rainy_days`` must name the affected rows without an API call.
"""

from __future__ import annotations

import sys
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import aqi_api  # noqa: E402
import rainy_days  # noqa: E402
import write_climate_data as wcd  # noqa: E402

# ── the definition ───────────────────────────────────────────────────────────

def test_threshold_is_the_wmo_rain_day():
    assert rainy_days.RAINY_DAY_THRESHOLD_MM == 1.0
    assert "1 mm" in rainy_days.DEFINITION


def test_is_rain_day_boundary():
    assert rainy_days.is_rain_day(1.0) is True
    assert rainy_days.is_rain_day(1.4) is True
    assert rainy_days.is_rain_day(0.999) is False
    assert rainy_days.is_rain_day(0) is False
    assert rainy_days.is_rain_day("2.5") is True     # numbers arrive as text too


def test_blank_or_broken_values_are_not_rain_days():
    """An unfilled cell must never inflate a count."""
    for value in (None, "", "n/a", float("nan")):
        assert rainy_days.is_rain_day(value) is False
    assert rainy_days.count_rain_days([None, 0.2, "", 3.0, 1.0]) == 2


def test_aqi_api_uses_the_shared_definition():
    """The API path must not carry its own hardcoded threshold."""
    source = (ROOT / "aqi_api.py").read_text(encoding="utf-8")
    assert "rainy_days.is_rain_day" in source
    assert ">= 1.0" not in source, \
        "the threshold must live in rainy_days.py only"


def test_no_module_hardcodes_another_precipitation_threshold():
    offenders = []
    for path in sorted(ROOT.glob("*.py")):
        if path.name == "rainy_days.py":
            continue
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            code = line.split("#", 1)[0]
            if "precip" in code.lower() and (">= 1.0" in code or "> 0.1" in code
                                             or ">= 0.1" in code):
                offenders.append(f"{path.name}: {line.strip()}")
    assert offenders == []


# ── provenance report ────────────────────────────────────────────────────────

def _book_with(tmp_path: Path, rows: dict) -> Path:
    path = tmp_path / "wb.xlsx"
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Result sheet"
    header = ["Destination", "Country"] + [f"{m} Rainy Days" for m in wcd.MONTHS]
    ws.append(header)
    for name, values in rows.items():
        ws.append([name, "X"] + list(values))
    spare = wb.create_sheet("Airlines")
    spare.append(["Airline"])
    wb.save(path)
    wb.close()
    return path


def test_report_names_the_curated_rows_it_would_regenerate(tmp_path):
    curated = list(wcd.CURATED_CLIMATE)[0]
    expected = [wcd.preserved_destination_climate(curated)[f"{m} Rainy Days"]
                for m in wcd.MONTHS]
    fetched = [float(v) + 3 for v in expected]        # not the curated numbers
    path = _book_with(tmp_path, {
        curated: expected,
        "Somewhere Else": fetched,
    })

    report = wcd.list_legacy_rainy_days(path)
    assert report["curated"] == [curated]
    assert report["canonical"] == ["Somewhere Else"]
    assert report["review"] == [] and report["no_data"] == []


def test_report_flags_a_partially_overwritten_row(tmp_path):
    curated = list(wcd.CURATED_CLIMATE)[0]
    expected = [wcd.preserved_destination_climate(curated)[f"{m} Rainy Days"]
                for m in wcd.MONTHS]
    mixed = list(expected)
    mixed[0] = float(mixed[0]) + 1                    # one month hand-edited
    mixed[1] = float(mixed[1]) + 1
    mixed[2] = float(mixed[2]) + 1
    path = _book_with(tmp_path, {curated: mixed})

    report = wcd.list_legacy_rainy_days(path)
    assert report["curated"] == []
    assert len(report["review"]) == 1
    assert "9/12" in report["review"][0], \
        "the report must show how much of the row still matches"


def test_a_row_with_no_rainy_days_is_reported_as_such(tmp_path):
    path = _book_with(tmp_path, {"Empty": [None] * 12})
    report = wcd.list_legacy_rainy_days(path)
    assert report["no_data"] == ["Empty"]
    assert report["curated"] == [] and report["canonical"] == []


def test_report_never_touches_the_workbook(tmp_path, monkeypatch):
    curated = list(wcd.CURATED_CLIMATE)[0]
    expected = [wcd.preserved_destination_climate(curated)[f"{m} Rainy Days"]
                for m in wcd.MONTHS]
    path = _book_with(tmp_path, {curated: expected})
    before = path.read_bytes()

    def explode(*_a, **_k):
        raise AssertionError("the provenance report must not write")

    monkeypatch.setattr(wcd, "save_workbook_atomic", explode)
    wcd.list_legacy_rainy_days(path)
    assert path.read_bytes() == before


def test_curated_table_survived_the_deletion_of_its_old_module():
    """Regression: commit 89b777c deleted populate_destination_details.py,
    which left ``preserved_destination_climate`` importing a module that no
    longer existed (so the script's main path raised ModuleNotFoundError)."""
    source = (ROOT / "write_climate_data.py").read_text(encoding="utf-8")
    code = "\n".join(line.split("#", 1)[0] for line in source.splitlines())
    assert "populate_destination_details" not in code, \
        "the deleted module must not be imported again"
    for destination in wcd.LAST_SIX_AQI:
        data = wcd.preserved_destination_climate(destination)
        assert [data[f"{m} Rainy Days"] for m in wcd.MONTHS] == \
            wcd.CURATED_CLIMATE[destination]["rainy_days"]


def test_legacy_whole_variant_and_new_per_stop_keys_are_both_documented():
    """Both key shapes must stay replayable for journals already on the branch."""
    from sync import merge

    assert "(trip_id, variant_id, part)" in (merge._apply_trips.__doc__ or "")
    assert "(trip_id, variant_id)" in (merge._apply_trips.__doc__ or "")


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit("This module needs pytest: "
                     "python -m pytest tests/test_rainy_days.py")