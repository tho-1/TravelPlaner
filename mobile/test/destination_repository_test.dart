import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

DestinationRepository _repo(FakeTurso fake) =>
    DestinationRepository(TursoClient(
      const TursoConfig(url: 'https://db.example.turso.io', token: 'token'),
      httpClient: fake.client(),
    ));

void main() {
  test('loadDestinations parses every row', () async {
    final fake = FakeTurso((statements) {
      expect(statements.single,
          'SELECT * FROM destinations ORDER BY destination');
      return okRows(['destination', 'country', 'data'], [
        ['Kyoto', 'Japan', jsonEncode([])],
        ['Lima', 'Peru', jsonEncode([])],
      ]);
    });
    final (destinations, problems) = await _repo(fake).loadDestinations();
    expect(problems, isEmpty);
    expect([for (final dest in destinations) dest.name], ['Kyoto', 'Lima']);
  });

  test('loadDestinations reports problems instead of an empty list',
      () async {
    final fake = FakeTurso((_) => pipelineError('no such table'));
    final (destinations, problems) = await _repo(fake).loadDestinations();
    expect(destinations, isEmpty);
    expect(problems, ['no such table']);
  });

  test('getDestination escapes single quotes in the name', () async {
    final fake = FakeTurso((_) => okRows(['destination'], []));
    final (dest, problems) = await _repo(fake).getDestination("Saint O'Brien");
    expect(problems, isEmpty);
    expect(dest, isNull);
    expect(
      fake.requests.single.single,
      "SELECT * FROM destinations WHERE destination = 'Saint O''Brien'",
    );
  });

  test('getDestination distinguishes unknown from failed', () async {
    final unknown = FakeTurso((_) => okRows(['destination'], []));
    final (missing, missingProblems) =
        await _repo(unknown).getDestination('Nowhere');
    expect(missing, isNull);
    expect(missingProblems, isEmpty);

    final failed = FakeTurso((_) => pipelineError('timeout'));
    final (dest, problems) = await _repo(failed).getDestination('Kyoto');
    expect(dest, isNull);
    expect(problems, isNotEmpty);
  });

  test('updateField read-modify-writes the typed core and the tail',
      () async {
    final fake = FakeTurso((statements) {
      if (statements.single.startsWith('SELECT')) {
        return okRows(
          [
            'destination', 'continent', 'country', 'visited', 'favourite',
            'prio', 'safety_rating', 'avg_cost_day', 'flight_time_fra',
            'to_be_researched', 'malaria_risk', 'data_status', 'comment',
            'data',
          ],
          [[
            'Kyoto', 'Asia', 'Japan', 1, 1, '2', 8.5, 120, 14.2, 0,
            'no — no local transmission', null, 'Temples',
            jsonEncode([
              ['Destination', 'Kyoto'],
              ['Prio Thorsten', '2'],
              ['Comment', 'Temples'],
              ['In näherer Auswahl 2025?', true],
            ]),
          ]],
        );
      }
      return okEmpty(1);
    });
    final ok = await _repo(fake).updateField('Kyoto', 'favourite', false);
    expect(ok, isTrue);
    expect(fake.requests, hasLength(2));

    final sql = fake.requests.last.single;
    // The typed core: destination, continent, country,
    // visited=1, favourite=0, prio text, the numbers, the
    // remaining booleans, the comment.
    expect(
      sql,
      contains("'Kyoto', 'Asia', 'Japan', 1, 0, '2', "
          '8.5, 120, 14.2, 0, 0, NULL,'),
    );
    // The tail: the favourite entry replaced, everything
    // else untouched.
    expect(sql, contains('In näherer Auswahl 2025?",false]'));
    expect(sql, contains('["Comment","Temples"]'));
    expect(sql, contains('+00:00'));
    expect(sql, contains('ON CONFLICT(destination) DO UPDATE SET'));
  });

  test('updateField writes nothing when the destination is unknown',
      () async {
    final fake = FakeTurso((_) => okRows(['destination'], []));
    final ok = await _repo(fake).updateField('Nowhere', 'favourite', true);
    expect(ok, isFalse);
    expect(fake.requests, hasLength(1), reason: 'only the read ran');
  });

  test('saveDestination returns false on a failed write', () async {
    final fake = FakeTurso((_) => pipelineError('read-only database'));
    const dest = Destination(core: {'destination': 'Kyoto'});
    final ok = await _repo(fake).saveDestination(dest);
    expect(ok, isFalse);
  });
}
