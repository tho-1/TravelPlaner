"""Tests for the airline benefit flag (weekend finder).

Runs with or without pytest:
    python -m pytest tests/test_airline_benefits.py
    python tests/test_airline_benefits.py
"""

from __future__ import annotations

import os
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import airline_benefits as ab  # noqa: E402


@contextmanager
def without_external_file():
    """Ignore the real ``airlines_benefits.xlsx`` for the duration.

    pytest does this for the whole session in conftest.py; running as a script
    needs it per test, otherwise the developer's own file decides the outcome.
    """
    previous = os.environ.get(ab.EXTERNAL_FILE_ENV)
    os.environ[ab.EXTERNAL_FILE_ENV] = str(ROOT / "tests" / "_absent.xlsx")
    ab._EXTERNAL_CACHE = None
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(ab.EXTERNAL_FILE_ENV, None)
        else:
            os.environ[ab.EXTERNAL_FILE_ENV] = previous
        ab._EXTERNAL_CACHE = None

# ── name normalisation ───────────────────────────────────────────────────────

def test_normalisation_strips_punctuation_case_and_legal_forms():
    assert ab.normalize_airline("Lufthansa") == "lufthansa"
    assert ab.normalize_airline("BRITISH AIRWAYS PLC") == "british"
    assert ab.normalize_airline("Swiss International Air Lines") == "swissair"
    assert ab.normalize_airline("  Air  France  ") == "airfrance"


def test_legal_suffixes_do_not_make_one_carrier_look_like_two():
    for a, b in [
        ("British Airways", "British Airways plc"),
        ("British Airways", "British Airways Limited"),
        ("Emirates", "Emirates Airline"),
        ("Air France", "Air France S.A."),
    ]:
        assert ab.canonical_airline_key(a) == ab.canonical_airline_key(b), (a, b)


def test_a_repeated_word_collapses():
    assert ab.canonical_airline_key("SWISS Swiss") == ab.canonical_airline_key("SWISS")


def test_equivalent_spellings_share_a_key():
    for a, b in [
        ("Deutsche Lufthansa AG", "Lufthansa"),
        ("Lufthansa CityLine", "Lufthansa"),
        ("TAP Air Portugal", "TAP"),
        ("SAS Scandinavian Airlines", "SAS"),
        ("All Nippon Airways", "ANA"),
        ("KLM Royal Dutch Airlines", "KLM"),
        ("Swiss International Air Lines", "SWISS"),
        ("Eurowings Europe", "Eurowings"),
    ]:
        assert ab.canonical_airline_key(a) == ab.canonical_airline_key(b), (a, b)


def test_different_carriers_keep_different_keys():
    keys = {ab.canonical_airline_key(name) for name in
            ("Lufthansa", "Ryanair", "easyJet", "Air France", "KLM", "TAP")}
    assert len(keys) == 6, keys


def test_blank_and_none_airlines_have_no_key():
    assert ab.canonical_airline_key(None) == ""
    assert ab.canonical_airline_key("") == ""
    assert ab.canonical_airline_key("   ") == ""
    assert ab.has_benefits(None) is False


# ── the seed list ────────────────────────────────────────────────────────────

def test_seed_list_resolves_every_name_to_itself():
    """A seed entry that does not resolve to its own key would be a silent
    no-op: has_benefits() would be asked about a key the sheet never contains.
    """
    seeds = ab.seed_flags()
    for name in ab.SEED_BENEFIT_AIRLINES:
        key = ab.canonical_airline_key(name)
        assert key in seeds, f"{name} -> {key} missing from the seed map"
        assert seeds[key] is True


def test_seed_list_has_no_duplicate_carriers():
    """Two names for one carrier ("Lufthansa" + "Lufthansa CityLine") collapse
    to the same key, so one sheet row would overwrite the other and the count
    the UI reports would not match the rows written."""
    keys = [ab.canonical_airline_key(name) for name in ab.SEED_BENEFIT_AIRLINES]
    assert len(keys) == len(set(keys)), "duplicate carrier in the seed list"
    assert len(ab.seed_flags()) == len(ab.SEED_BENEFIT_AIRLINES)


def test_seed_names_are_qualified_by_default():
    for name in ("Lufthansa", "Eurowings", "Air France", "KLM", "British Airways"):
        assert ab.has_benefits(name, {}) is True, name


def test_low_cost_carriers_are_not_qualified_by_default():
    for name in ("Ryanair", "easyJet", "Wizz Air", "Volaris", "Condor"):
        assert ab.has_benefits(name, {}) is False, name


# ── the flags argument wins over the seed ────────────────────────────────────

def test_an_explicit_sheet_overrides_the_seed_list():
    flags = {ab.canonical_airline_key("Ryanair"): True}
    assert ab.has_benefits("Ryanair", flags) is True
    # The seed would have said yes for Lufthansa; the sheet says nothing, and an
    # unlisted airline must not qualify once the sheet exists.
    assert ab.has_benefits("Lufthansa", flags) is False


def test_an_explicit_no_outranks_the_seed_yes():
    flags = {"lufthansa": False}
    assert ab.has_benefits("Lufthansa", flags) is False


def test_truthy_spellings():
    for value in ("x", "X", "yes", "y", "true", "True", 1, True):
        assert ab._truthy(value) is True, value
    for value in (None, "", "no", "false", "0", 0, False, "maybe"):
        assert ab._truthy(value) is False, value


def test_a_substring_match_resolves_an_unfolded_spelling():
    flags = {ab.canonical_airline_key("Singapore Airlines"): True}
    assert ab.has_benefits("Singapore Airlines Limited", flags) is True


def test_an_ambiguous_substring_is_not_treated_as_qualified():
    """A "yes" and a "no" inside one name means we cannot tell which carrier is
    meant, so it must not qualify."""
    flags = {"sing": True, "singapore": False}
    assert ab.has_benefits("Something Singapore-ish", flags) is False


def test_agreeing_substring_matches_still_answer():
    """Several flagged carriers matching with the same answer is not ambiguous."""
    flags = {"sing": True, "singapore": True}
    assert ab.has_benefits("Something Singapore-ish", flags) is True


# ── filtered_airlines ────────────────────────────────────────────────────────

def test_filtered_airlines_keeps_order_and_drops_blanks():
    keep = ab.filtered_airlines(
        ["Lufthansa", "Ryanair", "  ", "Air France", "Lufthansa"], {})
    assert keep == ["Lufthansa", "Air France"]


def test_filtered_airlines_with_no_input_is_empty():
    assert ab.filtered_airlines(None) == []
    assert ab.filtered_airlines([]) == []


def test_unmatched_airlines_reports_carriers_the_sheet_lacks():
    """Only carriers absent from the *effective* list are reported. With no
    sheet the effective list is the seed, so a seeded carrier is known."""
    missing = ab.unmatched_airlines(
        ["Lufthansa", "Ryanair", "Brand New Air"], {})
    assert missing == ["Brand New Air"], missing
    # Once a sheet exists, it defines the whole list, so an unlisted seeded
    # carrier becomes "unmatched" — that is the point of showing it.
    flags = {ab.canonical_airline_key("Lufthansa"): True}
    missing = ab.unmatched_airlines(["Lufthansa", "Ryanair"], flags)
    assert missing == ["Ryanair"], missing


# ── reading the sheet ────────────────────────────────────────────────────────

def _workbook_with_sheet(rows, tmp: Path) -> Path:
    import openpyxl

    path = tmp / "wb.xlsx"
    workbook = openpyxl.Workbook()
    workbook.active.title = "Result sheet"
    workbook.active.append(["Destination", "Country"])
    workbook.active.append(["Naples", "Italy"])
    worksheet = workbook.create_sheet(ab.SHEET_NAME)
    worksheet.append(["Airline", ab.FLAG_HEADER, ab.NOTE_HEADER])
    for row in rows:
        worksheet.append(list(row))
    workbook.save(path)
    workbook.close()
    return path


def test_flags_are_read_from_the_workbook_sheet(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _workbook_with_sheet(
        [("Lufthansa", "x", "confirmed"), ("Ryanair", "", ""),
         ("Air France", "yes", ""), ("", "x", "")], tmp)
    with without_external_file():
        flags = ab.load_benefit_flags(path)
    assert flags[ab.canonical_airline_key("Lufthansa")] is True
    assert flags[ab.canonical_airline_key("Air France")] is True
    assert flags[ab.canonical_airline_key("Ryanair")] is False
    assert "" not in flags


def test_a_missing_sheet_yields_no_flags_and_no_error(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    import openpyxl

    path = tmp / "plain.xlsx"
    workbook = openpyxl.Workbook()
    workbook.active.title = "Result sheet"
    workbook.save(path)
    workbook.close()
    with without_external_file():
        assert ab.load_benefit_flags(path) == {}


def test_an_unreadable_or_missing_file_yields_no_flags(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    assert ab.load_benefit_flags(tmp / "does-not-exist.xlsx") == {}


def test_sheet_columns_are_found_case_insensitively(tmp_path=None):
    """A sheet named "CARRIER" with the flag column in lower case still works."""
    tmp = tmp_path or Path(tempfile.mkdtemp())
    import openpyxl

    path = tmp / "wb.xlsx"
    workbook = openpyxl.Workbook()
    first = workbook.active
    first.title = "Result sheet"
    first.append(["Destination", "Country"])
    first.append(["Naples", "Italy"])
    worksheet = workbook.create_sheet(ab.SHEET_NAME)
    worksheet.append(["CARRIER", "has benefits"])
    worksheet.append(["Lufthansa", "x"])
    workbook.save(path)
    workbook.close()
    with without_external_file():
        flags = ab.load_benefit_flags(path)
    assert flags == {"lufthansa": True}, flags


# ── writing the sheet ────────────────────────────────────────────────────────

def test_write_seed_sheet_creates_a_readable_sheet(tmp_path=None):
    """Starts from a workbook with no such sheet — the state the user is in."""
    tmp = tmp_path or Path(tempfile.mkdtemp())
    import openpyxl

    path = tmp / "wb.xlsx"
    workbook = openpyxl.Workbook()
    workbook.active.title = "Result sheet"
    workbook.active.append(["Destination", "Country"])
    workbook.active.append(["Naples", "Italy"])
    workbook.save(path)
    workbook.close()

    assert ab.load_benefit_flags(path) == {}
    written = ab.write_seed_sheet(path)
    assert written == len(ab.SEED_BENEFIT_AIRLINES)
    flags = ab.load_benefit_flags(path)
    assert len(flags) == written
    assert all(flags.values()), "every seeded row is ticked"
    # Running again must not duplicate or truncate the sheet.
    assert ab.write_seed_sheet(path) == 0
    assert len(ab.load_benefit_flags(path)) == written


def test_write_seed_sheet_never_raises_on_a_bad_path(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    assert ab.write_seed_sheet(tmp / "missing.xlsx") == 0


# ── the summary line ─────────────────────────────────────────────────────────

def test_summary_mentions_the_sheet_when_present(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _workbook_with_sheet([("Lufthansa", "x"), ("Ryanair", "")], tmp)
    flags = ab.load_benefit_flags(path)
    text = ab.benefit_summary(flags)
    assert "1 of 2" in text and ab.SHEET_NAME in text


def test_summary_explains_the_seed_fallback_when_there_is_no_sheet():
    text = ab.benefit_summary({})
    assert ab.SHEET_NAME in text and "built-in default" in text


# ── the external benefits file ───────────────────────────────────────────────

def _external_workbook(tmp: Path, rows, sheet: str = "Benefits",
                       header=None) -> Path:
    """A stand-in for airlines_benefits.xlsx with the same structure."""
    import openpyxl

    path = tmp / "airlines_benefits.xlsx"
    workbook = openpyxl.Workbook()
    worksheet = workbook.active
    worksheet.title = sheet
    worksheet.append(header if header else
                      ["iata", "name", "discount_eligible", "business_class",
                       "confirmed_booking", "comments"])
    for row in rows:
        worksheet.append(list(row))
    workbook.save(path)
    workbook.close()
    return path


def test_the_external_file_is_parsed_by_code_and_name(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _external_workbook(tmp, [
        ("LH", "Lufthansa", "Yes", "Yes", "Yes", None),
        ("FR", "Air France", "No", "No", "No", None),
        ("XX", "Some New Air", "Unknown", "Unknown", "Unknown", None),
    ])
    flags, problems = ab.parse_external_benefits(path)
    assert problems == []
    assert flags["LH"] is True
    assert flags["lufthansa"] is True
    assert flags["FR"] is False
    assert flags["XX"] is False, "Unknown must not count as a benefit"


def test_any_single_yes_qualifies(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _external_workbook(tmp, [
        ("AA", "Carrier A", "Yes", "Unknown", "Unknown", None),
        ("BB", "Carrier B", "Unknown", "Yes", "Unknown", None),
        ("CC", "Carrier C", "Unknown", "Unknown", "Yes", None),
        ("DD", "Carrier D", "Unknown", "Unknown", "Unknown", None),
    ])
    flags, _ = ab.parse_external_benefits(path)
    assert flags["AA"] and flags["BB"] and flags["CC"]
    assert not flags["DD"]


def test_the_benefit_columns_that_matched_are_reported(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _external_workbook(tmp, [
        ("LH", "Lufthansa", "Yes", "Yes", "No", None),
    ])
    rows, _ = ab.parse_external_rows(path)
    assert rows[0]["which"] == ["discount_eligible", "business_class"]
    assert rows[0]["benefits"] is True


def test_a_missing_column_is_reported_not_guessed(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _external_workbook(tmp, [("LH", "Lufthansa", "Yes")],
                              header=["iata", "name", "something_else"])
    rows, problems = ab.parse_external_rows(path)
    assert rows == []
    assert any("benefit column" in p for p in problems), problems


def test_an_unreadable_or_missing_external_file_is_handled(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    rows, problems = ab.parse_external_rows(tmp / "nope.xlsx")
    assert rows == [] and problems
    assert "does not exist" in problems[0]


def test_a_renamed_benefits_sheet_still_imports(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _external_workbook(tmp, [("LH", "Lufthansa", "Yes", "Yes", "Yes", None)],
                              sheet="Carriers")
    flags, problems = ab.parse_external_benefits(path)
    assert problems == []
    assert flags["LH"] is True


def test_a_duplicated_code_is_read_once(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    path = _external_workbook(tmp, [
        ("LH", "Lufthansa", "No", "No", "No", None),
        ("LH", "Lufthansa", "Yes", "Yes", "Yes", None),
    ])
    rows, _ = ab.parse_external_rows(path)
    assert len(rows) == 1
    assert rows[0]["benefits"] is False, "the first row wins; no silent merge"


def test_the_external_file_overrides_the_workbook_sheet(tmp_path=None):
    """Resolution order: external file first, then the workbook sheet."""
    tmp = tmp_path or Path(tempfile.mkdtemp())
    book = _workbook_with_sheet([("Lufthansa", "", ""), ("Ryanair", "x", "")], tmp)
    external = _external_workbook(tmp, [("LH", "Lufthansa", "Yes", "", "", None)])

    original = ab.external_file_path
    ab.external_file_path = lambda: external
    try:
        flags = ab.load_benefit_flags(book)
    finally:
        ab.external_file_path = original
    assert flags["LH"] is True
    # The workbook said Ryanair yes; the external file wins and says nothing.
    assert ab.has_benefits("Ryanair", flags) is False


def test_import_mirrors_the_file_into_the_workbook(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    book = _workbook_with_sheet([("Lufthansa", "x", "")], tmp)
    external = _external_workbook(tmp, [
        ("LH", "Lufthansa", "Yes", "Yes", "Yes", None),
        ("FR", "Air France", "Unknown", "Unknown", "Unknown", None),
    ])
    report = ab.import_benefits_file(external, workbook_path=book)
    assert report["read"] == 2
    assert report["qualified"] == 1
    assert report["qualified_list"] == ["LH Lufthansa"]
    assert report["problems"] == []
    assert report["written"] == 2

    import openpyxl

    workbook = openpyxl.load_workbook(book)
    try:
        worksheet = workbook[ab.SHEET_NAME]
        header = [c.value for c in worksheet[1]]
        assert header[:3] == ["IATA", "Airline", ab.FLAG_HEADER]
        data = [r for r in worksheet.iter_rows(min_row=2, values_only=True)]
    finally:
        workbook.close()
    assert len(data) == 2
    lh = next(r for r in data if r[0] == "LH")
    assert lh[1] == "Lufthansa" and lh[2] == "x"
    assert "discount_eligible" in lh[3]
    fr = next(r for r in data if r[0] == "FR")
    assert fr[2] in ("", None), "an Unknown airline must not be ticked"


def test_import_reports_rather_than_raises_when_the_file_is_missing(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    report = ab.import_benefits_file(tmp / "gone.xlsx")
    assert report["read"] == 0
    assert report["written"] == 0
    assert report["problems"]


def test_the_env_var_overrides_the_default_path():
    original = os.environ.get(ab.EXTERNAL_FILE_ENV)
    os.environ[ab.EXTERNAL_FILE_ENV] = r"D:\somewhere\benefits.xlsx"
    try:
        assert ab.external_file_path() == Path(r"D:\somewhere\benefits.xlsx")
    finally:
        if original is None:
            os.environ.pop(ab.EXTERNAL_FILE_ENV, None)
        else:
            os.environ[ab.EXTERNAL_FILE_ENV] = original


def test_a_cached_read_is_reused_but_invalidated_by_an_edit(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    external = _external_workbook(tmp, [("LH", "Lufthansa", "Yes", "", "", None)])
    ab._EXTERNAL_CACHE = None
    first, _ = ab.load_external_flags(external)
    second, _ = ab.load_external_flags(external)
    assert first is second, "the same unchanged file should be served from cache"

    from openpyxl import Workbook, load_workbook

    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = "Benefits"
    worksheet.append(["iata", "name", "discount_eligible", "business_class",
                      "confirmed_booking"])
    worksheet.append(["ZZ", "Brand New", "Yes", "", ""])
    workbook.save(external)
    workbook.close()
    third, _ = ab.load_external_flags(external)
    assert "ZZ" in third, "an edit in the other project must be picked up"


# ── IATA codes on flight boards ──────────────────────────────────────────────

def test_iata_codes_are_extracted_from_names_and_flight_numbers():
    assert ab.iata_code("LH") == "LH"
    assert ab.iata_code("lh") == "LH"
    assert ab.iata_code("LH 1000") == "LH"
    assert ab.iata_code("LH1000") == "LH"
    assert ab.iata_code("LH-1000") == "LH"
    assert ab.iata_code("Lufthansa") == ""
    assert ab.iata_code("") == ""
    assert ab.iata_code(None) == ""


def test_a_qualifying_carrier_is_found_by_code_or_by_name(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    external = _external_workbook(tmp, [
        ("LH", "Lufthansa", "Yes", "", "", None),
        ("CX", "Cathay Pacific", "Yes", "", "", None),
    ])
    flags, _ = ab.parse_external_benefits(external)
    assert ab.has_benefits("LH", flags) is True
    assert ab.has_benefits("LH1000", flags) is True
    assert ab.has_benefits("Lufthansa", flags) is True
    assert ab.has_benefits("CX", flags) is True
    assert ab.has_benefits("Cathay Pacific", flags) is True
    assert ab.has_benefits("FR", flags) is False


def test_a_known_but_unknown_carrier_is_not_reported_as_unmatched():
    """It is in the file, so it is known — just not qualified."""
    flags = {"FR": False, "airfrance": False}
    assert ab.unmatched_airlines(["Air France"], flags) == []
    assert ab.unmatched_airlines(["Who Knows Air"], flags) == ["Who Knows Air"]


def test_summary_counts_real_airlines_not_table_rows(tmp_path=None):
    tmp = tmp_path or Path(tempfile.mkdtemp())
    external = _external_workbook(tmp, [
        ("LH", "Lufthansa", "Yes", "", "", None),
        ("CX", "Cathay Pacific", "Yes", "", "", None),
        ("FR", "Air France", "Unknown", "", "", None),
    ])
    original = ab.external_file_path
    ab.external_file_path = lambda: external
    try:
        text = ab.benefit_summary(ab.parse_external_benefits(external)[0])
    finally:
        ab.external_file_path = original
    assert "2 of 3" in text
    assert "Unknown" in text


if __name__ == "__main__":
    tests = [
        test_normalisation_strips_punctuation_case_and_legal_forms,
        test_legal_suffixes_do_not_make_one_carrier_look_like_two,
        test_a_repeated_word_collapses,
        test_equivalent_spellings_share_a_key,
        test_different_carriers_keep_different_keys,
        test_blank_and_none_airlines_have_no_key,
        test_seed_list_resolves_every_name_to_itself,
        test_seed_list_has_no_duplicate_carriers,
        test_seed_names_are_qualified_by_default,
        test_low_cost_carriers_are_not_qualified_by_default,
        test_an_explicit_sheet_overrides_the_seed_list,
        test_an_explicit_no_outranks_the_seed_yes,
        test_truthy_spellings,
        test_a_substring_match_resolves_an_unfolded_spelling,
        test_an_ambiguous_substring_is_not_treated_as_qualified,
        test_agreeing_substring_matches_still_answer,
        test_filtered_airlines_keeps_order_and_drops_blanks,
        test_filtered_airlines_with_no_input_is_empty,
        test_unmatched_airlines_reports_carriers_the_sheet_lacks,
        test_flags_are_read_from_the_workbook_sheet,
        test_a_missing_sheet_yields_no_flags_and_no_error,
        test_an_unreadable_or_missing_file_yields_no_flags,
        test_sheet_columns_are_found_case_insensitively,
        test_write_seed_sheet_creates_a_readable_sheet,
        test_write_seed_sheet_never_raises_on_a_bad_path,
        test_summary_mentions_the_sheet_when_present,
        test_summary_explains_the_seed_fallback_when_there_is_no_sheet,
        test_the_external_file_is_parsed_by_code_and_name,
        test_any_single_yes_qualifies,
        test_the_benefit_columns_that_matched_are_reported,
        test_a_missing_column_is_reported_not_guessed,
        test_an_unreadable_or_missing_external_file_is_handled,
        test_a_renamed_benefits_sheet_still_imports,
        test_a_duplicated_code_is_read_once,
        test_the_external_file_overrides_the_workbook_sheet,
        test_import_mirrors_the_file_into_the_workbook,
        test_import_reports_rather_than_raises_when_the_file_is_missing,
        test_the_env_var_overrides_the_default_path,
        test_a_cached_read_is_reused_but_invalidated_by_an_edit,
        test_iata_codes_are_extracted_from_names_and_flight_numbers,
        test_a_qualifying_carrier_is_found_by_code_or_by_name,
        test_a_known_but_unknown_carrier_is_not_reported_as_unmatched,
        test_summary_counts_real_airlines_not_table_rows,
    ]
    for test in tests:
        with without_external_file():
            test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")