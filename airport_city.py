"""Airport -> city -> country lookup with multi-airport cities merged.

The weekend finder must show one row per *city*, so London's five airports
(LHR, LGW, STN, LTN, LCY) and Paris' three (CDG, ORY, BVA) have to collapse
into one entry. Two mechanisms do that:

1. **This file's explicit merge table.** Every real metro area with more than
   one airport is listed once, with the city label to show and the country.
   IATA codes are matched case-insensitively against ``data/airports.csv``;
   an unknown code is ignored (so a code that never reaches Frankfurt costs
   nothing) but is reported by ``merged_groups()`` so the table stays honest.

2. **Everything else falls through** to its own ``municipality`` from the
   airport table, which is already the city for the overwhelming majority.

The table is data, not logic, so it is easy to extend when a new metro shows
up — add the code under its existing city and the row keeps working.
"""

from __future__ import annotations

import csv
import functools
import re
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent
AIRPORTS_CSV = ROOT / "data" / "airports.csv"

#: ``city label -> (country code, IATA codes)``. Codes not present in the
#: airport table are skipped silently; ``merged_groups()`` surfaces them.
METRO_GROUPS: dict[str, tuple[str, tuple[str, ...]]] = {
    "London": ("GB", ("LHR", "LGW", "STN", "LTN", "LCY", "SEN")),
    "Paris": ("FR", ("CDG", "ORY", "BVA")),
    "Milan": ("IT", ("MXP", "LIN", "BGY")),
    "New York": ("US", ("JFK", "EWR", "LGA")),
    "Washington": ("US", ("IAD", "DCA")),
    "Tokyo": ("JP", ("NRT", "HND")),
    "Osaka": ("JP", ("KIX", "ITM")),
    "Moscow": ("RU", ("SVO", "DME", "VKO")),
    "Rome": ("IT", ("FCO", "CIA")),
    "Milan (Bergamo)": ("IT", ("BGY",)),          # placeholder, merged below
    "Stockholm": ("SE", ("ARN", "BMA", "NYO")),
    "Copenhagen": ("DK", ("CPH",)),
    "Basel": ("CH", ("BSL",)),
    "Zurich": ("CH", ("ZRH",)),
    "Düsseldorf": ("DE", ("DUS",)),
    "Stuttgart": ("DE", ("STR",)),
    "Bologna": ("IT", ("BLQ",)),
    "Washington (Baltimore)": ("US", ("BWI",)),
    "Bangkok": ("TH", ("BKK", "DMK")),
    "Seoul": ("KR", ("ICN", "GMP")),
    "Taipei": ("TW", ("TPE", "TSA")),
    "Guangzhou": ("CN", ("CAN", "SZX")),
    "Shanghai": ("CN", ("PVG", "SHA")),
    "Chengdu": ("CN", ("TFU", "CTU")),
    "Nanjing": ("CN", ("NKG",)),
    "Hangzhou": ("CN", ("HGH",)),
    "Xiamen": ("CN", ("XMN",)),
    "Guangxi": ("CN", ("KWL",)),
    "Buenos Aires": ("AR", ("EZE", "AEP")),
    "Rio de Janeiro": ("BR", ("GIG", "SDU")),
    "Sao Paulo": ("BR", ("GRU", "VCP", "CGH")),
    "Jakarta": ("ID", ("CGK", "HLP")),
    "Kuala Lumpur": ("MY", ("KUL",)),
    "Johannesburg": ("ZA", ("JNB",)),
    "Brussels": ("BE", ("BRU", "CRL")),
    "Lisbon": ("PT", ("LIS", "OUE")),
    "Porto": ("PT", ("OPO",)),
    "Milan (Malpensa)": ("IT", ("MXP",)),
    "Naples": ("IT", ("NAP",)),
    "Venice": ("IT", ("VCE",)),
    "Palermo": ("IT", ("PMO",)),
    "Valencia": ("ES", ("VLC",)),
    "Seville": ("ES", ("SVQ",)),
    "Bilbao": ("ES", ("BIO",)),
    "Malaga": ("ES", ("AGP",)),
    "Athens": ("GR", ("ATH",)),
    "Thessaloniki": ("GR", ("SKG",)),
    "Porto Santo": ("PT", ("FNC",)),
    "Gothenburg": ("SE", ("GOT",)),
    "Aarhus": ("DK", ("AAR",)),
    "Bergen": ("NO", ("BGO",)),
    "Malmo": ("SE", ("MMX",)),
    "Vienna": ("AT", ("VIE",)),
    "Geneva": ("CH", ("GVA",)),
    "Lyon": ("FR", ("LYS",)),
    "Nice": ("FR", ("NCE",)),
    "Toulouse": ("FR", ("TLS",)),
    "Bordeaux": ("FR", ("BOD",)),
    "Marseille": ("FR", ("MRS",)),
    "Nantes": ("FR", ("NTE",)),
    "Manchester": ("GB", ("MAN",)),
    "Birmingham": ("GB", ("BHX",)),
    "Edinburgh": ("GB", ("EDI",)),
    "Glasgow": ("GB", ("GLA",)),
    "Belfast": ("GB", ("BFS",)),
    "Dublin": ("IE", ("DUB",)),
    "Cork": ("IE", ("ORK",)),
    "Newcastle": ("GB", ("NCL",)),
    "Bristol": ("GB", ("BRS",)),
    "Bengaluru": ("IN", ("BLR",)),
    "Cebu City": ("PH", ("CEB",)),
    "New Delhi": ("IN", ("DEL",)),
    "Kota Kinabalu": ("MY", ("BKI",)),
    "Kochi": ("IN", ("COK",)),
    "Saiss": ("MA", ("FEZ",)),
    "Khabarovsk": ("RU", ("KHV",)),
    "Luang Phabang": ("LA", ("LPQ",)),
    "Medellin": ("CO", ("MDE",)),
    "Nha Trang": ("VN", ("CXR",)),
    "Phu Quoc": ("VN", ("PQC",)),
    "Bandar Seri Begawan": ("BN", ("BWN",)),
    "Mandalay": ("MM", ("MDL",)),
    "Can Tho": ("VN", ("VCA",)),
    "Khiva": ("UZ", ("HVA",)),
    "Kaohsiung": ("TW", ("KHH",)),
    "Surabaya": ("ID", ("SUB",)),
    "Oaxaca": ("MX", ("OAX",)),
    "Colombo": ("LK", ("CMB",)),
}

#: Codes that must not appear twice: BGY/MXP are Milan, and a second label for
#: the same city would make one airport show up under two different rows.
_ALIAS_TO_CANONICAL = {
    "Milan (Malpensa)": "Milan",
    "Milan (Bergamo)": "Milan",
    "Washington (Baltimore)": "Washington",
}

#: ``IATA -> (city label, country)`` for airports whose OurAirports
#: ``municipality`` is the *district* the airport sits in rather than the city
#: a traveller would say: Milan is "Ferno", Marseille is "Marignane, Bouches-
#: du-Rhone", Nice is "Nice, Alpes-Maritimes". Left to the generic path they
#: produce rows nobody would recognise. The entries that are genuinely *different
#: cities* even though they share a name (Ubud/Denpasar -> Bali, Fez/Saiss,
#: Khiva in Uzbekistan, Montenegro/Medellin) are deliberately absent: the city
#: is what the result list should show, and a metro group would hide a real
#: second destination.
CITY_OVERRIDES: dict[str, tuple[str, str]] = {
    "ADB": ("Izmir", "TR"),
    "AGP": ("Malaga", "ES"),
    "AHO": ("Alghero", "IT"),
    "ARN": ("Stockholm", "SE"),
    "ATH": ("Athens", "GR"),
    "BCN": ("Barcelona", "ES"),
    "BFS": ("Belfast", "GB"),
    "BGO": ("Bergen", "NO"),
    "BGY": ("Milan", "IT"),
    "BMA": ("Stockholm", "SE"),
    "BLQ": ("Bologna", "IT"),
    "BOD": ("Bordeaux", "FR"),
    "BOM": ("Mumbai", "IN"),
    "BRS": ("Bristol", "GB"),
    "BSL": ("Basel", "CH"),
    "BRU": ("Brussels", "BE"),
    "BUD": ("Budapest", "HU"),
    "CDG": ("Paris", "FR"),
    "CIA": ("Rome", "IT"),
    "DME": ("Moscow", "RU"),
    "DPS": ("Bali (Denpasar)", "ID"),
    "DUS": ("Dusseldorf", "DE"),
    "EDI": ("Edinburgh", "GB"),
    "FCO": ("Rome", "IT"),
    "FLR": ("Florence", "IT"),
    "FNC": ("Funchal", "PT"),
    "GLA": ("Glasgow", "GB"),
    "GOA": ("Genoa", "IT"),
    "GOT": ("Goteborg", "SE"),
    "GRZ": ("Graz", "AT"),
    "GVA": ("Geneva", "CH"),
    "HEL": ("Helsinki", "FI"),
    "KLU": ("Krakow", "PL"),
    "KRK": ("Krakow", "PL"),
    "LHR": ("London", "GB"),
    "LIN": ("Milan", "IT"),
    "LIS": ("Lisbon", "PT"),
    "LYS": ("Lyon", "FR"),
    "MAN": ("Manchester", "GB"),
    "MCT": ("Muscat", "OM"),
    "MRS": ("Marseille", "FR"),
    "MUC": ("Munich", "DE"),
    "MXP": ("Milan", "IT"),
    "NAP": ("Naples", "IT"),
    "NCE": ("Nice", "FR"),
    "NCL": ("Newcastle", "GB"),
    "NTE": ("Nantes", "FR"),
    "OPO": ("Porto", "PT"),
    "ORY": ("Paris", "FR"),
    "OSL": ("Oslo", "NO"),
    "PMI": ("Mallorca", "ES"),
    "PMO": ("Palermo", "IT"),
    "PRG": ("Prague", "CZ"),
    "SKG": ("Thessaloniki", "GR"),
    "STL": ("St Louis", "US"),
    "STR": ("Stuttgart", "DE"),
    "SVQ": ("Seville", "ES"),
    "SVO": ("Moscow", "RU"),
    "TLS": ("Toulouse", "FR"),
    "VCE": ("Venice", "IT"),
    "VIE": ("Vienna", "AT"),
    "VKO": ("Moscow", "RU"),
    "VLC": ("Valencia", "ES"),
    "ZRH": ("Zurich", "CH"),
}


#: Codes whose OurAirports municipality is a district inside a *different*
#: city. None of these is a weekend destination from Frankfurt, but leaving
#: them unmapped would report "Bury Saint Edmunds, Suffolk" as a city, so each
#: one is either named correctly or dropped.
EXTRA_OVERRIDES: dict[str, tuple[str, str]] = {
    "LBA": ("Leeds", "GB"),
    "NHT": ("London", "GB"),
    "PIK": ("Glasgow", "GB"),
    "SPC": ("La Palma", "ES"),
    "LDY": ("Derry", "GB"),
}


def normalize_key(value: object) -> str:
    """Lowercase alphanumeric key used for city-name matching."""
    if value is None:
        return ""
    text = unicodedata.normalize("NFKD", str(value))
    text = text.encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "", text.lower())


@functools.lru_cache(maxsize=1)
def _load_airports() -> dict[str, tuple[str, str, str]]:
    """``IATA -> (city, country, name)`` from the generated table."""
    table: dict[str, tuple[str, str, str]] = {}
    try:
        with AIRPORTS_CSV.open(encoding="utf-8", newline="") as fh:
            for row in csv.DictReader(fh):
                code = (row.get("iata") or "").strip().upper()
                if not code:
                    continue
                table[code] = (
                    (row.get("city") or "").strip(),
                    (row.get("country") or "").strip().upper(),
                    (row.get("name") or "").strip(),
                )
    except OSError:
        return table
    return table


@functools.lru_cache(maxsize=1)
def _code_to_city() -> dict[str, tuple[str, str]]:
    """``IATA -> (city label, country)`` with the metro merge applied."""
    airports = _load_airports()
    code_to_city: dict[str, tuple[str, str]] = dict(CITY_OVERRIDES)
    code_to_city.update(EXTRA_OVERRIDES)
    for label, (country, codes) in METRO_GROUPS.items():
        canonical = _ALIAS_TO_CANONICAL.get(label, label)
        for code in codes:
            code_to_city[code] = (canonical, country)
    for code, (city, country, _name) in airports.items():
        if code in code_to_city:
            continue
        cleaned = clean_city_name(city)
        if "," in city and cleaned.count(" ") >= 2:
            # "Marignane, Bouches-du-Rhone" / "Mataram (Pujut, Lombok Tengah)"
            # is a province/district, not a city name anybody would search for.
            # Dropping the code is safer than inventing one: an unknown airport
            # is reported as unmapped, whereas a wrong label silently merges two
            # cities. A single-word suffix ("Napoli Capodichino") is kept.
            continue
        code_to_city[code] = (cleaned or city, country)
    return code_to_city


def city_for_airport(code: object) -> tuple[str, str] | None:
    """``(city, country_code)`` for an IATA code, or ``None`` when unknown."""
    if not code:
        return None
    key = str(code).strip().upper()
    found = _code_to_city().get(key)
    if not found or not found[0]:
        return None
    return found


def display_name(code: object) -> str | None:
    """``"City (Country)"`` for an IATA code, ready for the result list."""
    found = city_for_airport(code)
    if not found:
        return None
    city, country = found
    return f"{city} ({country})"


def merged_groups() -> dict[str, list[str]]:
    """``city label -> IATA codes not present in the airport table``.

    Used by the tests as a data-quality report: an empty result means the
    merge table and the generated airport table agree.
    """
    airports = _load_airports()
    missing: dict[str, list[str]] = {}
    for label, (_country, codes) in METRO_GROUPS.items():
        absent = [code for code in codes if code not in airports]
        if absent:
            missing[label] = absent
    return missing


def city_key(city: object) -> str:
    """Stable key for de-duplicating cities in the result list."""
    return normalize_key(city)


def is_known_airport(code: object) -> bool:
    return city_for_airport(code) is not None


def clean_city_name(raw: object) -> str:
    """Strip a district/qualifier suffix from an airport's municipality.

    OurAirports records the administrative district for many airports —
    ``"Hanoi (Soc Son)"``, ``"Buenos Aires (Ezeiza)"``, ``"Kota Kinabalu
    (KK)"`` — and a result row reading ``Hanoi (Soc Son) (VN)`` is worse than
    useless. The same shape appears in the workbook, so both go through here.
    """
    text = str(raw or "").strip()
    match = re.match(r"^(?P<city>[^(]+?)\s*\([^()]+\)\s*$", text)
    return match.group("city").strip() if match else text


# ── catalogue matching ────────────────────────────────────────────────────────
# The workbook writes 37 of its 144 destinations in the form
# "Name (Qualifier)" — mostly Chinese cities ("Chongqing (Chongqing)"), but
# also cities that genuinely repeat across provinces. Two Suzhou rows must not
# collapse into each other, so the qualifier is *stripped for matching* but
# *kept when the result is shown*, and the country decides which one wins.

#: ISO 3166-1 alpha-2 -> English country name. Small and stable; used so the
#: match can require city *and* country to agree.
COUNTRY_NAMES: dict[str, str] = {
    "AE": "United Arab Emirates", "AL": "Albania", "AM": "Armenia",
    "AR": "Argentina", "AT": "Austria", "AU": "Australia", "AZ": "Azerbaijan",
    "BA": "Bosnia and Herzegovina", "BD": "Bangladesh", "BE": "Belgium",
    "BG": "Bulgaria", "BH": "Bahrain", "BR": "Brazil", "BY": "Belarus",
    "CA": "Canada", "CH": "Switzerland", "CL": "Chile", "CN": "China",
    "CO": "Colombia", "CR": "Costa Rica", "CY": "Cyprus", "CZ": "Czechia",
    "DE": "Germany", "DK": "Denmark", "DO": "Dominican Republic",
    "DZ": "Algeria", "EC": "Ecuador", "EE": "Estonia", "EG": "Egypt",
    "ES": "Spain", "FI": "Finland", "FR": "France", "GB": "United Kingdom",
    "GE": "Georgia", "GR": "Greece", "HR": "Croatia", "HU": "Hungary",
    "ID": "Indonesia", "IE": "Ireland", "IL": "Israel", "IN": "India",
    "IQ": "Iraq", "IR": "Iran", "IS": "Iceland", "IT": "Italy",
    "JO": "Jordan", "JP": "Japan", "KE": "Kenya", "KG": "Kyrgyzstan",
    "KH": "Cambodia", "KR": "South Korea", "KW": "Kuwait",
    "LA": "Laos", "LB": "Lebanon", "LK": "Sri Lanka", "LT": "Lithuania",
    "LU": "Luxembourg", "LV": "Latvia", "MA": "Morocco", "MD": "Moldova",
    "ME": "Montenegro", "MK": "North Macedonia", "MM": "Myanmar",
    "MN": "Mongolia", "MO": "Macau", "MT": "Malta", "MU": "Mauritius",
    "MV": "Maldives", "MX": "Mexico", "MY": "Malaysia", "MZ": "Mozambique",
    "NA": "Namibia", "NE": "Niger", "NG": "Nigeria", "NL": "Netherlands",
    "NO": "Norway", "NP": "Nepal", "NZ": "New Zealand", "OM": "Oman",
    "PA": "Panama", "PE": "Peru", "PH": "Philippines", "PK": "Pakistan",
    "PL": "Poland", "PR": "Puerto Rico", "PT": "Portugal", "PY": "Paraguay",
    "QA": "Qatar", "RO": "Romania", "RS": "Serbia", "RU": "Russia",
    "SA": "Saudi Arabia", "SE": "Sweden", "SG": "Singapore", "SI": "Slovenia",
    "SK": "Slovakia", "SN": "Senegal", "TH": "Thailand", "TN": "Tunisia",
    "TR": "Turkey", "TW": "Taiwan", "TZ": "Tanzania", "UA": "Ukraine",
    "US": "United States", "UY": "Uruguay", "UZ": "Uzbekistan",
    "VN": "Vietnam", "ZA": "South Africa",
}
COUNTRY_NAMES["BO"] = "Bolivia"
COUNTRY_NAMES["BN"] = "Brunei"
COUNTRY_NAMES["CG"] = "Congo"
COUNTRY_NAMES["NI"] = "Nicaragua"
COUNTRY_NAMES["PG"] = "Papua New Guinea"
COUNTRY_NAMES["TZ"] = "Tanzania"
COUNTRY_NAMES["XK"] = "Kosovo"


def split_qualifier(destination: object) -> tuple[str, str | None]:
    """``"Chongqing (Chongqing)" -> ("Chongqing", "Chongqing")``.

    A qualifier is only treated as one when it is not itself a country name,
    so ``"San Jose (Costa Rica)"`` yields the bare city ``San Jose`` (which is
    how airports spell it) while ``"Suzhou (Jiangsu)"`` keeps its province.
    """
    text = str(destination or "").strip()
    match = re.match(r"^(?P<city>[^(]+?)\s*\((?P<qual>[^()]+)\)\s*$", text)
    if not match:
        return text, None
    city = match.group("city").strip()
    qualifier = match.group("qual").strip()
    if normalize_key(qualifier) in {normalize_key(v) for v in COUNTRY_NAMES.values()}:
        return city, None
    return city, qualifier


@functools.lru_cache(maxsize=1)
def _catalogue_index() -> dict[tuple[str, str], str]:
    """``(normalized city, normalized country) -> workbook destination name``.

    Built from the live workbook. A missing or unreadable workbook yields an
    empty index: the finder still lists every served city, just without the
    links to the destination pages.
    """
    try:
        import openpyxl

        from data_utils import DATA_PATH, _find_destination_sheet

        workbook = openpyxl.load_workbook(DATA_PATH, read_only=True, data_only=True)
        try:
            sheet = _find_destination_sheet(DATA_PATH)
            worksheet = workbook[sheet] if sheet else workbook.active
            header = [c.value for c in next(worksheet.iter_rows(min_row=1, max_row=1))]
            try:
                name_at = header.index("Destination")
                country_at = header.index("Country")
            except ValueError:
                return {}
            index: dict[tuple[str, str], str] = {}
            for row in worksheet.iter_rows(min_row=2, values_only=True):
                name = row[name_at] if name_at < len(row) else None
                if not name:
                    continue
                country = row[country_at] if country_at < len(row) else ""
                city, _qualifier = split_qualifier(name)
                index.setdefault(
                    (normalize_key(city), normalize_key(country)), str(name).strip()
                )
            return index
        finally:
            workbook.close()
    except Exception:
        return {}


#: Workbook destinations whose city name differs from the airport's. Keyed by
#: ``(airport city label, ISO country code)`` so the match resolves without
#: guessing. The code form is used deliberately: it is what the airport table
#: carries, and an English country name would be a second spelling to keep in
#: sync.
CATALOGUE_ALIASES: dict[tuple[str, str], str] = {
    ("Bengaluru", "IN"): "Bangalore",
    ("Cebu City", "PH"): "Cebu City",
    ("New Delhi", "IN"): "Delhi",
    ("Saiss", "MA"): "Fez",
    ("Bandar Seri Begawan", "BN"): "Brunei (capital)",
    ("Kaohsiung", "TW"): "Tainan",
    ("Denpasar", "ID"): "Denpasar",
    ("Saigon", "VN"): "Saigon",
    ("Phu Quoc", "VN"): "Phu Quoc",
    ("Montevideo", "UY"): "Montevideo",
    ("Kota Kinabalu", "MY"): "Kota Kinabalu",
}

#: The workbook's "Sri Lanka" row is a country, not a city. Resolving an
#: airport to it would list "Sri Lanka (LK)" as if it were a city, so the
#: match is refused rather than returning a non-city. The second element is the
#: ISO code, compared case-insensitively, because the airport table may spell
#: the country differently.
NOT_A_CITY: set[tuple[str, str]] = {("Sri Lanka", "LK")}


def match_catalogue(city: object, country_code: object) -> str | None:
    """The workbook's name for this city/country, or ``None`` when absent."""
    country = COUNTRY_NAMES.get(str(country_code or "").strip().upper(), "")
    if not country:
        return None
    raw_city = clean_city_name(city)
    iso = str(country_code or "").strip().upper()
    if any(raw_city == name and iso == code for name, code in NOT_A_CITY):
        # A catalogue row that names a country, not a city: linking it would put
        # "Sri Lanka (LK)" in a list of cities.
        return None
    alias = CATALOGUE_ALIASES.get((raw_city, iso))
    if alias:
        return alias
    key = (normalize_key(raw_city), normalize_key(country))
    found = _catalogue_index().get(key)
    if found:
        return found
    # Fall back to matching on the city alone, but only when the country's
    # English name and the workbook's country agree case-insensitively.
    for (norm_city, norm_country), name in _catalogue_index().items():
        if norm_city == key[0] and norm_country == normalize_key(country):
            return name
    return None


def catalogue_name(city: object, country_code: object) -> str:
    """Display name for a result row: the workbook's spelling when we have it."""
    return match_catalogue(city, country_code) or clean_city_name(city)


if __name__ == "__main__":  # pragma: no cover - manual inspection helper
    for probe in ("LHR", "LGW", "CDG", "MXP", "FRA", "ZZZ"):
        print(probe, "->", display_name(probe))
    print("incomplete merge groups:", merged_groups() or "none")