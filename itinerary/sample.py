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
    """A *plausible* China round trip from Frankfurt (two variants).

    Variant A "Return via Beijing": FRA -> Beijing -> Xi'an -> Shanghai ->
    Beijing (high-speed rail) -> FRA. Variant B returns straight from Shanghai.
    Every arrival is at or after the previous stop's departure: an 11-hour
    flight with a +8 h offset cannot arrive on the day it left, and the previous
    version of this sample claimed a *train* from Shanghai to Frankfurt.
    """
    fra = _stop("Frankfurt", "Germany", 50.1109, 8.6821, kind="gateway",
                role="origin", dep="2027-04-01", dep_t="10:00")
    beijing = _stop("Beijing", "China", 39.9042, 116.4074,
                    arr="2027-04-02", dep="2027-04-05", arr_t="05:00",
                    dep_t="09:00", nights=3)
    xian = _stop("Xi'an", "China", 34.3416, 108.9398,
                 arr="2027-04-05", dep="2027-04-08", arr_t="10:00",
                 dep_t="15:00", nights=3)
    shanghai = _stop("Shanghai", "China", 31.2304, 121.4737,
                     arr="2027-04-08", dep="2027-04-12", arr_t="14:00",
                     nights=4)
    beijing_back = _stop("Beijing", "China", 39.9042, 116.4074,
                         arr="2027-04-12", dep="2027-04-14", arr_t="15:30",
                         dep_t="11:00", nights=1)
    home_again = _stop("Frankfurt", "Germany", 50.1109, 8.6821, kind="gateway",
                       role="return", arr="2027-04-14", arr_t="18:00")

    stops_a = [
        fra,
        models.make_stop(dict(beijing["ref"]), role="stop",
                         arrival_date="2027-04-02", departure_date="2027-04-05",
                         arrival_time="05:00", departure_time="09:00",
                         nights=3),
        models.make_stop(dict(xian["ref"]), role="stop",
                         arrival_date="2027-04-05", departure_date="2027-04-08",
                         arrival_time="10:00", departure_time="15:00",
                         nights=3),
        models.make_stop(dict(shanghai["ref"]), role="stop",
                         arrival_date="2027-04-08", departure_date="2027-04-12",
                         arrival_time="14:00", nights=4),
        models.make_stop(dict(beijing_back["ref"]), role="stop",
                         arrival_date="2027-04-12", departure_date="2027-04-14",
                         arrival_time="15:30", departure_time="11:00",
                         nights=1),
        models.make_stop(dict(home_again["ref"]), role="return",
                         arrival_date="2027-04-14", arrival_time="18:00"),
    ]
    legs_a = [models.make_leg("flight"), models.make_leg("flight"),
              models.make_leg("flight"), models.make_leg("train"),
              models.make_leg("flight")]

    stops_b = [
        models.make_stop(dict(s["ref"]), role=s["role"],
                         arrival_date=s.get("arrival_date"),
                         departure_date=s.get("departure_date"),
                         arrival_time=s.get("arrival_time"),
                         departure_time=s.get("departure_time"),
                         nights=s.get("nights"))
        for s in stops_a[:4]
    ] + [models.make_stop(dict(home_again["ref"]), role="return",
                          arrival_date="2027-04-12", arrival_time="16:00")]

    variant_a = models.make_variant(
        "Return via Beijing", stops_a, legs_a,
        comment="Classic northern loop; high-speed rail back from Shanghai to "
                "Beijing for the return flight.")
    variant_b = models.make_variant(
        "Return via Shanghai", stops_b,
        [models.make_leg("flight"), models.make_leg("flight"),
         models.make_leg("flight"), models.make_leg("flight")],
        comment="Skip the backtrack — fly home directly from Shanghai (PVG).")

    trip = models.make_trip("China Trip 2027", [variant_a, variant_b])
    trip["active_variant_id"] = variant_a["id"]
    return trip
