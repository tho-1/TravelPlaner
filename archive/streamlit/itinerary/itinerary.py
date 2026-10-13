"""Variant/stop operations, totals, warnings, month suggestions.

All functions are pure (data in -> data out / in-place edits of plain dicts)
and Streamlit-free, so they can be unit-tested headlessly.

Leg invariants (see models.py): ``legs[i]`` sits between ``stops[i]`` and
``stops[i+1]``. ``remove_stop(i)`` therefore deletes ``legs[max(i-1, 0)]`` —
the leg that pointed INTO the removed stop. ``move_stop`` only reorders
adjacent stops; the gap between them keeps its transport, so legs stay valid.
"""

from __future__ import annotations

import copy
import re
import unicodedata
from datetime import date, datetime

from . import models

MONTHS = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]
MONTH_SHORT = {m: m[:3] for m in MONTHS}

# workbook "best time" vocabulary that counts as a good month
GOOD_MONTH_VALUES = {"ideal", "good", "great", "best", "green"}

ROLES: dict[str, dict] = {
    "origin":  {"label": "▶ Origin",    "bgcolor": "#f1f8ff"},
    "stop":    {"label": "📍 Stop",     "bgcolor": "#ffffff"},
    "return":  {"label": "🏁 Return",   "bgcolor": "#fffaf0"},
}


# ── trip / variant management ────────────────────────────────────────────────

def create_trip(data: dict, name: str) -> dict:
    trip = models.make_trip(name)
    data["trips"].append(trip)
    return trip


def duplicate_trip(data: dict, trip_id: str) -> dict | None:
    src = models.find_trip(data, trip_id)
    if src is None:
        return None
    clone = copy.deepcopy(src)
    clone["id"] = models.new_id("trip")
    clone["name"] = f"{src['name']} (copy)"
    clone["created"] = datetime.now().isoformat(timespec="seconds")
    for variant in clone["variants"]:
        variant["id"] = models.new_id("variant")
        for stop in variant["stops"]:
            stop["id"] = models.new_id("stop")
    # keep pointing at the cloned active variant
    old_active = src.get("active_variant_id")
    idx = next((i for i, v in enumerate(src["variants"])
                if v["id"] == old_active), 0)
    clone["active_variant_id"] = clone["variants"][idx]["id"]
    data["trips"].append(clone)
    return clone


def delete_trip(data: dict, trip_id: str) -> None:
    data["trips"] = [t for t in data["trips"] if t["id"] != trip_id]


def rename_trip(trip: dict, name: str) -> None:
    trip["name"] = name.strip() or trip["name"]


def create_variant(trip: dict, name: str) -> dict:
    variant = models.make_variant(name or "Variant",
                                  copy.deepcopy(active_variant(trip)["stops"]),
                                  copy.deepcopy(active_variant(trip)["legs"]))
    if not variant["stops"]:
        variant = models.make_variant(name or "Variant")
    trip["variants"].append(variant)
    return variant


def duplicate_variant(trip: dict, variant_id: str) -> dict | None:
    src = models.find_variant(trip, variant_id)
    if src is None:
        return None
    clone = copy.deepcopy(src)
    clone["id"] = models.new_id("variant")
    clone["name"] = f"{src['name']} (copy)"
    for stop in clone["stops"]:
        stop["id"] = models.new_id("stop")
    trip["variants"].append(clone)
    return clone


def delete_variant(trip: dict, variant_id: str) -> None:
    if len(trip["variants"]) <= 1:
        return  # a trip always keeps at least one variant
    trip["variants"] = [v for v in trip["variants"] if v["id"] != variant_id]
    if trip.get("active_variant_id") == variant_id:
        trip["active_variant_id"] = trip["variants"][0]["id"]


def set_active_variant(trip: dict, variant_id: str) -> None:
    if models.find_variant(trip, variant_id) is not None:
        trip["active_variant_id"] = variant_id


def active_variant(trip: dict) -> dict | None:
    return models.active_variant(trip)


# ── stop operations (legs stay positional & consistent) ─────────────────────

def add_stop(variant: dict, ref: dict, role: str = "stop", at: int | None = None,
             **kwargs) -> dict:
    """Append or insert a stop; a matching leg placeholder is inserted too."""
    stop = models.make_stop(ref, role=role, **kwargs)
    if at is None or at >= len(variant["stops"]):
        variant["stops"].append(stop)
        if len(variant["stops"]) > 1:
            variant["legs"].append(models.make_leg())
    else:
        at = max(0, at)
        variant["stops"].insert(at, stop)
        variant["legs"].insert(max(at - 1, 0), models.make_leg())
    return stop


def remove_stop(variant: dict, index: int) -> None:
    """Remove stop ``index`` and the leg that pointed into it."""
    stops, legs = variant["stops"], variant["legs"]
    if not 0 <= index < len(stops):
        return
    del stops[index]
    if legs:
        del legs[max(index - 1, 0)]


def move_stop(variant: dict, index: int, direction: int) -> int:
    """Swap stop ``index`` with its neighbour; returns the new index.

    Legs are positional gaps and are left UNTOUCHED: the transport of gap i
    stays attached to positions (i, i+1) regardless of which stop sits there.
    Swapping FRA-flight-A-train-B to FRA-B-A therefore means "fly FRA→B,
    train B→A" — the A↔B train stays on the A-B gap, which is what a
    traveler reordering visits expects.
    """
    target = index + (1 if direction > 0 else -1)
    stops = variant["stops"]
    if not 0 <= index < len(stops) or not 0 <= target < len(stops):
        return index
    stops[index], stops[target] = stops[target], stops[index]
    return target


def set_leg_mode(variant: dict, index: int, mode: str) -> None:
    if 0 <= index < len(variant["legs"]):
        variant["legs"][index]["mode"] = (mode if mode in models.TRANSPORT_MODES
                                          else "other")


def resolve_variant_coords(variant: dict,
                           coords_index: dict | None = None) -> None:
    """Fill in missing lat/lon on every stop ref, in place."""
    from . import geo
    idx = coords_index if coords_index is not None else geo.load_coords_index()
    for stop in variant["stops"]:
        stop["ref"] = geo.resolve_ref(stop["ref"], idx)


# ── totals / warnings ────────────────────────────────────────────────────────

def totals(variant: dict) -> dict:
    stops = variant.get("stops", [])
    legs = variant.get("legs", [])
    out = {
        "stops": len(stops),
        "nights": 0,
        "flights": 0,
        "trains": 0,
        "other": 0,
        "start": None,
        "end": None,
    }
    known_nights = False
    for stop in stops:
        if stop.get("nights") is not None:
            out["nights"] += int(stop["nights"])
            known_nights = True
    # nights from date spans where nights is unset
    for stop in stops:
        if stop.get("nights") is None and stop.get("arrival_date") \
                and stop.get("departure_date"):
            try:
                a = date.fromisoformat(stop["arrival_date"])
                d = date.fromisoformat(stop["departure_date"])
                if d > a:
                    out["nights"] += (d - a).days
                    known_nights = True
            except ValueError:
                pass
    for leg in legs:
        if leg.get("mode") == "flight":
            out["flights"] += 1
        elif leg.get("mode") == "train":
            out["trains"] += 1
        else:
            out["other"] += 1
    dates = []
    for s in stops:
        if s.get("arrival_date"):
            dates.append(s["arrival_date"])
        if s.get("departure_date"):
            dates.append(s["departure_date"])
    dates = sorted(d for d in dates if d)
    if dates:
        out["start"], out["end"] = dates[0], dates[-1]
    out["nights_known"] = known_nights
    return out


def warnings_for(variant: dict) -> list[str]:
    out: list[str] = []
    stops = variant.get("stops", [])
    if not stops:
        return ["No stops yet — add your first destination."]
    if len(stops) == 1:
        out.append("Single stop — add more destinations to build a route.")
    for i, stop in enumerate(stops):
        ref = stop.get("ref", {})
        if ref.get("lat") is None or ref.get("lon") is None:
            out.append(f"'{ref.get('name')}' has no coordinates — "
                       "it will not appear on the map.")
        a, d = stop.get("arrival_date"), stop.get("departure_date")
        role = stop.get("role")
        if a and d:
            try:
                if date.fromisoformat(d) < date.fromisoformat(a):
                    out.append(f"'{ref.get('name')}': departure before arrival.")
            except ValueError:
                out.append(f"'{ref.get('name')}': invalid date format.")
        elif d and not a and role != "origin":
            # origin stops legitimately have only a departure date
            out.append(f"'{ref.get('name')}': departure date without arrival.")
        if stop.get("nights") is not None and int(stop["nights"]) < 0:
            out.append(f"'{ref.get('name')}': negative nights.")
    out.extend(_leg_warnings(stops))
    if variant.get("months") and len(variant["months"]) > 12:
        out.append("More than 12 months selected?!")
    return out


def _leg_warnings(stops: list[dict]) -> list[str]:
    """Flag legs that cannot happen: arriving before the previous departure.

    The per-stop checks cannot see this — an 11-hour flight with a large time
    offset arrives on the *next* day, so identical dates on two consecutive
    stops mean the route is impossible.
    """
    out: list[str] = []
    for i in range(len(stops) - 1):
        here, nxt = stops[i], stops[i + 1]
        dep, arr = here.get("departure_date"), nxt.get("arrival_date")
        if not dep or not arr:
            continue
        try:
            dep_date, arr_date = date.fromisoformat(dep), date.fromisoformat(arr)
        except ValueError:
            continue
        if arr_date < dep_date:
            out.append(
                f"{nxt['ref'].get('name', '?')} arrives {arr} — before leaving "
                f"{here['ref'].get('name', '?')} on {dep}."
            )
    return out


def route_summary(variant: dict) -> str:
    t = totals(variant)
    bits = [f"{t['stops']} stops"]
    if t["nights"]:
        bits.append(f"{t['nights']} nights")
    if t["flights"]:
        bits.append(f"{t['flights']} flights")
    if t["trains"]:
        bits.append(f"{t['trains']} trains")
    if t["other"]:
        bits.append(f"{t['other']} other")
    if t["start"]:
        bits.append(f"{t['start']} → {t['end']}")
    return " · ".join(bits)


# ── month suggestions from the workbook ─────────────────────────────────────

def _dest_name(stop: dict) -> str:
    return str(stop.get("ref", {}).get("name") or "")


def _norm_dest_key(name: str) -> str:
    """Tolerant lookup key: "Xi'an (Shaanxi)" and "Xian" both -> "xian"."""
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"\s*\([^)]*\)", "", s)  # drop "(Province)" suffixes
    return re.sub(r"[^a-z0-9]+", "", s.casefold())


def suggested_months(variant: dict, df, dest_col: str | None = None) -> dict[str, list[str]]:
    """For each 'destination'-kind stop: months where the workbook says the
    destination's climate is good. ``df`` is the destinations DataFrame with
    the destination column plus month-name columns. ``dest_col`` overrides the
    (case-insensitive) 'Destination' lookup. Workbook rows often carry province
    suffixes ("Xi'an (Shaanxi)"), so an exact match is tried first, then a
    normalised one. Core stays Streamlit-free."""
    out: dict[str, list[str]] = {}
    if df is None:
        return out
    dest_col = dest_col or next((c for c in df.columns if c.casefold() == "destination"),
                                None)
    if dest_col is None:
        return out
    month_cols = [c for c in df.columns if str(c).strip() in MONTHS]
    by_name = {str(r[dest_col]).casefold(): r for _, r in df.iterrows()}
    by_norm = {}
    for _, r in df.iterrows():
        key = _norm_dest_key(str(r[dest_col]))
        if key and key not in by_norm:
            by_norm[key] = r
    for stop in variant.get("stops", []):
        if stop.get("ref", {}).get("kind") != "destination":
            continue
        name = _dest_name(stop)
        row = by_name.get(name.casefold())
        if row is None:
            row = by_norm.get(_norm_dest_key(name))
        if row is None:
            continue
        good = []
        for col in month_cols:
            val = str(row[col]).strip().casefold()
            if val and any(g in val for g in GOOD_MONTH_VALUES):
                good.append(str(col).strip())
        if good:
            out[name] = good
    return out
