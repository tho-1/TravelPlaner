"""Run full ground typical fetch for Asian destinations one by one and log progress."""

from __future__ import annotations

import sys
import time
from pathlib import Path

from aqi_api import (
    load_coordinates,
    load_cached,
    _slugify,
    refresh_ground_full,
    update_destination_climate,
    print_report,
    MONTHS_SHORT,
    DIVERGENCE_ABS,
    DIVERGENCE_REL,
)

# List of Asian destinations with ground stations
TARGETS = [
    'Guilin (Guangxi)', 'Nagoya', 'Saigon', 'Sapporo', 'Kathmandu', 'Kunming (Yunnan)',
    'Okinawa', 'Denpasar', 'Izmir', 'Ankara', 'Luang Prabang', 'Manila', 'Fukuoka',
    "Xi'an (Shaanxi)", 'Wuhan (Hubei)', 'Hat Yai', 'Vientiane', 'Ubud', 'Medan',
    'Dhaka', 'Hangzhou (Zhejiang)', 'Ürümqi (Xinjiang)', 'Ulaanbaatar', 'Shenyang (Liaoning)',
    'Harbin (Heilongjiang)', 'Luoyang (Henan)', 'Datong (Shanxi)', 'Suzhou (Jiangsu)',
    'Qingdao (Shandong)', 'Xiamen (Fujian)', 'Zhangjiajie (Hunan)', 'Guiyang (Guizhou)',
    'Yogyakarta', 'Bishkek', 'Dubai', 'Nanjing (Jiangsu)', 'Nanning (Guangxi)',
    'Nanchang (Jiangxi)', 'Xiangyang (Hubei)', 'Quanzhou (Fujian)', 'Yichun (Jiangxi)',
    'Wuxi (Jiangsu)', 'Jakarta', 'Dali (Yunnan)', 'Lijiang (Yunnan)', 'Amman',
    'Kashgar (Xinjiang)', 'Tainan', 'Hiroshima', 'Tashkent', 'Kanazawa', 'Nagasaki',
    'Taichung', 'Muscat', 'Zigong (Sichuan)', 'Lanzhou (Gansu)', 'Jinan (Shandong)',
    'Kaifeng (Henan)', 'Liuzhou (Guangxi)'
]


def format_dest_markdown(name: str, payload: dict) -> str:
    model, ground = payload["model_aqi"], payload.get("ground_aqi") or {}
    typ = payload.get("model_aqi_typical") or {}
    gtyp = payload.get("ground_aqi_typical") or {}

    def _fmt(v):
        return str(v) if v is not None else "—"

    lines = [
        f"\n### **{name}** (lat {payload['lat']}, lon {payload['lon']})",
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


def main():
    coords = load_coordinates()
    print(f"Starting --ground-full for {len(TARGETS)} Asian destinations...\n", flush=True)

    completed = []
    failed = []

    for idx, name in enumerate(TARGETS, 1):
        if name not in coords:
            print(f"[{idx}/{len(TARGETS)}] {name}: No coordinates found, skipping.\n", flush=True)
            continue

        entry = coords[name]
        slug = _slugify(name)
        cached = load_cached(slug)
        if cached and cached.get("ground_aqi_typical"):
            print(f"[{idx}/{len(TARGETS)}] {name}: Already has ground typical data. Skipping.\n", flush=True)
            completed.append(name)
            continue

        print(f"[{idx}/{len(TARGETS)}] Processing {name} …", flush=True)
        try:
            payload = refresh_ground_full(entry["lat"], entry["lon"], slug)
            msg = update_destination_climate(
                name,
                payload["model_aqi"],
                payload.get("climate") or {},
                payload.get("ground_aqi"),
                model_typical=payload.get("model_aqi_typical"),
                ground_typical=payload.get("ground_aqi_typical"),
            )
            print(f"  ✓ {msg}", flush=True)
            md_table = format_dest_markdown(name, payload)
            print(md_table, flush=True)
            print("\n" + "=" * 60 + "\n", flush=True)
            completed.append(name)
        except Exception as exc:
            print(f"  ✗ FAILED {name}: {exc}\n", flush=True)
            failed.append((name, str(exc)))

        time.sleep(1.0)

    print(f"ALL DONE: {len(completed)} completed, {len(failed)} failed.", flush=True)


if __name__ == "__main__":
    main()

