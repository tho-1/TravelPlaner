/// The offline-first read layer (Phase 5, Option A): the
/// snapshot store's own contract and the two big
/// repositories' fallback behaviour. The one rule that
/// reaches past this file: a failed live read is never an
/// ambiguous empty answer -- offline it is a *labelled*
/// snapshot answer or the original failure.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/offline_cache.dart';
import 'package:travel_planner/data/trip_repository.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/trip.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
    url: 'https://db.example.turso.io', token: 'token');

DestinationRepository _destRepo(FakeTurso fake, OfflineCache offline) =>
    DestinationRepository(
      TursoClient(_config, httpClient: fake.client()),
      offline: offline,
    );

TripRepository _tripRepo(FakeTurso fake, OfflineCache offline) =>
    TripRepository(
      TursoClient(_config, httpClient: fake.client()),
      offline: offline,
    );

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('offline_cache_test');
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  group('OfflineCache', () {
    test('a saved dataset round-trips with its save time', () {
      final cache = OfflineCache(temp.path);
      cache.save('destinations', [
        [
          {'destination': 'Kyoto', 'country': 'Japan'},
          {'destination': 'Lima', 'country': 'Peru'},
        ],
      ]);

      final loaded = cache.load('destinations')!;
      expect(loaded.savedAt, matches(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'),
          reason: 'the stamp the user sees, minutes precision');
      expect(loaded.tables.single, hasLength(2));
      expect(loaded.tables.single.first['destination'], 'Kyoto');
    });

    test('an empty dataset is a legitimate snapshot', () {
      final cache = OfflineCache(temp.path);
      cache.save('destinations', [const <Map<String, Object?>>[]]);
      final loaded = cache.load('destinations')!;
      expect(loaded.tables.single, isEmpty);
    });

    test('a missing dataset is not a snapshot', () {
      expect(OfflineCache(temp.path).load('trips'), isNull);
    });

    test('a corrupt file is not a snapshot', () {
      File('${temp.path}${Platform.pathSeparator}offline_trips.json')
          .writeAsStringSync('{not json');
      expect(OfflineCache(temp.path).load('trips'), isNull);
    });
  });

  group('the destination snapshot fallback', () {
    test('a successful full read writes the snapshot', () async {
      final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'data'],
          [['Kyoto', 'Japan', jsonEncode([])]]));
      final cache = OfflineCache(temp.path);
      final (_, problems) =
          await _destRepo(fake, cache).loadDestinations();

      expect(problems, isEmpty);
      expect(cache.load('destinations')!.tables.single.single['destination'],
          'Kyoto');
    });

    test('a failed live read serves the snapshot, labelled', () async {
      final fake = FakeTurso((_) => pipelineError('no such table'));
      final cache = OfflineCache(temp.path);
      cache.save('destinations', [
        ['Kyoto', 'Lima'].map((name) => {
              'destination': name,
              'country': '',
              'data': jsonEncode([]),
            }).toList(),
      ]);

      final (List<Destination> destinations, List<String> problems) =
          await _destRepo(fake, cache).loadDestinations();

      expect(destinations.map((d) => d.name), ['Kyoto', 'Lima'],
          reason: 'the snapshot answers, not the failure');
      expect(problems.single, allOf(startsWith('offline:'),
          contains('snapshot from'), contains('no such table')));
    });

    test('no snapshot keeps the original failure, as before', () async {
      final fake = FakeTurso((_) => pipelineError('timeout'));
      final (destinations, problems) =
          await _destRepo(fake, OfflineCache(temp.path)).loadDestinations();

      expect(destinations, isEmpty);
      expect(problems, ['timeout']);
    });

    test('getDestination reads one row from the snapshot', () async {
      final fake = FakeTurso((_) => pipelineError('no such table'));
      final cache = OfflineCache(temp.path);
      cache.save('destinations', [
        [
          {'destination': 'Kyoto', 'country': 'Japan', 'data': '[]'},
          {'destination': 'Lima', 'country': 'Peru', 'data': '[]'},
        ],
      ]);
      final repo = _destRepo(fake, cache);

      final (found, noteProblems) = await repo.getDestination('Kyoto');
      expect(found, isNotNull);
      expect(found!.name, 'Kyoto');
      expect(noteProblems.single, startsWith('offline:'));

      // Absent from the snapshot: unknown offline -- a
      // different answer from a live "does not exist".
      final (missing, missingProblems) = await repo.getDestination('Athens');
      expect(missing, isNull);
      expect(missingProblems, hasLength(2));
      expect(missingProblems[0], startsWith('offline:'));
      expect(missingProblems[1],
          'Athens is not in the offline snapshot',
          reason: '"unknown offline" -- not "does not exist"');
    });
  });

  group('the trip snapshot fallback', () {
    test('a failed live read rebuilds trips from the snapshot',
        () async {
      final fake = FakeTurso((_) => pipelineError('no such table'));
      final cache = OfflineCache(temp.path);
      cache.save('trips', [
        [
          {
            'id': 'trip-1',
            'name': 'Alps by rail',
            'created': '2026-10-01T10:00:00',
            'active_variant_id': 'var-1',
            'updated_at': '2026-10-15T08:00:00',
          },
        ],
        [
          {
            'id': 'var-1',
            'trip_id': 'trip-1',
            'name': 'Winter',
            'months': jsonEncode([]),
            'stops': jsonEncode([]),
          },
        ],
        [
          {
            'id': 'stop-1',
            'variant_id': 'var-1',
            'position': 1,
            'kind': 'city',
            'name': 'Zurich',
            'country': 'CH',
          },
        ],
        [
          {
            'variant_id': 'var-1',
            'position': 1,
            'mode': 'train',
            'note': 'Glacier Express',
          },
        ],
      ]);

      final (List<Trip> trips, List<String> problems) =
          await _tripRepo(fake, cache).loadTrips();

      expect(problems.single, startsWith('offline:'));
      expect(trips.single.name, 'Alps by rail');
      expect(trips.single.variants.single.name, 'Winter');
      expect(
          trips.single.variants.single.stops.single.ref.name, 'Zurich');
      expect(trips.single.variants.single.legs.single.note,
          'Glacier Express');
    });

    test('no snapshot keeps the original failure, as before',
        () async {
      final fake = FakeTurso((_) => pipelineError('timeout'));
      final (trips, problems) =
          await _tripRepo(fake, OfflineCache(temp.path)).loadTrips();

      expect(trips, isEmpty);
      expect(problems, ['timeout']);
    });
  });
}
