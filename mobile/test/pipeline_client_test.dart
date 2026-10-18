import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
    url: 'https://db.example.turso.io', token: 'token');

void main() {
  group('endpoint', () {
    test('libsql:// is upgraded to https and /v2/pipeline appended', () {
      const config =
          TursoConfig(url: 'libsql://db.example.turso.io', token: 'token');
      expect(
          TursoClient(config).endpoint, 'https://db.example.turso.io/v2/pipeline');
    });

    test('an explicit /v2/pipeline suffix is kept', () {
      const config = TursoConfig(
          url: 'https://db.example.turso.io/v2/pipeline', token: 'token');
      expect(
          TursoClient(config).endpoint, 'https://db.example.turso.io/v2/pipeline');
    });
  });

  group('runPipeline', () {
    test('decodes typed cells to plain Dart values', () async {
      final fake = FakeTurso((_) => okRows(
        ['destination', 'prio', 'safety_rating', 'comment'],
        [
          [
            {'type': 'text', 'value': 'Kyoto'},
            {'type': 'text', 'value': '2'},
            {'type': 'real', 'value': '8.5'},
            {'type': 'null', 'value': ''},
          ],
        ],
      ));
      final client = TursoClient(_config, httpClient: fake.client());
      final (rows, problems) = await client.query('SELECT * FROM destinations');
      expect(problems, isEmpty);
      expect(rows, [
        {
          'destination': 'Kyoto',
          'prio': '2',
          'safety_rating': 8.5,
          'comment': null,
        },
      ]);
    });

    test('an error inside a 200 response is a problem, not a result', () async {
      final fake =
          FakeTurso((_) => pipelineError('SQL parse error: syntax error'));
      final client = TursoClient(_config, httpClient: fake.client());
      final (rows, problems) = await client.query('SELECT broken');
      expect(rows, isEmpty);
      expect(problems, ['SQL parse error: syntax error']);
    });

    test('a 401 reports the rejected token', () async {
      final fake = FakeTurso((_) => httpStatus(401));
      final client = TursoClient(_config, httpClient: fake.client());
      final (_, problems) = await client.query('SELECT 1');
      expect(problems, ['Turso rejected the token (401)']);
    });

    test('a connection failure becomes a problem, never an exception',
        () async {
      final client = TursoClient(_config, httpClient: _FailingClient());
      final (_, problems) = await client.query('SELECT 1');
      // Same wording as turso_db.py: the exception type only.
      expect(problems.single, 'could not reach Turso: TimeoutException');
    });

    test('an unconfigured client never touches the network', () async {
      final fake = FakeTurso((_) =>
          throw StateError('no request expected while unconfigured'));
      const config = TursoConfig(
          url: 'https://db.example.turso.io', token: '');
      final client = TursoClient(config, httpClient: fake.client());
      final (rows, problems) = await client.query('SELECT 1');
      expect(rows, isEmpty);
      expect(problems, ['Turso URL or token is not set']);
    });

    test('always sends the statements in order and close last', () async {
      final fake = FakeTurso((_) => okEmpty(2));
      final client = TursoClient(_config, httpClient: fake.client());
      final (results, problems) =
          await client.runPipeline(['SELECT 1', 'SELECT 2']);
      expect(problems, isEmpty);
      expect(results, hasLength(2));
      expect(fake.requests.single, ['SELECT 1', 'SELECT 2']);
      expect(fake.requestTypes.single, ['execute', 'execute', 'close']);
    });
  });

  group('offlineProblem', () {
    // Only transport failures are worth replaying. The
    // distinction decides whether a failed write is queued
    // (and will succeed later) or surfaced immediately.
    test('transport failures count as offline', () {
      expect(offlineProblem('could not reach Turso: TimeoutException'),
          isTrue);
      expect(offlineProblem('could not reach Turso: SocketException'),
          isTrue);
      expect(offlineProblem('Turso is unavailable (503)'), isTrue);
      expect(offlineProblem('Turso returned a non-JSON response'), isTrue);
    });

    test('a rejected token or a statement error is not offline', () {
      expect(offlineProblem('Turso rejected the token (401)'), isFalse);
      expect(
          offlineProblem('Turso denied access (403) -- the token may be '
              'read-only for this database'),
          isFalse);
      expect(offlineProblem('SQLite error: no such column: nope'), isFalse);
      expect(offlineProblem('Turso URL or token is not set'), isFalse);
    });
  });

  group('rowsAffected', () {
    // The trip save's conflict guard is `rowsAffected == 0`,
    // so a null here silently reports every stale save as
    // saved. The live endpoint answers with
    // `affected_row_count` (probed 2026-10-18) and never with
    // `rows_affected` -- reading only the documented name is
    // what made the guard a no-op in production.
    test('reads the live field name, affected_row_count', () async {
      final fake = FakeTurso((_) => okEmptyLive(1, 0));
      final client = TursoClient(_config, httpClient: fake.client());
      final (results, problems) = await client.runPipeline(['DELETE FROM x']);
      expect(problems, isEmpty);
      expect(results.single.rowsAffected, 0);
    });

    test('reads a string-encoded count', () async {
      final fake = FakeTurso((_) => okWrites([3]));
      final client = TursoClient(_config, httpClient: fake.client());
      final (results, _) = await client.runPipeline(['DELETE FROM x']);
      expect(results.single.rowsAffected, 3);
    });

    test('prefers rows_affected when both are present', () async {
      final fake = FakeTurso((_) => http.Response.bytes(
            utf8.encode(jsonEncode({
              'results': [
                {
                  'type': 'ok',
                  'response': {
                    'result': {
                      'cols': const [],
                      'rows': const [],
                      'rows_affected': 2,
                      'affected_row_count': 7,
                    },
                  },
                },
              ],
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final client = TursoClient(_config, httpClient: fake.client());
      final (results, _) = await client.runPipeline(['DELETE FROM x']);
      expect(results.single.rowsAffected, 2);
    });

    test('is null when the endpoint reports no count at all', () async {
      // Pinned deliberately: null is "unknown", and the
      // guard must not read it as zero (a false conflict) --
      // but it also cannot read it as one. A future change to
      // the response shape must fail this test, not the guard.
      final fake = FakeTurso((_) => okEmpty(1));
      final client = TursoClient(_config, httpClient: fake.client());
      final (results, _) = await client.runPipeline(['DELETE FROM x']);
      expect(results.single.rowsAffected, isNull);
    });
  });
}

class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw TimeoutException('request timed out');
  }
}
