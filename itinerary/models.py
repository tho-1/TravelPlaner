"""Trip / Variant / Stop / Leg data model — plain JSON-friendly dicts.

Invariants
----------
- A Trip has 1..n Variants; exactly one is active (``active_variant_id``).
- A Variant's stops are ordered; ``legs`` is POSITIONAL: ``legs[i]`` is the
  transport between ``stops[i]`` and ``stops[i+1]``. Hence
  ``len(legs) == len(stops) - 1`` whenever there are >= 2 stops.
- Times are strings ("YYYY-MM-DD", "HH:MM") or None — never datetime objects —
  so the whole structure is directly JSON-serializable.
- ``normalize_*`` repairs old/partial payloads so storage loading is tolerant.
"""

from __future__ import annotations

import uuid
from datetime import datetime

SCHEMA_VERSION = 1

TRANSPORT_MODES = ["flight", "train", "bus", "car", "boat", "other"]

STOP_KINDS = ["destination", "custom", "gateway"]
STOP_ROLES = ["origin", "stop", "return"]


def new_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:10]}"


# ── builders ─────────────────────────────────────────────────────────────────

def make_ref(kind: str, name: str, country: str | None = None,
             lat: float | None = None, lon: float | None = None) -> dict:
    return {"kind": kind, "name": name, "country": country,
            "lat": lat, "lon": lon}


def make_stop(ref: dict, role: str = "stop", arrival_date: str | None = None,
              departure_date: str | None = None, arrival_time: str | None = None,
              departure_time: str | None = None, nights: int | None = None,
              notes: str = "") -> dict:
    return {
        "id": new_id("stop"),
        "ref": ref,
        "arrival_date": arrival_date,
        "departure_date": departure_date,
        "arrival_time": arrival_time,
        "departure_time": departure_time,
        "nights": nights,
        "role": role,
        "notes": notes,
    }


def make_leg(mode: str = "flight", note: str = "") -> dict:
    return {"mode": mode if mode in TRANSPORT_MODES else "other", "note": note}


def make_variant(name: str, stops: list[dict] | None = None,
                 legs: list[dict] | None = None, notes: str = "",
                 rating: int | None = None, months: list[str] | None = None,
                 comment: str = "") -> dict:
    return {
        "id": new_id("variant"),
        "name": name,
        "notes": notes,
        "rating": rating,
        "months": list(months or []),
        "comment": comment,
        "stops": list(stops or []),
        "legs": list(legs or []),
    }


def make_trip(name: str, variants: list[dict] | None = None) -> dict:
    variants = list(variants) if variants else [make_variant("Variant 1")]
    return {
        "id": new_id("trip"),
        "name": name,
        "created": datetime.now().isoformat(timespec="seconds"),
        "active_variant_id": variants[0]["id"],
        "variants": variants,
    }


# ── normalization (tolerant loading) ─────────────────────────────────────────

def _s(v, default=None):
    return v if isinstance(v, str) else default


def normalize_ref(ref: dict | None) -> dict:
    ref = ref if isinstance(ref, dict) else {}
    lat, lon = ref.get("lat"), ref.get("lon")
    return make_ref(
        ref.get("kind") if ref.get("kind") in STOP_KINDS else "custom",
        str(ref.get("name") or "Unnamed stop"),
        _s(ref.get("country")),
        float(lat) if isinstance(lat, (int, float)) else None,
        float(lon) if isinstance(lon, (int, float)) else None,
    )


def normalize_stop(stop: dict | None) -> dict:
    stop = stop if isinstance(stop, dict) else {}
    nights = stop.get("nights")
    return {
        "id": _s(stop.get("id")) or new_id("stop"),
        "ref": normalize_ref(stop.get("ref")),
        "arrival_date": _s(stop.get("arrival_date")),
        "departure_date": _s(stop.get("departure_date")),
        "arrival_time": _s(stop.get("arrival_time")),
        "departure_time": _s(stop.get("departure_time")),
        "nights": int(nights) if isinstance(nights, (int, float)) else None,
        "role": stop.get("role") if stop.get("role") in STOP_ROLES else "stop",
        "notes": str(stop.get("notes") or ""),
    }


def normalize_leg(leg: dict | None) -> dict:
    leg = leg if isinstance(leg, dict) else {}
    return make_leg(leg.get("mode") or "flight", str(leg.get("note") or ""))


def normalize_variant(variant: dict | None) -> dict:
    variant = variant if isinstance(variant, dict) else {}
    stops = [normalize_stop(s) for s in (variant.get("stops") or [])]
    legs = [normalize_leg(l) for l in (variant.get("legs") or [])]
    # enforce the positional-legs invariant
    want = max(0, len(stops) - 1)
    if len(legs) > want:
        legs = legs[:want]
    while len(legs) < want:
        legs.append(make_leg())
    rating = variant.get("rating")
    months = [str(m) for m in (variant.get("months") or [])]
    return {
        "id": _s(variant.get("id")) or new_id("variant"),
        "name": str(variant.get("name") or "Variant"),
        "notes": str(variant.get("notes") or ""),
        "rating": int(rating) if isinstance(rating, (int, float)) else None,
        "months": months,
        "comment": str(variant.get("comment") or ""),
        "stops": stops,
        "legs": legs,
    }


def normalize_trip(trip: dict | None) -> dict:
    trip = trip if isinstance(trip, dict) else {}
    variants = [normalize_variant(v) for v in (trip.get("variants") or [])]
    if not variants:
        variants = [make_variant("Variant 1")]
    active = trip.get("active_variant_id")
    if active not in {v["id"] for v in variants}:
        active = variants[0]["id"]
    return {
        "id": _s(trip.get("id")) or new_id("trip"),
        "name": str(trip.get("name") or "Untitled trip"),
        "created": _s(trip.get("created"))
        or datetime.now().isoformat(timespec="seconds"),
        "active_variant_id": active,
        "variants": variants,
    }


def normalize_all(data: dict | None) -> dict:
    data = data if isinstance(data, dict) else {}
    return {
        "schema_version": SCHEMA_VERSION,
        "trips": [normalize_trip(t) for t in (data.get("trips") or [])],
    }


# ── lookups ──────────────────────────────────────────────────────────────────

def find_trip(data: dict, trip_id: str) -> dict | None:
    for trip in data.get("trips", []):
        if trip["id"] == trip_id:
            return trip
    return None


def find_variant(trip: dict, variant_id: str | None) -> dict | None:
    for variant in trip.get("variants", []):
        if variant["id"] == variant_id:
            return variant
    return None


def active_variant(trip: dict) -> dict | None:
    return find_variant(trip, trip.get("active_variant_id"))
