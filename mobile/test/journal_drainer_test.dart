/// The drain (Phase 5, commit 2): what happens to a queued
/// write when it is finally sent. Four outcomes, each of them
/// explicit -- applied, refused by the guard (a conflict), a
/// statement error (dropped, logged), or still offline (kept).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/journal_drainer.dart';
import 'package:travel_planner/data/write_journal.dart';
import 'package:travel_planner/models/pending_write.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

const _config =
    TursoConfig(url: 'https://db.example.turso.io', token: 'token');

PendingWrite _tripOp({String id = 't-1'}) => PendingWrite(
      key: 'trip:$id',
      label: 'trip “Japan”',
      statements: [
        'UPDATE trips SET name = 1 WHERE updated_at = 2',
        'DELETE FROM stops',
      ],
      guardFirst: true,
      at: '2026-10-18 12:00',
    );

PendingWrite _destOp(String name) => PendingWrite(
      key: 'destination:$name',
      label: 'destination $name',
      statements: ['UPDATE destinations SET x = 1'],
      at: '2026-10-18 12:00',
    );

void main() {
  late Directory temp;
  late WriteJournal journal;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('journal_drainer_test');
    journal = WriteJournal(temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  JournalDrainer drainer(FakeTurso fake) =>
      JournalDrainer(TursoClient(_config, httpClient: fake.client()), journal);

  test('an empty queue touches the network not at all', () async {
    final fake = FakeTurso((_) =>
        throw StateError('no request expected with an empty queue'));
    final report = await drainer(fake).drain();
    expect(report.idle, isTrue);
    expect(report.remaining, 0);
    expect(fake.requests, isEmpty);
  });

  test('a queued trip write replays the guard first, then the rest',
      () async {
    journal.enqueue(_tripOp());
    final fake = FakeTurso((statements) =>
        okEmpty(statements.length, 1));
    final report = await drainer(fake).drain();

    expect(report.applied, 1);
    expect(report.remaining, 0);
    expect(fake.requests, hasLength(2),
        reason: 'the guard statement runs alone, exactly like the online save');
    expect(fake.requests.first, ['UPDATE trips SET name = 1 '
        'WHERE updated_at = 2']);
    expect(fake.requests.last, ['DELETE FROM stops']);
    expect(journal.pending(), isEmpty);
  });

  test('a guard refusal is a conflict: the rest never runs', () async {
    journal.enqueue(_tripOp());
    final fake = FakeTurso((statements) => okEmpty(statements.length, 0));
    final report = await drainer(fake).drain();

    expect(report.conflicts, 1);
    expect(report.applied, 0);
    expect(fake.requests, hasLength(1),
        reason: 'a conflicted replay must not delete and re-insert '
            'another device\'s variants');
    expect(journal.pending(), isEmpty);
    final conflict = journal.conflicts().single;
    expect(conflict.op.key, 'trip:t-1');
    expect(conflict.reason, contains('changed elsewhere'));
    expect(report.notes.single, contains('changed elsewhere'));
  });

  test('a statement error drops the op and names it', () async {
    journal.enqueue(_destOp('Kyoto'));
    final fake = FakeTurso((_) => pipelineError('SQLite error: no such column'));
    final report = await drainer(fake).drain();

    expect(report.dropped, 1);
    expect(report.applied, 0);
    expect(journal.pending(), isEmpty,
        reason: 'it would fail identically next time');
    expect(journal.conflicts(), isEmpty,
        reason: 'a broken statement is not a lost race');
    expect(report.notes.single, contains('could not sync'));
  });

  test('a transport failure stops the drain and keeps the rest', () async {
    journal.enqueue(_destOp('Kyoto'));
    journal.enqueue(_destOp('Lima'));
    var calls = 0;
    final fake = FakeTurso((_) {
      calls++;
      return calls == 1 ? okEmpty(1, 1) : httpStatus(503);
    });
    final report = await drainer(fake).drain();

    expect(report.applied, 1);
    expect(report.offline, isTrue);
    expect(report.remaining, 1);
    expect(report.summary, contains('still offline'));
    final left = journal.pending();
    expect(left.single.key, 'destination:Lima',
        reason: 'the op that failed stays queued -- it was never sent');
  });

  test('a rejected token is dropped, not queued forever', () async {
    journal.enqueue(_destOp('Kyoto'));
    final fake = FakeTurso((_) => httpStatus(401));
    final report = await drainer(fake).drain();

    expect(report.dropped, 1);
    expect(report.offline, isFalse,
        reason: 'a bad token will not fix itself by retrying');
    expect(journal.pending(), isEmpty);
  });

  test('ops replay in enqueue order', () async {
    journal.enqueue(_destOp('Kyoto'));
    journal.enqueue(_destOp('Lima'));
    final fake = FakeTurso((_) => okEmpty(1, 1));
    await drainer(fake).drain();

    expect(fake.requests, hasLength(2));
    expect(fake.requests.first.single, contains('x = 1'));
    expect(journal.pending(), isEmpty);
  });
}
