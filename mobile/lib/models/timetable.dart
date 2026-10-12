/// Flight-board fetching: the Fraport departure/arrival
/// board, and the CSV override that replaces it.
///
/// The Dart port of `timetable.py`. Semantics that must
/// not drift:
///
/// * **The `time` parameter is a cursor, not a filter.**
///   Paging walks forward through the archive from that
///   instant, so a fetch starts the cursor at the first
///   moment the window needs and stops once a record
///   passes the window's end (the board is chronological).
/// * **Times are naive wall-clocks.** The board's offsets
///   are unreliable on `schedArr`/`schedDep`, so the
///   wall-clock is taken as the local time of the airport
///   the time belongs to -- the same convention the CSV
///   provider and the matcher use.
/// * **Direct flights only**, and a *missing* `stops`
///   value is kept (the arrivals board never reports stops;
///   dropping those would drop every return).
/// * **A missing or non-list `data` array is a loud
///   failure**, not "nowhere to fly" -- the shape-change
///   guard the legacy page relies on.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'weekend_match.dart';

class ProviderUnavailable implements Exception {
  final String message;
  const ProviderUnavailable(this.message);
  @override
  String toString() => message;
}

/// What a fetch returned, plus what the user needs to know.
class FetchResult {
  final List<Flight> flights;
  final String source;
  final String warning;
  final String fetchedAt;

  const FetchResult({
    required this.flights,
    required this.source,
    this.warning = '',
    required this.fetchedAt,
  });

  int get length => flights.length;
}

/// Parse one of the board's ISO timestamps into a *naive*
/// datetime.
///
/// The board answers ``2026-10-09T14:00:00+0200`` — ISO 8601
/// with a numeric offset and no colon. The offset is **not
/// reliable** on ``schedArr``/``schedDep`` (destination and
/// origin times are stamped ``+0000``/``+0100`` regardless
/// of the airport), so the wall-clock is taken as the local
/// time of the airport the time belongs to.
///
/// Only the date/time components are kept — never the
/// offset, never a conversion — which is why this parses
/// with a regex instead of `DateTime.parse` (whose offset
/// handling would quietly shift the wall clock).
DateTime? wallClock(Object? text) {
  final raw = (text ?? '').toString().trim();
  if (raw.isEmpty) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[T ]'
          r'(\d{2}):(\d{2})(?::(\d{2}))?')
      .firstMatch(raw);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    match.group(6) == null ? 0 : int.parse(match.group(6)!),
  );
}

/// The Europe/Berlin offset for a naive moment, computed
/// from the zone (+02:00 in summer, +01:00 in winter): a
/// hard-coded offset silently returns the wrong day across
/// a DST change — the same reason `timetable.py` keeps a
/// `ZoneInfo` at all.
///
/// EU rule: from the last Sunday of March 01:00 UTC to the
/// last Sunday of October 01:00 UTC it is +02:00.
int berlinOffsetHours(DateTime naive) {
  final startDay = _lastSundayOf(naive.year, 3).day;
  final endDay = _lastSundayOf(naive.year, 10).day;
  final afterStart = !naive.isBefore(DateTime(naive.year, 3, startDay, 2));
  final beforeEnd = naive.isBefore(DateTime(naive.year, 10, endDay, 3));
  return afterStart && beforeEnd ? 2 : 1;
}

DateTime _lastSundayOf(int year, int month) {
  final lastDay = DateTime(year, month + 1, 0);
  return DateTime(year, month, lastDay.day - lastDay.weekday % 7);
}

/// The provider protocol: one board query in, the
/// flights that answer it plus what the user needs
/// to know out. The live board and the CSV override
/// both speak it, so the finder can swap them.
abstract interface class FlightBoardProvider {
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  });
}

/// frankfurt-airport.com's own departure/arrival board.
///
/// The rendered page is a JavaScript shell, but the board
/// component advertises its JSON endpoint in a
/// `data-api-url` attribute, and that endpoint answers
/// plain GETs (verified 2026-10-07, implemented in the
/// legacy app 2026-10-08).
class FraportBoardProvider implements FlightBoardProvider {
  static const name = 'fraport';

  /// The endpoint is implemented and answers plain GETs. A
  /// failure is a *fetch* failure (surfaced as a note), not
  /// a reason to hide the source.
  static const available = true;

  /// Verified to answer any date ±60 days out and beyond,
  /// so the finder can plan any Friday.
  static const supportsFarDates = true;

  static const endpoint =
      'https://www.frankfurt-airport.com/en/_jcr_content.flights.json/filter';
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0 Safari/537.36 travel-planner/1.0';

  /// The server caps a page at 50 records.
  static const perPage = 50;

  /// Safety net: a day is ~16 pages, a window ~8-16. If the
  /// walk ever reaches this many pages without passing the
  /// window's end, something is wrong — stop rather than
  /// hammer the endpoint.
  static const maxPages = 64;

  final http.Client httpClient;

  /// Minimum seconds between two board requests. The legacy
  /// app uses 5.0 with a Streamlit spinner; the app tightens
  /// it because a weekend search walks ~39 requests and a
  /// three-minute wait is not acceptable on a phone. The
  /// endpoint stays a public board; this is a courtesy
  /// delay, not a quota.
  final double throttleSeconds;

  DateTime? _lastRequestAt;

  FraportBoardProvider({
    http.Client? httpClient,
    this.throttleSeconds = 1.5,
  }) : httpClient = httpClient ?? http.Client();

  /// Walk the board from the window's start until a record
  /// passes its end. `since`/`until` default to the whole
  /// day, which is only sensible for a full-day dump.
  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    final start = since ?? DateTime(day.year, day.month, day.day);
    final end = until ??
        DateTime(day.year, day.month, day.day, 23, 59, 59);
    final flights = <Flight>[];
    var warning = '';
    var brokeEarly = false;
    for (var page = 1; page <= maxPages; page++) {
      final payload = await _request(direction, start, page);
      final records = payload['data'];
      if (records is! List) {
        // An empty list is a legitimate "no flights in
        // range"; a missing or non-list `data` means the
        // endpoint changed shape. That must fail loudly, not
        // look like "nowhere to fly".
        final keys = payload.keys.toList()..sort();
        throw ProviderUnavailable(
          'fraport: the board response carries no flight data — the '
          'endpoint changed? (keys: ${keys.take(8).join(', ')})');
      }
      for (final record in records) {
        if (record is! Map) continue;
        final sched = wallClock(record['sched']);
        if (sched == null) continue;
        if (sched.isAfter(end)) {
          brokeEarly = true; // chronological: nothing later fits
          continue;
        }
        if (sched.isBefore(start)) continue; // defensive: cursor prevents it
        final flight = flightFromRecord(record, direction);
        if (flight != null) flights.add(flight);
      }
      if (brokeEarly) break;
      if (records.isEmpty) {
        // The walk from the cursor is exhausted: the board
        // has nothing later to offer, so the window's end is
        // simply beyond the last scheduled flight.
        brokeEarly = true;
        break;
      }
    }
    if (!brokeEarly) {
      // The loop ran out of pages without seeing the end of
      // the window: a walk that long means something is
      // wrong, so say so instead of silently truncating.
      warning =
          'stopped after $maxPages pages without reaching the end of the window';
    }
    return FetchResult(
      flights: flights,
      source: name,
      warning: warning,
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }

  /// One board record -> one [Flight], or `null`.
  ///
  /// * **Direct flights only.** `stops` counts intermediate
  ///   stops; a value > 0 is skipped. A *missing* value is
  ///   kept: the arrivals board never reports stops at all,
  ///   and the departures records without it are
  ///   Lufthansa's direct train connections to FRA.
  /// * **Benefits follow the operator.** The board shows
  ///   the *operated* flight: `al`/`fnr`/`alname` are the
  ///   carrier flying the metal. The `cs` codeshare list
  ///   appears on some records and not others, so it is
  ///   ignored entirely.
  static Flight? flightFromRecord(Object? record, String direction) {
    if (record is! Map) return null;
    var stops = 0;
    final rawStops = record['stops'];
    if (rawStops != null) {
      stops = int.tryParse(rawStops.toString()) ?? 0;
    }
    if (stops > 0) return null;
    final airline = (record['al'] ?? '').toString().trim();
    final airport = (record['iata'] ?? '').toString().trim().toUpperCase();
    if (airline.isEmpty || airport.isEmpty) return null;
    final sched = wallClock(record['sched']);
    if (sched == null) return null;
    final String origin;
    final String destination;
    DateTime departure;
    DateTime arrival;
    if (direction == 'departures') {
      origin = homeAirport;
      destination = airport;
      departure = sched;
      arrival = wallClock(record['schedArr']) ?? departure;
    } else {
      origin = airport;
      destination = homeAirport;
      arrival = sched;
      departure = wallClock(record['schedDep']) ?? arrival;
    }
    if (arrival.isBefore(departure)) {
      // A data glitch, not a time machine: the destination
      // wall-clock already carries the next day on overnight
      // legs, so a genuinely earlier arrival means the record
      // is wrong — keep the pair usable by pushing it a day.
      arrival = arrival.add(const Duration(days: 1));
    }
    final flightNo = (record['fnr'] ?? '').toString().trim().replaceAll(' ', '');
    return Flight(
      flightNo: flightNo.isEmpty ? airline : flightNo,
      airline: airline,
      origin: origin,
      destination: destination,
      departure: departure,
      arrival: arrival,
      terminal: (record['terminal'] ?? '').toString(),
    );
  }

  bool pageExhausted(List<Flight> flights) => false;

  Future<void> _throttle() async {
    final previous = _lastRequestAt;
    if (previous == null) return;
    final wait = throttleSeconds -
        DateTime.now().difference(previous).inMilliseconds / 1000.0;
    if (wait > 0) {
      await Future<void>.delayed(Duration(milliseconds: (wait * 1000).round()));
    }
  }

  Future<Map<String, dynamic>> _request(
      String direction, DateTime cursor, int page) async {
    await _throttle();
    _lastRequestAt = DateTime.now();
    final offset = berlinOffsetHours(cursor);
    final sign = offset >= 0 ? '+' : '-';
    final cursorStamp =
        '${_naiveIso(cursor)}$sign${offset.abs().toString().padLeft(2, '0')}:00';
    final uri = Uri.parse(endpoint).replace(queryParameters: {
      'flighttype': direction, // departures | arrivals
      'time': cursorStamp,
      'perpage': perPage.toString(),
      'page': page.toString(),
      'lang': 'en',
    });
    final http.Response response;
    try {
      response = await httpClient
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      throw ProviderUnavailable(
          'fraport: the board could not be reached (${error.runtimeType})');
    }
    if (response.statusCode != 200) {
      throw ProviderUnavailable(
          'fraport: the board returned HTTP ${response.statusCode}');
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map<String, dynamic>) return body;
      throw ProviderUnavailable('fraport: the board returned a non-JSON response');
    } on FormatException {
      throw const ProviderUnavailable(
          'fraport: the board returned a non-JSON response');
    }
  }

  static String _naiveIso(DateTime moment) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${moment.year}-${two(moment.month)}-${two(moment.day)}'
        'T${two(moment.hour)}:${two(moment.minute)}:${two(moment.second)}';
  }
}

/// The time range one board query must cover, from the six
/// bounds.
///
/// The matcher applies the bounds to the flights it is
/// given; the provider uses the *same* range as its fetch
/// window, so the board is only walked as far as the window
/// reaches. All times are the board's own wall-clock
/// (Europe/Berlin), which is what the matcher compares.
(DateTime?, DateTime?) fetchWindow(
    Weekend weekend, Windows windows, DateTime day, String kind) {
  DateTime at(DateTime d, int hour, int minute) =>
      DateTime(d.year, d.month, d.day, hour, minute);
  // A day that is switched off fetches nothing: its bound
  // is null and the board query is skipped entirely.
  final thursdayFrom = windows.thursdayFrom == null
      ? null
      : Duration(minutes: windows.thursdayFrom!);
  final fridayFrom = windows.fridayFrom == null
      ? null
      : Duration(minutes: windows.fridayFrom!);
  final satBefore = windows.saturdayBefore == null
      ? null
      : Duration(minutes: windows.saturdayBefore!);
  final satAfter = windows.saturdayReturnAfter == null
      ? null
      : Duration(minutes: windows.saturdayReturnAfter!);
  final monBefore = windows.mondayReturnBefore == null
      ? null
      : Duration(minutes: windows.mondayReturnBefore!);
  final tueBefore = windows.tuesdayReturnBefore == null
      ? null
      : Duration(minutes: windows.tuesdayReturnBefore!);

  if (kind == 'departures') {
    if (_same(day, weekend.thursday)) {
      // Outbound Thursday (the holiday bridge): same rule
      // as Friday.
      if (thursdayFrom == null) return (null, null);
      return (at(day, 0, 0).add(thursdayFrom), at(weekend.friday, 0, 0));
    }
    if (_same(day, weekend.friday)) {
      // Outbound Friday: departs at or after the Friday bound.
      if (fridayFrom == null) return (null, null);
      return (at(day, 0, 0).add(fridayFrom), at(weekend.saturday, 0, 0));
    }
    if (_same(day, weekend.saturday)) {
      // Outbound Saturday: departs before the Saturday bound.
      if (satBefore == null) return (null, null);
      return (at(day, 0, 0), at(day, 0, 0).add(satBefore));
    }
  } else {
    if (_same(day, weekend.saturday)) {
      // Return Saturday: lands at or after the Saturday bound.
      if (satAfter == null) return (null, null);
      return (at(day, 0, 0).add(satAfter), at(weekend.sunday, 0, 0));
    }
    if (_same(day, weekend.sunday)) {
      // Return Sunday: lands by the Sunday bound.
      // Off (null) means any Sunday return counts:
      // 24:00 is Monday 00:00, so the walk covers
      // exactly what the matcher keeps -- and the
      // "flights read" count stays honest.
      if (!windows.sundayEnabled) return (null, null);
      return (
        at(day, 0, 0),
        at(day, 0, 0).add(
            Duration(minutes: windows.sundayReturnUntil ?? 24 * 60)),
      );
    }
    if (_same(day, weekend.monday)) {
      // Return Monday: lands before the Monday bound.
      if (monBefore == null) return (null, null);
      return (at(day, 0, 0), at(day, 0, 0).add(monBefore));
    }
    if (_same(day, weekend.tuesday)) {
      // Return Tuesday (the holiday bridge): lands before
      // the Tuesday bound.
      if (tueBefore == null) return (null, null);
      return (at(day, 0, 0), at(day, 0, 0).add(tueBefore));
    }
  }
  return (null, null);
}

bool _same(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The unique IATA codes appearing in a set of flights —
/// the finder's "which airports did we see" report line.
List<String> airportsOf(Iterable<Flight> flights) {
  final seen = <String>{};
  for (final flight in flights) {
    if (flight.origin == homeAirport) {
      seen.add(flight.destination);
    } else if (flight.destination == homeAirport) {
      seen.add(flight.origin);
    }
  }
  final out = seen.toList()..sort();
  return out;
}

// ── the CSV override ─────────────────────────────────────────────────
//
// The escape hatch that keeps the finder usable with no network or
// when the board changes under us. An explicit CSV always wins over
// the live board (the weekend-finder plan's decision 1). The rules
// are `timetable.parse_csv_flights`, ported rule for rule:

/// Header aliases, matched case-insensitively with underscores and
/// spaces dropped, so "operated_by", "Operated By" and "operatedby"
/// all reach the same field.
const _csvColumns = {
  'flight_no': ['flightno', 'flightnumber', 'flight', 'number', 'nr'],
  'airline': ['airline', 'carrier'],
  'origin': ['origin', 'from', 'departureairport', 'fromairport'],
  'destination': [
    'destination',
    'to',
    'arrivalairport',
    'toairport',
  ],
  'departure': [
    'departure',
    'dep',
    'departuretime',
    'scheduleddeparture',
    'std',
  ],
  'arrival': ['arrival', 'arr', 'arrivaltime', 'scheduledarrival', 'sta'],
  'operated_by': [
    'operatedby',
    'operator',
    'operatedbyairline',
    'operatingcarrier',
    'operatedbyairlinecode',
  ],
  'terminal': ['terminal', 'term'],
};

/// The time stamps a CSV may carry, as anchored patterns.
/// Each builder reads one matched pattern; the ones without
/// a date combine the time with the query's day.
final _stampPatterns = <(RegExp, DateTime Function(Match, DateTime))>[
  // %H:%M, %H:%M:%S
  (
    RegExp(r'^(\d{1,2}):(\d{2})$'),
    (match, day) => DateTime(day.year, day.month, day.day,
        int.parse(match.group(1)!), int.parse(match.group(2)!)),
  ),
  (
    RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})$'),
    (match, day) => DateTime(day.year, day.month, day.day,
        int.parse(match.group(1)!), int.parse(match.group(2)!)),
  ),
  // %d.%m.%Y %H:%M
  (
    RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4}) (\d{1,2}):(\d{2})$'),
    (match, _) => DateTime(
        int.parse(match.group(3)!),
        int.parse(match.group(2)!),
        int.parse(match.group(1)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!)),
  ),
  // %Y-%m-%d %H:%M
  (
    RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2}):(\d{2})$'),
    (match, _) => DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!)),
  ),
  // %d/%m/%Y %H:%M
  (
    RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4}) (\d{1,2}):(\d{2})$'),
    (match, _) => DateTime(
        int.parse(match.group(3)!),
        int.parse(match.group(2)!),
        int.parse(match.group(1)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!)),
  ),
  // %H:mm %d.%m.%Y
  (
    RegExp(r'^(\d{1,2}):(\d{2}) (\d{1,2})\.(\d{1,2})\.(\d{4})$'),
    (match, _) => DateTime(
        int.parse(match.group(5)!),
        int.parse(match.group(4)!),
        int.parse(match.group(3)!),
        int.parse(match.group(1)!),
        int.parse(match.group(2)!)),
  ),
];

/// Parse the CSV upload into flights plus the lines that could not
/// be read. One bad line is a warning, not a reason to discard an
/// otherwise good upload.
(List<Flight>, List<String>) parseCsvFlights(
    String text, DateTime defaultDay) {
  final flights = <Flight>[];
  final problems = <String>[];
  final records = _csvRecords(text);
  if (records.isEmpty) {
    return (flights, ['The file has no header row.']);
  }
  final mapping = _mapColumns(records.first);
  final missing = [
    for (final name in ['departure', 'arrival'])
      if (!mapping.containsKey(name)) name,
  ];
  if (missing.isNotEmpty) {
    return (
      flights,
      [
        'Missing required column(s): ${missing.join(', ')}. '
            'Expected at least: flight_no, airline, origin, '
            'destination, departure, arrival.',
      ],
    );
  }
  // Python's DictReader numbers data rows from 2 (the header is 1).
  for (var number = 2; number < records.length + 1; number++) {
    try {
      final flight =
          _flightFromRow(records[number - 1], mapping, defaultDay);
      if (flight != null) flights.add(flight);
    } on FormatException catch (error) {
      problems.add('line $number: ${error.message}');
    }
  }
  return (flights, problems);
}

/// Split CSV text into records (rows of fields), honouring quoted
/// fields — a comma inside quotes does not split, and a quoted
/// field may span lines.
List<List<String>> _csvRecords(String text) {
  final records = <List<String>>[];
  var record = <String>[];
  var field = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (inQuotes) {
      if (char == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(char);
      }
    } else if (char == '"') {
      inQuotes = true;
    } else if (char == ',') {
      record.add(field.toString());
      field.clear();
    } else if (char == '\n') {
      record.add(field.toString());
      field.clear();
      if (record.any((value) => value.trim().isNotEmpty)) {
        records.add(record);
      }
      record = <String>[];
    } else if (char != '\r') {
      field.write(char);
    }
  }
  record.add(field.toString());
  if (record.any((value) => value.trim().isNotEmpty)) {
    records.add(record);
  }
  return records;
}

Map<String, int> _mapColumns(List<String> fieldnames) {
  final mapping = <String, int>{};
  for (var index = 0; index < fieldnames.length; index++) {
    final name = fieldnames[index]
        .replaceAll(RegExp(r'[\s_]+'), '')
        .trim()
        .toLowerCase();
    for (final entry in _csvColumns.entries) {
      if (entry.value.contains(name) && !mapping.containsKey(entry.key)) {
        mapping[entry.key] = index;
      }
    }
  }
  return mapping;
}

String _cell(List<String> row, Map<String, int> mapping, String field) {
  final index = mapping[field];
  if (index == null || index >= row.length) return '';
  return row[index].trim();
}

/// One time cell. Throws [FormatException] (the port's
/// `ValueError`) when the cell cannot be read, so the
/// caller can report the line instead of crashing.
DateTime _parseStamp(String text, DateTime defaultDay) {
  final raw = text.trim();
  if (raw.isEmpty) throw const FormatException('empty time');
  for (final (pattern, build) in _stampPatterns) {
    final match = pattern.firstMatch(raw);
    if (match != null) return build(match, defaultDay);
  }
  // A trailing "+1" (or "-1") means the next day — the
  // board's overnight notation. Both signs add the day,
  // exactly like the legacy's `re.sub(r"[+\-]\d$", ...)`
  // fallback.
  final cleaned = raw.replaceFirst(RegExp(r'[+\-]\d$'), '');
  final stamp = _parseFlightTime(cleaned, defaultDay);
  if (stamp == null) throw FormatException('unreadable time "$raw"');
  return cleaned != raw ? stamp.add(const Duration(days: 1)) : stamp;
}

/// The board's own time notation: "14:05", "14:05+1", occasionally
/// "-". Returns `null` rather than guessing; an unparseable time is
/// dropped instead of being silently assumed midnight.
DateTime? _parseFlightTime(String text, DateTime day) {
  var raw = text.trim();
  if (raw.isEmpty || raw == '-' || raw == '--' || raw == 'n/a') {
    return null;
  }
  var nextDay = false;
  if (raw.endsWith('+1')) {
    raw = raw.substring(0, raw.length - 2).trim();
    nextDay = true;
  }
  final parts = raw.split(':');
  final hour = int.tryParse(parts[0]);
  final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  if (hour == null || !(_inRange(hour, 0, 23) && _inRange(minute, 0, 59))) {
    return null;
  }
  final stamp = DateTime(day.year, day.month, day.day, hour, minute);
  return nextDay ? stamp.add(const Duration(days: 1)) : stamp;
}

bool _inRange(int value, int low, int high) => low <= value && value <= high;

Flight? _flightFromRow(
    List<String> row, Map<String, int> mapping, DateTime defaultDay) {
  final departure = _parseStamp(_cell(row, mapping, 'departure'), defaultDay);
  final arrivalText = _cell(row, mapping, 'arrival');
  var arrival = arrivalText.isNotEmpty
      ? _parseStamp(arrivalText, defaultDay)
      : departure;
  if (arrival.isBefore(departure)) {
    // A data glitch, not a time machine: an overnight leg's arrival
    // already carries the next day, so a genuinely earlier arrival
    // means the row is wrong — keep the pair usable by pushing it a
    // day.
    arrival = arrival.add(const Duration(days: 1));
  }
  final origin = _cell(row, mapping, 'origin').toUpperCase();
  final destination = _cell(row, mapping, 'destination').toUpperCase();
  if (origin.isEmpty || destination.isEmpty) {
    throw const FormatException('origin or destination missing');
  }
  // Benefits follow the operator: `operated_by` is the carrier
  // flying the metal, the `airline` cell the one marketing it.
  final airline = _cell(row, mapping, 'airline');
  final operatedBy = _cell(row, mapping, 'operated_by');
  final flightNo = _cell(row, mapping, 'flight_no');
  return Flight(
    flightNo: flightNo.isEmpty ? 'n/a' : flightNo,
    airline: operatedBy.isNotEmpty ? operatedBy : airline,
    origin: origin,
    destination: destination,
    departure: departure,
    arrival: arrival,
    terminal: _cell(row, mapping, 'terminal'),
    marketingAirline: airline,
  );
}

/// The user-supplied CSV override. No network, always available —
/// the only source when the board cannot be reached, and an
/// explicit override that always wins over the live board.
class CsvBoardProvider implements FlightBoardProvider {
  static const name = 'csv';

  /// A CSV is not bound by the board's ±60-day window: it carries
  /// its own dates.
  static const supportsFarDates = true;

  final String departuresCsv;
  final String arrivalsCsv;

  const CsvBoardProvider({this.departuresCsv = '', this.arrivalsCsv = ''});

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    // The matcher applies the window bounds; the CSV is read whole.
    final text = direction == 'departures' ? departuresCsv : arrivalsCsv;
    if (text.trim().isEmpty) {
      return FetchResult(
        flights: const <Flight>[],
        source: name,
        warning: 'No CSV data loaded.',
        fetchedAt: DateTime.now().toIso8601String(),
      );
    }
    final (flights, problems) = parseCsvFlights(text, day);
    var warning = '';
    if (problems.isNotEmpty) {
      warning = '${problems.length} row(s) skipped: '
          '${problems.take(3).join('; ')}';
    }
    return FetchResult(
      flights: flights,
      source: name,
      warning: warning,
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}
