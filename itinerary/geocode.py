"""Open-Meteo geocoding client with a small disk cache.

Used when the traveler adds a city that is neither a workbook destination nor
the home gateway (e.g. Beijing, Chengdu). Responses are cached in
``itinerary_cache/geocode.json`` so repeat selections and offline restarts
never re-query.

Two failure modes this file used to have, both permanent for the user:

* an **empty** result was cached forever, so one bad API answer blocked that
  city until the cache file was deleted by hand;
* Open-Meteo answers **HTTP 200** with ``{"error": true, ...}`` for a rejected
  query, which looked exactly like "no such city".
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import requests

import runtime_paths

CACHE_DIR = runtime_paths.state_path("itinerary_cache")
CACHE_PATH = CACHE_DIR / "geocode.json"

ENDPOINT = "https://geocoding-api.open-meteo.com/v1/search"

#: How long a cached result stays usable.
CACHE_TTL_DAYS = 30

_SCHEMA = 2  # bump to invalidate every existing entry at once


def _norm(query: str) -> str:
    return " ".join(str(query).casefold().split())


def _load_cache() -> dict:
    try:
        raw = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not isinstance(raw, dict) or raw.get("schema") != _SCHEMA:
        return {}
    entries = raw.get("entries")
    return entries if isinstance(entries, dict) else {}


def _save_cache(entries: dict) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        payload = {"schema": _SCHEMA, "entries": entries}
        tmp = CACHE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=1),
                       encoding="utf-8")
        tmp.replace(CACHE_PATH)
    except OSError:
        pass  # cache is best-effort


def _is_fresh(entry) -> bool:
    if not isinstance(entry, dict) or "ts" not in entry:
        return False
    try:
        stamp = datetime.fromisoformat(str(entry["ts"]))
    except ValueError:
        return False
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) - stamp <= timedelta(days=CACHE_TTL_DAYS)


def search(query: str, count: int = 5, use_cache: bool = True) -> list[dict]:
    """[{name, country, admin1, lat, lon}] — possibly empty, never raises."""
    query = str(query).strip()
    if not query:
        return []
    key = f"{_norm(query)}|{count}"
    cache = _load_cache() if use_cache else {}
    cached = cache.get(key)
    if isinstance(cached, dict) and _is_fresh(cached):
        results = cached.get("results")
        if isinstance(results, list):
            return results

    try:
        resp = requests.get(ENDPOINT, params={
            "name": query, "count": count, "language": "en", "format": "json",
        }, timeout=15)
        resp.raise_for_status()
        payload = resp.json()
        if isinstance(payload, dict) and payload.get("error"):
            return []          # rejected query — do not cache it
        results = [
            {"name": r.get("name", query),
             "country": r.get("country"),
             "admin1": r.get("admin1"),
             "lat": r.get("latitude"),
             "lon": r.get("longitude")}
            for r in (payload.get("results") or [])
        ]
    except Exception:
        return []              # transient network error: don't cache the failure

    if results:
        cache[key] = {"ts": datetime.now(timezone.utc).isoformat(),
                      "results": results}
        _save_cache(cache)
    return results
