/// Pure weekend-trip matching: flights + selected travel
/// days -> ranked cities.
///
/// The rules that must not drift, ported rule-for-rule from
/// `weekend_match.py`: outbound direct FRA -> X and return
/// direct X -> FRA; both legs must qualify for a city to
/// appear in the main list; one-leg cities come back
/// separately so near misses are visible instead of silently
/// missing. Which days and times qualify is no longer fixed
/// Thu-Sat / Sat-Tue -- the user selects the days and their
/// any/after/before bounds (see `travel_days.dart`).
///
/// No network, no Turso, no Flutter. Times are naive
/// wall-clock datetimes (the departure airport's local
/// time), the same convention the Python matcher and the
/// board parser keep.
library;

import 'travel_days.dart';

class Flight {
  final String flightNo;
  final String airline;

  /// The board's own carrier name (`alname`), when the
  /// record carries one. The airline *filter* matches on
  /// names ("only Lufthansa"), so the name must survive the
  /// parser -- the code alone cannot say "Lufthansa City".
  final String airlineName;

  final String origin;
  final String destination;

  /// The board's own airport/station name for the far end
  /// (`apname`, e.g. "Cologne Main Station" for the AIRail
  /// station code QKL). It is the fallback label for a code
  /// the city table does not know -- the `?CODE` mystery
  /// labels of 2026-10-16.
  final String airportName;
  final DateTime departure;
  final DateTime arrival;
  final String terminal;

  const Flight({
    required this.flightNo,
    required this.airline,
    this.airlineName = '',
    required this.origin,
    required this.destination,
    this.airportName = '',
    required this.departure,
    required this.arrival,
    this.terminal = '',
  });

  /// Benefits and the airline filter follow the operator;
  /// the board's `al` already is it.
  String get operatorAirline => airline.trim();
}

class TripOption {
  final String city;
  final String country;
  final Flight outFlight;
  final Flight backFlight;
  final int nights;

  const TripOption({
    required this.city,
    required this.country,
    required this.outFlight,
    required this.backFlight,
    required this.nights,
  });
}

class CityResult {
  final String city;
  final String country;
  final List<TripOption> options;
  final List<Flight> outOnly;
  final List<Flight> backOnly;
  final Set<String> airports;
  final Set<String> unmappedAirports;

  const CityResult({
    required this.city,
    required this.country,
    this.countryDisplay,
    this.options = const [],
    this.outOnly = const [],
    this.backOnly = const [],
    this.airports = const {},
    this.unmappedAirports = const {},
  });

  /// The English country name for the ISO code, when the
  /// caller can resolve it. The label prefers it: "(RO)"
  /// meant nothing to readers who do not know the codes.
  final String? countryDisplay;

  String get label {
    if (country.isEmpty) return city;
    final name = (countryDisplay == null || countryDisplay!.isEmpty)
        ? country
        : countryDisplay!;
    return '$city ($name)';
  }
  int get count => options.length;

  /// Earliest departure first, then fewest nights, then name.
  int compareTo(CityResult other) {
    final a = options.first.outFlight.departure;
    final b = other.options.first.outFlight.departure;
    if (a != b) return a.isBefore(b) ? -1 : 1;
    final an = options.first.nights;
    final bn = other.options.first.nights;
    if (an != bn) return an.compareTo(bn);
    return city.compareTo(other.city);
  }
}

class MatchReport {
  final TravelPlan plan;
  final List<CityResult> cities;
  final List<CityResult> oneWayOnly;
  final int outboundTotal;
  final int returnTotal;
  final Map<String, int> outboundRejectedAirlines;

  /// Options and cities the minimum-stay rule removed
  /// (report e: 1-night stays do not count). Shown, never
  /// silent -- a filter that can empty a list says what it
  /// dropped and why.
  final int shortStaysDropped;
  final int shortStayCities;
  final List<String> notes;

  const MatchReport({
    required this.plan,
    required this.cities,
    required this.oneWayOnly,
    required this.outboundTotal,
    required this.returnTotal,
    required this.outboundRejectedAirlines,
    this.shortStaysDropped = 0,
    this.shortStayCities = 0,
    required this.notes,
  });

  int get cityCount => cities.length;
  int get optionCount =>
      cities.fold(0, (sum, result) => sum + result.count);
}

const homeAirport = 'FRA';
const _monday = 1;
const _saturday = 6;
const _sunday = 7;

/// Dart's weekday: Monday=1 .. Sunday=7 (the Python port uses Mon=0).

bool isOutboundCandidate(Flight flight, TravelPlan plan) {
  final dep = flight.departure;
  if (!_isDirectFromHome(flight)) return false;
  for (final day in plan.outDays) {
    if (_sameDay(dep, day.day) && day.accepts(_minutesOfDay(dep))) {
      return true;
    }
  }
  return false;
}

/// The return-day rules apply to the **landing**: "home
/// before 09:00" is about arriving, not about leaving.
bool isReturnCandidate(Flight flight, TravelPlan plan) {
  final arr = flight.arrival;
  if (!_isDirectToHome(flight)) return false;
  for (final day in plan.backDays) {
    if (_sameDay(arr, day.day) && day.accepts(_minutesOfDay(arr))) {
      return true;
    }
  }
  return false;
}

bool _isDirectFromHome(Flight flight) =>
    _airport(flight.origin) == homeAirport;

bool _isDirectToHome(Flight flight) =>
    _airport(flight.destination) == homeAirport;

String _airport(Object? code) =>
    code?.toString().trim().toUpperCase() ?? '';

int _minutesOfDay(DateTime moment) => moment.hour * 60 + moment.minute;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Nights between landing and taking off, floored at zero: an overnight
/// return that lands the morning it departed is a same-day trip, not a
/// negative stay.
///
/// Calendar days, not elapsed time: `DateTime.difference`
/// measures hours, and the spring-forward night is 23 h,
/// which would floor a one-night stay to zero. UTC
/// midnights have no DST, so their difference is exactly
/// the number of calendar nights -- what the legacy's
/// date subtraction computes.
int nightsAway(Flight outFlight, Flight backFlight) {
  final out = DateTime.utc(outFlight.arrival.year,
      outFlight.arrival.month, outFlight.arrival.day);
  final back = DateTime.utc(backFlight.departure.year,
      backFlight.departure.month, backFlight.departure.day);
  final nights = back.difference(out).inDays;
  return nights < 0 ? 0 : nights;
}

/// The map key for one airport's city: a string encoding of
/// the Python side's `(city, country)` tuple. An airport the
/// table does not know keys under its own code.
String _cityKeyOf(String airport, (String, String)? location) =>
    location == null ? '?$airport|' : '${location.$1}|${location.$2}';

/// Build the full result set. `airlineCheck` and `cityLookup` are injected
/// so this module stays free of Turso and of the airport asset, exactly
/// like the Python matcher. `countryNameFor` optionally resolves an ISO
/// country code to its English name for the labels.
///
/// `minNights` drops shorter options before ranking (report
/// e: the finder's visible "Min. nights" filter, default 1
/// night); the drop counts are on the report, never silent.
MatchReport findWeekends({
  required Iterable<Flight> outbound,
  required Iterable<Flight> returns,
  required TravelPlan plan,
  required bool Function(String code, String name) airlineCheck,
  required (String, String)? Function(String airport) cityLookup,
  String Function(String countryCode)? countryNameFor,
  int maxOptionsPerCity = 6,
  int minNights = 1,
}) {
  final outList = outbound.toList();
  final backList = returns.toList();
  final rejectedAirlines = <String, int>{};

  final goodOut = <Flight>[];
  for (final flight in outList) {
    if (!isOutboundCandidate(flight, plan)) continue;
    if (!airlineCheck(flight.operatorAirline, flight.airlineName)) {
      final name = flight.operatorAirline.isEmpty ? '?' : flight.operatorAirline;
      rejectedAirlines[name] = (rejectedAirlines[name] ?? 0) + 1;
      continue;
    }
    goodOut.add(flight);
  }

  final goodBack = <Flight>[];
  for (final flight in backList) {
    if (!isReturnCandidate(flight, plan)) continue;
    if (!airlineCheck(flight.operatorAirline, flight.airlineName)) continue;
    goodBack.add(flight);
  }

  final backByAirport = <String, List<Flight>>{};
  for (final flight in goodBack) {
    backByAirport.putIfAbsent(
        _airport(flight.origin), () => <Flight>[]).add(flight);
  }
  for (final flights in backByAirport.values) {
    flights.sort((a, b) => a.departure.compareTo(b.departure));
  }

  final outByAirport = <String, List<Flight>>{};
  for (final flight in goodOut) {
    outByAirport.putIfAbsent(
        _airport(flight.destination), () => <Flight>[]).add(flight);
  }

  final cities = <String, _MutableCity>{};

  /// The board's own far-end names ("Cologne Main
  /// Station"), keyed by code: the fallback label for a code
  /// the city table does not know.
  final airportNames = <String, String>{};
  for (final flight in [...outList, ...backList]) {
    for (final code in [_airport(flight.destination), _airport(flight.origin)]) {
      if (code.isEmpty) continue;
      final name = flight.airportName.trim();
      if (name.isNotEmpty) airportNames.putIfAbsent(code, () => name);
    }
  }

  /// The city entry for one airport, creating it when the
  /// first leg for it arrives. An airport the table does not
  /// know falls back to the board's own name for it (and
  /// failing that its code) -- never a `?CODE` placeholder
  /// (report f, 2026-10-16).
  _MutableCity cityFor(String airport, {required bool addAirport}) {
    final location = cityLookup(airport);
    final key = _cityKeyOf(airport, location);
    final created = cities.putIfAbsent(key, () {
      final fallback = airportNames[airport] ?? airport;
      final (city, country) = location ?? (fallback, '');
      return _MutableCity(
        city: city,
        country: country,
        countryDisplay:
            countryNameFor == null ? null : countryNameFor(country),
      );
    });
    if (addAirport) created.airports.add(airport);
    return created;
  }

  var shortStaysDropped = 0;
  var shortStayCities = 0;
  final shortStayOnly = <String>{};

  for (final entry in outByAirport.entries) {
    final result = cityFor(entry.key, addAirport: true);
    if (cityLookup(entry.key) == null) {
      result.unmappedAirports.add(entry.key);
    }
    final pairs = <TripOption>[];
    var droppedShortHere = 0;
    final outs = [...entry.value]..sort(
        (a, b) => a.departure.compareTo(b.departure));
    for (final outFlight in outs) {
      for (final backFlight in backByAirport[entry.key] ?? const <Flight>[]) {
        if (backFlight.departure.isBefore(outFlight.arrival)) {
          continue; // cannot leave before landing
        }
        final option = TripOption(
          city: result.city,
          country: result.country,
          outFlight: outFlight,
          backFlight: backFlight,
          nights: nightsAway(outFlight, backFlight),
        );
        // The minimum-stay filter runs before the budget
        // counts, so short stays never crowd out real ones.
        if (option.nights < minNights) {
          droppedShortHere++;
          continue;
        }
        pairs.add(option);
        if (pairs.length >= maxOptionsPerCity * 3) break;
      }
      if (pairs.length >= maxOptionsPerCity * 3) break;
    }
    if (pairs.isNotEmpty) {
      result.options = _bestOptions(pairs, maxOptionsPerCity);
    } else if (droppedShortHere > 0) {
      // Both legs qualify but every pair is too short: the
      // city is not a result at all (report e), and the
      // report says how many were dropped instead of
      // leaving the reader to wonder. It must not resurface
      // as a "one leg only" near miss below either.
      shortStayCities++;
      shortStayOnly.add(_cityKeyOf(entry.key, cityLookup(entry.key)));
    } else {
      final outs2 = [...entry.value]..sort(
          (a, b) => a.departure.compareTo(b.departure));
      result.outOnly = outs2.take(4).toList();
    }
    shortStaysDropped += droppedShortHere;
  }

  // A city whose only qualifying leg is the return still counts as a
  // near miss.
  for (final entry in backByAirport.entries) {
    final location = cityLookup(entry.key);
    if (shortStayOnly.contains(_cityKeyOf(entry.key, location))) continue;
    final known = cities[_cityKeyOf(entry.key, location)] != null;
    final result = cityFor(entry.key, addAirport: !known);
    if (result.options.isNotEmpty) continue; // already a full city
    if (!known && cityLookup(entry.key) == null) {
      result.unmappedAirports.add(entry.key);
    }
    if (result.backOnly.isEmpty) {
      result.backOnly = entry.value.take(4).toList();
    }
  }

  final full = <CityResult>[];
  final partial = <CityResult>[];
  for (final result in cities.values) {
    final view = result.view();
    if (view.options.isNotEmpty) {
      full.add(view);
    } else if (view.outOnly.isNotEmpty || view.backOnly.isNotEmpty) {
      partial.add(view);
    }
  }
  full.sort((a, b) => a.compareTo(b));
  partial.sort((a, b) {
    final byCity = a.city.compareTo(b.city);
    return byCity != 0 ? byCity : a.country.compareTo(b.country);
  });
  return MatchReport(
    plan: plan,
    cities: full,
    oneWayOnly: partial,
    outboundTotal: outList.length,
    returnTotal: backList.length,
    outboundRejectedAirlines: rejectedAirlines,
    shortStaysDropped: shortStaysDropped,
    shortStayCities: shortStayCities,
    notes: const [],
  );
}

class _MutableCity {
  final String city;
  final String country;

  /// The resolved English name for [country], when the
  /// caller supplied a resolver.
  final String? countryDisplay;
  final Set<String> airports = {};
  final Set<String> unmappedAirports = {};
  List<TripOption> options = [];
  List<Flight> outOnly = [];
  List<Flight> backOnly = [];

  _MutableCity({
    required this.city,
    required this.country,
    this.countryDisplay,
  });

  CityResult view() => CityResult(
        city: city,
        country: country,
        countryDisplay: countryDisplay,
        options: List.of(options),
        outOnly: List.of(outOnly),
        backOnly: List.of(backOnly),
        airports: Set.of(airports),
        unmappedAirports: Set.of(unmappedAirports),
      );
}

/// Prefer: fewer nights, then a Sunday return over Monday, then earlier
/// departure. A Saturday-evening return beats a Monday-06:00 one for the
/// same city -- the whole point of a weekend finder.
List<TripOption> _bestOptions(List<TripOption> pairs, int limit) {
  int dayRank(DateTime arrival) {
    switch (arrival.weekday) {
      case _monday:
        return 0;
      case _sunday:
        return 1;
      case _saturday:
        return 2;
      default:
        return 3;
    }
  }

  // Dart's List.sort is not stable, Python's sorted is:
  // two options with an identical rank key keep their
  // input order here (the original index is the final
  // tiebreaker), so the chosen option set matches the
  // legacy's on ties.
  final ranked = <(int, TripOption)>[
    for (var i = 0; i < pairs.length; i++) (i, pairs[i]),
  ];
  ranked.sort((a, b) {
    final byNights = a.$2.nights.compareTo(b.$2.nights);
    if (byNights != 0) return byNights;
    final byDay = dayRank(a.$2.backFlight.arrival)
        .compareTo(dayRank(b.$2.backFlight.arrival));
    if (byDay != 0) return byDay;
    final byOut =
        a.$2.outFlight.departure.compareTo(b.$2.outFlight.departure);
    if (byOut != 0) return byOut;
    final byBack =
        a.$2.backFlight.departure.compareTo(b.$2.backFlight.departure);
    if (byBack != 0) return byBack;
    return a.$1.compareTo(b.$1);
  });
  final ordered = [for (final entry in ranked) entry.$2];

  final seen = <String>{};
  final outCount = <String, int>{};
  final chosen = <TripOption>[];
  for (final option in ordered) {
    final signature =
        '${option.outFlight.flightNo}|${option.backFlight.flightNo}';
    if (seen.contains(signature)) continue;
    seen.add(signature);
    final key = option.outFlight.flightNo;
    if ((outCount[key] ?? 0) >= 2) continue; // max two ways home per outbound
    outCount[key] = (outCount[key] ?? 0) + 1;
    chosen.add(option);
    if (chosen.length >= limit) break;
  }
  return chosen;
}

/// A one-line explanation of what the airline filter removed.
String describeRule(Map<String, int> rejected) {
  if (rejected.isEmpty) return '';
  final total = rejected.values.fold(0, (a, b) => a + b);
  // Stable on ties (the original order wins), like the
  // legacy's sorted(): the caption names the same
  // airlines the legacy names when counts tie.
  final entries = rejected.entries.toList();
  final ranked = <(int, MapEntry<String, int>)>[
    for (var i = 0; i < entries.length; i++) (i, entries[i]),
  ];
  ranked.sort((a, b) {
    final byCount = b.$2.value.compareTo(a.$2.value);
    return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
  });
  final top = ranked
      .take(4)
      .map((entry) => '${entry.$2.key} (${entry.$2.value})')
      .join(', ');
  final more = rejected.length <= 4 ? '' : ', +${rejected.length - 4} more';
  return '$total outbound flight(s) dropped by the airline '
      'filter: $top$more';
}
