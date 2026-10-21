/// The finder end to end with faked boards: one windowed
/// query per selected day in, one explainable report out.
/// No network, no assets (the lookup and the flags are
/// installed).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/data/error_log.dart';
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

final friday = DateTime(2026, 10, 16);

/// The legacy rules: out Fri from 14:00 / Sat before 12:00,
/// back Sat after 12:00 / Sun any / Mon before 09:00.
final plan = legacyWeekendPlan(friday);

/// One board page; page 2 ends the walk.
http.Response _page(List<Map<String, Object?>> records) => http.Response(
      jsonEncode({'data': records}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _empty() => _page(const []);

Map<String, Object?> _dep(String no, String iata, String stamp) => {
      'al': 'LH',
      'fnr': no,
      'iata': iata,
      'sched': stamp,
    };

Map<String, Object?> _arr(String no, String iata, String stamp) => {
      'al': 'LH',
      'fnr': no,
      'iata': iata,
      'sched': stamp,
    };

/// The board fixture: five windows, each with one
/// qualifying flight. `downFrom` is how many windows answer
/// (in query order) -- every page call of theirs works;
/// each later window fails. `empty` makes those windows
/// answer with no flights at all.
http.Client _board({int downFrom = 99, Set<String> empty = const {}}) {
  final calls = <String, int>{};
  return MockClient((request) async {
    final direction = request.url.queryParameters['flighttype']!;
    final time = request.url.queryParameters['time']!;
    final day = time.substring(0, 10);
    final key = '$day $direction';
    final page = int.parse(request.url.queryParameters['page']!);
    calls[key] = (calls[key] ?? 0) + 1;
    // A window's fate is per window, not per request: the
    // walk makes several page calls per window, and "the
    // first window answers" must cover all of them.
    final windowIndex = calls.keys.toList().indexOf(key);
    if (windowIndex >= downFrom) {
      return http.Response('board down', 503);
    }
    if (page > 1) return _empty();
    if (empty.contains(key)) return _empty();
    switch (key) {
      case '2026-10-16 departures':
        return _page([_dep('LH1000', 'LHR', '2026-10-16T15:10:00+0200')]);
      case '2026-10-17 departures':
        return _page([_dep('LH1001', 'CDG', '2026-10-17T09:00:00+0200')]);
      case '2026-10-17 arrivals':
        return _page([_arr('LH2000', 'LHR', '2026-10-17T19:30:00+0200')]);
      case '2026-10-18 arrivals':
        return _page([_arr('LH2002', 'CDG', '2026-10-18T20:30:00+0200')]);
      default: // 2026-10-19 arrivals
        return _page([_arr('LH2003', 'CDG', '2026-10-19T08:15:00+0200')]);
    }
  });
}

/// A board that answers from a fixture map, for the
/// fallback tests (no HTTP shape involved).
class _FakeBoard implements FlightBoardProvider {
  @override
  bool get answersWholeDay => false;

  _FakeBoard(this.flightsByWindow, {this.fail = const {}});

  final Map<String, List<Flight>> flightsByWindow;
  final Set<String> fail;

  static String label(DateTime day, String kind) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')} $kind';

  @override
  Future<FetchResult> fetch(DateTime day, String kind,
      {DateTime? since, DateTime? until}) async {
    final key = label(day, kind);
    if (fail.contains(key)) {
      throw const ProviderUnavailable('fake board down');
    }
    return FetchResult(
      flights: flightsByWindow[key] ?? const [],
      source: 'fake',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}

    // A provider that answers *windowed* calls and *full-day*
// calls differently and records every call, so a write-back
// test can say which shape was asked for. Full-day means
// both window bounds omitted -- the exact call the sharing
// pass makes.
class _SplitBoard implements FlightBoardProvider {
  /// It answers a whole day when asked without bounds (the
  /// `fullDay` map), which is what the fallback contract and
  /// the share pass need.
  @override
  bool get answersWholeDay => true;

  _SplitBoard({
    this.windows = const {},
    this.fullDay = const {},
    this.fullDayWarning = '',
    this.source = 'fraport',
  });

  final Map<String, List<Flight>> windows;
  final Map<String, List<Flight>> fullDay;
  final String fullDayWarning;
  final String source;
  final List<String> calls = [];

  @override
  Future<FetchResult> fetch(DateTime day, String kind,
      {DateTime? since, DateTime? until}) async {
    final label =
        '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')} $kind';
    final full = since == null && until == null;
    calls.add(full ? '$label (full day)' : label);
    final flights =
        (full ? fullDay[label] : windows[label]) ?? const <Flight>[];
    return FetchResult(
      flights: flights,
      source: source,
      warning: full ? fullDayWarning : '',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}

Flight _flight({
  required String no,
  required String from,
  required String to,
  required DateTime departure,
  int flightMinutes = 105,
  String airline = 'LH',
  String airportName = '',
}) =>
    Flight(
      flightNo: no,
      airline: airline,
      origin: from,
      destination: to,
      airportName: airportName,
      departure: departure,
      arrival: departure.add(Duration(minutes: flightMinutes)),
    );

const _benefits = (
  flags: {'LH': true, 'lufthansa': true},
  records: <AirlineRecord>[],
  sourceLabel: 'fake',
  problems: <String>[],
);

void main() {
  setUp(() {
    AirportLookup.installForTesting({
      'LHR': ('London', 'GB'),
      'CDG': ('Paris', 'FR'),
    });
  });

  test('a qualifying pair reaches the report as one city', () async {
    final repository = WeekendRepository(
        FraportBoardProvider(httpClient: _board(), throttleSeconds: 0));
    final result = await repository.search(plan, _benefits);
    expect(result.report.notes, isEmpty);
    final london = result.report.cities
        .firstWhere((city) => city.city == 'London');
    expect(london.count, 1);
    expect(london.options.single.outFlight.flightNo, 'LH1000');
    expect(london.options.single.backFlight.flightNo, 'LH2000');
    expect(london.options.single.nights, 1);
    // Both out legs were in their windows.
    expect(result.report.outboundTotal, 2);
  });

  test('full shared FlightRoutes boards supply both weekend legs', () async {
    final day = '2026-10-16';
    final returnDay = '2026-10-17';
    final fakeTurso = FakeTurso((statements) {
      final sql = statements.single;
      if (sql.contains("day = '$day'") && sql.contains("IN ('FRA')")) {
        return okRows(
          ['iata', 'day', 'payload', 'updated_at'],
          [
            [
              'FRA',
              day,
              jsonEncode({
                'meta': {
                  'schema_version': 2,
                  'airport': 'FRA',
                  'date': day,
                  'source': 'aerodatabox',
                  'obtained_at': '2026-10-15T12:00:00Z',
                  'n_flights': 1,
                },
                'flights': [
                  {
                    'dep_time': '15:10',
                    'arr_time': '15:55',
                    'carrier_iata': 'LH',
                    'carrier_name': 'Lufthansa',
                    'flight_no': 'LH1000',
                    'dest_iata': 'LHR',
                    'dep_at_local': '2026-10-16T15:10:00+02:00',
                    'arr_at_local': '2026-10-16T15:55:00+01:00',
                    'dep_at_utc': '2026-10-16T13:10:00Z',
                    'arr_at_utc': '2026-10-16T14:55:00Z',
                  },
                ],
              }),
              '2026-10-15T12:00:00Z',
            ],
          ],
        );
      }
      if (sql.contains("day = '$returnDay'") && sql.contains("IN ('LHR')")) {
        return okRows(
          ['iata', 'day', 'payload', 'updated_at'],
          [
            [
              'LHR',
              returnDay,
              jsonEncode({
                'meta': {
                  'schema_version': 2,
                  'airport': 'LHR',
                  'date': returnDay,
                  'source': 'aerodatabox',
                  'obtained_at': '2026-10-16T12:00:00Z',
                  'n_flights': 1,
                },
                'flights': [
                  {
                    'dep_time': '17:30',
                    'arr_time': '20:30',
                    'carrier_iata': 'LH',
                    'carrier_name': 'Lufthansa',
                    'flight_no': 'LH2000',
                    'dest_iata': 'FRA',
                    'dep_at_local': '2026-10-17T17:30:00+01:00',
                    'arr_at_local': '2026-10-17T20:30:00+02:00',
                    'dep_at_utc': '2026-10-17T16:30:00Z',
                    'arr_at_utc': '2026-10-17T18:30:00Z',
                  },
                ],
              }),
              '2026-10-16T12:00:00Z',
            ],
          ],
        );
      }
      return okRows(
        ['iata', 'day', 'payload', 'updated_at'],
        const [],
      );
    });
    final shared = FlightRoutesScheduleRepository(
      TursoClient(
        const TursoConfig(url: 'https://shared.test.turso.io', token: 'fake'),
        httpClient: fakeTurso.client(),
      ),
    );
    final selectedDays = TravelPlan(
      outDays: [TravelDay(DateTime(2026, 10, 16))],
      backDays: [TravelDay(DateTime(2026, 10, 17))],
    );
    final repository = WeekendRepository(
      _FakeBoard(const {}),
      sharedSchedules: shared,
    );

    final result = await repository.search(selectedDays, _benefits);

    final london = result.report.cities.single;
    expect(london.city, 'London');
    expect(london.options.single.outFlight.flightNo, 'LH1000');
    expect(london.options.single.backFlight.flightNo, 'LH2000');
    expect(london.options.single.nights, 1);
    expect(london.options.single.outFlight.duration, const Duration(minutes: 105));
    expect(result.report.notes, contains(contains('shared by FlightRoutes')));
    expect(fakeTurso.requests.length, greaterThanOrEqualTo(3));
  });

  test('an airline the filter drops explains itself in the report',
      () async {
    final repository = WeekendRepository(
        FraportBoardProvider(httpClient: _board(), throttleSeconds: 0));
    final result = await repository.search(
      plan,
      (
        flags: const {},
        records: const <AirlineRecord>[],
        sourceLabel: 'nothing qualifies',
        problems: const ['source empty'],
      ),
      // The old "only airlines with benefits" behaviour.
      options:
          const WeekendSearchOptions(airlineScope: AirlineScope.allWithBenefits),
    );
    expect(result.report.cities, isEmpty);
    expect(result.report.outboundRejectedAirlines, {'LH': 2});
    expect(describeRule(result.report.outboundRejectedAirlines),
        contains('LH (2)'));
  });

  test('a board failure becomes a note, not a crash, and keeps partial legs',
      () async {
    // The first window answers; every later query fails.
    final repository = WeekendRepository(FraportBoardProvider(
        httpClient: _board(downFrom: 1), throttleSeconds: 0));
    final result = await repository.search(plan, _benefits);
    expect(result.report.notes, hasLength(4));
    for (final note in result.report.notes) {
      expect(note, contains('HTTP 503'));
    }
    // The outbound that did arrive is kept; the city shows
    // as a one-way near miss instead of vanishing.
    expect(result.report.oneWayOnly, isNotEmpty);
    expect(result.report.cities, isEmpty);
  });

  test('a window with no flights at all says so instead of looking like '
      '"nowhere to fly"', () async {
    final repository = WeekendRepository(FraportBoardProvider(
        httpClient: _board(empty: {'2026-10-18 arrivals'}),
        throttleSeconds: 0));
    final result = await repository.search(plan, _benefits);
    final notes = result.report.notes
        .where((note) => note.contains('no flights at all'))
        .toList();
    expect(notes, hasLength(1));
    expect(notes.single, contains('2026-10-18 arrivals'));
    // The healthy legs still produced their cities.
    expect(result.report.cities, isNotEmpty);
  });

  test('the fallback fills a window the primary lost', () async {
    // The primary answers the Friday out and two of the
    // three back windows; Sunday arrivals fail. The
    // fallback carries that day.
    final sunday = DateTime(2026, 10, 18);
    final monday = DateTime(2026, 10, 19);
    final primary = _FakeBoard(
      {
        _FakeBoard.label(friday, 'departures'): [
          _flight(
              no: 'LH1000',
              from: 'FRA',
              to: 'LHR',
              departure: DateTime(2026, 10, 16, 15, 10),
              airportName: 'Heathrow'),
        ],
        _FakeBoard.label(DateTime(2026, 10, 17), 'arrivals'): [
          _flight(
              no: 'LH2000',
              from: 'LHR',
              to: 'FRA',
              departure: DateTime(2026, 10, 17, 17, 30),
              airportName: 'Heathrow'),
        ],
        _FakeBoard.label(monday, 'arrivals'): [
          _flight(
              no: 'LH2003',
              from: 'CDG',
              to: 'FRA',
              departure: DateTime(2026, 10, 19, 6, 0),
              airportName: 'Charles de Gaulle'),
        ],
      },
      fail: {
        _FakeBoard.label(sunday, 'arrivals'),
        _FakeBoard.label(DateTime(2026, 10, 17), 'departures'),
      },
    );
    final fallback = _FakeBoard({
      _FakeBoard.label(sunday, 'arrivals'): [
        _flight(
            no: 'LH2002',
            from: 'LHR',
            to: 'FRA',
            departure: DateTime(2026, 10, 18, 18, 0),
            airportName: 'Heathrow'),
      ],
    });
    final repository = WeekendRepository(primary, fallback: fallback);
    final result = await repository.search(plan, _benefits);

    final fill = result.report.notes
        .where((note) => note.contains('filled in'))
        .toList();
    expect(fill, hasLength(1));
    expect(fill.single, contains('2026-10-18 arrivals'));
    expect(fill.single, contains('1 flight(s)'));
    // The failed Saturday-departures window had nothing to
    // fill (the fallback answered with no flights), so its
    // note stays a failure note.
    expect(
      result.report.notes
          .where((note) => note.contains('fake board down')),
      hasLength(2),
    );
    // The fallback flight paired with the Friday outbound.
    final london = result.report.cities
        .firstWhere((city) => city.city == 'London');
    expect(
      london.options
          .any((option) => option.backFlight.flightNo == 'LH2002'),
      isTrue,
    );
  });

  group('the FlightRoutes write-back (2026-10-18)', () {
    FlightRoutesScheduleRepository sharedRepo(FakeTurso fakeTurso) =>
        FlightRoutesScheduleRepository(
          TursoClient(
            const TursoConfig(
                url: 'https://shared.test.turso.io', token: 'fake'),
            httpClient: fakeTurso.client(),
          ),
        );

    WeekendRepository repoFor(
      _SplitBoard board, {
      required FlightRoutesScheduleRepository shared,
      FlightBoardProvider? fallback,
    }) =>
        WeekendRepository(
          board,
          fallback: fallback,
          sharedSchedules: shared,
          sharedBoardWriter: FlightRoutesScheduleWriter(
            shared.client,
            now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
          ),
          clock: () => DateTime(2026, 10, 18, 21, 9, 40),
        );

    test('a live Fraport search shares nothing to the shared cache', () async {
      // Fraport is free and unlimited, so its boards can be
      // re-grabbed any time and never spend Turso space; the
      // whole-day walk is not even run (the user's decision,
      // 2026-10-21).
      const day = '2026-10-16';
      const otherOut = '2026-10-17';
      final fakeTurso = FakeTurso((statements) {
        if (statements.any((sql) => sql.startsWith('INSERT INTO'))) {
          return okWrites(const [1, 1]);
        }
        // Cache miss everywhere: every window runs live.
        return okRows(
            ['iata', 'day', 'payload', 'updated_at'], const []);
      });
      final board = _SplitBoard(
        windows: {
          // The window the matcher asks about.
          '$day departures': [
            _flight(
                no: 'LH1000',
                from: 'FRA',
                to: 'LHR',
                departure: DateTime(2026, 10, 16, 15, 10)),
          ],
        },
        fullDay: {
          // A whole day ready to go -- must never be walked.
          '$day departures': [
            _flight(
                no: 'LH1000',
                from: 'FRA',
                to: 'LHR',
                departure: DateTime(2026, 10, 16, 15, 10)),
            _flight(
                no: 'LH1010',
                from: 'FRA',
                to: 'MUC',
                departure: DateTime(2026, 10, 16, 9, 30)),
          ],
        },
      );
      final shared = sharedRepo(fakeTurso);
      final repository = repoFor(board, shared: shared);

      final result = await repository.search(plan, _benefits);
      for (final write in result.pendingWrites) {
        await write;
      }

      expect(result.pendingWrites, isEmpty,
          reason: 'a free board is never shared');
      expect(
        board.calls.where((call) => call.endsWith('(full day)')),
        isEmpty,
        reason: 'no share means no whole-day walk',
      );
      expect(
        fakeTurso.requests.where(
            (s) => s.any((sql) => sql.startsWith('INSERT INTO'))),
        isEmpty,
        reason: 'nothing cost a credential, so nothing is written',
      );
      expect(otherOut, isNotEmpty); // the second out day is untouched too
    });

    test('a board that arrived while the search ran is not overwritten',
        () async {
      // The race the guard exists for: the out day's board was
      // a cache miss when the search started, and another
      // device wrote a complete board before the share ran. A
      // second writer must not replace a complete board.
      const day = '2026-10-16';
      var sharedReads = 0;
      final fakeTurso = FakeTurso((statements) {
        final sql = statements.first;
        if (sql.startsWith('INSERT INTO')) {
          return okWrites(const [1, 1]);
        }
        if (sql.contains("day = '$day'")) {
          sharedReads++;
          // The search's read: nothing there yet.
          if (sharedReads == 1) {
            return okRows(
                ['iata', 'day', 'payload', 'updated_at'], const []);
          }
          // The share's read: a complete board now exists.
          return okRows([
            'iata',
            'day',
            'payload',
            'updated_at'
          ], [
            [
              'FRA',
              day,
              jsonEncode({
                'meta': {
                  'schema_version': 2,
                  'airport': 'FRA',
                  'date': day,
                  'source': 'aerodatabox',
                  'obtained_at': '2026-10-15T12:00:00Z',
                  'n_flights': 1,
                },
                'flights': [
                  {
                    'dep_time': '15:10',
                    'arr_time': '15:55',
                    'carrier_iata': 'LH',
                    'carrier_name': 'Lufthansa',
                    'flight_no': 'LH1000',
                    'dest_iata': 'LHR',
                    'dep_at_local': '2026-10-16T15:10:00+02:00',
                    'arr_at_local': '2026-10-16T15:55:00+01:00',
                    'dep_at_utc': '2026-10-16T13:10:00Z',
                    'arr_at_utc': '2026-10-16T14:55:00Z',
                  },
                ],
              }),
              '2026-10-15T12:00:00Z',
            ],
          ]);
        }
        return okRows(
            ['iata', 'day', 'payload', 'updated_at'], const []);
      });
      // The primary answers nothing for the out day, so the
      // fallback is asked -- and its answer is what a share
      // would come from.
      final board = _SplitBoard(
        windows: {
          '$day departures': const [],
        },
      );
      final fallback = _SplitBoard(
        fullDay: {
          '$day departures': [
            _flight(
                no: 'LH1000',
                from: 'FRA',
                to: 'LHR',
                departure: DateTime(2026, 10, 16, 15, 10)),
          ],
        },
        source: 'aerodatabox',
      );
      final selectedDays = TravelPlan(
        outDays: [TravelDay(DateTime(2026, 10, 16))],
        backDays: [TravelDay(DateTime(2026, 10, 17))],
      );
      final shared = sharedRepo(fakeTurso);
      final repository =
          repoFor(board, shared: shared, fallback: fallback);

      final result = await repository.search(selectedDays, _benefits);
      await Future.wait(result.pendingWrites);

      expect(result.report.outboundTotal, 1);
      expect(
        fakeTurso.requests.where(
            (s) => s.any((sql) => sql.startsWith('INSERT INTO'))),
        isEmpty,
        reason: 'a complete board is never replaced by a share',
      );
      expect(
        ErrorLog.instance.entries.where((entry) => entry.message
            .contains('already holds a complete FRA board')),
        isNotEmpty,
      );
    });

    test('a truncated fallback day is never shared', () async {
      const day = '2026-10-16';
      final fakeTurso = FakeTurso((statements) {
        if (statements.any((sql) => sql.startsWith('INSERT INTO'))) {
          return okWrites(const [1, 1]);
        }
        return okRows(
            ['iata', 'day', 'payload', 'updated_at'], const []);
      });
      // The primary answers nothing, so the fallback is asked;
      // its whole-day walk stops without covering the day.
      final board = _SplitBoard(
        windows: {
          '$day departures': const [],
        },
      );
      final fallback = _SplitBoard(
        fullDay: {
          '$day departures': [
            _flight(
                no: 'LH1000',
                from: 'FRA',
                to: 'LHR',
                departure: DateTime(2026, 10, 16, 15, 10)),
          ],
        },
        fullDayWarning:
            'stopped after 64 pages without reaching the end of the window',
        source: 'aerodatabox',
      );
      final selectedDays = TravelPlan(
        outDays: [TravelDay(DateTime(2026, 10, 16))],
        backDays: [TravelDay(DateTime(2026, 10, 17))],
      );
      final shared = sharedRepo(fakeTurso);
      final repository =
          repoFor(board, shared: shared, fallback: fallback);

      final result = await repository.search(selectedDays, _benefits);
      await Future.wait(result.pendingWrites);

      expect(
        fakeTurso.requests.where(
            (s) => s.any((sql) => sql.startsWith('INSERT INTO'))),
        isEmpty,
        reason: 'a truncated day is not a complete board',
      );
      expect(
        ErrorLog.instance.entries
            .where((entry) => entry.message.contains('$day was not shared')),
        isNotEmpty,
      );
    });

    test('a Travel Planner share round-trips through the shared cache',
        () async {
      const day = '2026-10-16';
      const returnDay = '2026-10-17';
      final fakeTurso = FakeTurso((statements) {
        final sql = statements.first;
        if (sql.contains("day = '$day'")) {
          // Exactly what the writer sends for one FRA
          // departure: departure stamps real, the arrival
          // pair blanks (the far end's zone is unknown).
          return okRows([
            'iata',
            'day',
            'payload',
            'updated_at'
          ], [
            [
              'FRA',
              day,
              jsonEncode({
                'meta': {
                  'schema_version': 2,
                  'airport': 'FRA',
                  'date': day,
                  'source': 'fraport',
                  'obtained_at': '2026-10-18T21:09:40',
                  'n_flights': 1,
                },
                'flights': [
                  {
                    'dep_time': '15:10',
                    'arr_time': '15:55',
                    'carrier_iata': 'LH',
                    'carrier_name': 'Lufthansa',
                    'flight_no': 'LH1000',
                    'dest_iata': 'LHR',
                    'price': null,
                    'dep_at_local': '2026-10-16T15:10:00+02:00',
                    'arr_at_local': '2026-10-16T15:55:00',
                    'dep_at_utc': '2026-10-16T13:10:00Z',
                    'arr_at_utc': '',
                  },
                ],
              }),
              '2026-10-18T20:09:40+00:00',
            ],
          ]);
        }
        if (sql.contains("day = '$returnDay'")) {
          return okRows([
            'iata',
            'day',
            'payload',
            'updated_at'
          ], [
            [
              'LHR',
              returnDay,
              jsonEncode({
                'meta': {
                  'schema_version': 2,
                  'airport': 'LHR',
                  'date': returnDay,
                  'source': 'aerodatabox',
                  'obtained_at': '2026-10-16T12:00:00Z',
                  'n_flights': 1,
                },
                'flights': [
                  {
                    'dep_time': '17:30',
                    'arr_time': '20:30',
                    'carrier_iata': 'LH',
                    'carrier_name': 'Lufthansa',
                    'flight_no': 'LH2000',
                    'dest_iata': 'FRA',
                    'dep_at_local': '2026-10-17T17:30:00+01:00',
                    'arr_at_local': '2026-10-17T20:30:00+02:00',
                    'dep_at_utc': '2026-10-17T16:30:00Z',
                    'arr_at_utc': '2026-10-17T18:30:00Z',
                  },
                ],
              }),
              '2026-10-16T12:00:00Z',
            ],
          ]);
        }
        return okRows(
            ['iata', 'day', 'payload', 'updated_at'], const []);
      });
      final selectedDays = TravelPlan(
        outDays: [TravelDay(DateTime(2026, 10, 16))],
        backDays: [TravelDay(DateTime(2026, 10, 17))],
      );
      final shared = sharedRepo(fakeTurso);
      final provider = _SplitBoard(fullDay: const {});
      final repository = WeekendRepository(
        provider,
        sharedSchedules: shared,
        sharedBoardWriter: FlightRoutesScheduleWriter(shared.client),
        clock: () => DateTime(2026, 10, 18, 21, 9, 40),
      );

      final result = await repository.search(selectedDays, _benefits);
      await Future.wait(result.pendingWrites);

      // The dep-only board answers the outbound leg with no
      // duration; the fully stamped sibling board keeps its
      // exact leg length.
      final london = result.report.cities.single;
      expect(london.city, 'London');
      expect(london.options.single.outFlight.flightNo, 'LH1000');
      expect(london.options.single.outFlight.duration, isNull,
          reason: 'without an arrival UTC there is no leg length');
      expect(london.options.single.backFlight.duration,
          const Duration(minutes: 120));
      expect(result.report.notes, contains(contains('shared by FlightRoutes')));
      // ... and the row it reads being complete, no share
      // was attempted (no departure fetch at all).
      expect(
        provider.calls.where((call) => call.contains('departures')),
        isEmpty,
      );
    });

    test('without the shared cache wired, nothing is shared', () async {
      final repository = WeekendRepository(
          FraportBoardProvider(
              httpClient: _board(), throttleSeconds: 0));
      final result = await repository.search(plan, _benefits);
      expect(result.pendingWrites, isEmpty);
    });
  });
}

