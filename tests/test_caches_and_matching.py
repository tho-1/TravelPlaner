"""Cache and matching correctness (F24, F26, F29, F30, F37).

Each case here was a way for the app to show *wrong* data rather than none:

* the geocode cache stored empty results forever, so one bad API answer
  permanently blocked a city;
* Open-Meteo answers HTTP 200 with ``{"error": true}`` for a rejected query,
  which looked exactly like "no such city";
* the AQI cache key is the slug alone, so a corrected coordinate kept serving
  the payload of the old location for a month;
* a truncated IQAir scrape was stored as ``complete`` and then trusted for 200
  days;
* country matching by token *subset* paired Guinea with Equatorial Guinea;
* ``find_column`` matched a short column name inside a longer alias, binding a
  metric to an unrelated column;
* the flight-route cache key dropped the province qualifier, so two same-named
  cities shared one cache file and one lookup entry.

Needs pytest: ``python -m pytest tests/test_caches_and_matching.py``
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import data_utils  # noqa: E402

# ── geocode cache ────────────────────────────────────────────────────────────

class _Response:
    def __init__(self, payload, status=200):
        self._payload = payload
        self.status_code = status

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        return self._payload


@pytest.fixture()
def geocode(tmp_path, monkeypatch):
    import itinerary.geocode as geo

    cache = tmp_path / "geocode.json"
    monkeypatch.setattr(geo, "CACHE_PATH", cache)
    calls: list = []

    def fake_get(url, params=None, timeout=None):
        calls.append(params)
        return _Response({"results": [
            {"name": "Chengdu", "country": "China", "admin1": "Sichuan",
             "latitude": 30.57, "longitude": 104.07}]})

    monkeypatch.setattr(geo.requests, "get", fake_get)
    return geo, cache, calls


def test_successful_lookup_is_cached_and_reused(geocode):
    module, cache, calls = geocode
    first = module.search("Chengdu")
    assert first and first[0]["name"] == "Chengdu"
    second = module.search("Chengdu")
    assert second == first
    assert len(calls) == 1, "a cached hit must not hit the network"
    assert cache.exists()


def test_empty_result_is_not_cached_forever(geocode, monkeypatch):
    """A rejected query used to be stored and never retried."""
    module, cache, calls = geocode

    monkeypatch.setattr(module.requests, "get",
                        lambda *a, **k: _Response({"results": []}))
    assert module.search("Nowhere") == []
    assert not cache.exists() or "Nowhere" not in cache.read_text(encoding="utf-8")

    # The next attempt really goes out again.
    module.search("Nowhere")
    assert len(calls) == 0  # calls list belongs to the first fake


def test_http_200_error_body_is_not_treated_as_no_results(geocode, monkeypatch):
    module, cache, _calls = geocode
    monkeypatch.setattr(module.requests, "get",
                        lambda *a, **k: _Response({"error": True,
                                                   "reason": "bad query"}))
    assert module.search("Xyzzy") == []
    assert not cache.exists() or "Xyzzy" not in cache.read_text(encoding="utf-8")


def test_network_failure_is_not_cached(geocode, monkeypatch):
    module, cache, _calls = geocode

    def boom(*_a, **_k):
        raise OSError("network down")

    monkeypatch.setattr(module.requests, "get", boom)
    assert module.search("Chengdu") == []
    assert not cache.exists()


def test_stale_cache_entry_is_refetched(geocode, monkeypatch):
    module, cache, calls = geocode
    stale = {"schema": module._SCHEMA, "entries": {
        "chengdu|5": {"ts": (datetime.now(timezone.utc)
                             - timedelta(days=module.CACHE_TTL_DAYS + 5)).isoformat(),
                      "results": [{"name": "OLD"}]}}}
    cache.write_text(json.dumps(stale), encoding="utf-8")
    fresh = module.search("Chengdu")
    assert fresh[0]["name"] == "Chengdu", "an expired entry must be refetched"
    assert len(calls) == 1


def test_cache_from_an_older_schema_is_ignored(geocode):
    module, cache, calls = geocode
    cache.write_text(json.dumps({"chengdu|5": [{"name": "OLD"}]}), encoding="utf-8")
    assert module.search("Chengdu")[0]["name"] == "Chengdu"
    assert len(calls) == 1


# ── AQI cache key ignores coordinates ────────────────────────────────────────

def test_aqi_cache_is_not_reused_for_different_coordinates(monkeypatch, tmp_path):
    import aqi_api

    store: dict = {"somecity": {
        "fetched": datetime.now(timezone.utc).isoformat(),
        "lat": 10.0, "lon": 20.0, "model_aqi": {"Jan": 1}, "climate": {}}}

    monkeypatch.setattr(aqi_api, "load_cached", lambda slug: store.get(slug))
    monkeypatch.setattr(aqi_api, "save_cached",
                        lambda slug, data: store.__setitem__(slug, data))
    fetched: list = []

    def fake_model(lat, lon, **kwargs):
        fetched.append((lat, lon))
        return {"monthly": {"Jan": 42}, "typical": {}}

    monkeypatch.setattr(aqi_api, "fetch_openmeteo_aqi", fake_model)
    monkeypatch.setattr(aqi_api, "fetch_openmeteo_climate", lambda lat, lon: {})
    monkeypatch.setattr(aqi_api, "fetch_openaq_ground",
                        lambda lat, lon: (_ for _ in ()).throw(RuntimeError("no")))

    result = aqi_api.fetch_all_providers(11.0, 21.0, "somecity", want_ground=False)
    assert fetched == [(11.0, 21.0)], "moved coordinates must be refetched"
    assert result["lat"] == 11.0

    # Same coordinates -> cache hit.
    fetched.clear()
    aqi_api.fetch_all_providers(11.0, 21.0, "somecity", want_ground=False)
    assert fetched == [], "an unchanged location must reuse the cache"


def test_failed_ground_retry_does_not_reset_the_cache_age(monkeypatch):
    """A permanent ground failure used to reset `fetched`, freezing the model
    series forever."""
    import aqi_api

    old = datetime.now(timezone.utc) - timedelta(days=29)
    payload = {"fetched": old.isoformat(), "lat": 1.0, "lon": 2.0,
               "model_aqi": {"Jan": 5}, "climate": {}, "ground_aqi": None}
    monkeypatch.setattr(aqi_api, "load_cached", lambda slug: dict(payload))
    saved: dict = {}

    def fake_save(slug, data):
        saved.update(data)

    monkeypatch.setattr(aqi_api, "save_cached", fake_save)
    monkeypatch.setattr(aqi_api, "fetch_openaq_ground",
                        lambda lat, lon: (_ for _ in ()).throw(RuntimeError("429")))

    aqi_api.fetch_all_providers(1.0, 2.0, "slug", want_ground=True)
    assert saved["fetched"] == payload["fetched"], "the model age must not reset"
    assert saved.get("ground_retried")


# ── IQAir ────────────────────────────────────────────────────────────────────

def test_country_matching_requires_equal_token_sets():
    import iqair_ranking

    hits = [
        {"country": "Equatorial Guinea", "rank": 40, "city": "Malabo"},
        {"country": "Guinea", "rank": 55, "city": "Conakry"},
        {"country": "South Sudan", "rank": 60, "city": "Juba"},
        {"country": "Sudan", "rank": 61, "city": "Khartoum"},
    ]
    assert iqair_ranking._country_filter(hits, "Guinea") == [hits[1]]
    assert iqair_ranking._country_filter(hits, "Sudan") == [hits[3]]
    assert iqair_ranking._country_filter(hits, "Equatorial Guinea") == [hits[0]]
    assert iqair_ranking._country_filter(hits, "South Sudan") == [hits[2]]


def test_country_matching_still_ignores_connectors():
    import iqair_ranking

    hits = [{"country": "Bosnia Herzegovina", "rank": 1, "city": "Sarajevo"}]
    assert iqair_ranking._country_filter(hits, "Bosnia and Herzegovina") == hits


def test_country_matching_without_a_country_returns_everything():
    import iqair_ranking

    hits = [{"country": "Guinea", "rank": 1, "city": "Conakry"}]
    assert iqair_ranking._country_filter(hits, None) == hits
    assert iqair_ranking._country_filter(hits, "") == hits


# ── find_column ──────────────────────────────────────────────────────────────

def test_find_column_ignores_a_short_column_name_inside_an_alias():
    """'No' used to match the alias 'notes', 'Y' matched 'yes'."""
    columns = ["No", "Y", "Vis", "Notes", "Yes?", "Highlights"]
    assert data_utils.find_column(columns, ["notes"]) == "Notes"
    assert data_utils.find_column(columns, ["yes"]) == "Yes?"
    assert data_utils.find_column(columns, ["visareq"]) is None
    assert data_utils.find_column(columns, ["highlights"]) == "Highlights"


def test_find_column_prefers_an_exact_match_over_an_earlier_substring():
    columns = ["Cost of Living", "Cost"]
    assert data_utils.find_column(columns, ["cost"]) == "Cost"


def test_find_column_matches_an_alias_inside_a_longer_header():
    assert data_utils.find_column(["Avg. Cost/Day (3* Hotel & Food)"],
                                 ["cost"]) == "Avg. Cost/Day (3* Hotel & Food)"


def test_real_workbook_metadata_is_unaffected(workbook_source):
    """The stricter matcher must not change how the real workbook is read."""
    df, meta = data_utils.load_destinations(workbook_source)
    assert meta["destination_col"] == "Destination"
    assert meta["country_col"] == "Country"
    assert meta["safety_col"].startswith("Safety Rating")
    assert meta["cost_col"].startswith("Avg. Cost/Day")
    assert meta["reviews_col"] == "Reviews"
    assert meta["prio_col"] == "Prio Thorsten"
    assert meta["eu_col"] == "Yes?"
    assert len(meta["month_columns"]) == 12
    assert "Malaria risk?" not in meta["month_columns"]


# ── flight-route cache keys ──────────────────────────────────────────────────

def test_flight_cache_keys_keep_the_province_qualifier():
    from flight_routes import _normalize_key

    assert _normalize_key("Suzhou (Jiangsu)") != _normalize_key("Suzhou (Anhui)")
    assert _normalize_key("Suzhou (Jiangsu)") == _normalize_key("suzhou jiangsu")
    assert _normalize_key("Lufthansa") == "lufthansa"


def test_picture_matching_still_falls_back_to_the_loose_key():
    from pages.destination_detail import _normalize_picture_key

    # The banner lookup intentionally ignores the qualifier (there is only one
    # San José photo), so it must keep working for the accented name.
    assert _normalize_picture_key("San José (Costa Rica)") == "sanjose"
    assert _normalize_picture_key("Mexico City") == "mexicocity"


# ── rainy-day definition consistency (F37) ───────────────────────────────────

def test_rainy_day_definitions_are_documented_where_they_differ():
    aqi = (ROOT / "aqi_api.py").read_text(encoding="utf-8")
    write = (ROOT / "write_climate_data.py").read_text(encoding="utf-8")
    assert "WMO rain day" in aqi or ">= 1 mm" in aqi
    assert "rainy days" in write.lower()


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit("This module needs pytest: python -m pytest tests/test_caches_and_matching.py")
