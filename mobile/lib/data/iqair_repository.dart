/// The IQAir snapshot reader: the I/O half of
/// `iqair_ranking.py`.
///
/// The legacy page reads `iqair_cache/world_cities.json`
/// (a rebuildable cache of the IQAir world ranking,
/// ~9,400 cities) every time a destination renders.
/// The desktop app reads the same file with `dart:io`
/// — the path comes from `turso_config.json`
/// (`iqair_snapshot`), so it is a per-machine
/// setting like the Pictures folder. Android has no
/// such file and the PM2.5 history table stays
/// hidden, exactly like the banner photos.
///
/// The snapshot is read once and cached for the
/// process: it is large, and a destination page
/// must not re-parse it on every build.
library;

import 'dart:convert';
import 'dart:io';

import 'iqair_ranking.dart';

class IqairRepository {
  final String path;

  List<IqairCity>? _cache;

  IqairRepository(this.path);

  bool get isConfigured => path.isNotEmpty;

  /// The snapshot's cities, or an empty list when
  /// the file is missing or malformed — a missing
  /// snapshot is a normal state (the table hides),
  /// never a crash.
  Future<List<IqairCity>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    if (!isConfigured) {
      _cache = const [];
      return _cache!;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        _cache = const [];
        return _cache!;
      }
      final text = await file.readAsString();
      final map = jsonDecode(text) as Map<String, dynamic>;
      final raw = map['cities'];
      final cities = <IqairCity>[];
      if (raw is List) {
        for (final entry in raw) {
          if (entry is Map<String, dynamic>) {
            cities.add(IqairCity.fromJson(entry));
          }
        }
      }
      _cache = cities;
      return cities;
    } catch (_) {
      // A malformed snapshot is the same as a missing
      // one: the table hides rather than erroring.
      _cache = const [];
      return _cache!;
    }
  }
}
