"""Geography: coordinate sources, great-circle math, arrowheads, view fitting.

Coordinate resolution order for a stop ref:
  1. coords already stored on the ref (added at stop-creation time)
  2. workbook destination table (city_coordinates.json, name-insensitive)
  3. bundled gateway coordinates (Frankfurt home)
Anything unresolved stays (lat, lon) = (None, None) -> validation warning.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COORDS_PATH = ROOT / "city_coordinates.json"

HOME_GATEWAY = {"kind": "gateway", "name": "Frankfurt", "country": "Germany",
                "lat": 50.1109, "lon": 8.6821}

EARTH_RADIUS_KM = 6371.0


def _norm_name(name: str) -> str:
    return " ".join(str(name).casefold().split())


def load_coords_index() -> dict[str, dict]:
    """{normalized destination/city name -> {name, country, lat, lon}}.

    Both the raw normalized form ("xi'an") and a punctuation-stripped alias
    ("xian") are indexed so user-typed variants still match.
    """
    index: dict[str, dict] = {}
    try:
        raw = json.loads(COORDS_PATH.read_text(encoding="utf-8"))
    except Exception:
        return index
    for entry in raw.values():
        item = {"name": entry.get("city") or entry.get("destination"),
                "country": entry.get("country"),
                "lat": entry.get("lat"), "lon": entry.get("lon")}
        for key in (entry.get("destination"), entry.get("city")):
            if key:
                norm = _norm_name(key)
                index.setdefault(norm, item)
                index.setdefault(norm.replace("'", "").replace(".", ""), item)
    return index


def resolve_ref(ref: dict, coords_index: dict[str, dict] | None = None) -> dict:
    """Return a copy of ``ref`` with lat/lon filled in if at all possible."""
    out = dict(ref)
    if out.get("lat") is not None and out.get("lon") is not None:
        return out
    idx = coords_index if coords_index is not None else load_coords_index()
    name = _norm_name(out.get("name", ""))
    hit = idx.get(name) or idx.get(name.replace("'", "").replace(".", ""))
    if hit:
        out["lat"], out["lon"] = hit["lat"], hit["lon"]
        if not out.get("country"):
            out["country"] = hit.get("country")
    return out


# ── spherical math ───────────────────────────────────────────────────────────

def _rad(deg: float) -> float:
    return deg * math.pi / 180.0


def _deg(rad: float) -> float:
    return rad * 180.0 / math.pi


def angular_distance_deg(lat1: float, lon1: float,
                         lat2: float, lon2: float) -> float:
    """Central angle between two points, in degrees."""
    p1, p2 = _rad(lat1), _rad(lat2)
    dl = _rad(lon2 - lon1)
    a = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return _deg(2 * math.asin(min(1.0, math.sqrt(a))))


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    return angular_distance_deg(lat1, lon1, lat2, lon2) * math.pi / 180.0 \
        * EARTH_RADIUS_KM


def initial_bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Compass bearing (degrees 0-360) from point 1 to point 2."""
    p1, p2 = _rad(lat1), _rad(lat2)
    dl = _rad(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = (math.cos(p1) * math.sin(p2)
         - math.sin(p1) * math.cos(p2) * math.cos(dl))
    return (_deg(math.atan2(y, x)) + 360.0) % 360.0


def direct_point(lat: float, lon: float, bearing_deg: float,
                 angular_deg: float) -> tuple[float, float]:
    """Point reached from (lat, lon) going ``bearing_deg`` for ``angular_deg``."""
    p1, d = _rad(lat), _rad(angular_deg)
    br = _rad(bearing_deg)
    p2 = math.asin(math.sin(p1) * math.cos(d)
                   + math.cos(p1) * math.sin(d) * math.cos(br))
    l1 = _rad(lon)
    l2 = l1 + math.atan2(math.sin(br) * math.sin(d) * math.cos(p1),
                         math.cos(d) - math.sin(p1) * math.sin(p2))
    return _deg(p2), (_deg(l2) + 540.0) % 360.0 - 180.0


def great_circle_points(lat1: float, lon1: float, lat2: float, lon2: float,
                        n: int = 24) -> list[tuple[float, float]]:
    """Densified great-circle path (n segments, inclusive endpoints)."""
    if n < 1:
        n = 1
    p1, p2 = _rad(lat1), _rad(lat2)
    l1, l2 = _rad(lon1), _rad(lon2)
    d = 2 * math.asin(min(1.0, math.sqrt(
        math.sin((p2 - p1) / 2) ** 2
        + math.cos(p1) * math.cos(p2) * math.sin((l2 - l1) / 2) ** 2)))
    pts: list[tuple[float, float]] = []
    if d < 1e-9:  # identical points
        return [(lat1, lon1), (lat2, lon2)]
    sin_d = math.sin(d)
    for i in range(n + 1):
        t = i / n
        a = math.sin((1 - t) * d) / sin_d
        b = math.sin(t * d) / sin_d
        x = a * math.cos(p1) * math.cos(l1) + b * math.cos(p2) * math.cos(l2)
        y = a * math.cos(p1) * math.sin(l1) + b * math.cos(p2) * math.sin(l2)
        z = a * math.sin(p1) + b * math.sin(p2)
        pts.append((_deg(math.atan2(z, math.hypot(x, y))),
                    _deg(math.atan2(y, x))))
    return pts


def arrow_wings(pts: list[tuple[float, float]]
                ) -> list[tuple[float, float]]:
    """Arrowhead V-wings for a densified polyline.

    The bearing is measured from a LOCAL segment (t=0.50 -> t=0.55) so the
    arrow points the way the line actually draws even on curved long legs.
    Wing length scales with the leg length (clamped 0.5°..2°).
    Returns [] for degenerate paths; otherwise the wing points are meant to
    be drawn as tip->wing sequences separated from the line by a None gap.
    """
    if len(pts) < 3:
        return []
    i_tail = max(0, int(len(pts) * 0.50) - 1)
    i_tip = min(len(pts) - 1, int(len(pts) * 0.55) + 1)
    tail_lat, tail_lon = pts[i_tail]
    tip_lat, tip_lon = pts[i_tip]
    brg = initial_bearing(tail_lat, tail_lon, tip_lat, tip_lon)
    wing_len = min(2.0, max(0.5, 0.008 * angular_distance_deg(
        pts[0][0], pts[0][1], pts[-1][0], pts[-1][1])))
    left = direct_point(tip_lat, tip_lon, (brg + 140) % 360, wing_len)
    right = direct_point(tip_lat, tip_lon, (brg - 140) % 360, wing_len)
    tip = (tip_lat, tip_lon)
    return [tip, left, tip, right]


def unwrap_longitudes(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Shift each longitude by multiples of 360 so the path stays continuous.

    Great-circle interpolation runs off the end of the longitude scale (Tokyo
    139.7°E -> Los Angeles -118.2°W passes through 180, 200, 220...). Feeding
    those raw values to :func:`fit_view` produced a 398°-wide axis centred
    nowhere, which is what a transpacific itinerary used to render as.
    """
    if not points:
        return []
    out: list[tuple[float, float]] = [(points[0][0], points[0][1])]
    offset = 0.0
    previous = points[0][1]
    for lat, lon in points[1:]:
        candidate = lon + offset
        while candidate - previous > 180:
            offset -= 360.0
            candidate -= 360.0
        while previous - candidate > 180:
            offset += 360.0
            candidate += 360.0
        out.append((lat, candidate))
        previous = candidate
    return out


def fit_view(points: list[tuple[float, float]], pad_frac: float = 0.06
             ) -> dict:
    """Plotly geo layout dict (center + lon/lat ranges) framing the points."""
    if not points:
        return {"center": {"lat": 20, "lon": 10},
                "lonaxis": {"range": [-140, 140]},
                "lataxis": {"range": [-60, 75]}}
    points = unwrap_longitudes(points)
    lats = [p[0] for p in points]
    lons = [p[1] for p in points]
    lat_min, lat_max = min(lats), max(lats)
    lon_min, lon_max = min(lons), max(lons)
    lat_pad = max(1.5, (lat_max - lat_min) * pad_frac)
    lon_pad = max(1.5, (lon_max - lon_min) * pad_frac)
    return {
        "center": {"lat": (lat_min + lat_max) / 2,
                   "lon": (lon_min + lon_max) / 2},
        "lonaxis": {"range": [lon_min - lon_pad, lon_max + lon_pad]},
        "lataxis": {"range": [lat_min - lat_pad, lat_max + lat_pad]},
    }
