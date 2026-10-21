/// A per-device cache of board answers from a **credentialed**
/// source.
///
/// The board providers that need an API key have request limits
/// (weekly, monthly -- the exact caps depend on the plan), so
/// the finder must not ask them for the same day twice. This
/// store keeps the last answer per (day, direction) on the
/// device, so a repeated search -- the user changing a day
/// re-runs the search (2026-10-21) -- costs nothing.
///
/// The Fraport board is *not* cached here: it is free and
/// unlimited, so it is asked every time (the user's decision,
/// 2026-10-21).
///
/// The same file contracts as the other per-device stores here:
/// a missing or corrupt file is a cache miss (never a crash),
/// a write goes through a temporary file and a rename, and a
/// write that fails is a `false`, never an exception.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/weekend_match.dart' show Flight;

/// One day's answer from a credentialed source: the flights
/// and the provider's own name (the shared board's `source`
/// field is that name, and the sibling's readers use it to
/// tell a board apart).
typedef CachedBoard = ({List<Flight> flights, String source});

class FlightBoardCache {
  /// The directory the cache files live in. Empty means
  /// unconfigured -- nothing is ever written.
  final String dir;

  const FlightBoardCache(this.dir);

  bool get isConfigured => dir.trim().isNotEmpty;

  /// The cached answer for one day -- or for one window of it
  /// when [since]/[until] are given -- or null on a miss.
  ///
  /// The window is part of the key: a whole-day answer and a
  /// windowed one are different data, and a changed time rule
  /// must not read the old window's flights as its own.
  CachedBoard? load(DateTime day, String direction,
      {DateTime? since, DateTime? until}) {
    if (!isConfigured) return null;
    try {
      final file = File(_path(day, direction, since, until));
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final raw = decoded['flights'];
      if (raw is! List) return null;
      final flights = <Flight>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final flight = _flightFrom(item);
        if (flight != null) flights.add(flight);
      }
      return (flights: flights, source: '${decoded['source'] ?? ''}');
    } catch (_) {
      // A corrupt cache file is a miss, not a crash.
      return null;
    }
  }

  /// Store one day's answer (or one window's). Best effort:
  /// a write that fails is a `false`, never an exception.
  bool save(DateTime day, String direction, List<Flight> flights,
      {String source = '', DateTime? since, DateTime? until}) {
    if (!isConfigured) return false;
    try {
      Directory(dir).createSync(recursive: true);
      final path = _path(day, direction, since, until);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'day': _isoDate(day),
        'direction': direction,
        'source': source,
        'since': since?.toIso8601String(),
        'until': until?.toIso8601String(),
        'flights': [for (final flight in flights) _flightTo(flight)],
      }));
      try {
        tmp.renameSync(path);
      } on FileSystemException {
        // Atomic replace is not available on every platform.
        File(path).writeAsStringSync(tmp.readAsStringSync());
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  String _path(DateTime day, String direction, DateTime? since,
          DateTime? until) =>
      p.join(dir, since == null || until == null
          ? 'board_${_isoDate(day)}_$direction.json'
          : 'board_${_isoDate(day)}_${direction}_'
              '${_clock(since)}-${_clock(until)}.json');

  static String _clock(DateTime moment) =>
      '${moment.hour.toString().padLeft(2, '0')}'
      '${moment.minute.toString().padLeft(2, '0')}';

  static String _isoDate(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static Map<String, Object?> _flightTo(Flight flight) => {
        'flight_no': flight.flightNo,
        'airline': flight.airline,
        'airline_name': flight.airlineName,
        'origin': flight.origin,
        'destination': flight.destination,
        'airport_name': flight.airportName,
        'departure': flight.departure.toIso8601String(),
        'arrival': flight.arrival.toIso8601String(),
        'terminal': flight.terminal,
      };

  static Flight? _flightFrom(Map item) {
    final number = item['flight_no'];
    final origin = item['origin'];
    final destination = item['destination'];
    final departure = DateTime.tryParse('${item['departure'] ?? ''}');
    final arrival = DateTime.tryParse('${item['arrival'] ?? ''}');
    if (number is! String ||
        origin is! String ||
        destination is! String ||
        departure == null ||
        arrival == null) {
      return null;
    }
    return Flight(
      flightNo: number,
      airline: '${item['airline'] ?? ''}',
      airlineName: '${item['airline_name'] ?? ''}',
      origin: origin,
      destination: destination,
      airportName: '${item['airport_name'] ?? ''}',
      departure: departure,
      arrival: arrival,
      terminal: '${item['terminal'] ?? ''}',
    );
  }
}
