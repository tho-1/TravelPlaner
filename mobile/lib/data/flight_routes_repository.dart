/// The transport routes cache: one JSON file
/// per destination, in a writable directory.
///
/// The Dart port of `flight_routes.load_cached_
/// flight_routes` / `save_cached_flight_routes`.
/// The directory is a per-machine path from
/// `turso_config.json` (`flight_routes_cache`),
/// so on the phone it is empty and every open
/// researches afresh — the same per-device
/// pattern as the Pictures folder. A missing or
/// corrupt cache is a normal state, never a
/// crash.
library;

import 'dart:convert';
import 'dart:io';

import 'flight_routes.dart' show normalizeKey;

class FlightRoutesRepository {
  /// The cache directory, from
  /// `turso_config.json` (`flight_routes_cache`).
  /// Empty means unconfigured — no directory is
  /// ever assumed.
  final String cacheDir;

  const FlightRoutesRepository(this.cacheDir);

  bool get isConfigured => cacheDir.trim().isNotEmpty;

  /// The cached research for a destination, or
  /// null when there is none.
  Map<String, dynamic>? load(String destinationName) {
    if (!isConfigured) return null;
    final key = normalizeKey(destinationName);
    if (key.isEmpty) return null;
    final file = File('$cacheDir/$key.json');
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Persist the research. Best effort: a
  /// failure to write is a false return, never
  /// a crash. The write goes through a temporary
  /// file and a rename, like the geocode cache:
  /// a crash mid-write must not leave a
  /// truncated JSON behind (a later load would
  /// silently lose the entry).
  bool save(String destinationName, Map<String, dynamic> data) {
    if (!isConfigured) return false;
    final key = normalizeKey(destinationName);
    if (key.isEmpty) return false;
    try {
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final path = File('$cacheDir/$key.json');
      final tmp = File('$cacheDir/$key.json.tmp');
      tmp.writeAsStringSync(jsonEncode(data));
      try {
        tmp.renameSync(path.path);
      } on FileSystemException {
        // Atomic replace is not available on
        // every platform; a direct write is the
        // fallback (the cache is best-effort).
        path.writeAsStringSync(jsonEncode(data));
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
