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


def load_benefit_flags(path: Path | str | None = None) -> dict[str, bool]:
    """``canonical key -> has benefits`` from the workbook sheet.

    A missing sheet, a missing column, an empty cell and an unreadable file all
    mean "no flags", never an exception: the finder must run before the sheet
    exists. An empty result makes ``has_benefits`` fall back to the seed list.
    """
    from data_utils import DATA_PATH

    target = Path(path) if path is not None else DATA_PATH
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

    Falls back to ``SEED_BENEFIT_AIRLINES`` only when the sheet is missing
    entirely. If the sheet exists, an unlisted airline does **not** qualify:
    the user's explicit list outranks our guess. That is the safer direction —
    a too-narrow list is visible and fixable, a too-wide one silently invents
    destinations.
    """
    key = canonical_airline_key(airline)
    if not key:
        return False
    if flags is None:
        flags = load_benefit_flags()
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
        if len(matches) > 1:
            # Both a "yes" and a "no" matched: we cannot tell which carrier the
            # name means, so do not claim it qualifies.
            return False
        return False
    return key in seed_flags()


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
    """Distinct carriers in the data that the sheet does not mention.

    Shown in the UI so a missing flag is visible rather than silent.
    """
    if flags is None:
        flags = load_benefit_flags()
    known = set(flags) or set(seed_flags())
    out: list[str] = []
    for airline in airlines or []:
        name = str(airline or "").strip()
        if not name:
            continue
        key = canonical_airline_key(name)
        if key in known or any(k and (k in key or key in k) for k in known):
            continue
        if name not in out:
            out.append(name)
    return sorted(out)


def benefit_summary(flags: dict[str, bool] | None = None) -> str:
    """One line for the results header, so "nothing matched" is explainable."""
    if flags is None:
        flags = load_benefit_flags()
    if not flags:
        return (f"No '{SHEET_NAME}' sheet yet - using the built-in default list of "
                f"{len(SEED_BENEFIT_AIRLINES)} airlines. Tick your own in the "
                f"workbook to narrow it down.")
    flagged = sum(1 for value in flags.values() if value)
    return (f"{flagged} of {len(flags)} listed airlines marked as having "
            f"benefits (sheet '{SHEET_NAME}')")


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
    print(benefit_summary())
    for name in SEED_BENEFIT_AIRLINES:
        print(f"  {name:24} {canonical_airline_key(name)}")