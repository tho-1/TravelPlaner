"""Regenerate the mobile app's generated assets from the
Python modules that own them.

The Flutter app ships two tables that already exist on the
Python side. Keeping the Python modules the single source of
truth means a correction to one reaches both apps; this
script is the documented regeneration path (the AGENTS.md
convention: an explicit table with a regeneration script,
not a copy that drifts).

    python mobile/tools/generate_assets.py

Outputs:

* ``assets/airports.json``   -- IATA -> [city, country],
  from ``airport_city`` (metro merges included).
* ``assets/country_names.json`` -- ISO code -> English
  name, from ``airport_city.COUNTRY_NAMES``.
* ``assets/city_coordinates.json`` -- one entry per
  coordinate row of ``city_coordinates.json`` (the table
  ``itinerary.geo`` and ``aqi_api`` read): name, country,
  lat, lon. Both the destination and the city spelling are
  kept, because the Python index registers both.

Run from the repository root or from anywhere: the path
resolution below finds the repo relative to this file.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))


def main() -> None:
    import airport_city

    airports = {
        code: [city, country]
        for code, (city, country) in sorted(airport_city._code_to_city().items())
        if city
    }
    _write(ROOT / "mobile" / "assets" / "airports.json", airports)
    print(f"airports: {len(airports)}")

    countries = {
        code: name
        for code, name in sorted(airport_city.COUNTRY_NAMES.items())
        if name
    }
    _write(ROOT / "mobile" / "assets" / "country_names.json", countries)
    print(f"countries: {len(countries)}")

    coordinates = _coordinates()
    _write(ROOT / "mobile" / "assets" / "city_coordinates.json", coordinates)
    print(f"coordinates: {len(coordinates)}")


def _coordinates() -> list[dict]:
    """The coordinate table, one entry per row.

    The Python index keys each row under both its
    destination and its city spelling; the Dart side does
    the same, so both strings travel in the entry.
    """
    import json

    path = ROOT / "city_coordinates.json"
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        print(f"[WARN] could not read {path.name}: {error}")
        return []
    entries = []
    for entry in raw.values():
        name = entry.get("city") or entry.get("destination")
        if not name or entry.get("lat") is None or entry.get("lon") is None:
            continue
        entries.append({
            "name": name,
            "destination": entry.get("destination") or name,
            "country": entry.get("country") or "",
            "lat": entry["lat"],
            "lon": entry["lon"],
        })
    entries.sort(key=lambda item: item["name"])
    return entries


def _write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()
