/// The offline-first read layer (Phase 5, Option A).
///
/// The Turso pipeline is HTTP-only: with the network down,
/// every read fails (invariant 1 -- and it must stay a
/// *reported* failure, never an empty answer). This store
/// keeps the last fully-successful reads of the big
/// datasets on the device, so a failed live read can be
/// answered from the snapshot -- clearly labelled as such,
/// with the time it was saved, so "offline data" is never
/// mistaken for "current data".
///
/// The rules that must not drift:
///
/// * **Only a full read may write a snapshot.** A partial
///   read (one destination, one trip) would overwrite the
///   full dataset with a fragment. Callers assert which
///   dataset they save, and only the "load everything"
///   methods save.
/// * **An empty dataset is a legitimate snapshot.** The
///   database genuinely being empty at save time is
///   knowledge worth keeping; a corrupt or missing file is
///   not a snapshot at all (null, and the caller fails the
///   read like before).
/// * **Offline answers are labelled.** The note returned
///   alongside snapshot rows says what failed and how old
///   the copy is; the UI prints it where it prints every
///   other read problem.
/// * Writes are *not* journaled here (Phase 5 commit 2); a
///   failed write keeps returning false with its problems.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'error_log.dart';

class OfflineCache {
  /// The per-device directory to keep the snapshot JSON
  /// files in (the resolved state dir plus a subdirectory,
  /// wired by the shell). Same file contracts as
  /// `app_settings.json`: atomic tmp+rename, missing files
  /// are normal states, never crashes.
  final String dir;

  const OfflineCache(this.dir);

  /// Save one dataset's tables (a full read's raw rows,
  /// table by table). A failure is swallowed into the
  /// ErrorLog -- a snapshot that cannot be written must not
  /// break a successful online read.
  void save(String dataset, List<List<Map<String, Object?>>> tables) {
    try {
      Directory(dir).createSync(recursive: true);
      final file = File(_path(dataset));
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'saved_at': _nowStamp(),
        'tables': [
          for (final table in tables) [for (final row in table) row],
        ],
      }));
      tmp.renameSync(file.path);
    } catch (error) {
      ErrorLog.instance.record('offline-cache',
          'the $dataset snapshot could not be saved: $error');
    }
  }

  /// Load one dataset's snapshot: its save time and the
  /// tables' raw rows, or null when nothing usable is
  /// stored (missing, corrupt, or wrong shape -- none of
  /// which may look like "the data was empty").
  ({String savedAt, List<List<Map<String, Object?>>> tables})? load(
    String dataset,
  ) {
    try {
      final text = File(_path(dataset)).readAsStringSync();
      final map = jsonDecode(text) as Map<String, dynamic>;
      final savedAt = '${map['saved_at'] ?? ''}';
      final raw = map['tables'];
      if (savedAt.isEmpty || raw is! List) return null;
      return (
        savedAt: savedAt,
        tables: [
          for (final table in raw)
            [
              if (table is List)
                for (final row in table)
                  if (row is Map<String, dynamic>) row,
            ],
        ],
      );
    } catch (_) {
      return null;
    }
  }

  String _path(String dataset) =>
      p.join(dir, 'offline_$dataset.json');

  String _nowStamp() {
    final now = DateTime.now();
    String pad(int value, [int width = 2]) =>
        value.toString().padLeft(width, '0');
    return '${now.year}-${pad(now.month)}-${pad(now.day)} '
        '${pad(now.hour)}:${pad(now.minute)}';
  }
}

/// The standard offline note: what failed and how old the
/// copy is, so the answer can never read as "up to date"
/// or as "nothing there".
List<String> offlineNote(String dataset, String failed, String savedAt) => [
      'offline: the live read failed ($failed); showing the '
          '$dataset snapshot from $savedAt',
    ];
