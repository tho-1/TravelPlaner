/// The weekend finder's orchestration: five board queries,
/// one matcher run, one explainable report.
///
/// The Dart port of `timetable.search_weekend`. A provider
/// that cannot answer for one window is not fatal: the legs
/// that did arrive are still collected and the report
/// explains the gap in `notes` instead of pretending there
/// were no flights.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/airline_benefits.dart';
import '../models/schedule_board_payload.dart';
import '../models/timetable.dart';
import '../models/travel_days.dart';
import '../models/weekend_match.dart';
import 'benefits_repository.dart';
import 'catalogue_match.dart';
import 'error_log.dart';
import 'flight_routes_schedule_repository.dart';
import 'flight_routes_schedule_writer.dart';

/// IATA code -> "City|Country" records from the generated
/// `assets/airports.json` (built from the Python
/// `airport_city` module, which is the single source of
/// truth). Loaded once and cached, like the Python module's
/// `lru_cache`.
class AirportLookup {
  static final Map<String, (String, String)> _table = {};
  static var _loaded = false;

  /// Railway stations on Fraport's board: Lufthansa AIRail
  /// trains carry LH flight numbers into main-station codes,
  /// which are *DB station codes, not IATA* -- the airport
  /// table cannot know them. Without this table they render
  /// under their code ("?QKL", report f, 2026-10-16). The
  /// nine the legacy `airport_city.RAIL_STATIONS` knew plus
  /// QKL/ZWS, which the board serves since. Names are ASCII,
  /// matching the rest of the tables.
  static const railStations = <String, (String, String)>{
    'DHC': ('Bremen', 'DE'),
    'DTZ': ('Dortmund', 'DE'),
    'QDU': ('Dusseldorf', 'DE'),
    'QKL': ('Cologne', 'DE'),
    'XHJ': ('Aachen', 'DE'),
    'XIR': ('Dresden', 'DE'),
    'ZBA': ('Basel', 'CH'),
    'ZEU': ('Goettingen', 'DE'),
    'ZMB': ('Hamburg', 'DE'),
    'ZMU': ('Munich', 'DE'),
    'ZWS': ('Stuttgart', 'DE'),
  };

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _table.addAll(railStations);
    try {
      final text = await rootBundle.loadString('assets/airports.json');
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final pair = entry.value;
        if (pair is List && pair.length >= 2) {
          final city = '${pair[0]}'.trim();
          final country = '${pair[1]}'.trim();
          if (city.isNotEmpty) {
            _table[entry.key] = (city, country);
          }
        }
      }
    } catch (_) {
      // A missing or malformed asset leaves the
      // table empty: airports then key under
      // their own code, which the matcher handles
      // (unknown is not a failure), instead of
      // throwing into the finder's search.
    }
    _loaded = true;
  }

  /// The city and country an airport serves, or `null` when
  /// the table does not know the code -- the same contract
  /// `airport_city.city_for_airport` has (unknown is not a
  /// failure).
  static (String, String)? cityForAirport(String code) {
    final key = code.trim().toUpperCase();
    if (key.isEmpty) return null;
    return _table[key];
  }

  /// Test seam: install a table without loading the asset.
  static void installForTesting(Map<String, (String, String)> table) {
    _table
      ..clear()
      ..addAll(railStations)
      ..addAll(table);
    _loaded = true;
  }
}

/// The finder's outcome: the report plus the benefit source
/// that produced it, so the UI can show both from one run.
///
/// `pendingWrites` holds the feed-back futures of the
/// schedule-board sharing (2026-10-18): one per out day that
/// gets its full-day FRA board written to the shared
/// FlightRoutes cache. They resolve *after* the report is
/// built and are awaited by tests only — the production UI
/// lets them finish in the background, their errors surfacing
/// in the ErrorLog, never a silent swallow.
typedef WeekendSearch = ({
  MatchReport report,
  BenefitSource benefits,
  List<Future<List<String>>> pendingWrites,
});

/// The flight filters the finder card exposes: which
/// airlines count (the dropdown, report d) and the longest
/// leg the user is willing to sit through. `null` disables
/// the cap. `minNights` is the stay-length floor — a
/// *visible* finder control (report e, clarified 2026-10-16:
/// default "at least 1 night", the user may change it).
class WeekendSearchOptions {
  final AirlineScope airlineScope;
  final Duration? maxLegDuration;
  final int minNights;

  const WeekendSearchOptions({
    this.airlineScope = AirlineScope.lufthansaGroup,
    this.maxLegDuration,
    this.minNights = 1,
  });
}

class WeekendRepository {
  final FlightBoardProvider provider;

  /// The optional second source (report j): asked only
  /// about windows that failed or look incomplete, never
  /// about healthy ones.
  final FlightBoardProvider? fallback;

  /// Exact-day FlightRoutes boards supplement the live
  /// provider; only full v2 boards with timezone-aware
  /// timestamps are usable here.
  final FlightRoutesScheduleRepository? sharedSchedules;

  /// The write side of the same cache: full-day FRA boards
  /// the finder pulls through the live provider are fed back
  /// after the search, so the sibling app's next sync
  /// adopts them. The reader and the writer are wired
  /// together or not at all -- one without the other has
  /// their own (reader-only) behaviour.
  final FlightRoutesScheduleWriter? sharedBoardWriter;

  /// The payload clock for `obtained_at` stamps; injectable
  /// so tests can freeze the format.
  final DateTime Function() clock;

  WeekendRepository(
    this.provider, {
    this.fallback,
    this.sharedSchedules,
    this.sharedBoardWriter,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// Run one board query per selected day and match them.
  Future<WeekendSearch> search(
    TravelPlan plan,
    BenefitSource benefits, {
    WeekendSearchOptions options = const WeekendSearchOptions(),
  }) async {
    await AirportLookup.ensureLoaded();
    await CountryNames.ensureLoaded();
    final outbound = <Flight>[];
    final returns = <Flight>[];
    final notes = <String>[];

    // One board query per selected out/back day.
    final queries = <(TravelDay, String, List<Flight>)>[
      for (final day in plan.outDays) (day, 'departures', outbound),
      for (final day in plan.backDays) (day, 'arrivals', returns),
    ];
    final windowsByKey = <String, (TravelDay, String, List<Flight>)>{
      for (final query in queries) '${_isoDate(query.$1.day)} ${query.$2}': query,
    };
    final windowCounts = <String, int>{};
    final failedWindows = <String>[];
    for (final (rule, kind, sink) in queries) {
      final (since, until) = rule.fetchWindow();
      final windowLabel = '${_isoDate(rule.day)} $kind';
      if (kind == 'departures') {
        final cached = await _cachedOutbound(rule, windowLabel, notes);
        if (cached != null) {
          sink.addAll(cached.flights);
          windowCounts[windowLabel] = cached.windowCount;
          continue;
        }
      }
      try {
        final result = await provider.fetch(rule.day, kind,
            since: since, until: until);
        if (result.warning.isNotEmpty) {
          notes.add('$windowLabel: ${result.warning}');
        }
        sink.addAll(result.flights);
        windowCounts[windowLabel] = result.flights.length;
      } on ProviderUnavailable catch (error) {
        // One dead window must not end the search (the old
        // `break` lost every later day because one query
        // failed): the other days still answer, and the
        // failure is a visible note *and* a log line, never
        // silence.
        notes.add('$windowLabel: ${error.message}');
        ErrorLog.instance.record('weekend-finder', error.message,
            details: {'window': windowLabel});
        failedWindows.add(windowLabel);
      } catch (error) {
        notes.add('$windowLabel: the query failed ($error)');
        ErrorLog.instance
            .record('weekend-finder', '$error', details: {'window': windowLabel});
        failedWindows.add(windowLabel);
      }
    }

    // An empty or implausible window is never silently "no
    // flights": the Fraport feed carried exactly one arrival
    // on 2026-10-25 where sibling windows carried hundreds
    // (report f, 2026-10-16). Compare the windows against
    // each other and say what looks wrong.
    final busiest =
        windowCounts.values.fold<int>(0, (a, b) => a > b ? a : b);
    final suspicious = <String>{...failedWindows};
    for (final entry in windowCounts.entries) {
      final warning = _windowWarning(entry.key, entry.value, busiest);
      if (warning == null) continue;
      suspicious.add(entry.key);
      notes.add(warning);
      ErrorLog.instance.record('weekend-finder', warning, details: {
        'window': entry.key,
        'flights': entry.value,
        'busiest': busiest,
      });
    }

    // The fallback pass (report j): every suspicious window
    // is asked again from the second source, and what it
    // returns is merged in -- deduplicated by flight number
    // and departure, so two sources never double-count.
    for (final label in suspicious) {
      final query = windowsByKey[label];
      if (query == null) continue;
      if (query.$2 == 'arrivals') {
        await _fillFromSharedScheduleCache(
          rule: query.$1,
          outbound: outbound,
          sink: query.$3,
          windowLabel: label,
          notes: notes,
        );
      }
      await _fillFromFallback(
        rule: query.$1,
        kind: query.$2,
        sink: query.$3,
        primaryCount: windowCounts[label] ?? 0,
        windowLabel: label,
        notes: notes,
      );
    }

    // The leg-duration cap: how many flights each list lost
    // goes into the notes, so an empty result can never be
    // mistaken for "nothing flies".
    final cap = options.maxLegDuration;
    if (cap != null) {
      _dropOverlong(outbound, cap);
      _dropOverlong(returns, cap);
    }

    final report = findWeekends(
      outbound: outbound,
      returns: returns,
      plan: plan,
      airlineCheck: (code, name) => airlineInScope(
          code, name, options.airlineScope, benefits.flags),
      cityLookup: AirportLookup.cityForAirport,
      countryNameFor: CountryNames.nameFor,
      minNights: options.minNights,
    );
    if (report.shortStaysDropped > 0) {
      // Report e: a filter that can empty a list says what
      // it dropped and why. The floor is the user's choice
      // ("Min. nights"), so the note names it.
      notes.add('${report.shortStaysDropped} option(s) in '
          '${report.shortStayCities} cit(y/ies) dropped for staying '
          'fewer than ${options.minNights} '
          'night(s).');
    }

    // Unknown airport/station codes become log lines with
    // the board's own name for them, so the city table can
    // be grown from the log instead of from screenshots.
    for (final city in [...report.cities, ...report.oneWayOnly]) {
      for (final code in city.unmappedAirports) {
        ErrorLog.instance.record(
            'weekend-finder',
            'airport code $code is not on the city table',
            details: {
              'shown as': city.city,
              'airports': city.airports.toList()..sort(),
            });
      }
    }

    // The feed-back pass (2026-10-18): every out day this
    // search touched gets its complete FRA departure board
    // shared to the FlightRoutes cache, so the sibling app's
    // next sync adopts it. Runs off the result path -- the
    // futures land in `pendingWrites` for the tests to await;
    // the production UI never waits on a share.
    final pendingWrites = <Future<List<String>>>[];
    if (sharedSchedules != null && sharedBoardWriter != null) {
      var chain = Future<void>.value();
      for (final rule in plan.outDays) {
        pendingWrites.add(chain.then((_) => _shareFullDayBoard(rule)));
        chain = pendingWrites.last;
      }
    }
    return (
      report: withNotes(report, notes),
      benefits: benefits,
      pendingWrites: pendingWrites,
    );
  }

  /// Share one out day's full departure board with
  /// FlightRoutes. Runs after the answer (never on the
  /// result path), chains sequentially so the shared
  /// provider's throttle stays polite, and turns every
  /// failure into its problems list plus an ErrorLog line --
  /// never an error thrown into the background.
  Future<List<String>> _shareFullDayBoard(TravelDay rule) async {
    final shared = sharedSchedules!;
    final writer = sharedBoardWriter!;
    final day = _isoDate(rule.day);
    final problems = <String>[];
    try {
      // Their own rule, extended to this side of the
      // handshake: a partial source never overwrites full-day
      // data cached by another provider. A complete board in
      // the cache is at least as good as anything this fetch
      // could produce, so a share would be churn, not value.
      final existing = await shared.loadBoards(day: day, airports: ['FRA']);
      if (!existing.ok) {
        problems.add('the shared-cache read failed before sharing '
            '(${existing.problems.join('; ')})');
        ErrorLog.instance.record('weekend-finder',
            'the FRA board for $day was not shared: ${problems.first}');
        return problems;
      }
      if (existing.boards.any(
          (board) => board.airport == 'FRA' && board.isCompleteV2)) {
        ErrorLog.instance.record(
            'weekend-finder',
            'the shared cache already holds a complete FRA board for '
            '$day; nothing was shared.');
        return problems;
      }

      // Only a whole day counts as a complete board: a full
      // day's walk (the whole-day fetch is the provider's
      // default) is the one shape that may be written. Stops
      // on a truncation warning, on zero flights (a "nothing
      // flies" answer is never cached as truth), and on any
      // write problem.
      final result = await provider.fetch(rule.day, 'departures');
      if (result.warning.isNotEmpty) {
        problems.add('the full-day walk stopped early (${result.warning})');
      } else if (result.flights.isEmpty) {
        problems.add('the board walked the whole day and answered '
            'no flights');
      } else {
        final payload = scheduleBoardPayload(
          airport: 'FRA',
          day: day,
          source: FraportBoardProvider.name,
          // The sibling format's stamp: naive local, seconds.
          obtainedAt: clock().toIso8601String().substring(0, 19),
          flights: result.flights,
        );
        final (wrote, writeProblems) = await writer.writeBoard(
          airport: 'FRA',
          day: day,
          payload: payload,
        );
        problems.addAll(writeProblems);
        if (problems.isEmpty && wrote) {
          ErrorLog.instance.record(
              'weekend-finder',
              'the complete FRA departure board for $day was shared with '
              'FlightRoutes (source ${result.source}, '
              '${result.flights.length} flight(s)).');
          return problems;
        } else if (problems.isEmpty) {
          ErrorLog.instance.record(
              'weekend-finder',
              'the shared FRA row for $day was kept newer; this fetch '
              'was not written.');
          return problems;
        }
      }
      ErrorLog.instance.record('weekend-finder',
          'the FRA board for $day was not shared: ${problems.join('; ')}',
          details: {'day': day, 'flights': result.flights.length});
      return problems;
    } catch (error) {
      final message = 'sharing the FRA board for $day failed ($error)';
      ErrorLog.instance.record('weekend-finder', message);
      return [message];
    }
  }

  Future<({List<Flight> flights, int windowCount})?> _cachedOutbound(
    TravelDay rule,
    String windowLabel,
    List<String> notes,
  ) async {
    final shared = sharedSchedules;
    if (shared == null) return null;
    final day = _isoDate(rule.day);
    final read = await shared.loadBoards(day: day, airports: const ['FRA']);
    if (!read.ok) {
      final note = '$windowLabel: the shared schedule read failed '
          '(${read.problems.join('; ')}); trying the live board.';
      notes.add(note);
      ErrorLog.instance.record('weekend-finder', note);
      return null;
    }
    FlightRoutesScheduleBoard? board;
    for (final candidate in read.boards) {
      if (candidate.airport == 'FRA' && candidate.day == day) {
        board = candidate;
        break;
      }
    }
    if (board == null) return null;
    final flights = _flightsFromBoard(board);
    if (flights == null) return null;
    final windowCount = flights.where((flight) {
      final minutes = flight.departure.hour * 60 + flight.departure.minute;
      return rule.accepts(minutes);
    }).length;
    notes.add('$windowLabel: using the exact-day ${board.source} schedule '
        'shared by FlightRoutes (fetched ${board.obtainedAt}).');
    return (flights: flights, windowCount: windowCount);
  }

  Future<void> _fillFromSharedScheduleCache({
    required TravelDay rule,
    required List<Flight> outbound,
    required List<Flight> sink,
    required String windowLabel,
    required List<String> notes,
  }) async {
    final shared = sharedSchedules;
    if (shared == null) return;
    final airports = <String>{
      for (final flight in outbound)
        if (RegExp(r'^[A-Z0-9]{3,4}$')
            .hasMatch(flight.destination.trim().toUpperCase()))
          flight.destination.trim().toUpperCase(),
    };
    if (airports.isEmpty) return;

    final previousDay = DateTime(rule.day.year, rule.day.month, rule.day.day - 1);
    final candidates = <Flight>[];
    for (final day in [_isoDate(rule.day), _isoDate(previousDay)]) {
      final read = await shared.loadBoards(day: day, airports: airports);
      if (!read.ok) {
        final note = '$windowLabel: the shared schedule read failed '
            '(${read.problems.join('; ')}); keeping the live-board results.';
        notes.add(note);
        ErrorLog.instance.record('weekend-finder', note);
        return;
      }
      for (final board in read.boards) {
        if (!airports.contains(board.airport)) continue;
        final flights = _flightsFromBoard(board);
        if (flights == null) continue;
        for (final flight in flights) {
          if (flight.destination != 'FRA' ||
              flight.arrival.year != rule.day.year ||
              flight.arrival.month != rule.day.month ||
              flight.arrival.day != rule.day.day) {
            continue;
          }
          final minutes = flight.arrival.hour * 60 + flight.arrival.minute;
          if (rule.accepts(minutes)) candidates.add(flight);
        }
      }
    }

    final seen = {
      for (final flight in sink)
        '${flight.flightNo}|${flight.departure.toIso8601String()}',
    };
    var added = 0;
    for (final flight in candidates) {
      final key = '${flight.flightNo}|${flight.departure.toIso8601String()}';
      if (seen.add(key)) {
        sink.add(flight);
        added++;
      }
    }
    if (added > 0) {
      final note = '$windowLabel: added $added return flight(s) from exact-day '
          'full boards in the shared FlightRoutes cache; the live-board '
          'results remain included.';
      notes.add(note);
      ErrorLog.instance.record('weekend-finder', note, details: {
        'window': windowLabel,
        'added': added,
        'airports': airports.length,
      });
    }
  }

  /// The board -> Flight list, or null. A board that is not
  /// a full v2 board, or whose records cannot be placed on a
  /// timeline, is a cache miss -- never "no flights".
  ///
  /// Departure stamps are required (wall-clock plus zoned
  /// UTC); arrival stamps are optional, because Travel
  /// Planner's own Fraport-sourced boards leave the arrival
  /// UTC blank (the far end's zone is unknown). A record
  /// without the arrival pair yields a flight with no
  /// duration -- the leg-duration cap then reports it kept
  /// rather than silently measuring wall-clocks against a
  /// wrong zone.
  static List<Flight>? _flightsFromBoard(
    FlightRoutesScheduleBoard board,
  ) {
    if (!board.isCompleteV2) return null;
    final flights = <Flight>[];
    for (final record in board.flights) {
      if (!record.hasDepartureTimeline ||
          record.destIata.isEmpty ||
          record.flightNo.isEmpty) {
        return null;
      }
      final departure = wallClock(record.depAtLocal);
      final departureUtc = DateTime.tryParse(record.depAtUtc);
      if (departure == null || departureUtc == null) return null;
      final arrival = wallClock(record.arrAtLocal) ?? departure;
      // A record with arrival stamps but unparseable ones is
      // corrupt, not arrival-free -- corrupt data must never
      // pass as an empty/tolerable gap.
      DateTime? arrivalUtc;
      if (record.hasArrivalTimeline) {
        arrivalUtc = DateTime.tryParse(record.arrAtUtc);
        if (arrivalUtc == null) return null;
      }
      Duration? duration;
      if (arrivalUtc != null) {
        duration = arrivalUtc.toUtc().difference(departureUtc.toUtc());
        if (duration.isNegative) return null;
      }
      flights.add(Flight(
        flightNo: record.flightNo,
        airline: record.carrierIata,
        airlineName: record.carrierName,
        origin: board.airport,
        destination: record.destIata,
        departure: departure,
        arrival: arrival,
        duration: duration,
      ));
    }
    return flights;
  }

  /// The "this data looks wrong" note for one window, or
  /// null when it looks healthy. A window that answered
  /// nothing at all, or that answered a fraction of what
  /// sibling windows answered, is a board-side gap -- the
  /// reader must not mistake it for "nowhere to fly".
  static String? _windowWarning(String window, int flights, int busiest) {
    if (flights == 0) {
      return '$window: the board returned no flights at all — nothing '
          'is scheduled or the board has no data for this window yet; '
          'the results below may be incomplete.';
    }
    if (busiest >= 30 && flights < busiest * 0.02) {
      return '$window: only $flights flight(s) where other windows '
          'returned up to $busiest — the board\'s data for this window '
          'looks incomplete; the results below may be incomplete.';
    }
    return null;
  }

  /// Ask the fallback about one suspicious window and merge
  /// what it returns (report j). The primary's flights stay
  /// authoritative -- the fallback only adds what is
  /// missing, keyed by flight number and departure.
  Future<void> _fillFromFallback({
    required TravelDay rule,
    required String kind,
    required List<Flight> sink,
    required int primaryCount,
    required String windowLabel,
    required List<String> notes,
  }) async {
    final source = fallback;
    if (source == null) return;
    final (since, until) = rule.fetchWindow();
    try {
      final result = await source.fetch(rule.day, kind,
          since: since, until: until);
      final seen = {
        for (final flight in sink)
          '${flight.flightNo}|${flight.departure.toIso8601String()}',
      };
      var added = 0;
      for (final flight in result.flights) {
        final key =
            '${flight.flightNo}|${flight.departure.toIso8601String()}';
        if (seen.add(key)) {
          sink.add(flight);
          added++;
        }
      }
      if (added > 0) {
        final note = '$windowLabel: the primary source looked incomplete '
            '($primaryCount flight(s)) — filled in $added flight(s) '
            'from ${result.source}.';
        notes.add(note);
        ErrorLog.instance.record('weekend-finder', note, details: {
          'window': windowLabel,
          'primary': primaryCount,
          'fallback flights': result.flights.length,
          'added': added,
        });
      }
    } on ProviderUnavailable catch (error) {
      final note =
          '$windowLabel: the fallback source could not help either '
          '(${error.message}).';
      notes.add(note);
      ErrorLog.instance.record('weekend-finder', error.message,
          details: {'window': windowLabel, 'source': 'fallback'});
    } catch (error) {
      final note =
          '$windowLabel: the fallback source failed ($error).';
      notes.add(note);
      ErrorLog.instance.record('weekend-finder', '$error',
          details: {'window': windowLabel, 'source': 'fallback'});
    }
  }

  /// Retain only flights within the cap; returns the number
  /// dropped. A flight whose arrival precedes its departure
  /// (a board glitch) stays: the matcher reports it, not
  /// this filter.
  static int _dropOverlong(List<Flight> flights, Duration cap) {
    final before = flights.length;
    flights.retainWhere((flight) =>
        (flight.duration ?? flight.arrival.difference(flight.departure)) <= cap);
    return before - flights.length;
  }

  /// A copy of the report with its notes attached; the pure
  /// matcher stays free of fetch failures.
  static MatchReport withNotes(MatchReport report, List<String> notes) {
    return MatchReport(
      plan: report.plan,
      cities: report.cities,
      oneWayOnly: report.oneWayOnly,
      outboundTotal: report.outboundTotal,
      returnTotal: report.returnTotal,
      outboundRejectedAirlines: report.outboundRejectedAirlines,
      shortStaysDropped: report.shortStaysDropped,
      shortStayCities: report.shortStayCities,
      notes: notes,
    );
  }

  static String _isoDate(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
