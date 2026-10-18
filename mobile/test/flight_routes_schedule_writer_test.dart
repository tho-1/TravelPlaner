/// The schedule-board write side: the statements, the typed
/// args, the stamp format and the guards. The SQL text and
/// the arg encoding mirror the FlightRoutes sibling's
/// `utils/sync.py` -- a written byte off there means their
/// apps misread or reject the row, so this file checks them
/// literally.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/flight_routes_schedule_writer.dart';
import 'package:travel_planner/models/schedule_board_payload.dart';
import 'package:travel_planner/models/weekend_match.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
    url: 'https://flightconnections.example.turso.io', token: 'token');

Flight _flight(String no, String dest) => Flight(
      flightNo: no,
      airline: 'LH',
      airlineName: 'Lufthansa',
      origin: 'FRA',
      destination: dest,
      departure: DateTime(2026, 10, 24, 14, 35),
      arrival: DateTime(2026, 10, 24, 15, 20),
    );

Map<String, Object?> _payload(List<Flight> flights) => scheduleBoardPayload(
      airport: 'FRA',
      day: '2026-10-24',
      source: 'fraport',
      obtainedAt: '2026-10-18T21:09:40',
      flights: flights,
    );

// One captured arg is the typed Hrana Value the wire
// carried; text args read their payload through here.
String argText(Object? arg) => (arg as Map)['value'] as String;

/// The statements verbatim from the sibling's `utils/sync.py`
/// (its `_BOARD_UPSERT` / `_PROV_UPSERT`, conditional forms).
const _boardSql = 'INSERT INTO schedule_boards (iata, day, payload, '
    'updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(iata, day) DO UPDATE SET '
    'payload = excluded.payload, updated_at = excluded.updated_at '
    'WHERE excluded.updated_at > schedule_boards.updated_at';
const _provSql = 'INSERT INTO schedule_provenance (key, source, '
    'obtained_at, n_flights, updated_at) VALUES (?, ?, ?, ?, ?) '
    'ON CONFLICT(key) DO UPDATE SET source = excluded.source, '
    'obtained_at = excluded.obtained_at, n_flights = excluded.n_flights, '
    'updated_at = excluded.updated_at '
    'WHERE excluded.updated_at > schedule_provenance.updated_at';

void main() {
  group('writeBoard', () {
    test('reads the stamp, then one pipeline with both statements',
        () async {
      final fake = FakeTurso((statements) => okWrites(const [1, 1]));
      final writer = FlightRoutesScheduleWriter(
        TursoClient(_config, httpClient: fake.client()),
        now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
      );

      final (wrote, problems) = await writer.writeBoard(
          airport: 'FRA', day: '2026-10-24', payload: _payload([_flight('LH1', 'BER')]));

      expect(problems, isEmpty);
      expect(wrote, true);
      // Request 1: the stamp read -- their apps may hold a
      // newer copy, and the live pipeline reports no
      // rows_affected, so the decision precedes the write.
      expect(fake.requests.length, 2);
      expect(fake.requests[0].single,
          'SELECT updated_at FROM schedule_boards '
          "WHERE iata = 'FRA' AND day = '2026-10-24'");
      expect(fake.requestTypes[0], ['execute', 'close']);
      // Request 2: board first, provenance second -- the
      // sibling's own write order (save_schedules).
      expect(fake.requests[1], [_boardSql, _provSql]);
      expect(fake.requestTypes[1], ['execute', 'execute', 'close']);
    });

    test('the args carry the row, the integer string-encoded', () async {
      final fake = FakeTurso((statements) => okWrites(const [1, 1]));
      final writer = FlightRoutesScheduleWriter(
        TursoClient(_config, httpClient: fake.client()),
        now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
      );
      final payload = _payload([
        _flight('LH1', 'BER'),
        _flight('LH2', 'VIE'),
        _flight('LH3', 'MUC'),
      ]);

      await writer.writeBoard(airport: 'FRA', day: '2026-10-24', payload: payload);

      final boardArgs = fake.requestArgs[1]![0] as List<Object?>;
      expect(argText(boardArgs[0]), 'FRA');
      expect(argText(boardArgs[1]), '2026-10-24');
      // The payload JSON travels as one text parameter, so a
      // board string full of quotes cannot break the SQL.
      expect((boardArgs[2] as Map)['type'], 'text');
      // The stamp: the sibling db.now_iso() format, exactly.
      expect(argText(boardArgs[3]), '2026-10-18T20:09:40+00:00');
      final provArgs = fake.requestArgs[1]![1] as List<Object?>;
      expect(
        provArgs[0],
        {'type': 'text', 'value': 'FRA|2026-10-24'},
      );
      expect(argText(provArgs[1]), 'fraport');
      expect(argText(provArgs[2]), '2026-10-18T21:09:40');
      // n_flights: the Hrana i64-as-string rule.
      expect(provArgs[3], {'type': 'integer', 'value': '3'});
      expect(argText(provArgs[4]), '2026-10-18T20:09:40+00:00');
    });

    test('the payload round-trips through its own JSON', () async {
      final fake = FakeTurso((statements) => okWrites(const [1, 1]));
      final writer = FlightRoutesScheduleWriter(
        TursoClient(_config, httpClient: fake.client()),
        now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
      );
      final payload = _payload([_flight('LH1', 'BER')]);

      await writer.writeBoard(airport: 'FRA', day: '2026-10-24', payload: payload);

      final encoded = argText((fake.requestArgs[1]![0] as List)[2]);
      expect(jsonDecode(encoded), payload);
    });

    test('a newer remote row keeps itself: no write, no error', () async {
      final fake = FakeTurso((statements) {
        final sql = statements.first;
        // The stamp read answers with a stamp newer than the
        // writer's frozen clock: their copy already wins.
        if (sql.startsWith('SELECT updated_at')) {
          return okRows(['updated_at'], [['2026-10-19T20:00:00+00:00']]);
        }
        return okWrites(const [1, 1]);
      });
      final writer = FlightRoutesScheduleWriter(
        TursoClient(_config, httpClient: fake.client()),
        now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
      );

      final (wrote, problems) = await writer.writeBoard(
          airport: 'FRA', day: '2026-10-24', payload: _payload([_flight('LH1', 'BER')]));

      expect(problems, isEmpty,
          reason: 'the remote kept its newer row -- not a failure');
      expect(wrote, false);
      expect(
        fake.requests.where(
            (s) => s.any((sql) => sql.startsWith('INSERT INTO'))),
        isEmpty,
        reason: 'a lost race must not send its payload at all',
      );
    });

    test('an older remote row is overwritten', () async {
      final fake = FakeTurso((statements) {
        final sql = statements.first;
        if (sql.startsWith('SELECT updated_at')) {
          return okRows(
              ['updated_at'], [['2026-10-17T08:00:00+00:00']]);
        }
        return okWrites(const [1, 1]);
      });
      final writer = FlightRoutesScheduleWriter(
        TursoClient(_config, httpClient: fake.client()),
        now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
      );

      final (wrote, problems) = await writer.writeBoard(
          airport: 'FRA', day: '2026-10-24', payload: _payload([_flight('LH1', 'BER')]));

      expect(problems, isEmpty);
      expect(wrote, true);
      expect(
        fake.requests[1],
        [_boardSql, _provSql],
        reason: 'a fresh fetch may replace a stale sibling copy',
      );
    });

    test('a failed remote read surfaces in problems', () async {
      final fake = FakeTurso((statements) => pipelineError('no such table'));
      final writer = FlightRoutesScheduleWriter(
        TursoClient(_config, httpClient: fake.client()),
        now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
      );

      final (wrote, problems) = await writer.writeBoard(
          airport: 'FRA', day: '2026-10-24', payload: _payload([_flight('LH1', 'BER')]));

      expect(wrote, false);
      expect(problems, isNotEmpty);
    });

    test('an unconfigured client reports, never throws', () async {
      const unconfigured = TursoConfig(url: '', token: '');
      final writer = FlightRoutesScheduleWriter(TursoClient(unconfigured),
          now: () => DateTime.utc(2026, 10, 18, 20, 9, 40));

      final (wrote, problems) = await writer.writeBoard(
          airport: 'FRA', day: '2026-10-24', payload: _payload([_flight('LH1', 'BER')]));

      expect(wrote, false);
      expect(problems.single, 'Turso URL or token is not set');
    });

    group('the complete-board guards', () {
      FlightRoutesScheduleWriter writerWith(FakeTurso fake) =>
          FlightRoutesScheduleWriter(
            TursoClient(_config, httpClient: fake.client()),
            now: () => DateTime.utc(2026, 10, 18, 20, 9, 40),
          );

      test('v1 boards are never written', () async {
        final fake = FakeTurso((statements) => okWrites(const [1, 1]));
        final payload = {
          'meta': {'schema_version': 1, 'airport': 'FRA', 'date': '2026-10-24',
                   'source': 'fraport', 'obtained_at': '', 'n_flights': 1},
          'flights': [_flight('LH1', 'BER')],
        };
        final (wrote, problems) = await writerWith(fake)
            .writeBoard(airport: 'FRA', day: '2026-10-24', payload: payload);
        expect(wrote, false);
        expect(problems.single, contains('schema-v2'));
        expect(fake.requests, isEmpty, reason: 'nothing travels');
      });

      test('partial (coverage) boards are never written', () async {
        final fake = FakeTurso((statements) => okWrites(const [1, 1]));
        final payload = _payload([_flight('LH1', 'BER')]);
        (payload['meta'] as Map)['coverage'] = {'from': '14:00', 'to': '23:59'};
        final (wrote, problems) = await writerWith(fake)
            .writeBoard(airport: 'FRA', day: '2026-10-24', payload: payload);
        expect(wrote, false);
        expect(problems.single, contains('coverage'));
        expect(fake.requests, isEmpty);
      });

      test('zero-flight boards are never written', () async {
        final fake = FakeTurso((statements) => okWrites(const [1, 1]));
        final (wrote, problems) = await writerWith(fake).writeBoard(
            airport: 'FRA', day: '2026-10-24', payload: _payload(const []));
        expect(wrote, false);
        expect(problems.single, contains('never written'));
        expect(fake.requests, isEmpty);
      });

      test('meta and key must agree', () async {
        final fake = FakeTurso((statements) => okWrites(const [1, 1]));
        final (wrote, problems) = await writerWith(fake).writeBoard(
            airport: 'MUC', day: '2026-10-24', payload: _payload([_flight('LH1', 'BER')]));
        expect(wrote, false);
        expect(problems.single, contains('does not match'));
        expect(fake.requests, isEmpty);
      });

      test('n_flights must match the records', () async {
        final fake = FakeTurso((statements) => okWrites(const [1, 1]));
        final payload = _payload([_flight('LH1', 'BER')]);
        (payload['meta'] as Map)['n_flights'] = 7;
        final (wrote, problems) = await writerWith(fake)
            .writeBoard(airport: 'FRA', day: '2026-10-24', payload: payload);
        expect(wrote, false);
        expect(problems.single, contains('does not match'));
        expect(fake.requests, isEmpty);
      });

      test('a payload without meta is rejected', () async {
        final fake = FakeTurso((statements) => okWrites(const [1, 1]));
        final (wrote, problems) = await writerWith(fake)
            .writeBoard(airport: 'FRA', day: '2026-10-24', payload: {'flights': []});
        expect(wrote, false);
        expect(problems.single, contains('meta'));
        expect(fake.requests, isEmpty);
      });
    });
  });
}
