"""Which airlines count as "with benefits" for the weekend finder.

The rule the user gave: an airline qualifies when it offers **at least one**
staff benefit — confirmed travel, standby, business-cabin standby and so on.
What qualifies is a judgement call per airline, so it is stored as data, not
code: a single flag per airline in the workbook's ``Airline Benefits`` sheet.

    Airline                 | Has Benefits | Benefit note
    Lufthansa               | x            | confirmed + standby business
    Eurowings               |              |
    ...

Why a sheet rather than a constant: the list is personal (which programs the
user actually holds), it changes, and it must be editable without touching code.
Why not the existing ``Airlines`` sheet: that one is appended to by the
flight-routes code (every airline ever seen, ~300 rows, plus a colour) and is
written programmatically. Mixing a hand-maintained flag into it would let the
next ``sync_airlines_to_excel`` overwrite a decision.

Unknown airlines default to **not** qualifying, so a new carrier never silently
widens the result list. The UI states how many airlines are flagged, because an
unticked airline is indistinguishable from a forgotten one.
"""

from __future__ import annotations

import os
import re
import unicodedata
from pathlib import Path

SHEET_NAME = "Airline Benefits"
FLAG_HEADER = "Has Benefits"
NOTE_HEADER = "Benefit note"
SOURCE_HEADER = "Set By"

#: Used when the sheet does not exist yet, so the feature works before the user
#: has filled anything in. A starting point, NOT a claim about benefits: the
#: user corrects it by unticking.
#: One row per *carrier*. "Lufthansa CityLine" is deliberately absent: it
#: canonicalises to "lufthansa", so listing both would make the sheet's 26 rows
#: resolve to 25 keys and quietly drop one on read.
SEED_BENEFIT_AIRLINES: tuple[str, ...] = (
    "Lufthansa",
    "Eurowings",
    "SWISS",
    "Austrian",
    "Brussels Airlines",
    "Air France",
    "KLM",
    "ITA Airways",
    "SAS",
    "TAP Air Portugal",
    "Iberia",
    "British Airways",
    "Aer Lingus",
    "United Airlines",
    "Air Canada",
    "ANA",
    "Singapore Airlines",
    "Qatar Airways",
    "Emirates",
    "Turkish Airlines",
    "LOT Polish Airlines",
    "Aegean Airlines",
    "Air Europa",
    "Finnair",
)

#: Words that never identify a carrier: legal forms and filler. Dropping them
#: makes "British Airways plc" and "British Airways" reach the same key, and
#: "Swiss International Air Lines" reach the key "swiss". "Air" is deliberately
#: NOT dropped: it is part of real names ("Air France", "Air Canada").
_LEGAL_SUFFIXES = frozenset({
    "airlines", "airline", "airways", "lines", "airlinegroup", "airport",
    "transport", "ag", "kg", "mbh", "sa", "nv", "bv", "sarl", "aps",
    "group", "inc", "incorporated", "ltd", "limited", "plc", "llc", "llp",
    "corporation", "corp", "company", "co", "holdings", "holding",
    "worldwide", "global", "international", "intl", "national",
})


def normalize_airline(value: object) -> str:
    """Lowercase alphanumeric key used to match airline names across sources.

    Scraped feeds write "Deutsche Lufthansa AG", "British Airways plc" or
    "TAP Air Portugal" where the sheet has "Lufthansa" or "TAP". Punctuation and
    legal-form words go, a repeated word collapses ("SWISS Swiss" -> "swiss"),
    and the remaining words keep their order.

    Anything that still differs is handled by ``NAME_EQUIVALENTS`` rather than
    by dropping more words here: an earlier version stripped "optional" country
    words, which destroyed real names ("All Nippon" lost its Nippon, "Swiss
    Swiss" collapsed to nothing). An explicit table is boring and correct.
    """
    if value is None:
        return ""
    text = unicodedata.normalize("NFKD", str(value))
    text = text.encode("ascii", "ignore").decode("ascii")
    # Dotted legal forms first: "S.A." would otherwise split into "s" and "a"
    # and then look like two real words.
    text = re.sub(r"\b(?:s\.?a\.?|n\.?v\.?|b\.?v\.?|a\.?g\.?|g\.?b\.?r\.?|"
                  r"a\.?s\.?|s\.?a\.?r\.?l\.?|k\.?g\.?|l\.?t\.?d\.?|"
                  r"p\.?l\.?c\.?|l\.?l\.?c\.?)\b", " ", text, flags=re.IGNORECASE)
    words = [w.lower() for w in re.split(r"[^A-Za-z0-9]+", text) if w]
    kept: list[str] = []
    for word in words:
        if word in _LEGAL_SUFFIXES or word in kept:
            continue
        kept.append(word)
    return "".join(kept) or "".join(words)


#: Normalised keys that name a carrier the table does not spell identically.
#: Both sides are already normalised, so these entries are literal.
NAME_EQUIVALENTS: dict[str, str] = {
    "deutschelufthansa": "lufthansa",
    "lufthansacityline": "lufthansa",
    "lufthansaregional": "lufthansa",
    "lufthansagroup": "lufthansa",
    "cityline": "lufthansa",
    "eurowingseurope": "eurowings",
    "brussels": "brussels",
    "klmroyaldutch": "klm",
    "allnippon": "ana",
    "vivaaerobus": "viva",
    "wizzair": "wizz",
    "tapairportugal": "tap",
    "tapportugal": "tap",
    "taiportugal": "tap",
    "sasscandinavian": "sas",
    "lotpolish": "lot",
    "aegean": "aegean",
    "turkish": "turkish",
    "qatarairways": "qatar",
    "austrian": "austrian",
    "swissair": "swiss",
    "swissairlines": "swiss",
    "aireuropa": "aireuropa",
}


def canonical_airline_key(value: object) -> str:
    """Normalised key, folded through the equivalence table."""
    raw = normalize_airline(value)
    if not raw:
        return ""
    return NAME_EQUIVALENTS.get(raw, raw)


def _sheet_columns(worksheet) -> dict[str, int]:
    columns: dict[str, int] = {}
    for cell in worksheet[1]:
        if cell.value is not None:
            columns[str(cell.value).strip().lower()] = cell.column
    return columns


def _truthy(value: object) -> bool:
    """A ticked cell: 'x', 'yes', True, 1. Empty or unknown is False."""
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value == 1
    return str(value).strip().lower() in {"x", "yes", "y", "true", "1", "ja"}


# ── the external source of truth ─────────────────────────────────────────────
#
# The user maintains `airlines_benefits.xlsx` in another project (the flights
# route app). It is keyed by **IATA airline code** and carries three separate
# Yes/No/Unknown columns, not one flag. `import_benefits_file` reads it and
# folds it into the same shape the workbook sheet uses, so the rest of the app
# does not care where the answers came from.

#: Column names understood in the external file, lowercased.
EXTERNAL_CODE_COLUMNS = ("iata", "iata_code", "code", "airline_code")
EXTERNAL_NAME_COLUMNS = ("name", "airline", "airline_name", "carrier")
#: The benefit columns we read. Any "Yes" in any of them counts as benefits,
#: because the user's rule is "at least one of them".
EXTERNAL_BENEFIT_COLUMNS = ("discount_eligible", "business_class",
                            "confirmed_booking")

#: Where the user's file lives by default. Overridable via the env var so the
#: path is never hard-coded into behaviour, only into a default.
EXTERNAL_FILE_ENV = "TRAVEL_PLANNER_AIRLINE_BENEFITS"
DEFAULT_EXTERNAL_FILE = Path(
    r"C:\Users\Thors\OneDrive\Documents\VS Code - Flights"
    r"\flightroutes-app\data\airlines_benefits.xlsx"
)


def external_file_path() -> Path:
    """Resolve the external benefits file: env var first, then the default."""
    override = os.environ.get(EXTERNAL_FILE_ENV, "").strip()
    return Path(override) if override else DEFAULT_EXTERNAL_FILE


def _column_index(fieldnames, candidates: tuple[str, ...]) -> int | None:
    """Position of the first column whose normalised name matches a candidate.

    Both sides are normalised the same way (underscores and spaces removed), so
    ``discount_eligible`` in the file matches a ``discoun...`` style candidate
    without either side having to spell the separator.
    """
    def _norm(value: object) -> str:
        return re.sub(r"[\s_]+", "", str(value or "")).strip().lower()

    wanted = {_norm(name) for name in candidates}
    for position, raw in enumerate(fieldnames or []):
        if _norm(raw) in wanted:
            return position
    return None


def parse_external_rows(text_or_path) -> tuple[list[dict], list[str]]:
    """Read the external workbook into one dict per airline.

    Returns ``(rows, problems)`` where each row is
    ``{"code", "name", "benefits", "which"}`` and ``which`` lists the benefit
    columns that said Yes (so the UI can say *why* an airline qualifies).
    Problems (unreadable file, missing columns) are returned rather than raised.
    """
    import io

    import openpyxl

    def _load(source):
        if isinstance(source, (bytes, bytearray)):
            return openpyxl.load_workbook(io.BytesIO(bytes(source)),
                                          read_only=True, data_only=True)
        path = Path(source)
        if not path.exists():
            raise FileNotFoundError(f"{path} does not exist")
        return openpyxl.load_workbook(path, read_only=True, data_only=True)

    try:
        workbook = _load(text_or_path)
    except Exception as exc:
        return [], [f"could not read the benefits file: {exc}"]

    try:
        # The sheet is called "Benefits"; fall back to the first sheet so a
        # renamed sheet still imports.
        name = "Benefits" if "Benefits" in workbook.sheetnames \
            else (workbook.sheetnames or [None])[0]
        if name is None:
            return [], ["the benefits file has no sheets"]
        worksheet = workbook[name]
        rows = worksheet.iter_rows(values_only=True)
        try:
            header = next(rows)
        except StopIteration:
            return [], ["the benefits sheet is empty"]

        code_at = _column_index(header, EXTERNAL_CODE_COLUMNS)
        benefit_at = [(column, _column_index(header, (column,)))
                      for column in EXTERNAL_BENEFIT_COLUMNS]
        benefit_at = [(c, i) for c, i in benefit_at if i is not None]
        if code_at is None or not benefit_at:
            found = ", ".join(str(h) for h in header if h is not None)
            return [], [f"expected a code column "
                       f"({'/'.join(EXTERNAL_CODE_COLUMNS)}) and at least one "
                       f"benefit column ({'/'.join(EXTERNAL_BENEFIT_COLUMNS)}); "
                       f"found: {found}"]

        name_at = _column_index(header, EXTERNAL_NAME_COLUMNS)
        out: list[dict] = []
        problems: list[str] = []
        seen: set[str] = set()
        for number, raw_row in enumerate(rows, start=2):
            values = list(raw_row)
            if not values or code_at >= len(values):
                continue
            code = str(values[code_at] or "").strip().upper()
            if not code or code in seen:
                continue
            seen.add(code)
            airline_name = ""
            if name_at is not None and name_at < len(values):
                airline_name = str(values[name_at] or "").strip()
            which = [column for column, index in benefit_at
                     if index < len(values) and _is_yes(values[index])]
            out.append({"code": code, "name": airline_name or code,
                        "benefits": bool(which), "which": which})
        return out, problems
    except Exception as exc:
        return [], [f"could not read the benefits sheet: {exc}"]
    finally:
        try:
            workbook.close()
        except Exception:
            pass


def parse_external_benefits(text_or_path) -> tuple[dict[str, bool], list[str]]:
    """Read the external workbook into ``{key: has benefits}``.

    Each airline is registered under **both** its IATA code and its canonical
    name, so a flight can be resolved by whichever the source gives us: boards
    say "LH", CSV exports say "Lufthansa". "Unknown" and "No" both mean not
    qualified — an unverified airline is not one you can book on, and treating
    Unknown as a yes would silently widen the result list.
    """
    rows, problems = parse_external_rows(text_or_path)
    flags: dict[str, bool] = {}
    for row in rows:
        flags[row["code"]] = row["benefits"]
        if row["name"]:
            flags[canonical_airline_key(row["name"])] = row["benefits"]
    return flags, problems


def _is_yes(value: object) -> bool:
    """True only for an explicit yes. "Unknown" is not a yes."""
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"yes", "y", "true", "1", "ja", "x"}


#: Cached external flags, so a rerun does not re-read a 600-row workbook.
_EXTERNAL_CACHE: tuple[str, float, dict[str, bool], list[str]] | None = None
_EXTERNAL_TTL_S = 300.0


def load_external_flags(source=None,
                        max_age_s: float = _EXTERNAL_TTL_S
                        ) -> tuple[dict[str, bool], list[str]]:
    """Read (and briefly cache) the external ``airlines_benefits.xlsx``.

    ``source`` may be a path, raw bytes, or ``None`` to use
    :func:`external_file_path`. The cache is keyed on the resolved path *and*
    the file's mtime and size, so an edit in the other project is picked up
    immediately instead of after the TTL.
    """
    global _EXTERNAL_CACHE
    import time

    if source is None:
        source = external_file_path()
    key = ""
    if isinstance(source, (str, Path)):
        candidate = Path(source)
        try:
            stat = candidate.stat()
            key = f"{candidate}:{stat.st_mtime_ns}:{stat.st_size}"
        except OSError:
            key = str(candidate)
    if (_EXTERNAL_CACHE and _EXTERNAL_CACHE[0] == key
            and time.monotonic() - _EXTERNAL_CACHE[1] < max_age_s):
        return _EXTERNAL_CACHE[2], _EXTERNAL_CACHE[3]
    flags, problems = parse_external_benefits(source)
    _EXTERNAL_CACHE = (key, time.monotonic(), flags, problems)
    return flags, problems


def import_benefits_file(source=None,
                        workbook_path: Path | str | None = None) -> dict:
    """Read the external file and mirror it into the local workbook.

    ``source`` is the external benefits file, ``workbook_path`` the workbook to
    mirror into (default: the live one). Returns a report so the caller can tell
    the user what happened, rather than silently swapping the 24 seeded airlines
    for the 7 real ones. Nothing raises on failure: an unreadable file leaves the
    workbook untouched.
    """
    rows, problems = parse_external_rows(
        external_file_path() if source is None else source)
    qualified = [row for row in rows if row["benefits"]]
    report = {
        "source": str(source) if source is not None else str(external_file_path()),
        "read": len(rows),
        "qualified": len(qualified),
        "qualified_list": [f'{r["code"]} {r["name"]}' for r in qualified],
        "problems": problems,
        "written": 0,
    }
    if not rows:
        return report
    report["written"] = write_rows_to_sheet(rows, workbook_path)
    return report


def load_benefit_flags(path: Path | str | None = None) -> dict[str, bool]:
    """``canonical key -> has benefits``, from the best source available.

    Resolution order: the external ``airlines_benefits.xlsx`` the user maintains
    wins, because that is where they edit. The workbook's ``Airline Benefits``
    sheet is the mirror and the fallback, and the built-in seed list is the last
    resort so the page still works on a machine with neither.

    A missing sheet, a missing column, an empty cell and an unreadable file all
    mean "nothing from this source", never an exception.
    """
    from data_utils import DATA_PATH

    target = Path(path) if path is not None else DATA_PATH
    external, _problems = load_external_flags()
    if external:
        return external
    flags: dict[str, bool] = {}
    try:
        import openpyxl

        workbook = openpyxl.load_workbook(target, read_only=True, data_only=True)
    except Exception:
        return flags
    try:
        if SHEET_NAME not in workbook.sheetnames:
            return flags
        worksheet = workbook[SHEET_NAME]
        columns = _sheet_columns(worksheet)
        airline_col = next((c for name, c in columns.items()
                            if "airline" in name or "carrier" in name), None)
        flag_col = next((c for name, c in columns.items()
                         if "benefit" in name or name == "flag"), None)
        if airline_col is None or flag_col is None:
            return flags
        for row in worksheet.iter_rows(min_row=2, values_only=True):
            name = row[airline_col - 1] if airline_col - 1 < len(row) else None
            if not name or not str(name).strip():
                continue
            value = row[flag_col - 1] if flag_col - 1 < len(row) else None
            flags[canonical_airline_key(name)] = _truthy(value)
        return flags
    except Exception:
        return flags
    finally:
        try:
            workbook.close()
        except Exception:
            pass


def seed_flags() -> dict[str, bool]:
    """The documented default set, as canonical keys."""
    return {canonical_airline_key(name): True for name in SEED_BENEFIT_AIRLINES}


def has_benefits(airline: object, flags: dict[str, bool] | None = None) -> bool:
    """Whether one airline qualifies.

    Tries, in order: the exact IATA code (boards usually say "LH"), the
    canonical name key, an unambiguous substring match, and finally the seed list
    when no source at all could be read.

    When a source *was* read, an unlisted airline does **not** qualify. That is
    the safer direction: a too-narrow list is visible and fixable, a too-wide one
    silently invents destinations.
    """
    if flags is None:
        flags = load_benefit_flags()
    code = iata_code(airline)
    if code and code in flags:
        return flags[code]

    key = canonical_airline_key(airline)
    if not key:
        return False
    if flags:
        if key in flags:
            return flags[key]
        # A carrier may be listed under a spelling we could not fold
        # ("Singapore Airlines Limited" -> "singapore"). Substring containment
        # only, and only while the answer does not depend on which one matched.
        matches = {value for known, value in flags.items()
                   if known and (known in key or key in known)}
        if len(matches) == 1:
            return matches.pop()
        # 0 matches, or a yes and a no at once: either way we cannot claim it
        # qualifies.
        return False
    return key in seed_flags()


def iata_code(value: object) -> str:
    """Extract a 2-3 character IATA airline code from a name or flight number.

    Flight numbers are the other common shape a board gives us ("LH 1000"), and
    the external benefits file is keyed by code, so resolving it first is both
    cheaper and more reliable than the name heuristics.
    """
    if value is None:
        return ""
    text = str(value).strip().upper()
    if not text:
        return ""
    if re.fullmatch(r"[A-Z0-9]{2}", text):
        return text
    match = re.match(r"^([A-Z0-9]{2})\s*[\s-]?\d", text)
    if match:
        return match.group(1)
    return ""


def filtered_airlines(airlines, flags: dict[str, bool] | None = None) -> list[str]:
    """Keep only qualifying airlines, preserving order and dropping blanks."""
    keep: list[str] = []
    seen: set[str] = set()
    for airline in airlines or []:
        name = str(airline or "").strip()
        if not name or name in seen:
            continue
        seen.add(name)
        if has_benefits(name, flags):
            keep.append(name)
    return keep


def unmatched_airlines(airlines, flags: dict[str, bool] | None = None) -> list[str]:
    """Distinct carriers in the data that no source mentions.

    Shown in the UI so a missing flag is visible rather than silent. With the
    external file loaded, this is how a carrier with "Unknown" in every benefit
    column surfaces: it is in the file, so it is *known* but not qualified, and
    is therefore not reported here. It shows up in the results header instead.
    """
    if flags is None:
        flags = load_benefit_flags()
    known = set(flags) or set(seed_flags())
    out: list[str] = []
    for airline in airlines or []:
        name = str(airline or "").strip()
        if not name:
            continue
        code = iata_code(name)
        key = canonical_airline_key(name)
        if code and code in known:
            continue
        if key in known or any(k and (k in key or key in k) for k in known):
            continue
        if name not in out:
            out.append(name)
    return sorted(out)


def benefit_source_name(flags: dict[str, bool] | None = None) -> str:
    """Which source the flags came from: external file, sheet, or seed."""
    _external, problems = load_external_flags()
    if not problems and external_file_path().exists():
        return "airlines_benefits.xlsx"
    if flags:
        return f"'{SHEET_NAME}' sheet"
    return "built-in defaults"


def benefit_summary(flags: dict[str, bool] | None = None) -> str:
    """One line for the results header, so "nothing matched" is explainable.

    With the external file loaded this reports real airlines rather than the
    597-entry table: the user cares which carriers qualify, not how many are
    listed. "Unknown" counts as not qualified and is stated as such.
    """
    if flags is None:
        flags = load_benefit_flags()
    if not flags:
        return (f"No '{SHEET_NAME}' sheet and no external benefits file - using "
                f"the built-in default list of {len(SEED_BENEFIT_AIRLINES)} "
                f"airlines.")
    rows, problems = parse_external_rows(external_file_path())
    if rows and not problems:
        qualified = sorted(row["code"] for row in rows if row["benefits"])
        return (f"{len(qualified)} of {len(rows)} airlines have benefits "
                f"(from airlines_benefits.xlsx: "
                f"{', '.join(qualified) if qualified else 'none yet'}); "
                f"'Unknown' counts as no.")
    flagged = sum(1 for value in flags.values() if value)
    return (f"{flagged} of {len(flags)} listed airlines marked as having "
            f"benefits (sheet '{SHEET_NAME}')")


def benefit_names(flags: dict[str, bool] | None = None) -> list[str]:
    """The qualifying airlines as ``"LH Lufthansa"`` strings, for the UI."""
    rows, problems = parse_external_rows(external_file_path())
    if rows and not problems:
        return [f'{row["code"]} {row["name"]}' for row in sorted(
            rows, key=lambda r: str(r["code"])) if row["benefits"]]
    if flags is None:
        flags = load_benefit_flags()
    return sorted(name for name in SEED_BENEFIT_AIRLINES
                  if flags.get(canonical_airline_key(name)))


def write_rows_to_sheet(rows: list[dict], path: Path | str | None = None,
                        source_label: str = "external import") -> int:
    """Mirror the external airlines into the workbook's ``Airline Benefits`` sheet.

    One row per airline, mirroring the external columns so the sheet stays
    readable next to the file the user edits: ``IATA | Airline | Has Benefits |
    Benefit note | Set By``. The benefit note carries *which* columns said yes
    ("discount_eligible, business_class"), so the sheet explains itself.

    Used by :func:`import_benefits_file`, which means the app keeps working on a
    machine that cannot see the external folder. Returns rows written; never
    raises.
    """
    from data_utils import DATA_PATH, load_workbook_for_update, save_workbook_atomic

    target = Path(path) if path is not None else DATA_PATH
    if not rows:
        return 0
    try:
        workbook = load_workbook_for_update(target)
    except Exception:
        return 0
    try:
        if SHEET_NAME in workbook.sheetnames:
            del workbook[SHEET_NAME]
        worksheet = workbook.create_sheet(SHEET_NAME)
        worksheet.append(["IATA", "Airline", FLAG_HEADER, NOTE_HEADER,
                          SOURCE_HEADER])
        for row in sorted(rows, key=lambda r: str(r.get("code", ""))):
            worksheet.append([row.get("code", ""), row.get("name", ""),
                              "x" if row.get("benefits") else "",
                              ", ".join(row.get("which") or []), source_label])
        for column, width in (("A", 8), ("B", 34), ("C", 14), ("D", 46),
                              ("E", 16)):
            worksheet.column_dimensions[column].width = width
        save_workbook_atomic(workbook, target)
        return len(rows)
    except Exception:
        return 0
    finally:
        try:
            workbook.close()
        except Exception:
            pass


def write_seed_sheet(path: Path | str | None = None,
                     overwrite: bool = False) -> int:
    """Create the ``Airline Benefits`` sheet from the seed list. Returns rows.

    Never raises: this is a convenience, and the finder works without it.
    """
    from data_utils import DATA_PATH, load_workbook_for_update, save_workbook_atomic

    target = Path(path) if path is not None else DATA_PATH
    try:
        workbook = load_workbook_for_update(target)
    except Exception:
        return 0
    try:
        if SHEET_NAME in workbook.sheetnames:
            if not overwrite:
                return 0
            del workbook[SHEET_NAME]
        worksheet = workbook.create_sheet(SHEET_NAME)
        worksheet.append(["Airline", FLAG_HEADER, NOTE_HEADER, SOURCE_HEADER])
        for name in SEED_BENEFIT_AIRLINES:
            worksheet.append([name, "x", "", "seed default"])
        for column, width in (("A", 34), ("B", 14), ("C", 40), ("D", 14)):
            worksheet.column_dimensions[column].width = width
        save_workbook_atomic(workbook, target)
        return len(SEED_BENEFIT_AIRLINES)
    except Exception:
        return 0
    finally:
        try:
            workbook.close()
        except Exception:
            pass


if __name__ == "__main__":  # pragma: no cover - manual helper
    report = import_benefits_file()
    print(f"Benefits file: {report['source']}")
    if report["problems"]:
        for problem in report["problems"]:
            print(f"  [WARN] {problem}")
    if report["read"]:
        print(f"read {report['read']} entries, {report['qualified']} qualified "
              f"with benefits")
        for code in report["qualified_list"]:
            print(f"  ✓ {code}")
        print(f"mirrored {report['written']} row(s) into the workbook")
    else:
        print(f"nothing imported; falling back to the {SHEET_NAME} sheet")
        print(f"  {benefit_summary()}")