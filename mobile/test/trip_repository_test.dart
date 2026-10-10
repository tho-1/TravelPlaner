import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/trip_repository.dart';
import 'package:travel_planner/models/trip.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

TripRepository _repo(FakeTurso fake) => TripRepository(TursoClient(
      const TursoConfig(url: 'https://db.example.turso.io', token: 'token'),
      httpClient: fake.client(),
    ));

void main() {  test('loadTrips reads the four tables in one request and groups them',
      () async {
    final fake = FakeTurso((statements) {
      expect(statements, hasLength(4));
      expect(statements[0], 'SELECT * FROM trips ORDER BY created');
      expect(statements[1], 'SELECT * FROM variants ORDER BY trip_id, rowid');
      expect(statements[2], 'SELECT * FROM stops ORDER BY variant_id, position');
      expect(statements[3], 'SELECT * FROM legs ORDER BY variant_id, position');
      return okMulti([
        (
          ['id', 'name', 'created'],
          [
            ['t-1', 'Japan 2026', null],
          ],
        ),
        (
          ['id', 'trip_id', 'name'],
          [
            ['v-1', 't-1', 'Spring'],
            ['v-2', 't-1', 'Autumn'],
          ],
        ),
        (
          [
            'id', 'variant_id', 'position', 'kind', 'name', 'country',
            'lat', 'lon', 'role',
          ],
          [
            [
              's-1', 'v-1', 0, 'start', 'Frankfurt', 'Germany', 50.0379,
              8.5622, 'start',
            ],
            ['s-2', 'v-1', 1, 'stop', 'Kyoto', 'Japan', 35.0116, 135.7681, 'stop'],
          ],
        ),
        (
          ['variant_id', 'position', 'mode', 'note'],
          [
            ['v-1', 0, 'flight', 'direct FRA-KIX'],
          ],
        ),
      ]);
    });
    final (trips, problems) = await _repo(fake).loadTrips();
    expect(problems, isEmpty);
    expect(trips, hasLength(1));
    final trip = trips.single;
    expect(trip.id, 't-1');
    expect(trip.name, 'Japan 2026');
    expect(trip.variants, hasLength(2));
    expect([for (final v in trip.variants) v.name], ['Spring', 'Autumn']);

    final spring = trip.variants.first;
    expect(spring.stops, hasLength(2));
    expect(spring.stops[0].ref.name, 'Frankfurt');
    expect(spring.stops[0].role, 'start');
    expect(spring.stops[1].ref.lat, 35.0116);
    // legs[i] sits between stops[i] and stops[i+1]
    expect(spring.legs.single.mode, 'flight');
    expect(spring.legs.single.note, 'direct FRA-KIX');

    // The autumn variant has no stops or legs of its own.
    expect(trip.variants.last.stops, isEmpty);
    expect(trip.variants.last.legs, isEmpty);
  });

  test('loadTrips reports problems instead of an empty list', () async {
    final fake = FakeTurso((_) => pipelineError('no such table: stops'));
    final (trips, problems) = await _repo(fake).loadTrips();
    expect(trips, isEmpty);
    expect(problems, ['no such table: stops']);
  });

  test('saveTrip upserts, replaces stops and legs, all in one pipeline',
      () async {
    final fake = FakeTurso((_) => okEmpty(6));
    final trip = const Trip(
      id: 't-1',
      name: "Thorsten's Japan trip",
      created: '2026-10-10T21:00:00+00:00',
      activeVariantId: 'v-1',
      variants: [
        Variant(
          id: 'v-1',
          name: 'Spring',
          months: ['April'],
          rating: 5,
          stops: [
            Stop(
              id: '',
              ref: StopRef(kind: 'start', name: 'Frankfurt'),
            ),
            Stop(id: 's-2', ref: StopRef(kind: 'stop', name: 'Kyoto')),
          ],
          legs: [Leg(mode: 'flight', note: 'FRA-KIX')],
        ),
      ],
    );
    final ok = await _repo(fake).saveTrip(trip);
    expect(ok, isTrue);
    expect(fake.requests, hasLength(1), reason: 'one atomic pipeline request');

    final statements = fake.requests.single;
    expect(statements, hasLength(7));
    expect(statements[0], contains('INSERT INTO trips'));
    expect(statements[0], contains("'Thorsten''s Japan trip'"));
    expect(statements[1], contains('INSERT INTO variants'));
    expect(statements[1], contains("'[\"April\"]'"));
    expect(statements[2], "DELETE FROM stops WHERE variant_id = 'v-1'");
    expect(statements[3], "DELETE FROM legs WHERE variant_id = 'v-1'");
    // The stop without an id got one, in the models' shape.
    expect(statements[4], contains('INSERT INTO stops'));
    expect(statements[4], contains("'stop-"));
    expect(statements[4], contains("'Frankfurt'"));
    // The second stop keeps its own id and position 1.
    expect(statements[5], contains("'s-2'"));
    expect(statements[5], contains(', 1, \'stop\', \'Kyoto\''));
    expect(statements[6], contains('INSERT INTO legs'));
    expect(statements[6], contains(', 0, \'flight\', \'FRA-KIX\''));
  });

  test('saveTrip refuses a trip without an id', () async {
    final fake = FakeTurso((_) => okEmpty());
    const trip = Trip(id: '', name: 'No id');
    final ok = await _repo(fake).saveTrip(trip);
    expect(ok, isFalse);
    expect(fake.requests, isEmpty);
  });

  test('saveTrip returns false when the pipeline fails', () async {
    final fake = FakeTurso((_) => pipelineError('read-only'));
    const trip = Trip(id: 't-1', name: 'Japan');
    final ok = await _repo(fake).saveTrip(trip);
    expect(ok, isFalse);
  });

  test('deleteTrip removes legs, stops, variants, then the trip', () async {
    final fake = FakeTurso((_) => okEmpty(4));
    final ok = await _repo(fake).deleteTrip("t-o'brien");
    expect(ok, isTrue);
    expect(fake.requests.single, [
      'DELETE FROM legs WHERE variant_id IN '
          "(SELECT id FROM variants WHERE trip_id = 't-o''brien')",
      'DELETE FROM stops WHERE variant_id IN '
          "(SELECT id FROM variants WHERE trip_id = 't-o''brien')",
      "DELETE FROM variants WHERE trip_id = 't-o''brien'",
      "DELETE FROM trips WHERE id = 't-o''brien'",
    ]);
  });
}
