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

void main() {
  test('loadTrips reads the four tables in one request and groups them',
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

  test('loadTrips decodes the pipeline\'s typed cells', () async {
    // The real pipeline always types its cells
    // ({"type": "integer", "value": "1"}); the repository
    // must hand the models plain Dart values -- an
    // unchecked cast would take the trips page down.
    final fake = FakeTurso((_) => okMultiTyped([
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
            ],
          ),
          (
            [
              'id', 'variant_id', 'position', 'kind', 'name', 'country',
              'lat', 'lon', 'role',
            ],
            [
              [
                's-1', 'v-1', 0, 'stop', 'Kyoto', 'Japan', 35.0116,
                135.7681, 'stop',
              ],
            ],
          ),
          (
            ['variant_id', 'position', 'mode', 'note'],
            [
              ['v-1', 0, 'flight', null],
            ],
          ),
        ]));
    final (trips, problems) = await _repo(fake).loadTrips();
    expect(problems, isEmpty);
    final stop = trips.single.variants.single.stops.single;
    expect(stop.ref.lat, 35.0116);
    expect(stop.ref.lon, 135.7681);
  });

  test('saveTrip writes the trip first, then the variants', () async {
    final fake = FakeTurso((_) => okEmpty(6, 1));
    final trip = const Trip(
      id: 't-1',
      name: "Thorsten's Japan trip",
      created: '2026-10-10T21:00:00+00:00',
      updatedAt: '2026-10-11T08:00:00+00:00',
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
    final status = await _repo(fake).saveTrip(trip);
    expect(status, TripSaveStatus.saved);
    // The conditional upsert (request 1) must be
    // confirmed -- rows_affected 1 -- before the variant
    // statements (request 2) run: a conflict never
    // deletes and re-inserts the variants.
    expect(fake.requests, hasLength(2), reason: 'trip upsert, then variants');

    final upsert = fake.requests.first.single;
    expect(upsert, contains('INSERT INTO trips'));
    expect(upsert, contains("'Thorsten''s Japan trip'"));
    // The creation date is never rewritten (a copy from
    // an older export must not NULL the stored date).
    expect(upsert, isNot(contains('created = excluded.created')));
    // The concurrency guard: the update happens only
    // when the stored stamp is the one this copy saw.
    expect(upsert, contains('ON CONFLICT(id) DO UPDATE'));
    expect(
        upsert,
        contains(
            "WHERE trips.updated_at = '2026-10-11T08:00:00+00:00'"));

    final statements = fake.requests.last;
    expect(statements, hasLength(6));
    expect(statements[0], contains('INSERT INTO variants'));
    expect(statements[0], contains("'[\"April\"]'"));
    expect(statements[1], "DELETE FROM stops WHERE variant_id = 'v-1'");
    expect(statements[2], "DELETE FROM legs WHERE variant_id = 'v-1'");
    // The stop without an id got one, in the models' shape.
    expect(statements[3], contains('INSERT INTO stops'));
    expect(statements[3], contains("'stop-"));
    expect(statements[3], contains("'Frankfurt'"));
    // The second stop keeps its own id and position 1.
    expect(statements[4], contains("'s-2'"));
    expect(statements[4], contains(', 1, \'stop\', \'Kyoto\''));
    expect(statements[5], contains('INSERT INTO legs'));
    expect(statements[5], contains(', 0, \'flight\', \'FRA-KIX\''));
  });

  test('saveTrip reports a conflict and touches nothing else '
      'when the row changed underneath', () async {
    // The conditional upsert matched no row: another
    // device saved between this copy's load and the
    // save. Zero affected rows -- and the variant
    // statements never run.
    final fake = FakeTurso((_) => okEmpty(1, 0));
    final trip = const Trip(
      id: 't-1',
      name: 'Japan',
      created: '2026-01-01T00:00:00+00:00',
      activeVariantId: 'v-1',
      variants: [
        Variant(id: 'v-1', name: 'Spring', stops: [], legs: []),
      ],
    );
    final status = await _repo(fake).saveTrip(trip);
    expect(status, TripSaveStatus.conflict);
    expect(fake.requests, hasLength(1),
        reason: 'the variant statements must not run on a conflict');
    expect(fake.requests.single, hasLength(1));
  });

  test('saveTrip reads the live affected_row_count shape', () async {
    // The live endpoint reports DML counts as
    // `affected_row_count` with no `rows_affected` key
    // (probed 2026-10-18). If the guard only understood the
    // latter, `rowsAffected` would be null, `null == 0`
    // false, and every stale save would claim success.
    final stale = FakeTurso((_) => okEmptyLive(1, 0));
    const trip = Trip(id: 't-1', name: 'Japan');
    expect(await _repo(stale).saveTrip(trip), TripSaveStatus.conflict);
    expect(stale.requests, hasLength(1),
        reason: 'the variant statements must not run on a conflict');

    final fresh = FakeTurso((_) => okEmptyLive(1, 1));
    expect(await _repo(fresh).saveTrip(trip), TripSaveStatus.saved);
  });

  test('saveTrip reports a conflict when the pipeline fails '
      'on the upsert', () async {
    final fake = FakeTurso((_) => pipelineError('read-only'));
    const trip = Trip(id: 't-1', name: 'Japan');
    final status = await _repo(fake).saveTrip(trip);
    expect(status, TripSaveStatus.failed);
    expect(fake.requests, hasLength(1),
        reason: 'the variant statements must not run after a failed upsert');
  });

  test('the first save of a new trip inserts it', () async {
    // A row the store does not hold yet: the conditional
    // upsert takes the INSERT branch, which ignores the
    // WHERE clause -- one affected row, saved. A trip with
    // no variants has nothing else to send, so the second
    // request is skipped rather than sent empty.
    final fake = FakeTurso((_) => okEmpty(1, 1));
    const trip = Trip(id: 't-new', name: 'New trip');
    final status = await _repo(fake).saveTrip(trip);
    expect(status, TripSaveStatus.saved);
    expect(fake.requests, hasLength(1));
    expect(fake.requests.first.single, contains('INSERT INTO trips'));
  });

  test('a copy that never saw a stamp guards with IS NULL', () async {
    // `= NULL` never matches in SQL: the guard for a
    // stamp-less copy must be IS NULL, or every one of
    // its saves would be a false conflict.
    final fake = FakeTurso((_) => okEmpty(1, 1));
    const trip = Trip(id: 't-old', name: 'Imported');
    final status = await _repo(fake).saveTrip(trip);
    expect(status, TripSaveStatus.saved);
    expect(fake.requests.first.single,
        contains('WHERE trips.updated_at IS NULL'));
  });

  test('saveTrip never wraps the batch in a transaction', () async {
    // Verified against the live endpoint on 2026-10-18: the
    // pipeline keeps going after an error (`ok, error, ok`),
    // so a trailing COMMIT would make a half-written trip
    // durable. The conditional batch steps this would need
    // are rejected (400, "missing field `stmt`") and
    // `on_error: rollback` is ignored. A "tidier" save that
    // adds BEGIN/COMMIT here would silently turn a surfaced
    // partial failure into committed corruption.
    final fake = FakeTurso((_) => okEmpty(3, 1));
    final status = await _repo(fake).saveTrip(const Trip(
      id: 't-1',
      name: 'Japan',
      variants: [Variant(id: 'v-1', name: 'Spring')],
    ));
    expect(status, TripSaveStatus.saved);
    final all = [for (final request in fake.requests) ...request];
    expect(all.where((sql) => sql.trim().toUpperCase() == 'BEGIN'),
        isEmpty);
    expect(all.where((sql) => sql.trim().toUpperCase().startsWith('COMMIT')),
        isEmpty);
  });

  test('saveTrip refuses a trip without an id', () async {

    final fake = FakeTurso((_) => okEmpty());
    const trip = Trip(id: '', name: 'No id');
    final status = await _repo(fake).saveTrip(trip);
    expect(status, TripSaveStatus.failed);
    expect(fake.requests, isEmpty);
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
