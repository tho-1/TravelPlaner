/// The open-destination tabs, persisted in Turso.
///
/// The same table the legacy sidebar used (the port of
/// `storage_turso.load/save_open_tabs`): one row per open
/// destination, full-replace written, read back ordered by
/// name. The semantics that must not drift:
///
/// * A failed read returns an empty list *with* problems;
///   an empty list without problems means no tabs are open.
/// * A failed write returns `false` -- the caller surfaces
///   it, it is never reported as saved.
/// * The write replaces the whole list (DELETE + INSERTs in
///   one pipeline), so a device that closed a tab wins over
///   a stale copy on another device -- Turso is
///   last-write-wins, and the tab list is a whole-list value.
///
/// Offline (Phase 5): the last successful read is kept as a
/// snapshot, so a queued tab change is still *visible* after
/// a restart; a write that never reached the database is
/// queued in the journal, and `false` still comes back.
library;

import '../models/pending_write.dart';
import 'destination_repository.dart' show utcNow;
import '../turso/pipeline_client.dart';
import 'offline_cache.dart';
import 'write_journal.dart';

class OpenTabsRepository {
  final TursoClient client;

  /// The offline snapshot store and the write queue; both
  /// null keep the online-only contract (and the tests).
  final OfflineCache? offline;
  final WriteJournal? journal;

  OpenTabsRepository(this.client, {this.offline, this.journal});

  /// The open tabs, ordered by name -- the legacy read's
  /// exact ordering. A database that predates the feature
  /// has no `open_tabs` table yet: the first failed read
  /// creates it and retries once, so the first run against
  /// the live database just works.
  ///
  /// A failed read serves the snapshot, labelled with its
  /// save time, rather than an unexplained empty list.
  Future<(List<String>, List<String>)> loadTabs() async {
    const select = 'SELECT destination FROM open_tabs ORDER BY destination';
    var (rows, problems) = await client.query(select);
    if (problems.isNotEmpty) {
      final created = await ensureTable();
      if (created.isEmpty) {
        (rows, problems) = await client.query(select);
      }
    }
    if (problems.isNotEmpty) {
      final snapshot = offline?.load('open_tabs');
      if (snapshot == null) return (<String>[], problems);
      return (
        [
          for (final row in snapshot.tables.first)
            if ((row['destination'] as String?)?.trim().isNotEmpty ?? false)
              row['destination'] as String,
        ],
        offlineNote('open tabs', problems.first, snapshot.savedAt),
      );
    }
    offline?.save('open_tabs', [rows]);
    return (
      [
        for (final row in rows)
          if ((row['destination'] as String?)?.trim().isNotEmpty ?? false)
            row['destination'] as String,
      ],
      const <String>[],
    );
  }

  /// Create the table when missing. Empty problems = ready.
  Future<List<String>> ensureTable() => client.execute(
      'CREATE TABLE IF NOT EXISTS open_tabs '
      '(destination TEXT PRIMARY KEY, updated_at TEXT)');

  /// Replace the whole list. Returns `false` when anything
  /// failed -- the caller must surface that, never show the
  /// list as saved.
  Future<bool> saveTabs(List<String> tabs) async {
    final now = utcNow();
    final statements = [
      'DELETE FROM open_tabs',
      for (final tab in tabs)
        'INSERT OR IGNORE INTO open_tabs (destination, updated_at) VALUES '
        "('${tab.replaceAll("'", "''")}', '$now')",
    ];
    final (_, problems) = await client.runPipeline(statements);
    if (problems.isEmpty) {
      offline?.save('open_tabs', [
        [
          for (final tab in tabs) {'destination': tab},
        ],
      ]);
      return true;
    }
    final journal = this.journal;
    if (journal != null && problems.every(offlineProblem)) {
      journal.enqueue(PendingWrite(
        key: 'open_tabs',
        label: 'open tabs',
        statements: statements,
        at: now,
      ));
    }
    return false;
  }
}

