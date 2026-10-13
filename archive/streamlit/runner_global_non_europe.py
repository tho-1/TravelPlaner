"""Run multi-year typical fetch (--ground-full / model typical) for all remaining non-European destinations."""

from __future__ import annotations

import time

import openpyxl

from aqi_api import (
    DIVERGENCE_ABS,
    DIVERGENCE_REL,
    MONTHS_SHORT,
    _slugify,
    fetch_openaq_ground,
    fetch_openmeteo_aqi,
    load_cached,
    load_coordinates,
    save_cached,
    update_destination_climate,
)
from data_utils import DATA_PATH, _find_destination_sheet

EUROPEAN_COUNTRIES = {
    'Romania', 'Poland', 'Estonia', 'Norway', 'Iceland', 'Spain', 'Germany',
    'France', 'Italy', 'Greece', 'Portugal', 'United Kingdom', 'Albania',
    'Bulgaria', 'Croatia', 'Montenegro', 'Bosnia and Herzegovina', 'Serbia',
    'North Macedonia', 'Austria', 'Switzerland', 'Belgium', 'Netherlands',
    'Czech Republic', 'Hungary', 'Slovakia', 'Slovenia', 'Denmark', 'Sweden',
    'Finland', 'Ireland', 'Lithuania', 'Latvia', 'Cyprus', 'Malta', 'Europe'
}


def format_dest_markdown(name: str, payload: dict) -> str:
    model, ground = payload.get("model_aqi") or {}, payload.get("ground_aqi") or {}
    typ = payload.get("model_aqi_typical") or {}
    gtyp = payload.get("ground_aqi_typical") or {}

    def _fmt(v):
        return str(v) if v is not None else "—"

    lines = [
        f"\n### **{name}** (lat {payload.get('lat')}, lon {payload.get('lon')})",
        "| Month | Model (12M) | Model Typ | Ground (12M) | Ground Typ | Divergence |",
        "| :--- | :---: | :---: | :---: | :---: | :---: |"
    ]
    for m in MONTHS_SHORT:
        a, b = model.get(m), ground.get(m)
        flag = ""
        if a is not None and b is not None:
            diff = abs(a - b)
            rel = diff / max(abs(a), abs(b), 1)
            if diff > DIVERGENCE_ABS and rel > DIVERGENCE_REL:
                flag = "⚠️ DIVERGENT"
        lines.append(f"| {m} | {_fmt(a)} | {_fmt(typ.get(m))} | {_fmt(b)} | {_fmt(gtyp.get(m))} | {flag} |")
    return "\n".join(lines)


def get_non_european_destinations():
    sheet_name = _find_destination_sheet(DATA_PATH)
    wb = openpyxl.load_workbook(DATA_PATH, read_only=True)
    ws = wb[sheet_name]
    headers = {str(cell.value).strip(): i for i, cell in enumerate(next(ws.iter_rows(max_row=1))) if cell.value}
    dest_col = headers.get("Destination")
    country_col = headers.get("Country")
    continent_col = headers.get("Continent")

    out = []
    for row in ws.iter_rows(min_row=2, values_only=True):
        if dest_col is None or not row[dest_col]:
            continue
        dest = str(row[dest_col]).strip()
        country = str(row[country_col]).strip() if country_col is not None and row[country_col] else ""
        continent = str(row[continent_col]).strip() if continent_col is not None and row[continent_col] else ""

        is_europe = continent.lower() == "europe" or country in EUROPEAN_COUNTRIES
        if not is_europe:
            out.append((dest, country, continent))
    wb.close()
    return out


def process_destination(name: str, coords_entry: dict) -> dict:
    lat, lon = coords_entry["lat"], coords_entry["lon"]
    slug = _slugify(name)
    cached = load_cached(slug) or {}

    # 1. Ensure Model Typical is present
    if not cached.get("model_aqi") or not cached.get("model_aqi_typical"):
        try:
            m_data = fetch_openmeteo_aqi(lat, lon)
            cached["lat"] = lat
            cached["lon"] = lon
            cached["model_aqi"] = m_data["monthly"]
            cached["model_aqi_typical"] = m_data["typical"]
            save_cached(slug, cached)
        except Exception as exc:
            print(f"   Model fetch error: {exc}", flush=True)

    # 2. Fetch Ground Typical
    try:
        ground_data = fetch_openaq_ground(lat, lon, typical=True)
        cached["ground_aqi"] = ground_data["monthly"]
        cached["ground_aqi_typical"] = ground_data["typical"]
        cached["ground_error"] = None
    except Exception as exc:
        cached["ground_error"] = str(exc)
        # Keep existing ground_aqi if any, else None
        if "ground_aqi" not in cached:
            cached["ground_aqi"] = None
        if "ground_aqi_typical" not in cached:
            cached["ground_aqi_typical"] = None

    save_cached(slug, cached)
    return cached


def main():
    coords = load_coordinates()
    targets = get_non_european_destinations()
    print(f"Found {len(targets)} non-European destinations to process.\n", flush=True)

    completed_ground = []
    completed_model_only = []
    failed = []

    for idx, (name, country, continent) in enumerate(targets, 1):
        if name not in coords:
            print(f"[{idx}/{len(targets)}] {name} ({country}): No coordinates found, skipping.\n", flush=True)
            continue

        slug = _slugify(name)
        cached = load_cached(slug)
        # Check if already has full ground typical
        if cached and cached.get("ground_aqi_typical"):
            print(f"[{idx}/{len(targets)}] {name}: Already has ground typical data. Skipping.\n", flush=True)
            completed_ground.append(name)
            continue

        print(f"[{idx}/{len(targets)}] Processing {name} ({country}, {continent}) …", flush=True)
        try:
            payload = process_destination(name, coords[name])
            msg = update_destination_climate(
                name,
                payload.get("model_aqi") or {},
                payload.get("climate") or {},
                payload.get("ground_aqi"),
                model_typical=payload.get("model_aqi_typical"),
                ground_typical=payload.get("ground_aqi_typical"),
            )
            print(f"  ✓ {msg}", flush=True)
            if payload.get("ground_aqi"):
                md_table = format_dest_markdown(name, payload)
                print(md_table, flush=True)
                completed_ground.append(name)
            else:
                print("  (No PM2.5 ground sensors within 10 km; model multi-year typical written)", flush=True)
                completed_model_only.append(name)
            print("\n" + "=" * 60 + "\n", flush=True)
        except Exception as exc:
            print(f"  ✗ FAILED {name}: {exc}\n", flush=True)
            failed.append((name, str(exc)))

        time.sleep(1.0)

    print(
        f"GLOBAL (NON-EUROPE) RUN FINISHED:\n"
        f"  - Ground Typical completed: {len(completed_ground)}\n"
        f"  - Model Typical (no ground stations): {len(completed_model_only)}\n"
        f"  - Failed: {len(failed)}",
        flush=True,
    )


if __name__ == "__main__":
    main()

