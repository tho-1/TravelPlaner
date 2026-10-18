/// The offline write queue (offline-first Phase 5, Option A,
/// commit 2).
///
/// Two JSON-lines files in the per-device state dir, next to
/// the snapshot cache:
///
/// * `pending.jsonl` -- writes that never reached the
///   database, newest value per key, in enqueue order. This
///   is what the drain replays.
/// * `conflicts.jsonl` -- writes the drain could not apply
///   because the guard refused them (another device saved
///   first). They are never replayed and never deleted: the
///   user decides what happens to them.
///
/// The file contracts are the same as `app_settings.json` and
/// the snapshot store: atomic tmp+rename writes, a missing
/// file is a normal empty state, a corrupt line is dropped
/// (never guessed at), and nothing here throws -- a journal
/// that cannot be written must not break the caller's write
/// path, which still returns "not saved".
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/pending_write.dart';
import 'error_log.dart';

class WriteJournal {
  /// The per-device directory holding the two files (the
  /// shell passes `<state dir>/write_journal`).
  final String dir;

  /// The cap on queued operations. An unbounded queue is its
  /// own kind of bug: past this the oldest op is dropped with
  /// a logged line rather than letting the file grow forever.
  final int cap;

  const WriteJournal(this.dir, {this.cap = 500});

  File get _pending => File(p.join(dir, 'pending.jsonl'));
  File get _conflicts => File(p.join(dir, 'conflicts.jsonl'));

  /// The queued operations, oldest first. A corrupt line is
  /// dropped and logged -- it cannot be replayed safely.
  List<PendingWrite> pending() => _read(_pending, 'pending');

  int get pendingCount => pending().length;

  /// The conflicts the drain has collected, newest last.
  List<({PendingWrite op, String reason})> conflicts() {
    final result = <({PendingWrite op, String reason})>[];
    for (final map in _readMaps(_conflicts, 'conflict')) {
      final op = PendingWrite.fromJson(map);
      if (op == null) continue;
      result.add((op: op, reason: '${map['reason'] ?? ''}'));
    }
    return result;
  }

  /// Queue one operation, replacing any earlier op with the
  /// same key (same key means same whole value). Returns
  /// whether the queue was updated -- false means the op is
  /// lost, and the caller must not claim it is waiting.
  bool enqueue(PendingWrite op) {
    final ops = pending()
      ..removeWhere((queued) => queued.key == op.key)
      ..add(op);
    while (ops.length > cap) {
      final dropped = ops.removeAt(0);
      ErrorLog.instance.record('write-journal',
          'dropped the oldest queued write (${dropped.label}) -- '
              'the queue is capped at $cap');
    }
    return _write(_pending, [for (final queued in ops) queued.toJson()]);
  }

  /// Replace the queue with what the drain could not apply.
  bool keep(List<PendingWrite> ops) =>
      _write(_pending, [for (final op in ops) op.toJson()]);

  /// Record an op the guard refused. Surfaced, never retried.
  bool addConflict(PendingWrite op, String reason) {
    final maps = _readMaps(_conflicts, 'conflict')
      ..add({...op.toJson(), 'reason': reason});
    return _write(_conflicts, maps);
  }

  /// The whole queue is applied: empty it.
  bool clearPending() => _write(_pending, const []);

  List<PendingWrite> _read(File file, String what) {
    final ops = <PendingWrite>[];
    for (final map in _readMaps(file, what)) {
      final op = PendingWrite.fromJson(map);
      if (op == null) {
        ErrorLog.instance.record('write-journal',
            'dropped a corrupt $what entry -- it cannot be replayed');
        continue;
      }
      if (op.statements.isNotEmpty) ops.add(op);
    }
    return ops;
  }

  List<Map<String, dynamic>> _readMaps(File file, String what) {
    try {
      if (!file.existsSync()) return [];
      final maps = <Map<String, dynamic>>[];
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final value = jsonDecode(line);
          if (value is Map<String, dynamic>) maps.add(value);
        } on FormatException {
          ErrorLog.instance.record('write-journal',
              'dropped a corrupt $what entry -- it cannot be replayed');
        }
      }
      return maps;
    } catch (error) {
      ErrorLog.instance.record(
          'write-journal', 'the $what queue could not be read: $error');
      return [];
    }
  }

  bool _write(File file, List<Map<String, Object?>> maps) {
    try {
      Directory(dir).createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(
        maps.map((map) => jsonEncode(map)).join('\n'),
      );
      tmp.renameSync(file.path);
      return true;
    } catch (error) {
      ErrorLog.instance.record(
          'write-journal', 'the queue could not be saved: $error');
      return false;
    }
  }
}
