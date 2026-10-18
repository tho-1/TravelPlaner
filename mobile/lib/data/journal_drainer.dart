/// Replays the queued writes (offline-first Phase 5, Option A,
/// commit 2). The contract is in `OFFLINE_SYNC_PLAN.md`; the
/// parts that must not drift:
///
/// * **Sequential, in enqueue order.** A later op with the same
///   key already superseded the earlier one when it was
///   queued, so order only matters across different values.
/// * **A transport failure stops the drain** and keeps that op
///   and everything after it -- the network is still down; the
///   remaining ops are not lost, they are still waiting.
/// * **A statement error drops the op** (logged): it will fail
///   identically next time, and retrying it forever would hide
///   the real problem behind a stuck badge.
/// * **A guard refusal is a conflict**: the trip upsert matched
///   no row, so another device saved first. The op moves to
///   `conflicts.jsonl`, is never retried, and the rest of that
///   op's statements do **not** run -- the online save does the
///   same, so a conflicted replay cannot delete and re-insert
///   another device's variants.
library;

import '../models/pending_write.dart';
import '../turso/pipeline_client.dart';
import 'error_log.dart';
import 'write_journal.dart';

enum _Outcome { applied, conflict, dropped, offline }

class DrainReport {
  final int applied;
  final int conflicts;
  final int dropped;

  /// Ops still queued (the drain stopped early).
  final int remaining;

  /// True when the drain stopped because the network failed.
  final bool offline;

  final List<String> notes;

  const DrainReport({
    this.applied = 0,
    this.conflicts = 0,
    this.dropped = 0,
    this.remaining = 0,
    this.offline = false,
    this.notes = const [],
  });

  bool get idle => applied == 0 && conflicts == 0 && dropped == 0;

  /// The one-line state the UI prints; null when there is
  /// nothing to say.
  String? get summary {
    if (remaining > 0 && offline) {
      return '$remaining change${remaining == 1 ? '' : 's'} waiting '
          'to sync — still offline';
    }
    if (notes.isEmpty) return null;
    return notes.join(' · ');
  }
}

class JournalDrainer {
  final TursoClient client;
  final WriteJournal journal;

  const JournalDrainer(this.client, this.journal);

  Future<DrainReport> drain() async {
    final ops = journal.pending();
    if (ops.isEmpty) return const DrainReport();

    var applied = 0;
    var conflicts = 0;
    var dropped = 0;
    final notes = <String>[];
    var index = 0;
    var offline = false;

    for (; index < ops.length; index++) {
      final op = ops[index];
      final (outcome, message) = await _replay(op);
      switch (outcome) {
        case _Outcome.applied:
          applied++;
        case _Outcome.conflict:
          conflicts++;
          journal.addConflict(op, message);
          notes.add('${op.label}: $message');
        case _Outcome.dropped:
          dropped++;
          ErrorLog.instance.record('write-journal',
              'dropped the queued write (${op.label}): $message');
          notes.add('${op.label} could not sync: $message');
        case _Outcome.offline:
          offline = true;
      }
      if (offline) break;
    }

    // The failing op stays queued; so does everything after it.
    final remaining = offline ? ops.length - index : 0;
    if (offline) {
      journal.keep(ops.sublist(index));
    } else {
      journal.clearPending();
    }
    if (applied > 0) {
      notes.insert(0, '$applied queued change${applied == 1 ? '' : 's'} synced');
    }
    return DrainReport(
      applied: applied,
      conflicts: conflicts,
      dropped: dropped,
      remaining: remaining,
      offline: offline,
      notes: notes,
    );
  }

  /// Replay one op. The guard-bearing first statement runs
  /// alone: its affected-row count decides "already changed
  /// elsewhere" before anything else is touched.
  Future<(_Outcome, String)> _replay(PendingWrite op) async {
    var rest = op.statements;
    if (op.guardFirst) {
      final (results, problems) =
          await client.runPipeline([op.statements.first]);
      final failure = _classify(problems);
      if (failure != null) return failure;
      if (results.isNotEmpty && results.first.rowsAffected == 0) {
        return (
          _Outcome.conflict,
          'the trip changed elsewhere since this copy was loaded'
        );
      }
      rest = op.statements.skip(1).toList();
    }
    if (rest.isEmpty) return (_Outcome.applied, '');
    final (_, problems) = await client.runPipeline(rest);
    return _classify(problems) ?? (_Outcome.applied, '');
  }

  /// Null means "no problem": the statements ran.
  (_Outcome, String)? _classify(List<String> problems) {
    if (problems.isEmpty) return null;
    if (problems.every(offlineProblem)) {
      return (_Outcome.offline, problems.first);
    }
    return (_Outcome.dropped, problems.first);
  }
}
