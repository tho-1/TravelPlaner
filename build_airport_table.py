"""Build the compact airport table used by the weekend trip finder.

Source: OurAirports (public domain, https://ourairports.com/data/). Only
large/medium airports with an IATA code and a country are kept: 4.5k rows is
~150 kB, which is small enough to commit and large enough for any weekend
finder. Small airports (secondary London City, Paris Orly …) are handled by the
explicit metro merge in ``airport_city.py``.

Usage:
    python build_airport_table.py                 # report only
    python build_airport_table.py --write         # rewrite data/airports.csv
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "airports_raw.csv"
TARGET = ROOT / "data" / "airports.csv"
KEEP_TYPES = ("large_airport", "medium_airport")

HEADER = ["iata", "city", "country", "name", "lat", "lon"]


def build_rows(source: Path = SOURCE):
    """Yield ``[iata, city, country, name, lat, lon]`` for every usable airport.

    The city is kept exactly as OurAirports records it. Tidy-ups (dropping the
    district in "Hanoi (Soc Son)", renaming "Ferno" to Milan) belong to
    ``airport_city.py``, because they are presentation decisions that must stay
    reviewable in one table -- rewriting 4.5k rows here would hide them.
    """
    with source.open(encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            iata = (row.get("iata_code") or "").strip().upper()
            country = (row.get("iso_country") or "").strip().upper()
            if not iata or not country:
                continue
            if row.get("type") not in KEEP_TYPES:
                continue
            city = (row.get("municipality") or "").strip()
            if not city:
                # A few airports have no municipality; the airport name is the
                # best available label and is better than an empty cell.
                city = (row.get("name") or iata).split(" Airport")[0].strip()
            yield [
                iata,
                city,
                country,
                (row.get("name") or "").strip(),
                (row.get("latitude_deg") or "").strip(),
                (row.get("longitude_deg") or "").strip(),
            ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true",
                        help="write data/airports.csv instead of only reporting")
    args = parser.parse_args(argv)

    if not SOURCE.exists():
        print(f"[ERROR] {SOURCE.name} missing. Download OurAirports airports.csv "
              f"into the project folder first:\n"
              f"  https://davidmegginson.github.io/ourairports-data/airports.csv")
        return 1

    rows = sorted(build_rows())
    if len({row[0] for row in rows}) != len(rows):
        print("[ERROR] duplicate IATA codes in the filtered set; refusing to write")
        return 1

    print(f"rows: {len(rows)}")
    print(f"size: {sum(len(r) for r in rows) / 1024:.0f} kB of text")
    if not args.write:
        print("dry run — pass --write to update data/airports.csv")
        return 0

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    with TARGET.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(HEADER)
        writer.writerows(rows)
    print(f"[OK] wrote {TARGET.relative_to(ROOT)} ({TARGET.stat().st_size / 1024:.0f} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())