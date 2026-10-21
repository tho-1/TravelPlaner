/// The weekend finder's behaviour, end to end over the
/// repository: which source is asked, what is cached, what is
/// shared, and what the reader is told.
///
/// Two rules shape this file:
///
/// * **No API budget is spent.** Every provider here is a
///   fixture; nothing reaches the network. The cases that
///   matter for the budget -- a source that ran out of quota,
///   a window that is already cached -- are exercised with
///   fakes that count their calls.
/// * **The user's own reports are the cases.** The 2026-10-21
///   report was about a day that would not deselect, a return
///   line that showed one fact instead of two, and boards
///   being written to Turso that cost nothing to fetch.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/error_log.dart';
import 'package:travel_planner/data/flight_board_cache.dart';
import 'package:travel_planner/data/flight_routes_schedule_repository.dart';
import 'package:travel_planner/data/flight_routes_schedule_writer.dart';
import 'package:travel_planner/data/weekend_repository.dart';
import 'package:travel_planner/models/airline_benefits.dart';
import 'package:travel_planner/models/timetable.dart';
import 'package:travel_planner/models/travel_days.dart';
import 'package:travel_planner/models/weekend_match.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
  url: 'https://db.example.turso.io',
  token: 'token',
);

final _friday = DateTime(2026, 10, 23);
final _plan = legacyWeekendPlan(_friday);

const _benefits = (
  flags: {'LH': true, 'lufthansa': true},
  records: <AirlineRecord>[],
  sourceLabel: 'fake',
  problems: <String>[],
);

Flight _flight({
  required String no,
  required String from,
  required String to,
  required DateTime departure,
  required DateTime arrival,
  String airline = 'LH',
  String airlineName = 'Lufthansa',
  String airportName = '',
}) =>
    Flight(
      flightNo: no,
      airline: airline,
      airlineName: airlineName,
      origin: from,
      destination: to,
      airportName: airportName,
      departure: departure,
      arrival: arrival,
    );

String _window(DateTime day, String kind) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')} $kind';

/// A board that answers from a fixture map and counts the calls
/// it received, so a test can prove a window was *not* asked
/// for again.
class _CountingBoard implements FlightBoardProvider {
  @override
  bool get answersWholeDay => true;

  _CountingBoard(this.flightsByWindow, {this.failWith});

  final Map<String, List<Flight>> flightsByWindow;

  /// When set, every call fails with this message -- the
  /// "your monthly quota is used up" case.
  final String? failWith;

  final List<String> calls = [];

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String kind, {
    DateTime? since,
    DateTime? until,
  }) async {
    final key = _window(day, kind);
    calls.add(key);
    if (failWith != null) {
      throw ProviderUnavailable(failWith!);
    }
    return FetchResult(
      flights: flightsByWindow[key] ?? const <Flight>[],
      source: 'fraport',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}

/// A board that answers the full day, and records whether the
/// call was a full-day one (no window bounds).
class _FullDayBoard implements FlightBoardProvider {
  @override
  bool get answersWholeDay => true;

  _FullDayBoard(this.flights);

  final List<Flight> flights;
  final List<bool> fullDayCalls = [];

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String kind, {
    DateTime? since,
    DateTime? until,
  }) async {
    final full = since == null && until == null;
    fullDayCalls.add(full);
    return FetchResult(
      flights: flights,
      source: 'aerodatabox',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}

/// A board that answers a page for the window it was given,
/// the way AeroAPI does (`max_pages: 1`): one call is a page,
/// never a day.
class _WindowOnlyBoard implements FlightBoardProvider {
  @override
  bool get answersWholeDay => false;

  final List<String> calls = [];
  final List<bool> fullDayCalls = [];

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String kind, {
    DateTime? since,
    DateTime? until,
  }) async {
    calls.add(_window(day, kind));
    fullDayCalls.add(since == null && until == null);
    final hour = kind == 'departures' ? 15 : 8;
    final departure = DateTime(day.year, day.month, day.day, hour);
    return FetchResult(
      flights: [
        Flight(
          flightNo: kind == 'departures' ? 'LH1000' : 'LH2000',
          airline: 'LH',
          origin: kind == 'departures' ? 'FRA' : 'LHR',
          destination: kind == 'departures' ? 'LHR' : 'FRA',
          departure: departure,
          arrival: departure.add(const Duration(hours: 2)),
        ),
      ],
      source: 'flightaware',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}

void main() {
  group('the source that is asked', () {
    test('a healthy window never reaches the fallback', () async {
      // The fallback needs a credential, and credentials come
      // with request limits: it must only ever be asked about
      // the windows the primary did not deliver. Every window
      // of the plan answers here, so none of them is missing.
      final saturday = _friday.add(const Duration(days: 1));
      final sunday = _friday.add(const Duration(days: 2));
      // Calendar arithmetic: `add(Duration(days: 3))` is
      // absolute time, and across the DST change it lands an
      // hour early -- on the *Sunday*, which would overwrite
      // the Sunday key.
      final monday = DateTime(2026, 10, 26);
      final primary = _CountingBoard({
        _window(_friday, 'departures'): [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
        _window(saturday, 'departures'): [
          _flight(
            no: 'LH1001',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 24, 9),
            arrival: DateTime(2026, 10, 24, 11),
          ),
        ],
        _window(saturday, 'arrivals'): [
          _flight(
            no: 'LH2001',
            from: 'LHR',
            to: 'FRA',
            departure: DateTime(2026, 10, 24, 17),
            arrival: DateTime(2026, 10, 24, 19),
          ),
        ],
        _window(sunday, 'arrivals'): [
          _flight(
            no: 'LH2000',
            from: 'LHR',
            to: 'FRA',
            departure: DateTime(2026, 10, 25, 17),
            arrival: DateTime(2026, 10, 25, 19),
          ),
        ],
        _window(monday, 'arrivals'): [
          _flight(
            no: 'LH2002',
            from: 'LHR',
            to: 'FRA',
            departure: DateTime(2026, 10, 26, 6),
            arrival: DateTime(2026, 10, 26, 8),
          ),
        ],
      });
      final fallback = _CountingBoard(const {});
      final repository = WeekendRepository(primary, fallback: fallback);

      final result = await repository.search(_plan, _benefits);

      expect(result.report.cities, isNotEmpty);
      expect(fallback.calls, isEmpty,
          reason: 'a healthy window is never re-queried from a paid source');
    });

    test('a failed window is asked about exactly once', () async {
      final primary = _CountingBoard(const {});
      final fallback = _CountingBoard({
        _window(_friday, 'departures'): [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
      });
      final repository = WeekendRepository(primary, fallback: fallback);

      await repository.search(_plan, _benefits);

      expect(fallback.calls, isNotEmpty);
      // One call per suspicious window -- not one per search
      // and not one per page.
      expect(fallback.calls.toSet().length, fallback.calls.length,
          reason: 'a window is asked about once');
    });

    test('a source that ran out of quota leaves the answer standing',
        () async {
      // The case the user asked for: the credentialed source
      // says "your monthly limit is reached". The search must
      // still answer, and say what it could not do.
      final primary = _CountingBoard({
        _window(_friday, 'departures'): [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
      });
      final fallback = _CountingBoard(const {},
          failWith: 'aerodatabox: monthly request limit reached');
      final repository = WeekendRepository(primary, fallback: fallback);

      final result = await repository.search(_plan, _benefits);

      expect(result.report.notes.join(' '), contains('monthly request limit'));
      // The primary's own results are still there.
      expect(result.report.outboundTotal, greaterThan(0));
    });
  });

  group('the device cache of a paid source', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('board_cache'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('the answer is cached and the second search does not pay again',
        () async {
      final primary = _CountingBoard(const {});
      final fallback = _CountingBoard({
        _window(_friday, 'departures'): [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
      });
      final cache = FlightBoardCache('${temp.path}/boards');
      final repository = WeekendRepository(primary,
          fallback: fallback, fallbackCache: cache);

      await repository.search(_plan, _benefits);
      final callsAfterFirst = fallback.calls.length;
      expect(callsAfterFirst, greaterThan(0));

      // The second search: the same windows, the same fallback
      // instance -- but now the device has the answer, so the
      // paid source is not asked again.
      await repository.search(_plan, _benefits);
      expect(fallback.calls.length, callsAfterFirst,
          reason: 'the cached answer is used instead of a new request');
    });

    test('a cache miss falls back to the source', () async {
      final primary = _CountingBoard(const {});
      final fallback = _CountingBoard({
        _window(_friday, 'departures'): [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
      });
      final cache = FlightBoardCache('${temp.path}/boards');
      final repository = WeekendRepository(primary,
          fallback: fallback, fallbackCache: cache);

      await repository.search(_plan, _benefits);
      expect(fallback.calls, isNotEmpty);
    });

    test('an unconfigured cache never writes and never breaks', () async {
      final primary = _CountingBoard(const {});
      final fallback = _CountingBoard({
        _window(_friday, 'departures'): [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
      });
      final cache = FlightBoardCache('');
      expect(cache.isConfigured, isFalse);
      expect(cache.save(_friday, 'departures', const []), isFalse);
      expect(cache.load(_friday, 'departures'), isNull);

      final repository =
          WeekendRepository(primary, fallback: fallback, fallbackCache: cache);
      final result = await repository.search(_plan, _benefits);
      expect(result.report.notes, isNotEmpty);
    });
  });

  group('what is shared with the sibling', () {
    test('a Fraport board is not written to the shared cache', () async {
      // The Fraport board is free and can be re-grabbed any
      // time, so there is no reason to spend Turso space on
      // it (the user's decision, 2026-10-21).
      final primary = _CountingBoard({
        _window(_friday, 'departures'): [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'LHR',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
      });
      final shared = _SharedBoards();
      final writer = _RecordingWriter();
      final repository = WeekendRepository(
        primary,
        sharedSchedules: FlightRoutesScheduleRepository(shared.client),
        sharedBoardWriter: FlightRoutesScheduleWriter(writer.client),
      );

      final result = await repository.search(_plan, _benefits);
      for (final write in result.pendingWrites) {
        await write;
      }

      expect(writer.payloads, isEmpty,
          reason: 'a free board is never written to the shared cache');
    });

    test('a paging fallback is never shared as if it were a day', () async {
      // AeroAPI answers one page for the window it is given.
      // Writing that page as a whole-day board would tell the
      // sibling's readers that a short board is the day
      // (2026-10-21), so the share refuses instead.
      final primary = _CountingBoard(const {});
      final fallback = _WindowOnlyBoard();
      final shared = _SharedBoards();
      final writer = _RecordingWriter();
      final repository = WeekendRepository(
        primary,
        fallback: fallback,
        sharedSchedules: FlightRoutesScheduleRepository(shared.client),
        sharedBoardWriter: FlightRoutesScheduleWriter(writer.client),
      );

      final result = await repository.search(_plan, _benefits);
      for (final write in result.pendingWrites) {
        await write;
      }

      expect(fallback.fullDayCalls, isNotEmpty,
          reason: 'the paging fallback was asked, windowed');
      expect(fallback.fullDayCalls, everyElement(isFalse),
          reason: 'a paging provider is never asked for a whole day');
      expect(writer.payloads, isEmpty,
          reason: 'a page is not a whole-day board');
      expect(
        ErrorLog.instance.entries.where(
            (entry) => entry.message.contains('cannot answer a whole day')),
        isNotEmpty,
      );
    });

    test('a board that cost a credential is written', () async {
      // The fallback's answer is the data worth sharing: the
      // next search reads it from the cache instead of paying
      // for it again.
      final primary = _CountingBoard(const {});
      final fallback = _FullDayBoard([
        _flight(
          no: 'LH1000',
          from: 'FRA',
          to: 'LHR',
          departure: DateTime(2026, 10, 23, 15),
          arrival: DateTime(2026, 10, 23, 17),
        ),
      ]);
      final shared = _SharedBoards();
      final writer = _RecordingWriter();
      final repository = WeekendRepository(
        primary,
        fallback: fallback,
        sharedSchedules: FlightRoutesScheduleRepository(shared.client),
        sharedBoardWriter: FlightRoutesScheduleWriter(writer.client),
      );

      final result = await repository.search(_plan, _benefits);
      for (final write in result.pendingWrites) {
        await write;
      }

      expect(writer.payloads, isNotEmpty,
          reason: 'the paid board is the one worth sharing');
      // The payload names the source it came from -- the
      // sibling's own readers use that to tell a board apart.
      final payload = '${writer.args?[2] ?? ''}';
      expect(payload, contains('aerodatabox'));
    });
  });

  group('the return summary', () {
    test('it names the Sunday return and the Monday landing', () {
      // Both facts, not one of them (the report, 2026-10-21).
      final city = CityResult(
        city: 'Rome',
        country: 'IT',
        returns: [
          _flight(
            no: 'LH2000',
            from: 'FCO',
            to: 'FRA',
            departure: DateTime(2026, 10, 25, 17),
            arrival: DateTime(2026, 10, 25, 19),
          ),
          _flight(
            no: 'LH2001',
            from: 'FCO',
            to: 'FRA',
            departure: DateTime(2026, 10, 26, 6),
            arrival: DateTime(2026, 10, 26, 8),
          ),
        ],
      );
      final summary = cityReturnSummary(city);
      expect(summary, contains('Sunday 17:00 (takeoff)'));
      expect(summary, contains('Monday 08:00 (landing)'));
      expect(summary, contains(' or '));
    });

    test('a city that can only come home on Monday still says so', () {
      final city = CityResult(
        city: 'Rome',
        country: 'IT',
        returns: [
          _flight(
            no: 'LH2001',
            from: 'FCO',
            to: 'FRA',
            departure: DateTime(2026, 10, 26, 6),
            arrival: DateTime(2026, 10, 26, 8),
          ),
        ],
      );
      expect(cityReturnSummary(city), contains('Monday 08:00 (landing)'));
    });

    test('the matcher keeps the unpaired returns for the summary', () {
      // A Monday return that paired with no outbound is still
      // a Monday the reader can come home on.
      final report = findWeekends(
        outbound: [
          _flight(
            no: 'LH1000',
            from: 'FRA',
            to: 'FCO',
            departure: DateTime(2026, 10, 23, 15),
            arrival: DateTime(2026, 10, 23, 17),
          ),
        ],
        returns: [
          _flight(
            no: 'LH2000',
            from: 'FCO',
            to: 'FRA',
            departure: DateTime(2026, 10, 25, 17),
            arrival: DateTime(2026, 10, 25, 19),
          ),
          _flight(
            no: 'LH2001',
            from: 'FCO',
            to: 'FRA',
            departure: DateTime(2026, 10, 26, 6),
            arrival: DateTime(2026, 10, 26, 8),
          ),
        ],
        plan: _plan,
        airlineCheck: (code, name) => true,
        cityLookup: (airport) => airport == 'FCO' ? ('Rome', 'IT') : null,
      );
      final rome = report.cities.firstWhere((city) => city.city == 'Rome');
      expect(rome.returns.length, 2,
          reason: 'both return flights are kept for the summary');
      expect(cityReturnSummary(rome), contains('Monday 08:00 (landing)'));
    });
  });
}

/// The shared cache the repository reads: no board, so the
/// share path runs. The client records the statements, so a
/// test can see what was written.
class _SharedBoards {
  _SharedBoards() {
    client = TursoClient(
      _config,
      httpClient: FakeTurso((statements) {
        for (final statement in statements) {
          writes.add(statement);
        }
        return okRows(['iata', 'day', 'payload', 'updated_at'], []);
      }).client(),
    );
  }

  late final TursoClient client;
  final List<String> writes = [];
}

/// A writer that records what it was asked to write.
class _RecordingWriter {
  _RecordingWriter() {
    final fake = FakeTurso((statements) {
      for (final statement in statements) {
        if (statement.contains('INSERT INTO schedule_boards')) {
          payloads.add(statement);
        }
      }
      return okRows(['iata', 'day', 'payload', 'updated_at'], []);
    });
    fake_ = fake;
    client = TursoClient(_config, httpClient: fake.client());
  }

  late final FakeTurso fake_;
  late final TursoClient client;
  final List<String> payloads = [];

  /// The bound parameters of the first board write.
  List<Object?>? get args {
    for (final request in fake_.requestArgs) {
      if (request is! List) continue;
      for (final statementArgs in request) {
        if (statementArgs is List && statementArgs.length >= 3) {
          return statementArgs.cast<Object?>();
        }
      }
    }
    return null;
  }
}
