"""Bundled sample trip: China 2027 round trip from Frankfurt.

Built entirely from make_* builders with explicit coordinates, so seeding
works offline and deterministically. Two variants demonstrate comparison:
- "Return via Beijing": FRA → Beijing → Xi'an → Shanghai → Beijing → (FRA)
- "Return via Shanghai": same route without the final Beijing hop.
"""

from __future__ import annotations

from . import models


def _stop(name: str, country: str, lat: float, lon: float, *,
          kind: str = "destination", role: str = "stop",
          arr: str | None = None, dep: str | None = None,
          arr_t: str | None = None, dep_t: str | None = None,
          nights: int | None = None, notes: str = "") -> dict:
    return models.make_stop(
        models.make_ref(kind, name, country, lat, lon),
        role=role, arrival_date=arr, departure_date=dep,
        arrival_time=arr_t, departure_time=dep_t, nights=nights, notes=notes)


def make_sample_trip() -> dict:
    fra = _stop("Frankfurt", "Germany", 50.1109, 8.6821, kind="gateway",
                role="origin", dep="2027-04-01", dep_t="10:00")
    beijing = _stop("Beijing", "China", 39.9042, 116.4074,
                    arr="2027-04-01", dep="2027-04-04", arr_t="05:00",
                    dep_t="09:00", nights=3)
    xian = _stop("Xi'an", "China", 34.3416, 108.9398,
                 arr="2027-04-04", dep="2027-04-07", arr_t="10:00",
                 dep_t="15:00", nights=3)
    shanghai = _stop("Shanghai", "China", 31.2304, 121.4737,
                     arr="2027-04-07", dep="2027-04-11", nights=4)

    stops_a = [
        fra,
        models.make_stop(dict(beijing["ref"]), role="stop",
                         arrival_date="2027-04-01", departure_date="2027-04-04",
                         arrival_time="05:00", departure_time="09:00",
                         nights=3),
        models.make_stop(dict(xian["ref"]), role="stop",
                         arrival_date="2027-04-04", departure_date="2027-04-07",
                         arrival_time="10:00", departure_time="15:00",
                         nights=3),
        models.make_stop(dict(shanghai["ref"]), role="stop",
                         arrival_date="2027-04-07", departure_date="2027-04-11",
                         nights=4),
        models.make_stop(models.make_ref("gateway", "Frankfurt", "Germany",
                                         50.1109, 8.6821),
                         role="return", arrival_date="2027-04-11"),
    ]
    legs_a = [models.make_leg("flight"), models.make_leg("flight"),
              models.make_leg("flight"), models.make_leg("train")]

    stops_b = stops_a[:4]  # same route, ends in Shanghai
    stops_b = [
        models.make_stop(dict(s["ref"]), role=s["role"],
                         arrival_date=s.get("arrival_date"),
                         departure_date=s.get("departure_date"),
                         arrival_time=s.get("arrival_time"),
                         departure_time=s.get("departure_time"),
                         nights=s.get("nights")) for s in stops_a[:4]
    ]

    variant_a = models.make_variant(
        "Return via Beijing", stops_a, legs_a,
        comment="Classic northern loop; fast train back from Shanghai to "
                "Beijing for the return flight.")
    variant_b = models.make_variant(
        "Return via Shanghai", stops_b,
        [models.make_leg("flight"), models.make_leg("flight"),
         models.make_leg("flight")],
        comment="Skip the backtrack — fly home directly from Shanghai (PVG).")

    trip = models.make_trip("China Trip 2027", [variant_a, variant_b])
    trip["active_variant_id"] = variant_a["id"]
    return trip
