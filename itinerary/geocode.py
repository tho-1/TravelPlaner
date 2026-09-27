"""Open-Meteo geocoding client with a small disk cache.

Used when the traveler adds a city that is neither a workbook destination nor
the home gateway (e.g. Beijing, Chengdu). Responses are cached in
``itinerary_cache/geocode.json`` so repeat selections and offline restarts
never re-query.
"""

from __future__ import annotations

import json
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = ROOT / "itinerary_cache"
CACHE_PATH = CACHE_DIR / "geocode.json"

ENDPOINT = "https://geocoding-api.open-meteo.com/v1/search"


def _norm(query: str) -> str:
    return " ".join(str(query).casefold().split())


def _load_cache() -> dict:
    try:
        return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_cache(cache: dict) -> None:
    try:
        CACHE_DIR.mkdir(exist_ok=True)
        tmp = CACHE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(cache, ensure_ascii=False, indent=1),
                       encoding="utf-8")
        tmp.replace(CACHE_PATH)
    except OSError:
        pass  # cache is best-effort


def search(query: str, count: int = 5, use_cache: bool = True) -> list[dict]:
    """[{name, country, admin1, lat, lon}] — possibly empty, never raises."""
    query = str(query).strip()
    if not query:
        return []
    key = f"{_norm(query)}|{count}"
    cache = _load_cache() if use_cache else {}
    if key in cache:
        return cache[key]
    try:
        resp = requests.get(ENDPOINT, params={
            "name": query, "count": count, "language": "en", "format": "json",
        }, timeout=15)
        resp.raise_for_status()
        results = [
            {"name": r.get("name", query),
             "country": r.get("country"),
             "admin1": r.get("admin1"),
             "lat": r.get("latitude"),
             "lon": r.get("longitude")}
            for r in (resp.json().get("results") or [])
        ]
    except Exception:
        return []  # transient network error: don't cache the failure
    cache[key] = results
    _save_cache(cache)
    return results
