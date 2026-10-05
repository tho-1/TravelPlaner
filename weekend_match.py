"""Pure weekend-trip matching: flights + time windows -> ranked cities.

No network, no Streamlit, no workbook. Everything the finder decides lives here
so it can be tested with fixtures and reasoned about without a browser.

The rules, as the user specified them
-------------------------------------
Outbound (direct FRA -> X, benefit airline), departs **Friday >= x** or
**Saturday < y**.
Return (direct X -> FRA, benefit airline), lands **Saturday >= z**, **Sunday any
time**, or **Monday < w**.
Both legs must qualify for a city to appear in the main list. Cities that have
one qualifying leg only are returned separately so the near misses are visible
instead of silently missing.

Times are naive local (Europe/Berlin) ``datetime`` objects; the caller is
responsible for the timezone.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from typing import Iterable

HOME_AIRPORT = "FRA"

FRIDAY = 4
SATURDAY = 5
SUNDAY = 6
MONDAY = 0


@dataclass(frozen=True)
class Flight:
    """One scheduled flight, as the scrapers report it."""

    flight_no: str
    airline: str
    origin: str
    destination: str
    departure: datetime
    arrival: datetime
    operated_by: str = ""
    terminal: str = ""

    @property
    def operator_airline(self) -> str:
        """The carrier actually flying the metal: benefits follow the operator."""
        return (self.operated_by or self.airline or "").strip()

    @property
    def marketing_airline(self) -> str:
        return (self.airline or "").strip()


@dataclass
class Windows:
    """The user's six time bounds, all local to the departure airport."""

    friday_from: time = time(14, 0)
    saturday_before: time = time(12, 0)
    saturday_return_after: time = time(12, 0)
    monday_return_before: time = time(9, 0)
    sunday_return_until: time | None = None

    def describe(self) -> str:
        sunday = ("any time" if self.sunday_return_until is None
                  else f"before {self.sunday_return_until:%H:%M}")
        return (f"out: Fri from {self.friday_from:%H:%M} or Sat before "
                f"{self.saturday_before:%H:%M} · back: Sat after "
                f"{self.saturday_return_after:%H:%M}, Sun {sunday}, or Mon "
                f"before {self.monday_return_before:%H:%M}")


@dataclass
class Weekend:
    """The Friday (and its Sat/Sun/Mon) that a search is about."""

    friday: date

    @property
    def saturday(self) -> date:
        return self.friday + timedelta(days=1)

    @property
    def sunday(self) -> date:
        return self.friday + timedelta(days=2)

    @property
    def monday(self) -> date:
        return self.friday + timedelta(days=3)

    @property
    def days(self) -> tuple[date, ...]:
        return (self.friday, self.saturday, self.sunday, self.monday)

    def describe(self) -> str:
        return f"{self.friday:%Y-%m-%d} to {self.monday:%Y-%m-%d}"


@dataclass
class TripOption:
    """One way to spend the weekend in one city."""

    city: str
    country: str
    out_flight: Flight
    back_flight: Flight
    nights: int = 0
    notes: str = ""

    @property
    def outbound_airline(self) -> str:
        return self.out_flight.operator_airline

    @property
    def return_airline(self) -> str:
        return self.back_flight.operator_airline

    @property
    def label(self) -> str:
        return f"{self.city} ({self.country})"


@dataclass
class CityResult:
    """Every viable weekend in one city, plus the airports that serve it."""

    city: str
    country: str
    options: list[TripOption] = field(default_factory=list)
    airports: set[str] = field(default_factory=set)
    out_only: list[Flight] = field(default_factory=list)
    back_only: list[Flight] = field(default_factory=list)
    unmapped_airports: set[str] = field(default_factory=set)

    @property
    def label(self) -> str:
        return f"{self.city} ({self.country})"

    @property
    def count(self) -> int:
        return len(self.options)

    def sort_key(self):
        """Earliest departure first, then fewest nights, then name."""
        return (self.options[0].out_flight.departure,
                self.options[0].nights,
                self.city)


@dataclass
class MatchReport:
    """Everything the page needs to explain what it did."""

    weekend: Weekend
    windows: Windows
    cities: list[CityResult] = field(default_factory=list)
    one_way_only: list[CityResult] = field(default_factory=list)
    outbound_total: int = 0
    return_total: int = 0
    outbound_rejected_airlines: dict[str, int] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    @property
    def city_count(self) -> int:
        return len(self.cities)

    @property
    def option_count(self) -> int:
        return sum(result.count for result in self.cities)


def weekend_containing(day: date) -> Weekend:
    """The Fri/Sat/Sun/Monday that ``day`` belongs to.

    A Monday belongs to the weekend that is *starting*, i.e. the coming Friday,
    which is how the finder is used: on a Monday you plan the weekend ahead.
    A Saturday or Sunday belongs to the Friday that started it.
    """
    weekday = day.weekday()
    if weekday == MONDAY:
        return Weekend(friday=day + timedelta(days=4))
    if weekday in (SATURDAY, SUNDAY):
        return Weekend(friday=day - timedelta(days=weekday - FRIDAY))
    if weekday == FRIDAY:
        return Weekend(friday=day)
    # Tue/Wed/Thu: the Friday of the same week, i.e. in a few days.
    return Weekend(friday=day + timedelta(days=(FRIDAY - weekday)))


def next_friday(today: date, minimum_days_ahead: int = 0) -> date:
    """The first Friday at least ``minimum_days_ahead`` days after ``today``.

    ``minimum_days_ahead`` exists because a weekend's schedule only becomes
    useful once it is published: ask for too little lead time and you get a
    board that is still empty, which is worse than the following weekend.
    """
    ahead = (FRIDAY - today.weekday()) % 7
    if ahead == 0:
        ahead = 7                     # today is Friday: mean the coming one
    while ahead < minimum_days_ahead:
        ahead += 7
    return today + timedelta(days=ahead)


# ── the filters ──────────────────────────────────────────────────────────────

def is_outbound_candidate(flight: Flight, weekend: Weekend,
                          windows: Windows) -> bool:
    """True when the flight leaves on a Friday or Saturday inside the window."""
    dep = flight.departure
    if not _is_direct_from_home(flight):
        return False
    if dep.date() == weekend.friday:
        return dep.time() >= windows.friday_from
    if dep.date() == weekend.saturday:
        return dep.time() < windows.saturday_before
    return False


def is_return_candidate(flight: Flight, weekend: Weekend,
                        windows: Windows) -> bool:
    """True when the flight lands Sat (after z), Sun, or Mon (before w)."""
    arr = flight.arrival
    if not _is_direct_to_home(flight):
        return False
    if arr.date() == weekend.saturday:
        return arr.time() >= windows.saturday_return_after
    if arr.date() == weekend.sunday:
        if windows.sunday_return_until is None:
            return True
        return arr.time() <= windows.sunday_return_until
    if arr.date() == weekend.monday:
        return arr.time() < windows.monday_return_before
    return False


def _is_direct_from_home(flight: Flight) -> bool:
    return _airport(flight.origin) == HOME_AIRPORT


def _is_direct_to_home(flight: Flight) -> bool:
    return _airport(flight.destination) == HOME_AIRPORT


def _airport(code: object) -> str:
    return str(code or "").strip().upper()


def nights_away(out_flight: Flight, back_flight: Flight) -> int:
    """Nights between landing and taking off, floored at zero.

    An overnight return that lands the same morning it departed would give a
    negative number; that is a same-day trip, not a negative stay.
    """
    return max(0, (back_flight.departure.date()
                   - out_flight.arrival.date()).days)


def find_weekends(
    outbound: Iterable[Flight],
    returns: Iterable[Flight],
    weekend: Weekend,
    windows: Windows,
    benefit_check,
    city_lookup,
    *,
    max_options_per_city: int = 6,
) -> MatchReport:
    """Build the full result set.

    ``benefit_check(airline) -> bool`` and
    ``city_lookup(airport_code) -> (city, country) | None`` are injected so this
    module stays free of the workbook and of the benefit sheet.
    """
    out_list = list(outbound)
    back_list = list(returns)
    report = MatchReport(weekend=weekend, windows=windows)
    report.outbound_total = len(out_list)
    report.return_total = len(back_list)

    good_out: list[Flight] = []
    for flight in out_list:
        if not is_outbound_candidate(flight, weekend, windows):
            continue
        if not benefit_check(flight.operator_airline):
            name = flight.operator_airline or "?"
            report.outbound_rejected_airlines[name] = \
                report.outbound_rejected_airlines.get(name, 0) + 1
            continue
        good_out.append(flight)

    good_back: list[Flight] = []
    for flight in back_list:
        if not is_return_candidate(flight, weekend, windows):
            continue
        if not benefit_check(flight.operator_airline):
            continue
        good_back.append(flight)

    # Group returns by destination airport so the pairing is cheap.
    back_by_airport: dict[str, list[Flight]] = {}
    for flight in good_back:
        back_by_airport.setdefault(_airport(flight.origin), []).append(flight)
    for flights in back_by_airport.values():
        flights.sort(key=lambda f: f.departure)

    out_by_airport: dict[str, list[Flight]] = {}
    for flight in good_out:
        out_by_airport.setdefault(_airport(flight.destination), []).append(flight)

    cities: dict[tuple[str, str], CityResult] = {}

    for airport, outs in out_by_airport.items():
        location = city_lookup(airport)
        key = (location[0], location[1]) if location else (f"?{airport}", "")
        result = cities.setdefault(
            key, CityResult(city=key[0], country=key[1]))
        result.airports.add(airport)
        if location is None:
            result.unmapped_airports.add(airport)

        pairs: list[TripOption] = []
        for out_flight in sorted(outs, key=lambda f: f.departure):
            for back_flight in back_by_airport.get(airport, []):
                if back_flight.departure < out_flight.arrival:
                    continue                     # cannot leave before landing
                pairs.append(TripOption(
                    city=result.city, country=result.country,
                    out_flight=out_flight, back_flight=back_flight,
                    nights=nights_away(out_flight, back_flight),
                ))
                if len(pairs) >= max_options_per_city * 3:
                    break
            if len(pairs) >= max_options_per_city * 3:
                break

        if pairs:
            result.options = _best_options(pairs, max_options_per_city)
        else:
            result.out_only = sorted(outs, key=lambda f: f.departure)[:4]

    # A city whose only qualifying leg is the return still counts as a near miss.
    for airport, backs in back_by_airport.items():
        location = city_lookup(airport)
        key = (location[0], location[1]) if location else (f"?{airport}", "")
        result = cities.get(key)
        if result is not None and result.options:
            continue
        if result is None:
            result = cities.setdefault(key, CityResult(city=key[0],
                                                       country=key[1]))
            result.airports.add(airport)
            if location is None:
                result.unmapped_airports.add(airport)
        if not result.back_only:
            result.back_only = list(backs[:4])

    full = [r for r in cities.values() if r.options]
    partial = [r for r in cities.values() if not r.options
               and (r.out_only or r.back_only)]
    full.sort(key=CityResult.sort_key)
    partial.sort(key=lambda r: (r.city, r.country))
    report.cities = full
    report.one_way_only = partial
    return report


def _best_options(pairs: list[TripOption], limit: int) -> list[TripOption]:
    """Prefer: fewer nights, then earlier departure, then a Sunday return.

    A Saturday-evening return beats a Monday-06:00 one for the same city, which
    is the whole point of a weekend finder.
    """
    def rank(option: TripOption):
        back_day = option.back_flight.arrival.date().weekday()
        day_rank = {MONDAY: 0, SUNDAY: 1, SATURDAY: 2}.get(back_day, 3)
        return (option.nights, day_rank, option.out_flight.departure,
                option.back_flight.departure)

    ordered = sorted(pairs, key=rank)
    # One option per (out, back) flight pair; never the same flight twice.
    seen: set[tuple[str, str]] = set()
    out_count: dict[str, int] = {}
    chosen: list[TripOption] = []
    for option in ordered:
        signature = (option.out_flight.flight_no, option.back_flight.flight_no)
        if signature in seen:
            continue
        seen.add(signature)
        key = option.out_flight.flight_no
        if out_count.get(key, 0) >= 2:
            continue              # at most two ways home per outbound flight
        out_count[key] = out_count.get(key, 0) + 1
        chosen.append(option)
        if len(chosen) >= limit:
            break
    return chosen


def describe_rule(rejected: dict[str, int]) -> str:
    """A one-line explanation of what the airline filter removed."""
    if not rejected:
        return ""
    total = sum(rejected.values())
    top = sorted(rejected.items(), key=lambda kv: -kv[1])[:4]
    names = ", ".join(f"{name} ({count})" for name, count in top)
    more = "" if len(rejected) <= 4 else f", +{len(rejected) - 4} more"
    return f"{total} outbound flight(s) dropped for airlines without benefits: {names}{more}"


def parse_flight_time(text: str, day: date) -> datetime | None:
    """Parse a board's time field. Returns ``None`` rather than guessing.

    Boards print "14:05", "14:05+1" (arriving next day) and occasionally "-".
    An unparseable time is dropped instead of being silently assumed midnight.
    """
    raw = str(text or "").strip()
    if not raw or raw in {"-", "--", "n/a"}:
        return None
    next_day = False
    if raw.endswith("+1"):
        raw = raw[:-2].strip()
        next_day = True
    parts = raw.split(":")
    try:
        hour = int(parts[0])
        minute = int(parts[1]) if len(parts) > 1 else 0
    except (ValueError, IndexError):
        return None
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    stamp = datetime.combine(day, time(hour, minute))
    return stamp + timedelta(days=1) if next_day else stamp


def midnight(day: date) -> datetime:
    return datetime.combine(day, time(0, 0))


if __name__ == "__main__":  # pragma: no cover - manual smoke check
    upcoming = weekend_containing(date(2026, 10, 5))   # a Monday
    print("weekend for Mon 2026-10-05:", upcoming.describe())
    print(Windows().describe())