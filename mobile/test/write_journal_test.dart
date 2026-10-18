/// The offline write queue (Phase 5, commit 2): the file
/// contract -- round-trip, supersede, cap, corrupt lines, and
/// the conflicts file. The one rule that matters: a queued
/// write is never silently lost and never silently invented.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:travel_planner/data/write_journal.dart';
import 'package:travel_planner/models/pending_write.dart';

PendingWrite _op(String key, {String sql = 'DELETE FROM x'}) => PendingWrite(
      key: key,
      label: key,
      statements: [sql],
      at: '2026-10-18 12:00',
    );

void main() {
  late Directory temp;
  late WriteJournal journal;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('write_journal_test');
    journal = WriteJournal(temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('WriteJournal', () {
    test('a fresh directory is an empty queue, not a failure', () {
      expect(journal.pending(), isEmpty);
      expect(journal.pendingCount, 0);
      expect(journal.conflicts(), isEmpty);
    });

    test('an enqueued op round-trips through the file', () {
      expect(
        journal.enqueue(_op('trip:t-1', sql: "INSERT INTO trips VALUES ('x')")),
        isTrue,
      );
      // A new instance reads it: the journal is the file,
      // not memory -- a restart must not lose the queue.
      final loaded = WriteJournal(temp.path).pending().single;
      expect(loaded.key, 'trip:t-1');
      expect(loaded.statements, ["INSERT INTO trips VALUES ('x')"]);
      expect(loaded.guardFirst, isFalse);
    });

    test('guardFirst survives the round-trip', () {
      journal.enqueue(const PendingWrite(
        key: 'trip:t-1',
        label: 'trip “Japan”',
        statements: ['UPDATE trips SET x = 1 WHERE updated_at = 2'],
        guardFirst: true,
        at: '2026-10-18 12:00',
      ));
      expect(journal.pending().single.guardFirst, isTrue);
    });

    test('a newer op for the same key replaces the older one', () {
      journal.enqueue(_op('destination:Kyoto', sql: 'first'));
      journal.enqueue(_op('destination:Lima'));
      journal.enqueue(_op('destination:Kyoto', sql: 'second'));

      final ops = journal.pending();
      expect(ops.map((op) => op.key),
          ['destination:Lima', 'destination:Kyoto'],
          reason: 'the superseded op keeps its slot in the order');
      expect(ops.last.statements, ['second']);
      expect(ops, hasLength(2), reason: 'the older Kyoto write is gone');
    });

    test('the cap drops the oldest and keeps the newest', () {
      final capped = WriteJournal(temp.path, cap: 3);
      for (var i = 0; i < 5; i++) {
        capped.enqueue(_op('destination:d$i'));
      }
      expect(capped.pending().map((op) => op.key), [
        'destination:d2',
        'destination:d3',
        'destination:d4',
      ]);
    });

    test('a corrupt line is dropped, the rest still loads', () {
      File(p.join(temp.path, 'pending.jsonl')).writeAsStringSync(
        'this is not json\n'
        '{"key":"trip:t-1","label":"trip","at":"2026-10-18 12:00",'
        '"statements":["DELETE FROM x"]}\n',
      );
      final ops = journal.pending();
      expect(ops, hasLength(1));
      expect(ops.single.key, 'trip:t-1');
    });

    test('an op without statements is not replayed', () {
      File(p.join(temp.path, 'pending.jsonl')).writeAsStringSync(
        '{"key":"trip:t-1","label":"trip","at":"2026-10-18 12:00",'
        '"statements":[]}\n',
      );
      expect(journal.pending(), isEmpty,
          reason: 'an empty op would report a sync that wrote nothing');
    });

    test('conflicts are kept with their reason and never replayed', () {
      expect(
        journal.addConflict(_op('trip:t-1'), 'the trip changed elsewhere'),
        isTrue,
      );
      expect(journal.pending(), isEmpty);
      final conflict = journal.conflicts().single;
      expect(conflict.op.key, 'trip:t-1');
      expect(conflict.reason, 'the trip changed elsewhere');
    });

    test('keep() replaces the queue with what is still owed', () {
      journal.enqueue(_op('destination:Kyoto'));
      journal.enqueue(_op('destination:Lima'));
      expect(journal.keep([journal.pending().last]), isTrue);
      expect(journal.pending().map((op) => op.key), ['destination:Lima']);
    });

    test('clearPending empties the file', () {
      journal.enqueue(_op('destination:Kyoto'));
      expect(journal.clearPending(), isTrue);
      expect(journal.pending(), isEmpty);
    });
  });

  group('PendingWrite.fromJson', () {
    test('refuses a wrong shape instead of guessing', () {
      expect(PendingWrite.fromJson('not a map'), isNull);
      expect(PendingWrite.fromJson(<String, dynamic>{}), isNull);
      expect(
          PendingWrite.fromJson(<String, dynamic>{
            'key': 'x',
            'label': 'x',
            'at': 'now',
            'statements': 'DELETE FROM x',
          }),
          isNull);
    });

    test('keeps only non-empty statements', () {
      final op = PendingWrite.fromJson(<String, dynamic>{
        'key': 'x',
        'label': 'x',
        'at': 'now',
        'statements': ['DELETE FROM x', 42, '  '],
      })!;
      expect(op.statements, ['DELETE FROM x']);
    });
  });
}
