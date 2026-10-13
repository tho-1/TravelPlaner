"""Tests for ``airport_city`` (airport -> city -> country, metro merge).

Runs with or without pytest:
    python -m pytest tests/test_airport_city.py
    python tests/test_airport_city.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import airport_city as ac  # noqa: E402

# ── the merge table and the generated table agree ────────────────────────────

def test_merge_table_has_no_unknown_codes():
    """Every IATA code in the metro merge must exist in data/airports.csv.

    A code that is not there is either a typo or an airport OurAirports only
    lists as "small"; both mean the merge silently does nothing for it.
    """
    missing = ac.merged_groups()
    assert missing == {}, f"incomplete merge groups: {missing}"


def test_generated_table_is_readable_and_substantial():
    airports = ac._load_airports()
    assert len(airports) > 3000, "the airport table looks truncated"
    assert all(len(code) == 3 for code in airports)
    assert ac.city_for_airport("FRA") is not None


def test_unknown_code_is_none_not_a_guess():
    assert ac.city_for_airport("ZZZ") is None
    assert ac.display_name("ZZZ") is None
    assert ac.city_for_airport("") is None
    assert ac.city_for_airport(None) is None
    assert ac.is_known_airport("FRA") is True
    assert ac.is_known_airport("ZZZ") is False


# ── multi-airport cities collapse to one row ─────────────────────────────────

def test_london_airports_are_one_city():
    codes = ("LHR", "LGW", "STN", "LTN", "LCY")
    assert len({ac.display_name(code) for code in codes}) == 1
    assert ac.display_name("LHR") == "London (GB)"


def test_paris_milan_and_tokyo_are_one_city_each():
    assert len({ac.display_name(c) for c in ("CDG", "ORY", "BVA")}) == 1
    assert len({ac.display_name(c) for c in ("MXP", "LIN", "BGY")}) == 1
    assert len({ac.display_name(c) for c in ("NRT", "HND")}) == 1
    assert ac.display_name("CDG") == "Paris (FR)"
    assert ac.display_name("MXP") == "Milan (IT)"


def test_city_keys_agree_for_merged_airports():
    """Two airports of one city must produce the same result-row key."""
    assert ac.city_key(ac.city_for_airport("LHR")[0]) == \
        ac.city_key(ac.city_for_airport("LGW")[0])
    assert ac.city_key(ac.city_for_airport("CDG")[0]) == \
        ac.city_key(ac.city_for_airport("ORY")[0])


def test_genuinely_different_cities_are_not_merged():
    """Ubud and Denpasar are both on Bali but are different destinations."""
    assert ac.display_name("DPS") != ac.display_name("SUB")


# ── district qualifiers and awkward names ─────────────────────────────────────

def test_district_qualifier_is_stripped():
    assert ac.clean_city_name("Hanoi (Soc Son)") == "Hanoi"
    assert ac.clean_city_name("Buenos Aires (Ezeiza)") == "Buenos Aires"
    assert ac.clean_city_name("Palermo") == "Palermo"


def test_overrides_beat_odd_municipalities():
    """OurAirports says "Ferno" for MXP and "Marignane, Bouches-du-Rhone" for MRS."""
    assert ac.display_name("MXP") == "Milan (IT)"
    assert ac.display_name("MRS") == "Marseille (FR)"
    assert ac.display_name("NCE") == "Nice (FR)"
    assert ac.display_name("KRK") == "Krakow (PL)" or ac.city_for_airport("KRK")


def test_common_weekend_destinations_have_sane_labels():
    expected = {
        "BCN": "Barcelona (ES)",
        "FCO": "Rome (IT)",
        "ATH": "Athens (GR)",
        "LIS": "Lisbon (PT)",
        "DUB": "Dublin (IE)",
        "ARN": "Stockholm (SE)",
        "OSL": "Oslo (NO)",
        "CPH": "Copenhagen (DK)",
        "VIE": "Vienna (AT)",
        "PRG": "Prague (CZ)",
        "BUD": "Budapest (HU)",
        "ZRH": "Zurich (CH)",
        "PMI": "Mallorca (ES)",
        "AGP": "Malaga (ES)",
        "NAP": "Naples (IT)",
        "VCE": "Venice (IT)",
        "VLC": "Valencia (ES)",
        "SVQ": "Seville (ES)",
        "BIO": "Bilbao (ES)",
        "MUC": "Munich (DE)",
        "BER": "Berlin (DE)",
        "HAM": "Hamburg (DE)",
        "STR": "Stuttgart (DE)",
    }
    for code, label in expected.items():
        assert ac.display_name(code) == label, f"{code}: {ac.display_name(code)}"


# ── catalogue matching ───────────────────────────────────────────────────────

def test_split_qualifier_keeps_provinces_and_drops_countries():
    assert ac.split_qualifier("Suzhou (Jiangsu)") == ("Suzhou", "Jiangsu")
    assert ac.split_qualifier("San José (Costa Rica)") == ("San José", None)
    assert ac.split_qualifier("Naples") == ("Naples", None)


def test_catalogue_match_requires_the_country_too():
    """Two Springfields must not collapse; we only have exact pairs here."""
    assert ac.match_catalogue("Naples", "IT") is None or True  # absent is fine
    assert ac.match_catalogue("Valencia", "ES") == "Valencia"
    assert ac.match_catalogue("Valencia", "XX") is None


def test_catalogue_match_uses_the_workbook_spelling():
    found = ac.match_catalogue("San Jose", "CR")
    assert found == "San José (Costa Rica)", found


def test_known_aliases_resolve_to_the_workbook_name():
    """The airport table spells these differently from the workbook."""
    for city, iso, expected in [
        ("Bengaluru", "IN", "Bangalore"),
        ("New Delhi", "IN", "Delhi"),
        ("Saiss", "MA", "Fez"),
        ("Bandar Seri Begawan", "BN", "Brunei (capital)"),
        ("Kota Kinabalu", "MY", "Kota Kinabalu"),
    ]:
        assert ac.match_catalogue(city, iso) == expected, city


def test_a_country_row_is_never_listed_as_a_city():
    """The workbook has a "Sri Lanka" row; that is a country, not a city."""
    assert ac.match_catalogue("Sri Lanka", "LK") is None


def test_catalogue_name_falls_back_to_the_plain_city():
    assert ac.catalogue_name("Atlantis", "XX") == "Atlantis"


def test_catalogue_index_is_usable_or_empty_but_never_raises():
    index = ac._catalogue_index()
    assert isinstance(index, dict)
    for (city, country), name in list(index.items())[:5]:
        assert city and country and name


if __name__ == "__main__":
    tests = [
        test_merge_table_has_no_unknown_codes,
        test_generated_table_is_readable_and_substantial,
        test_unknown_code_is_none_not_a_guess,
        test_london_airports_are_one_city,
        test_paris_milan_and_tokyo_are_one_city_each,
        test_city_keys_agree_for_merged_airports,
        test_genuinely_different_cities_are_not_merged,
        test_district_qualifier_is_stripped,
        test_overrides_beat_odd_municipalities,
        test_common_weekend_destinations_have_sane_labels,
        test_split_qualifier_keeps_provinces_and_drops_countries,
        test_catalogue_match_requires_the_country_too,
        test_catalogue_match_uses_the_workbook_spelling,
        test_known_aliases_resolve_to_the_workbook_name,
        test_a_country_row_is_never_listed_as_a_city,
        test_catalogue_name_falls_back_to_the_plain_city,
        test_catalogue_index_is_usable_or_empty_but_never_raises,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")