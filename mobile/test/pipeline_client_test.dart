import 'dart:async';

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
}

class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw TimeoutException('request timed out');
  }
}
