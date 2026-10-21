/// Flight-board fetching: the Fraport departure/arrival
/// board.
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
///   the time belongs to -- the same convention the
///   matcher uses.
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
import 'travel_days.dart';

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
/// to know out.
abstract interface class FlightBoardProvider {
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  });

  /// Whether **one unbounded call** answers a whole day.
  ///
  /// The credentialed fallbacks' device cache and the shared
  /// board both need a *whole* day, and a provider that pages
  /// (AeroAPI is asked for `max_pages: 1`) would hand back a
  /// partial day that reads as complete -- which is how a
  /// short board gets cached, or written into the sibling's
  /// database, as if it were the whole day (2026-10-21).
  /// FlightRoutes' own readers had the same rule. Abstract on
  /// purpose: a new provider has to answer the question.
  bool get answersWholeDay;
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

  /// The board is walked to the end of the window (the
  /// pagination cap reports a warning instead of stopping
  /// silently), so an unbounded call is a whole day.
  @override
  bool get answersWholeDay => true;

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
  ///   and the Lufthansa AIRail trains (LH 34xx/35xx/36xx,
  ///   `ac: "TRS"`) carry none either -- they are bookable
  ///   flight numbers into/out of main-station codes (QKL,
  ///   ZWS, ...) and the finder keeps them like the legacy
  ///   did.
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
      arrival = DateTime(arrival.year, arrival.month, arrival.day + 1,
          arrival.hour, arrival.minute, arrival.second);
    }
    final flightNo = (record['fnr'] ?? '').toString().trim().replaceAll(' ', '');
    return Flight(
      flightNo: flightNo.isEmpty ? airline : flightNo,
      airline: airline,
      airlineName: (record['alname'] ?? '').toString().trim(),
      origin: origin,
      destination: destination,
      // The board's own name for the far end ("Cologne Main
      // Station" for the AIRail code QKL): the fallback
      // label for codes the city table does not know.
      airportName: (record['apname'] ?? '').toString().trim(),
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

/// FlightAware AeroAPI: the licensed *fallback* flight
/// source (report j, 2026-10-16).
///
/// Why this one, after checking the alternatives: keyless
/// scraping is out -- FlightRadar24's payload explicitly
/// forbids reusing the data and its schedule endpoint
/// rejects future dates, FlightStats sits behind an AWS WAF
/// captcha (verified 2026-10), Airportia blocks scripts,
/// and AirLabs' "schedules" only look ten hours ahead. The
/// sources that serve *future* schedules are the licensed
/// APIs, and AeroAPI is the one whose contract the vendor
/// documents publicly (`airports/{ident}/flights` with an
/// `x-apikey` header).
///
/// It stays a fallback: the Fraport board is the primary
/// source and this provider is only asked about windows
/// that failed or look incomplete (one request per window).
///
/// Conventions the matcher relies on:
///
/// * **wall-clock times**, not UTC instants. AeroAPI answers
///   in UTC; both sides are stamped with the Berlin offset.
///   For the FRA side that is exact. The far side's own
///   zone is not in the payload, so its wall clock is
///   approximated with the same offset -- good to the
///   calendar day everywhere in Europe, off by one only in
///   the evening edge cases. (Fraport, the primary, carries
///   true per-airport wall clocks.)
/// * **the operator is the benefit key**: AeroAPI's
///   `operator` is an ICAO code, mapped through
///   [icaoToIata]; an unmapped code is kept as-is and then
///   simply never counts as a benefit -- "unknown is not a
///   yes".
class AeroApiBoardProvider implements FlightBoardProvider {
  static const name = 'flightaware';

  /// `max_pages: 1` answers one page for the window it was
  /// given -- never a whole day (see the protocol's note).
  @override
  bool get answersWholeDay => false;

  static const endpoint =
      'https://aeroapi.flightaware.com/aeroapi/airports/EDDF/flights';

  final String apiKey;
  final http.Client httpClient;

  /// Courtesy delay between two requests, like the Fraport
  /// provider's.
  final double throttleSeconds;

  DateTime? _lastRequestAt;

  AeroApiBoardProvider({
    required this.apiKey,
    http.Client? httpClient,
    this.throttleSeconds = 1.5,
  }) : httpClient = httpClient ?? http.Client();

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
    final uri = Uri.parse(endpoint).replace(queryParameters: {
      'flight_type': direction == 'departures' ? 'departures' : 'arrivals',
      'start': _toUtcStamp(start),
      'end': _toUtcStamp(end),
      'max_pages': '1',
    });
    await _throttle();
    _lastRequestAt = DateTime.now();
    final http.Response response;
    try {
      response = await httpClient
          .get(uri, headers: {'x-apikey': apiKey}).timeout(
              const Duration(seconds: 20));
    } catch (error) {
      throw ProviderUnavailable(
          'aeroapi: the fallback could not be reached (${error.runtimeType})');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const ProviderUnavailable(
          'aeroapi: the API key was rejected (HTTP 401/403)');
    }
    if (response.statusCode != 200) {
      throw ProviderUnavailable(
          'aeroapi: the fallback returned HTTP ${response.statusCode}');
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ProviderUnavailable(
          'aeroapi: the fallback returned a non-JSON response');
    }
    if (body is! Map<String, dynamic>) {
      throw const ProviderUnavailable(
          'aeroapi: the fallback returned a non-JSON response');
    }
    final records = body['flights'];
    if (records is! List) {
      // A shape change must fail loudly, not look like
      // "nowhere to fly" (the same guard the Fraport
      // provider keeps).
      final keys = body.keys.toList()..sort();
      throw ProviderUnavailable(
          'aeroapi: the response carries no flight list -- the '
          'endpoint changed? (keys: ${keys.take(8).join(', ')})');
    }
    final flights = <Flight>[];
    for (final record in records) {
      final flight = flightFromAeroApi(record, direction, start, end);
      if (flight != null) flights.add(flight);
    }
    return FetchResult(
      flights: flights,
      source: name,
      warning: '',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }

  /// One AeroAPI record -> one [Flight], or null. The
  /// record's window is re-checked here (the API's `start`
  /// and `end` filter on the same times, but the window
  /// must hold for the matcher too).
  static Flight? flightFromAeroApi(
      Object? record, String direction, DateTime start, DateTime end) {
    if (record is! Map) return null;
    if (record['cancelled'] == true || record['diverted'] == true) {
      return null;
    }
    final origin = record['origin'];
    final destination = record['destination'];
    if (origin is! Map || destination is! Map) return null;
    final originCode = '${origin['code_iata'] ?? ''}'.trim().toUpperCase();
    final destinationCode =
        '${destination['code_iata'] ?? ''}'.trim().toUpperCase();
    if (originCode.isEmpty || destinationCode.isEmpty) return null;
    final outUtc = _utcOf(record['scheduled_out'] ?? record['estimated_out']);
    final onUtc = _utcOf(record['scheduled_on'] ?? record['estimated_on']);
    if (outUtc == null || onUtc == null) return null;

    // The wall clock the matcher compares: the Berlin
    // offset on both sides (see the class doc for the far
    // side's approximation), kept as a *naive* DateTime --
    // the same convention wallClock() uses, so nominal
    // times compare equal to the Fraport board's.
    final departure = _wallClockOf(outUtc);
    final arrival = _wallClockOf(onUtc);
    if (departure.isBefore(start) || departure.isAfter(end)) return null;

    final operator = '${record['operator'] ?? ''}'.trim().toUpperCase();
    final ident =
        '${record['ident'] ?? ''}'.trim().replaceAll(' ', '');
    final flightNumber = '${record['flight_number'] ?? ''}'.trim();
    final flightNo = ident.isNotEmpty
        ? ident
        : (operator.isNotEmpty ? '$operator$flightNumber' : flightNumber);
    if (flightNo.isEmpty) return null;

    return Flight(
      flightNo: flightNo,
      airline: icaoToIata[operator] ?? operator,
      origin: originCode,
      destination: destinationCode,
      airportName: direction == 'departures'
          ? '${destination['name'] ?? ''}'.trim()
          : '${origin['name'] ?? ''}'.trim(),
      departure: departure,
      arrival: arrival,
      terminal: direction == 'departures'
          ? '${origin['terminal'] ?? ''}'.trim()
          : '${destination['terminal'] ?? ''}'.trim(),
    );
  }

  /// A naive wall clock -> the UTC stamp the API wants.
  static String _toUtcStamp(DateTime naive) {
    final utc = naive.subtract(Duration(hours: berlinOffsetHours(naive)));
    return '${_naiveIso(utc)}Z';
  }

  /// A UTC instant -> the naive wall clock at the airport
  /// (the Berlin offset stands in for its own, per the
  /// class doc). The result is deliberately never
  /// UTC-flagged: board times are nominal local times, and
  /// DateTime equality distinguishes the two.
  static DateTime _wallClockOf(DateTime utc) {
    final shifted = utc.add(Duration(hours: berlinOffsetHours(utc)));
    return DateTime(shifted.year, shifted.month, shifted.day, shifted.hour,
        shifted.minute, shifted.second);
  }

  static DateTime? _utcOf(Object? text) {
    final raw = (text ?? '').toString().trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    return parsed?.toUtc();
  }

  static String _naiveIso(DateTime moment) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${moment.year}-${two(moment.month)}-${two(moment.day)}'
        'T${two(moment.hour)}:${two(moment.minute)}:${two(moment.second)}';
  }

  Future<void> _throttle() async {
    final previous = _lastRequestAt;
    if (previous == null) return;
    final wait = throttleSeconds -
        DateTime.now().difference(previous).inMilliseconds / 1000.0;
    if (wait > 0) {
      await Future<void>.delayed(Duration(milliseconds: (wait * 1000).round()));
    }
  }
}

/// ICAO -> IATA for the carriers whose flights matter here:
/// the Lufthansa Group and the benefits table's qualifying
/// carriers. AeroAPI answers in ICAO; the rest of the app
/// is keyed by IATA. Extend when the error log names an
/// operator this table missed -- an unmapped code is kept
/// as-is and never counts as a benefit, so the gap is
/// visible rather than wrong.
const icaoToIata = <String, String>{
  // Lufthansa Group
  'DLH': 'LH', // Lufthansa
  'CLH': 'CL', // Lufthansa CityLine
  'GEC': 'LH', // Lufthansa Cargo (LH flight numbers)
  'EWG': 'EW', // Eurowings
  'SWR': 'LX', // SWISS
  'EDW': 'WK', // Edelweiss
  'AUA': 'OS', // Austrian
  'BEL': 'SN', // Brussels Airlines
  'DLA': 'EN', // Air Dolomiti
  'ITY': 'AZ', // ITA Airways
  // The benefits database's qualifying carriers
  'CPA': 'CX', // Cathay Pacific
  'JAL': 'JL', // Japan Airlines
  'KZR': 'KC', // Air Astana
  'HVN': 'VN', // Vietnam Airlines
  'CSZ': 'ZH', // Shenzhen Airlines
};

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


/// AeroDataBox (RapidAPI) fallback provider.
///
/// The free Basic plan allows 12 requests per hour, so a
/// full day costs two. Used only as a fallback for the
/// board windows the primary source lost.
class AeroDataBoxBoardProvider implements FlightBoardProvider {
  static const name = 'aerodatabox';

  /// Both of the day's twelve-hour windows are walked in one
  /// call, so an unbounded call *is* the whole day.
  @override
  bool get answersWholeDay => true;

  final String apiKey;
  final http.Client httpClient;

  AeroDataBoxBoardProvider({
    required this.apiKey,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    final start = since ?? DateTime(day.year, day.month, day.day);
    final end = until ?? DateTime(day.year, day.month, day.day, 23, 59, 59);
    final outbound = direction == 'departures';
    final windows = <(String, String)>[
      ('${_isoDate(day)}T00:00', '${_isoDate(day)}T12:00'),
      ('${_isoDate(day)}T12:00', '${_nextIsoDate(day)}T00:00'),
    ];
    final collected = <Flight>[];
    final seen = <String>{};
    for (var i = 0; i < windows.length; i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      }
      final (from, to) = windows[i];
      final uri = Uri.parse(
        'https://aerodatabox.p.rapidapi.com/flights/airports/iata/'
        'FRA/$from/$to',
      ).replace(queryParameters: {
        'direction': outbound ? 'Departure' : 'Arrival',
        'withLeg': 'true',
        'withCancelled': 'false',
        'withCodeshared': 'true',
        'withCargo': 'false',
        'withPrivate': 'false',
      });
      final http.Response response;
      try {
        response = await httpClient.get(uri, headers: {
          'X-RapidAPI-Key': apiKey,
          'X-RapidAPI-Host': 'aerodatabox.p.rapidapi.com',
        }).timeout(const Duration(seconds: 30));
      } catch (error) {
        throw ProviderUnavailable(
            'aerodatabox: the provider could not be reached (${error.runtimeType})');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const ProviderUnavailable(
            'aerodatabox: the API key was rejected (HTTP 401/403)');
      }
      if (response.statusCode == 429) {
        throw const ProviderUnavailable(
            'aerodatabox: rate limit reached (HTTP 429)');
      }
      if (response.statusCode != 200) {
        throw ProviderUnavailable(
            'aerodatabox: HTTP ${response.statusCode}');
      }
      final Object? body;
      try {
        body = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw const ProviderUnavailable(
            'aerodatabox: non-JSON response');
      }
      if (body is Map && body['message'] is String) {
        throw ProviderUnavailable(
            'aerodatabox: ${body['message']}');
      }
      final rawRecords = body is Map
          ? body[outbound ? 'departures' : 'arrivals']
          : null;
      if (rawRecords != null && rawRecords is! List) {
        throw const ProviderUnavailable(
            'aerodatabox: the response carries no flight list');
      }
      final records = rawRecords is List ? rawRecords : const <Object?>[];
      for (final record in records) {
        if (record is! Map) continue;
        final flight = _flightFromAeroDataBox(record, outbound, start, end);
        if (flight == null) continue;
        final key =
            '${flight.flightNo}|${flight.departure.toIso8601String()}|'
            '${flight.destination}';
        if (seen.contains(key)) continue;
        seen.add(key);
        collected.add(flight);
      }
    }
    return FetchResult(
      flights: collected,
      source: name,
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }

  static Flight? _flightFromAeroDataBox(
      Map record, bool outbound, DateTime start, DateTime end) {
    final depBlock = (record['departure'] ?? record['movement']) as Map?;
    final arrBlock = record['arrival'] as Map?;
    if (depBlock == null || arrBlock == null) return null;
    final depAirport = (depBlock['airport'] as Map?) ?? const <String, dynamic>{};
    final arrAirport = (arrBlock['airport'] as Map?) ?? const <String, dynamic>{};
    final originCode = outbound
        ? 'FRA'
        : '${depAirport['iata'] ?? ''}'.trim().toUpperCase();
    final destinationCode = outbound
        ? '${arrAirport['iata'] ?? ''}'.trim().toUpperCase()
        : 'FRA';
    if (originCode.isEmpty || destinationCode.isEmpty) return null;

    final depScheduled = depBlock['scheduledTime'] as Map?;
    final arrScheduled = arrBlock['scheduledTime'] as Map?;
    final departure = _wallClock(
        (depScheduled?['local'] ?? depScheduled?['utc'])?.toString());
    final arrival = _wallClock(
        (arrScheduled?['local'] ?? arrScheduled?['utc'])?.toString());
    if (departure == null || arrival == null) return null;
    final relevant = outbound ? departure : arrival;
    if (relevant.isBefore(start) || relevant.isAfter(end)) return null;

    final airline = (record['airline'] as Map?) ?? const <String, dynamic>{};
    final code = '${airline['iata'] ?? ''}'.trim().toUpperCase();
    final carrierName = '${airline['name'] ?? ''}'.trim();
    final number = '${record['number'] ?? ''}'.trim().replaceAll(' ', '');
    final flightNo = number.isNotEmpty
        ? number
        : (code.isNotEmpty ? '$code$number' : '');
    if (flightNo.isEmpty) return null;

    return Flight(
      flightNo: flightNo,
      airline: code,
      airlineName: carrierName,
      origin: originCode,
      destination: destinationCode,
      airportName: outbound
          ? '${arrAirport['name'] ?? ''}'.trim()
          : '${depAirport['name'] ?? ''}'.trim(),
      departure: departure,
      arrival: arrival,
      terminal: '${depBlock['terminal'] ?? ''}'.trim(),
    );
  }

  static DateTime? _wallClock(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty) return null;
    final naive = text.length >= 19 ? text.substring(0, 19) : text;
    return DateTime.tryParse(naive);
  }

  static String _isoDate(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static String _nextIsoDate(DateTime day) {
    // Calendar arithmetic, not `add(Duration(days: 1))`: the
    // latter is absolute time, so across a DST change the
    // clock shifts an hour and the *date* can come out one
    // day early (2026-10-24 00:00 plus 24 hours is
    // 2026-10-24 23:00 local, so the second board window
    // would ask for the wrong day).
    final next = addCalendarDays(day, 1);
    return _isoDate(next);
  }
}

/// AirLabs secondary provider (today only).
class AirLabsBoardProvider implements FlightBoardProvider {
  static const name = 'airlabs';

  /// One request returns the schedule list, which the
  /// provider then filters to the window -- so the whole day
  /// costs the same request.
  @override
  bool get answersWholeDay => true;

  final String apiKey;
  final http.Client httpClient;

  AirLabsBoardProvider({
    required this.apiKey,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    final start = since ?? DateTime(day.year, day.month, day.day);
    final end = until ?? DateTime(day.year, day.month, day.day, 23, 59, 59);
    final outbound = direction == 'departures';
    final uri = Uri.parse('https://airlabs.co/api/v9/schedules').replace(
      queryParameters: {
        if (outbound) 'dep_iata': 'FRA' else 'arr_iata': 'FRA',
        'api_key': apiKey,
      },
    );
    final http.Response response;
    try {
      response = await httpClient.get(uri).timeout(const Duration(seconds: 30));
    } catch (error) {
      throw ProviderUnavailable(
          'airlabs: the provider could not be reached (${error.runtimeType})');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const ProviderUnavailable(
          'airlabs: the API key was rejected (HTTP 401/403)');
    }
    if (response.statusCode != 200) {
      throw ProviderUnavailable('airlabs: HTTP ${response.statusCode}');
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ProviderUnavailable('airlabs: non-JSON response');
    }
    final rawRecords = body is Map ? body['response'] : null;
    if (rawRecords != null && rawRecords is! List) {
      throw const ProviderUnavailable('airlabs: no flight list');
    }
    final records = rawRecords is List ? rawRecords : const <Object?>[];
    final collected = <Flight>[];
    for (final record in records) {
      if (record is! Map) continue;
      final flight = _flightFromAirLabs(record, outbound, day, start, end);
      if (flight != null) collected.add(flight);
    }
    return FetchResult(
      flights: collected,
      source: name,
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }

  static Flight? _flightFromAirLabs(
      Map record, bool outbound, DateTime day, DateTime start, DateTime end) {
    final originCode = outbound
        ? 'FRA'
        : '${record['dep_iata'] ?? ''}'.trim().toUpperCase();
    final destinationCode = outbound
        ? '${record['arr_iata'] ?? ''}'.trim().toUpperCase()
        : 'FRA';
    if (originCode.isEmpty || destinationCode.isEmpty) return null;

    final depTime = _airLabsTime(record['dep_time'], day);
    final arrTime = _airLabsTime(record['arr_time'], day);
    if (depTime == null || arrTime == null) return null;
    final relevant = outbound ? depTime : arrTime;
    if (relevant.isBefore(start) || relevant.isAfter(end)) return null;

    final code = '${record['airline_iata'] ?? ''}'.trim().toUpperCase();
    final flightNoRaw = '${record['flight_iata'] ?? record['flight_number'] ?? ''}'
        .trim()
        .replaceAll(' ', '');
    if (flightNoRaw.isEmpty) return null;
    final carrierName = '${record['airline_name'] ?? ''}'.trim();

    return Flight(
      flightNo: flightNoRaw,
      airline: code,
      airlineName: carrierName,
      origin: originCode,
      destination: destinationCode,
      airportName: '',
      departure: depTime,
      arrival: arrTime,
    );
  }

  static DateTime? _airLabsTime(Object? value, DateTime day) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    if (text.contains('T')) {
      final naive = text.length >= 19 ? text.substring(0, 19) : text;
      return DateTime.tryParse(naive);
    }
    if (text.contains(':')) {
      final parts = text.split(':');
      if (parts.length < 2) return null;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null) return null;
      return DateTime(day.year, day.month, day.day, hour, minute);
    }
    return null;
  }
}

/// Tries several providers in order and returns the first
/// non-empty result.
class CompositeBoardProvider implements FlightBoardProvider {
  final List<FlightBoardProvider> providers;

  const CompositeBoardProvider(this.providers);

  /// True when *some* provider can answer a whole day -- and
  /// an unbounded call then only asks those, so a paging
  /// provider's partial page can never be mistaken for one.
  @override
  bool get answersWholeDay => providers.any((p) => p.answersWholeDay);

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    final wholeDay = since == null && until == null;
    // When a provider *can* answer a whole day, an unbounded
    // ask goes only to those -- a paging provider's partial
    // page must not be mistaken for the day. When none can,
    // the composite keeps its plain "ask in order" contract
    // (its callers know, from [answersWholeDay], that the
    // answer is not a whole day).
    final capable = [
      for (final provider in providers)
        if (provider.answersWholeDay) provider,
    ];
    final candidates = wholeDay && capable.isNotEmpty ? capable : providers;
    Object? lastError;
    FetchResult? lastResult;
    for (final provider in candidates) {
      try {
        final result =
            await provider.fetch(day, direction, since: since, until: until);
        if (result.flights.isNotEmpty) return result;
        lastResult = result;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastResult != null) return lastResult;
    if (lastError is ProviderUnavailable) throw lastError;
    if (lastError != null) {
      throw ProviderUnavailable('all fallback providers failed: $lastError');
    }
    return FetchResult(
      flights: const <Flight>[],
      source: 'none',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}
