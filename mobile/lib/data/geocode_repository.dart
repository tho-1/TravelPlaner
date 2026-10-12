/// The Open-Meteo geocoding client with a small
/// disk cache -- the Dart port of
/// `itinerary/geocode.py`.
///
/// Used when the traveler adds a city that is
/// neither a workbook destination nor the home
/// gateway (e.g. Beijing, Chengdu). Responses
/// are cached in `{cacheDir}/geocode.json` so
/// repeat selections and offline restarts never
/// re-query. The directory is a per-machine
/// path from `turso_config.json`
/// (`geocode_cache`), so on the phone there is
/// no cache and every search queries afresh --
/// the same per-device pattern as the routes
/// cache.
///
/// Two failure modes the Python file fixed and
/// this port must keep fixed:
///
/// * an **empty** result was cached forever, so
///   one bad API answer blocked that city until
///   the cache file was deleted by hand;
/// * Open-Meteo answers **HTTP 200** with
///   `{"error": true, ...}` for a rejected
///   query, which looked exactly like "no such
///   city".
///
/// Neither is ever cached, and `search` never
/// throws -- a failed lookup is an empty list.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// One geocode match: `[{name, country, admin1,
/// lat, lon}]` in the legacy's shape.
class GeocodeResult {
  final String name;
  final String? country;
  final String? admin1;
  final double? lat;
  final double? lon;

  const GeocodeResult({
    required this.name,
    this.country,
    this.admin1,
    this.lat,
    this.lon,
  });

  factory GeocodeResult.fromJson(Map<String, dynamic> json) =>
      GeocodeResult(
        name: '${json['name']}',
        country: json['country'] as String?,
        admin1: json['admin1'] as String?,
      // The API's field names are latitude/longitude; the
      // legacy maps them onto the lat/lon shape it uses
      // everywhere else.
      lat: (json['latitude'] as num?)?.toDouble(),
      lon: (json['longitude'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'country': country,
        'admin1': admin1,
        'lat': lat,
        'lon': lon,
      };
}

class GeocodeRepository {
  /// The cache directory, from
  /// `turso_config.json` (`geocode_cache`).
  /// Empty means unconfigured -- searches still
  /// work, they just never persist.
  final String cacheDir;

  final http.Client httpClient;

  static const _endpoint =
      'https://geocoding-api.open-meteo.com/v1/search';

  /// How long a cached result stays usable.
  static const _ttlDays = 30;

  /// Bump to invalidate every existing entry at
  /// once (the legacy's `_SCHEMA = 2`).
  static const _schema = 2;

  static const _timeout = Duration(seconds: 15);

  GeocodeRepository(this.cacheDir, {http.Client? httpClient})
      : httpClient = httpClient ?? http.Client();

  /// Search for a city. Returns possibly-empty,
  /// never throws.
  Future<List<GeocodeResult>> search(
    String query, {
    int count = 5,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];
    final key = '${_norm(trimmed)}|$count';
    final cached = _loadCache()[key];
    if (cached != null && _isFresh(cached)) {
      final results = cached['results'];
      if (results is List) {
        return [
          for (final entry in results)
            if (entry is Map)
              GeocodeResult.fromJson(
                  Map<String, dynamic>.from(entry)),
        ];
      }
    }

    List<GeocodeResult> results;
    try {
      final response = await httpClient
          .get(
            Uri.parse(_endpoint).replace(queryParameters: {
              'name': trimmed,
              'count': '$count',
              'language': 'en',
              'format': 'json',
            }),
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        return [];
      }
      final payload = jsonDecode(response.body);
      if (payload is! Map || payload['error'] == true) {
        // A rejected query -- do not cache it.
        return [];
      }
      final raw = payload['results'];
      results = [
        for (final entry in raw is List ? raw : [])
          if (entry is Map)
            GeocodeResult.fromJson(
                Map<String, dynamic>.from(entry)),
      ];
    } catch (_) {
      // Transient network error: don't cache the
      // failure.
      return [];
    }

    if (results.isNotEmpty) {
      final entries = _loadCache();
      entries[key] = {
        'ts': DateTime.now().toUtc().toIso8601String(),
        'results': [for (final r in results) r.toJson()],
      };
      _saveCache(entries);
    }
    return results;
  }

  /// `" ".join(query.casefold().split())` -- the
  /// cache key's query half.
  static String _norm(String query) => query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .join(' ');

  Map<String, dynamic> _loadCache() {
    if (cacheDir.trim().isEmpty) return {};
    try {
      final raw = jsonDecode(
          File('$cacheDir/geocode.json').readAsStringSync());
      if (raw is! Map || raw['schema'] != _schema) {
        return {};
      }
      final entries = raw['entries'];
      return entries is Map
          ? Map<String, dynamic>.from(
              entries.map((k, v) => MapEntry('$k', v)))
          : {};
    } catch (_) {
      return {};
    }
  }

  /// Best effort: a failure to write is a missed
  /// cache entry, never a crash.
  void _saveCache(Map<String, dynamic> entries) {
    if (cacheDir.trim().isEmpty) return;
    try {
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final path = File('$cacheDir/geocode.json');
      final tmp = File('$cacheDir/geocode.json.tmp');
      tmp.writeAsStringSync(jsonEncode(
          {'schema': _schema, 'entries': entries}));
      // Atomic replace where the platform allows
      // it; a direct write is the fallback (the
      // cache is best-effort either way).
      try {
        tmp.renameSync(path.path);
      } on FileSystemException {
        path.writeAsStringSync(
            jsonEncode({'schema': _schema, 'entries': entries}));
      }
    } catch (_) {
      // cache is best-effort
    }
  }

  static bool _isFresh(Map<String, dynamic> entry) {
    final stamp = entry['ts'];
    if (stamp is! String) return false;
    final ts = DateTime.tryParse(stamp);
    if (ts == null) return false;
    final normalized =
        ts.isUtc ? ts : ts.toUtc();
    return DateTime.now()
            .toUtc()
            .difference(normalized) <=
        const Duration(days: _ttlDays);
  }
}
