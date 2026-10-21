/// The offline-first round trip, end to end: a live read
/// fills the snapshot, a failed live read falls back to it, a
/// failed write is queued, and the drain replays the queue
/// when the database is reachable again.
///
/// The three pieces -- the snapshot store, the write journal
/// and the drainer -- are unit-tested on their own. What
/// this file pins is the *seam* between them, which is where
/// the phase-5 contract actually lives: the snapshot must be
/// labelled as offline, a queued write must reach the
/// database once the network is back, and a write that was
/// queued must not be reported as saved before the drain.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/journal_drainer.dart';
import 'package:travel_planner/data/offline_cache.dart';
import 'package:travel_planner/data/write_journal.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/pending_write.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
  url: 'https://db.example.turso.io',
  token: 'token',
);

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('offline_round_trip'));
  tearDown(() => temp.deleteSync(recursive: true));

  OfflineCache cache() => OfflineCache('${temp.path}/offline_snapshot');
  WriteJournal newJournal() => WriteJournal('${temp.path}/write_journal');

  test('a live read fills the snapshot and a failed read falls back to it',
      () async {
    var online = true;
    final fake = FakeTurso((_) {
      if (!online) return httpStatus(503);
      return okRowsTyped(['destination', 'country', 'visited', 'data'], [
        ['Kyoto', 'Japan', 1, jsonEncode(const [])],
      ]);
    });
    final repository = DestinationRepository(
      TursoClient(_config, httpClient: fake.client()),
      offline: cache(),
    );

    // Online: the live answer, and the snapshot is written.
    final (live, liveProblems) = await repository.loadDestinations();
    expect(liveProblems, isEmpty);
    expect(live.single.name, 'Kyoto');
    expect(cache().load('destinations'), isNotNull,
        reason: 'the successful read fills the snapshot');

    // Offline: the snapshot answers, and it says so -- the
    // note is what tells the user the answer is a stored
    // copy, not the live database.
    online = false;
    final (offline, offlineProblems) = await repository.loadDestinations();
    expect(offline.single.name, 'Kyoto');
    expect(offlineProblems.join(' '), contains('offline'),
        reason: 'the snapshot answer is labelled as offline');
  });

  test('a failed write is queued and the drain replays it once online',
      () async {
    var online = false;
    final applied = <String>[];
    final fake = FakeTurso((statements) {
      if (!online) return httpStatus(503);
      for (final statement in statements) {
        if (statement.contains('INSERT INTO destinations')) {
          applied.add(statement);
        }
      }
      return okEmpty(1, 1);
    });
    final client = TursoClient(_config, httpClient: fake.client());
    final repository = DestinationRepository(
      client,
      offline: cache(),
      journal: newJournal(),
    );
    final dest = Destination.fromRow({
      'destination': 'Kyoto',
      'country': 'Japan',
      'visited': 1,
      'data': jsonEncode(const []),
    });

    // Offline: the write fails, is queued, and is NOT
    // reported as saved.
    final saved = await repository.saveDestination(dest);
    expect(saved, isFalse, reason: 'an unsent write is not a saved one');
    expect(newJournal().pendingCount, 1,
        reason: 'the write waits in the queue for the network');

    // Online again: the drain replays it and empties the
    // queue.
    online = true;
    final report = await JournalDrainer(client, newJournal()).drain();
    expect(report.applied, 1);
    expect(report.notes.join(' '), contains('synced'),
        reason: 'the drain says what it did');
    expect(newJournal().pendingCount, 0, reason: 'the queue is empty again');
    expect(applied, hasLength(1),
        reason: 'the queued write actually reached the database');
  });

  test('a drain that finds the network still down keeps the queue',
      () async {
    // The network is down: the drain must stop and keep the
    // op queued. A queue that empties itself on a failed
    // drain loses the user's change.
    final fake = FakeTurso((_) => httpStatus(503));
    final client = TursoClient(_config, httpClient: fake.client());
    final journal = newJournal();
    journal.enqueue(PendingWrite(
      key: 'destination:Kyoto',
      label: 'destination Kyoto',
      statements: ["INSERT INTO destinations (destination) VALUES ('Kyoto')"],
      at: '2026-10-20 09:00',
    ));

    final report = await JournalDrainer(client, journal).drain();
    expect(report.offline, isTrue);
    expect(report.applied, 0);
    expect(report.remaining, 1);
    expect(journal.pendingCount, 1, reason: 'the op is still waiting');
    expect(journal.conflicts(), isEmpty,
        reason: 'a network failure is not a conflict');
  });

  test('a write the guard refuses becomes a conflict, never a retry',
      () async {
    // The guard-bearing first statement matched no row:
    // another device saved first. The op moves to the
    // conflict file, is never replayed, and the rest of its
    // statements do not run -- the online save does the same.
    final executed = <String>[];
    final fake = FakeTurso((statements) {
      executed.addAll(statements);
      if (statements.length == 1) return okEmpty(1, 0);
      return okEmpty(1, 1);
    });
    final client = TursoClient(_config, httpClient: fake.client());
    final journal = newJournal();
    journal.enqueue(PendingWrite(
      key: 'trip:t-1',
      label: 'trip Japan',
      statements: [
        "INSERT INTO trips (id) VALUES ('t-1') ON CONFLICT(id) DO UPDATE "
            "SET name = 'x' WHERE trips.updated_at = 'old'",
        "DELETE FROM stops WHERE variant_id = 'v-1'",
      ],
      guardFirst: true,
      at: '2026-10-20 09:00',
    ));

    final report = await JournalDrainer(client, journal).drain();
    expect(report.conflicts, 1);
    expect(report.applied, 0);
    expect(journal.pendingCount, 0, reason: 'a conflict is not replayed');
    expect(journal.conflicts(), hasLength(1));
    expect(executed, hasLength(1),
        reason: 'the statements after the refused guard must not run');
  });
}
