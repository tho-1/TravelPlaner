/// Pure weekend-trip matching: flights + time windows -> ranked cities.
///
/// The Dart port of `weekend_match.py` (the legacy finder's matcher), rule
/// for rule: outbound direct FRA -> X on Friday from 14:00 or Saturday
/// before 12:00; return direct X -> FRA landing Saturday after 12:00,
/// Sunday any time, or Monday before 09:00. Both legs must qualify for a
/// city to appear in the main list; one-leg cities come back separately so
/// near misses are visible instead of silently missing.
///
/// No network, no Turso, no Flutter. Times are naive wall-clock datetimes
/// (the departure airport's local time), the same convention the Python
/// matcher and the board parser keep.
library;

class Flight {
  final String flightNo;
  final String airline;
  final String origin;
  final String destination;
  final DateTime departure;
  final DateTime arrival;
  final String terminal;

  const Flight({
    required this.flightNo,
    required this.airline,
    required this.origin,
    required this.destination,
    required this.departure,
    required this.arrival,
    this.terminal = '',
  });

  /// Benefits follow the operator; the board's `al` already is it.
  String get operatorAirline => airline.trim();
}

/// The user's six time bounds, as minutes-of-day for simple comparison.
class Windows {
  final int fridayFrom;
  final int saturdayBefore;
  final int saturdayReturnAfter;
  final int mondayReturnBefore;

  /// The legacy's "Limit Sunday returns too" bound:
  /// null means any Sunday return counts (the
  /// default), a value means the return must land
  /// by then.
  final int? sundayReturnUntil;

  const Windows({
    this.fridayFrom = 14 * 60,
    this.saturdayBefore = 12 * 60,
    this.saturdayReturnAfter = 12 * 60,
    this.mondayReturnBefore = 9 * 60,
    this.sundayReturnUntil,
  });

  String describe() {
    final sunday = sundayReturnUntil == null
        ? 'any time'
        : 'before ${_hm(sundayReturnUntil!)}';
    return 'out: Fri from ${_hm(fridayFrom)} or Sat before ${_hm(saturdayBefore)} '
        '· back: Sat after ${_hm(saturdayReturnAfter)}, Sun $sunday, or Mon '
        'before ${_hm(mondayReturnBefore)}';
  }

  static String _hm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';
}

/// The Friday and its Sat/Sun/Mon that a search is about.
class Weekend {
  final DateTime friday;

  const Weekend(this.friday);

  DateTime get saturday => friday.add(const Duration(days: 1));
  DateTime get sunday => friday.add(const Duration(days: 2));
  DateTime get monday => friday.add(const Duration(days: 3));

  String describe() =>
      '${_date(friday)} to ${_date(monday)}';

  static String _date(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
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
    this.options = const [],
    this.outOnly = const [],
    this.backOnly = const [],
    this.airports = const {},
    this.unmappedAirports = const {},
  });

  String get label => country.isEmpty ? city : '$city ($country)';
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
  final Weekend weekend;
  final Windows windows;
  final List<CityResult> cities;
  final List<CityResult> oneWayOnly;
  final int outboundTotal;
  final int returnTotal;
  final Map<String, int> outboundRejectedAirlines;
  final List<String> notes;

  const MatchReport({
    required this.weekend,
    required this.windows,
    required this.cities,
    required this.oneWayOnly,
    required this.outboundTotal,
    required this.returnTotal,
    required this.outboundRejectedAirlines,
    required this.notes,
  });

  int get cityCount => cities.length;
  int get optionCount =>
      cities.fold(0, (sum, result) => sum + result.count);
}

const homeAirport = 'FRA';
const _monday = 1;
const _friday = 5;
const _saturday = 6;
const _sunday = 7;

/// Dart's weekday: Monday=1 .. Sunday=7 (the Python port uses Mon=0).

/// The Fri/Sat/Sun/Mon that `day` belongs to. A Monday belongs to the
/// weekend that is *starting* (the coming Friday) -- on a Monday you plan
/// the weekend ahead. A Saturday or Sunday belongs to the Friday that
/// started it.
Weekend weekendContaining(DateTime day) {
  final weekday = day.weekday;
  if (weekday == _monday) {
    return Weekend(_addDays(day, 4));
  }
  if (weekday == _saturday || weekday == _sunday) {
    return Weekend(_addDays(day, _friday - weekday));
  }
  if (weekday == _friday) {
    return Weekend(day);
  }
  return Weekend(_addDays(day, _friday - weekday));
}

/// The first Friday at least `minimumDaysAhead` days after `today`. A
/// weekend's board is only useful once published; too little lead time
/// yields an empty board, which is worse than the following weekend.
DateTime nextFriday(DateTime today, {int minimumDaysAhead = 0}) {
  var ahead = (_friday - today.weekday) % 7;
  if (ahead == 0) ahead = 7;
  while (ahead < minimumDaysAhead) {
    ahead += 7;
  }
  return _addDays(today, ahead);
}

DateTime _addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

bool isOutboundCandidate(Flight flight, Weekend weekend, Windows windows) {
  final dep = flight.departure;
  if (!_isDirectFromHome(flight)) return false;
  if (_sameDay(dep, weekend.friday)) {
    return _minutesOfDay(dep) >= windows.fridayFrom;
  }
  if (_sameDay(dep, weekend.saturday)) {
    return _minutesOfDay(dep) < windows.saturdayBefore;
  }
  return false;
}

bool isReturnCandidate(Flight flight, Weekend weekend, Windows windows) {
  final arr = flight.arrival;
  if (!_isDirectToHome(flight)) return false;
  if (_sameDay(arr, weekend.saturday)) {
    return _minutesOfDay(arr) >= windows.saturdayReturnAfter;
  }
  if (_sameDay(arr, weekend.sunday)) {
    // The legacy's "Limit Sunday returns too": off
    // (null) means any Sunday return counts.
    final until = windows.sundayReturnUntil;
    return until == null || _minutesOfDay(arr) <= until;
  }
  if (_sameDay(arr, weekend.monday)) {
    return _minutesOfDay(arr) < windows.mondayReturnBefore;
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
int nightsAway(Flight outFlight, Flight backFlight) {
  final out = DateTime(
      outFlight.arrival.year, outFlight.arrival.month, outFlight.arrival.day);
  final back = DateTime(backFlight.departure.year,
      backFlight.departure.month, backFlight.departure.day);
  final nights = back.difference(out).inDays;
  return nights < 0 ? 0 : nights;
}

/// The map key for one airport's city: a string encoding of
/// the Python side's `(city, country)` tuple. An airport the
/// table does not know keys under its own code.
String _cityKeyOf(String airport, (String, String)? location) =>
    location == null ? '?$airport|' : '${location.$1}|${location.$2}';

/// Build the full result set. `benefitCheck` and `cityLookup` are injected
/// so this module stays free of Turso and of the airport asset, exactly
/// like the Python matcher.
MatchReport findWeekends({
  required Iterable<Flight> outbound,
  required Iterable<Flight> returns,
  required Weekend weekend,
  required Windows windows,
  required bool Function(String airline) benefitCheck,
  required (String, String)? Function(String airport) cityLookup,
  int maxOptionsPerCity = 6,
}) {
  final outList = outbound.toList();
  final backList = returns.toList();
  final rejectedAirlines = <String, int>{};

  final goodOut = <Flight>[];
  for (final flight in outList) {
    if (!isOutboundCandidate(flight, weekend, windows)) continue;
    if (!benefitCheck(flight.operatorAirline)) {
      final name = flight.operatorAirline.isEmpty ? '?' : flight.operatorAirline;
      rejectedAirlines[name] = (rejectedAirlines[name] ?? 0) + 1;
      continue;
    }
    goodOut.add(flight);
  }

  final goodBack = <Flight>[];
  for (final flight in backList) {
    if (!isReturnCandidate(flight, weekend, windows)) continue;
    if (!benefitCheck(flight.operatorAirline)) continue;
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

  /// The city entry for one airport, creating it when the
  /// first leg for it arrives. An airport the table does
  /// not know keeps its code as the label.
  _MutableCity cityFor(String airport, {required bool addAirport}) {
    final location = cityLookup(airport);
    final key = _cityKeyOf(airport, location);
    final created = cities.putIfAbsent(key, () {
      final (city, country) = location ?? ('?$airport', '');
      return _MutableCity(city: city, country: country);
    });
    if (addAirport) created.airports.add(airport);
    return created;
  }

  for (final entry in outByAirport.entries) {
    final result = cityFor(entry.key, addAirport: true);
    if (cityLookup(entry.key) == null) {
      result.unmappedAirports.add(entry.key);
    }
    final pairs = <TripOption>[];
    final outs = [...entry.value]..sort(
        (a, b) => a.departure.compareTo(b.departure));
    for (final outFlight in outs) {
      for (final backFlight in backByAirport[entry.key] ?? const <Flight>[]) {
        if (backFlight.departure.isBefore(outFlight.arrival)) {
          continue; // cannot leave before landing
        }
        pairs.add(TripOption(
          city: result.city,
          country: result.country,
          outFlight: outFlight,
          backFlight: backFlight,
          nights: nightsAway(outFlight, backFlight),
        ));
        if (pairs.length >= maxOptionsPerCity * 3) break;
      }
      if (pairs.length >= maxOptionsPerCity * 3) break;
    }
    if (pairs.isNotEmpty) {
      result.options = _bestOptions(pairs, maxOptionsPerCity);
    } else {
      final outs2 = [...entry.value]..sort(
          (a, b) => a.departure.compareTo(b.departure));
      result.outOnly = outs2.take(4).toList();
    }
  }

  // A city whose only qualifying leg is the return still counts as a
  // near miss.
  for (final entry in backByAirport.entries) {
    final location = cityLookup(entry.key);
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
    weekend: weekend,
    windows: windows,
    cities: full,
    oneWayOnly: partial,
    outboundTotal: outList.length,
    returnTotal: backList.length,
    outboundRejectedAirlines: rejectedAirlines,
    notes: const [],
  );
}

class _MutableCity {
  final String city;
  final String country;
  final Set<String> airports = {};
  final Set<String> unmappedAirports = {};
  List<TripOption> options = [];
  List<Flight> outOnly = [];
  List<Flight> backOnly = [];

  _MutableCity({required this.city, required this.country});

  CityResult view() => CityResult(
        city: city,
        country: country,
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

  final ordered = [...pairs]..sort((a, b) {
      final byNights = a.nights.compareTo(b.nights);
      if (byNights != 0) return byNights;
      final byDay = dayRank(a.backFlight.arrival)
          .compareTo(dayRank(b.backFlight.arrival));
      if (byDay != 0) return byDay;
      final byOut = a.outFlight.departure.compareTo(b.outFlight.departure);
      if (byOut != 0) return byOut;
      return a.backFlight.departure.compareTo(b.backFlight.departure);
    });

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
  final top = (rejected.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)))
      .take(4)
      .map((entry) => '${entry.key} (${entry.value})')
      .join(', ');
  final more = rejected.length <= 4 ? '' : ', +${rejected.length - 4} more';
  return '$total outbound flight(s) dropped for airlines without '
      'benefits: $top$more';
}
