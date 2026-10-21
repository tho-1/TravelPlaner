import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/flight_routes_schedule_repository.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
  url: 'https://schedule.example.turso.io',
  token: 'fake-token',
);

String _payload({
  required String airport,
  required String day,
  int version = 2,
  Map<String, String>? coverage,
  List<Map<String, Object?>> flights = const [],
}) => jsonEncode({
  'meta': {
    'schema_version': version,
    'airport': airport,
    'date': day,
    'source': 'aerodatabox',
    'obtained_at': '2026-10-15T10:00:00Z',
    'n_flights': flights.length,
    'coverage': ?coverage,
  },
  'flights': flights,
});

Map<String, Object?> _flight({
  String number = 'LH100',
  String destination = 'MUC',
}) => {
  'dep_time': '10:00',
  'arr_time': '11:00',
  'carrier_iata': 'LH',
  'carrier_name': 'Lufthansa',
  'flight_no': number,
  'dest_iata': destination,
  'dep_at_local': '2026-10-16T10:00:00+02:00',
  'arr_at_local': '2026-10-16T11:00:00+02:00',
  'dep_at_utc': '2026-10-16T08:00:00Z',
  'arr_at_utc': '2026-10-16T09:00:00Z',
};

FlightRoutesScheduleRepository _repository(FakeTurso fake) =>
    FlightRoutesScheduleRepository(
      TursoClient(_config, httpClient: fake.client()),
    );

void main() {
  test('reads a v2 full-day board with its timezone-aware records', () async {
    final fake = FakeTurso((statements) {
      expect(statements.single, contains("day = '2026-10-16'"));
      expect(statements.single, contains("iata IN ('FRA')"));
      return okRows(
        ['iata', 'day', 'payload', 'updated_at'],
        [
          [
            'FRA',
            '2026-10-16',
            _payload(airport: 'FRA', day: '2026-10-16', flights: [_flight()]),
            '2026-10-15T10:00:00Z',
          ],
        ],
      );
    });

    final read = await _repository(fake)
        .loadBoards(day: '2026-10-16', airports: const ['fra']);

    expect(read.problems, isEmpty);
    final board = read.boards.single;
    expect(board.isCompleteV2, isTrue);
    expect(board.source, 'aerodatabox');
    expect(board.flights.single.depAtLocal, '2026-10-16T10:00:00+02:00');
    expect(board.flights.single.arrAtUtc, '2026-10-16T09:00:00Z');
    expect(fake.requestTypes.single.last, 'close');
  });

  test(
    'legacy and partial boards are not treated as full-day caches',
    () async {
      final payloads = [
        _payload(
          airport: 'FRA',
          day: '2026-10-16',
          version: 1,
          flights: [_flight()],
        ),
        _payload(
          airport: 'FRA',
          day: '2026-10-16',
          coverage: const {'from': '10:00', 'to': '12:00'},
          flights: [_flight()],
        ),
      ];
      for (final payload in payloads) {
        final fake = FakeTurso(
          (_) => okRows(
            ['iata', 'day', 'payload', 'updated_at'],
            [
              ['FRA', '2026-10-16', payload, '2026-10-15T10:00:00Z'],
            ],
          ),
        );
        final read = await _repository(fake)
            .loadBoards(day: '2026-10-16', airports: const ['FRA']);
        expect(read.problems, isEmpty);
        expect(read.boards.single.isCompleteV2, isFalse);
      }
    },
  );

  test('a cache miss is distinct from a failed read', () async {
    final missing = await _repository(
      FakeTurso(
        (_) => okRows(['iata', 'day', 'payload', 'updated_at'], const []),
      ),
    ).loadBoards(day: '2026-10-16', airports: const ['FRA']);
    expect(missing.ok, isTrue);
    expect(missing.boards, isEmpty);

    final failed = await _repository(
      FakeTurso((_) => pipelineError('table missing')),
    ).loadBoards(day: '2026-10-16', airports: const ['FRA']);
    expect(failed.ok, isFalse);
    expect(failed.boards, isEmpty);
    expect(failed.problems, isNotEmpty);
  });

  test('invalid calendar dates are rejected before a database query', () async {
    final fake = FakeTurso(
      (_) => okRows(['iata', 'day', 'payload', 'updated_at'], const []),
    );
    final result = await _repository(fake)
        .loadBoards(day: '2026-02-30', airports: const ['FRA']);
    expect(result.ok, isFalse);
    expect(fake.requests, isEmpty);
  });

  test(
    'airport codes are validated before being interpolated into SQL',
    () async {
      final fake = FakeTurso(
        (_) => okRows(['iata', 'day', 'payload', 'updated_at'], const []),
      );
      final result = await _repository(fake).loadBoards(
        day: '2026-10-16',
        airports: const ["FRA'); DROP TABLE schedule_boards; --"],
      );
      expect(result.ok, isFalse);
      expect(fake.requests, isEmpty);
    },
  );

  test('a corrupt payload is reported rather than returned as empty', () async {
    final result = await _repository(
      FakeTurso(
        (_) => okRows(
          ['iata', 'day', 'payload', 'updated_at'],
          [
            ['FRA', '2026-10-16', 'not json', '2026-10-15T10:00:00Z'],
          ],
        ),
      ),
    ).loadBoards(day: '2026-10-16', airports: const ['FRA']);
    expect(result.ok, isFalse);
    expect(result.boards, isEmpty);
  });

  test('a board whose payload does not match its key is rejected',
      () async {
    // The row says FRA, the payload says MUC. Accepting it
    // would put a Munich board in the Frankfurt slot, and
    // every reader downstream would be wrong.
    final result = await _repository(
      FakeTurso(
        (_) => okRows(
          ['iata', 'day', 'payload', 'updated_at'],
          [
            [
              'FRA',
              '2026-10-16',
              _payload(airport: 'MUC', day: '2026-10-16'),
              '2026-10-15T10:00:00Z',
            ],
          ],
        ),
      ),
    ).loadBoards(day: '2026-10-16', airports: const ['FRA']);
    expect(result.ok, isFalse);
    expect(result.boards, isEmpty);
    expect(result.problems, isNotEmpty);
  });

  test('a flight count that disagrees with the records is not a full day',
      () async {
    // The meta claims three flights, the payload carries
    // one. The board is then not a full-day cache and must
    // not be treated as one.
    final payload = jsonDecode(
          _payload(airport: 'FRA', day: '2026-10-16', flights: [_flight()]),
        ) as Map<String, dynamic>;
    (payload['meta'] as Map<String, dynamic>)['n_flights'] = 3;
    final result = await _repository(
      FakeTurso(
        (_) => okRows(
          ['iata', 'day', 'payload', 'updated_at'],
          [
            [
              'FRA',
              '2026-10-16',
              jsonEncode(payload),
              '2026-10-15T10:00:00Z',
            ],
          ],
        ),
      ),
    ).loadBoards(day: '2026-10-16', airports: const ['FRA']);
    expect(result.ok, isTrue);
    expect(result.boards.single.isCompleteV2, isFalse);
  });

  test('a flight without an arrival stamp still has its departure half',
      () async {
    // The Fraport-sourced full-day boards the app writes
    // carry the departure pair but leave the arrival UTC
    // blank. Such a flight is still usable for an outbound
    // match -- it just has no leg duration.
    final flight = _flight()..remove('arr_at_utc');
    final result = await _repository(
      FakeTurso(
        (_) => okRows(
          ['iata', 'day', 'payload', 'updated_at'],
          [
            [
              'FRA',
              '2026-10-16',
              _payload(airport: 'FRA', day: '2026-10-16', flights: [flight]),
              '2026-10-15T10:00:00Z',
            ],
          ],
        ),
      ),
    ).loadBoards(day: '2026-10-16', airports: const ['FRA']);
    expect(result.ok, isTrue);
    final record = result.boards.single.flights.single;
    expect(record.hasTimestamps, isFalse);
    expect(record.hasDepartureTimeline, isTrue);
    expect(record.hasArrivalTimeline, isFalse);
  });
}
