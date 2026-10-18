/// Offline writes (Phase 5, commit 2) at the repository
/// boundary: which failures queue, which must not, and what
/// the caller is told. The rule that must not drift is
/// AGENTS.md rule 2 -- a queued write is never reported as
/// saved; the status says "owed", and only a replay says
/// "done".
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/offline_cache.dart';
import 'package:travel_planner/data/open_tabs_repository.dart';
import 'package:travel_planner/data/trip_repository.dart';
import 'package:travel_planner/data/write_journal.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/trip.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config =
    TursoConfig(url: 'https://db.example.turso.io', token: 'token');

void main() {
  late Directory temp;
  late WriteJournal journal;
  late OfflineCache snapshot;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('offline_writes_test');
    journal = WriteJournal('${temp.path}/journal');
    snapshot = OfflineCache('${temp.path}/snapshot');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  TursoClient client(FakeTurso fake) =>
      TursoClient(_config, httpClient: fake.client());

  group('TripRepository', () {
    test('a transport failure queues the trip and says so', () async {
      final fake = FakeTurso((_) => httpStatus(503));
      final repo = TripRepository(client(fake), journal: journal);
      const trip = Trip(
        id: 't-1',
        name: 'Japan',
        created: '2026-10-01T00:00:00+00:00',
        updatedAt: '2026-10-02T00:00:00+00:00',
        variants: [Variant(id: 'v-1', name: 'Spring')],
      );

      expect(await repo.saveTrip(trip), TripSaveStatus.queued,
          reason: 'queued is its own status -- never `saved`');
      final op = journal.pending().single;
      expect(op.key, 'trip:t-1');
      expect(op.guardFirst, isTrue);
      expect(op.statements.first, contains('INSERT INTO trips'));
      expect(op.statements.first, contains('WHERE trips.updated_at'));
      expect(op.statements.length, greaterThan(1),
          reason: 'the whole write is replayed, not just the row');
    });

    test('a statement error is a failure, never queued', () async {
      final fake = FakeTurso((_) => pipelineError('SQLite error: no such table'));
      final repo = TripRepository(client(fake), journal: journal);
      expect(
        await repo.saveTrip(const Trip(id: 't-1', name: 'Japan')),
        TripSaveStatus.failed,
      );
      expect(journal.pending(), isEmpty,
          reason: 'retrying a broken statement would hide the real problem');
    });

    test('a failure after the guard landed is not queued', () async {
      // Request 1 (the guard) succeeds, request 2 (the
      // variants) fails: something was already written, so a
      // replay would either fight its own new stamp or halve
      // the variant list. The caller reloads instead.
      final fake = FakeTurso((statements) =>
          statements.first.contains('INSERT INTO trips')
              ? okEmpty(1, 1)
              : pipelineError('connection reset'));
      final repo = TripRepository(client(fake), journal: journal);
      final status = await repo.saveTrip(const Trip(
        id: 't-1',
        name: 'Japan',
        variants: [Variant(id: 'v-1', name: 'Spring')],
      ));
      expect(status, TripSaveStatus.failed);
      expect(journal.pending(), isEmpty);
    });

    test('no journal means the online contract is unchanged', () async {
      final fake = FakeTurso((_) => httpStatus(503));
      final repo = TripRepository(client(fake));
      expect(
        await repo.saveTrip(const Trip(id: 't-1', name: 'Japan')),
        TripSaveStatus.failed,
      );
    });
  });

  group('DestinationRepository', () {
    Destination kyoto() => Destination.fromRow({
          'destination': 'Kyoto',
          'country': 'Japan',
          'updated_at': '2026-10-01T00:00:00+00:00',
        });

    test('a failed save is queued and still reports false', () async {
      final fake = FakeTurso((_) => httpStatus(503));
      final repo =
          DestinationRepository(client(fake), journal: journal);
      expect(await repo.saveDestination(kyoto()), isFalse);
      final op = journal.pending().single;
      expect(op.key, 'destination:Kyoto');
      expect(op.statements.single, contains('INSERT INTO destinations'));
    });

    test('a field edit offline applies to the snapshot copy and queues',
        () async {
      snapshot.save('destinations', [
        [
          {
            'destination': 'Kyoto',
            'country': 'Japan',
            'visited': 0,
            'updated_at': '2026-10-01T00:00:00+00:00',
          },
        ],
      ]);
      final fake = FakeTurso((_) => httpStatus(503));
      final repo = DestinationRepository(client(fake),
          offline: snapshot, journal: journal);

      // Offline the read is answered by the snapshot; the
      // edit must not be refused just because the read was
      // labelled offline.
      expect(await repo.updateField('Kyoto', 'visited', true), isFalse,
          reason: 'the write did not land, so nothing was written');
      final op = journal.pending().single;
      expect(op.key, 'destination:Kyoto');
      expect(op.statements.single, contains('visited'));
    });

    test('a read that failed for another reason still refuses the edit',
        () async {
      final fake = FakeTurso((_) => httpStatus(401));
      final repo = DestinationRepository(client(fake),
          offline: snapshot, journal: journal);
      expect(await repo.updateField('Kyoto', 'visited', true), isFalse);
      expect(journal.pending(), isEmpty,
          reason: 'no snapshot, no destination to edit -- nothing to queue');
    });
  });

  group('OpenTabsRepository', () {
    test('a failed read serves the snapshot, labelled', () async {
      snapshot.save('open_tabs', [
        [
          {'destination': 'Kyoto'},
          {'destination': 'Lima'},
        ],
      ]);
      final fake = FakeTurso((_) => httpStatus(503));
      final repo = OpenTabsRepository(client(fake),
          offline: snapshot, journal: journal);
      final (tabs, problems) = await repo.loadTabs();
      expect(tabs, ['Kyoto', 'Lima']);
      expect(problems.single, contains('open tabs snapshot'));
    });

    test('a successful read refreshes the snapshot', () async {
      final fake = FakeTurso((_) => okRows(['destination'], [
            ['Kyoto'],
          ]));
      final repo = OpenTabsRepository(client(fake),
          offline: snapshot, journal: journal);
      await repo.loadTabs();
      expect(snapshot.load('open_tabs')!.tables.single.single,
          {'destination': 'Kyoto'});
    });

    test('a failed save queues the whole-list write', () async {
      final fake = FakeTurso((_) => httpStatus(503));
      final repo = OpenTabsRepository(client(fake), journal: journal);
      expect(await repo.saveTabs(['Kyoto', "O'Brien"]), isFalse);
      final op = journal.pending().single;
      expect(op.key, 'open_tabs');
      expect(op.statements.first, 'DELETE FROM open_tabs');
      expect(op.statements.last, contains("O''Brien"),
          reason: 'the escape survives the journal round-trip');
    });
  });
}
