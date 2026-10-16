/// The app's error log: one JSONL line per incident, so the
/// failures seen on the phone can be analysed afterwards
/// (report f, 2026-10-16 -- "make sure the app has an error
/// log so that we can analyze them in the future").
///
/// Entries are kept in memory (so the settings viewer always
/// has something to show) and appended to
/// `error_log.jsonl` in the per-device state directory next
/// to `app_settings.json` when one is configured. Logging
/// must never take the app down: a write failure is dropped,
/// not thrown.
library;

import 'dart:convert';
import 'dart:io';

/// One logged incident.
class ErrorLogEntry {
  final DateTime at;
  final String area;
  final String message;
  final Map<String, Object?> details;

  const ErrorLogEntry({
    required this.at,
    required this.area,
    required this.message,
    this.details = const {},
  });

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'area': area,
        'message': message,
        if (details.isNotEmpty) 'details': details,
      };

  static ErrorLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    final message = '${raw['message']}';
    if (at == null || message.isEmpty) return null;
    final details = <String, Object?>{};
    final rawDetails = raw['details'];
    if (rawDetails is Map) {
      for (final entry in rawDetails.entries) {
        details['${entry.key}'] = entry.value;
      }
    }
    return ErrorLogEntry(
      at: at,
      area: '${raw['area'] ?? 'app'}',
      message: message,
      details: details,
    );
  }
}

class ErrorLog {
  ErrorLog._();

  static final ErrorLog instance = ErrorLog._();

  /// Test seam: a log of its own, so persistence can be
  /// checked without the global instance's memory.
  factory ErrorLog.forTesting() => ErrorLog._();

  /// The newest entries are kept in memory; the file keeps
  /// everything written since the last clear.
  static const memoryLimit = 200;

  final _entries = <ErrorLogEntry>[];
  String _dir = '';

  /// The file the log is appended to, or '' where no state
  /// directory exists (a test binding).
  String get filePath => _dir.isEmpty ? '' : '$_dir${Platform.pathSeparator}error_log.jsonl';

  /// Bind the log to a state directory. Entries recorded
  /// before this stay in memory only.
  void bind(String stateDir) {
    _dir = stateDir.trim();
  }

  /// Record one incident. Returns whether it was persisted
  /// (false also when no state directory is bound -- the
  /// entry is then kept in memory only).
  bool record(String area, String message, {Map<String, Object?> details = const {}}) {
    final entry = ErrorLogEntry(
      at: DateTime.now(),
      area: area,
      message: message,
      details: details,
    );
    _entries.add(entry);
    if (_entries.length > memoryLimit) {
      _entries.removeRange(0, _entries.length - memoryLimit);
    }
    final path = filePath;
    if (path.isEmpty) return false;
    try {
      File(path)
          .writeAsStringSync('${jsonEncode(entry.toJson())}\n', mode: FileMode.append);
      return true;
    } catch (_) {
      // Logging must never be the failure.
      return false;
    }
  }

  /// The in-memory entries, newest first.
  List<ErrorLogEntry> get entries => _entries.reversed.toList();

  /// Everything on disk plus what is still in memory,
  /// newest first. A file that cannot be read is reported
  /// through `problems` -- a failed read is never "no
  /// errors" (invariant 1).
  (List<ErrorLogEntry>, List<String>) readAll() {
    final problems = <String>[];
    final onDisk = <ErrorLogEntry>[];
    final path = filePath;
    if (path.isNotEmpty) {
      final file = File(path);
      // A missing file is a genuinely empty log (what
      // `clear` leaves behind), not a failed read: only a
      // file that exists but cannot be read is a problem
      // (invariant 1 distinguishes the two).
      if (file.existsSync()) {
        try {
          final lines = file.readAsLinesSync();
          for (final line in lines) {
            if (line.trim().isEmpty) continue;
            final entry = ErrorLogEntry.fromJson(jsonDecode(line));
            if (entry != null) onDisk.add(entry);
          }
        } catch (error) {
          problems.add('error log could not be read: $error');
        }
      }
    }
    final seen = <String>{};
    final merged = <ErrorLogEntry>[
      for (final entry in [...onDisk, ..._entries])
        if (seen.add('${entry.at.toIso8601String()}|${entry.area}|${entry.message}'))
          entry,
    ]..sort((a, b) => b.at.compareTo(a.at));
    return (merged, problems);
  }

  /// Forget everything: the file and the memory.
  bool clear() {
    _entries.clear();
    final path = filePath;
    if (path.isEmpty) return true;
    try {
      File(path).deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
}
