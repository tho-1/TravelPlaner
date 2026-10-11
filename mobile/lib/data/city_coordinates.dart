/// The destination coordinate table, loaded from the
/// generated `assets/city_coordinates.json`.
///
/// The same table `city_coordinates.json` holds for the
/// Streamlit world map and `itinerary/geo.py`, with the
/// *same* lookup contract -- and that contract has two
/// halves, because the two Python readers use two key
/// schemes:
///
/// * `world_map` looks the **raw** name up after
///   `data_utils.normalize_text` (everything that is not
///   a-z0-9 is dropped, so "Bogotá" reaches the slug
///   "bogot"), and then the same for the
///   parenthetical-stripped name ("Xi'an (Shaanxi)" ->
///   "xian");
/// * `itinerary.geo` keeps the case-folded spelling
///   (accents included) and adds a punctuation-stripped
///   alias.
///
/// The index registers every entry under both schemes, and
/// the lookup tries them in the world-map order, which is
/// what the legacy page does. Unknown is a normal answer --
/// a destination without coordinates simply has no map
/// position.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// One coordinate row.
class CityCoordinate {
  final String name;
  final String country;
  final double lat;
  final double lon;

  const CityCoordinate({
    required this.name,
    required this.country,
    required this.lat,
    required this.lon,
  });

  factory CityCoordinate.fromJson(Map<String, dynamic> json) =>
      CityCoordinate(
        name: '${json['name']}',
        country: '${json['country'] ?? ''}',
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
      );

  @override
  String toString() => '$name ($country) at $lat, $lon';
}

/// The loaded table, indexed like the Python readers do.
class CoordinateIndex {
  final Map<String, CityCoordinate> _index;

  const CoordinateIndex(this._index);

  static final Map<String, CityCoordinate> _cache = {};
  static var _loaded = false;
  static Object? _loadError;

  /// Load the asset once. A missing or malformed asset
  /// leaves the index empty rather than failing: a
  /// destination without coordinates shows no map, which
  /// is not a crash. `loadError` explains an empty table.
  static Future<CoordinateIndex> load() async {
    if (_loaded) return CoordinateIndex(_cache);
    try {
      final text =
          await rootBundle.loadString('assets/city_coordinates.json');
      final decoded = jsonDecode(text) as List;
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final coordinate = CityCoordinate.fromJson(
            Map<String, dynamic>.from(entry));
        for (final spelling in [
          coordinate.name,
          '${entry['destination']}',
        ]) {
          if (spelling.isEmpty || spelling == 'null') continue;
          final clean = cleanCityName(spelling);
          for (final candidate in [spelling, clean]) {
            _cache.putIfAbsent(normalizeText(candidate), () => coordinate);
            _cache.putIfAbsent(caseFolded(candidate), () => coordinate);
            _cache.putIfAbsent(aliasOf(candidate), () => coordinate);
          }
        }
      }
    } catch (problem) {
      _loadError = problem;
    }
    _loaded = true;
    return CoordinateIndex(_cache);
  }

  /// Why the table is empty, when it is.
  static Object? get loadError => _loadError;

  /// The coordinate for a destination name, or `null`.
  ///
  /// Tries the world-map order first (raw, then the
  /// parenthetical-stripped name), and the case-folded
  /// spellings after that.
  CityCoordinate? lookup(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final raw = name.trim();
    final clean = cleanCityName(raw);
    for (final candidate in [raw, clean]) {
      final coordinate = _index[normalizeText(candidate)];
      if (coordinate != null) return coordinate;
    }
    for (final candidate in [raw, clean]) {
      final coordinate = _index[caseFolded(candidate)];
      if (coordinate != null) return coordinate;
    }
    for (final candidate in [raw, clean]) {
      final coordinate = _index[aliasOf(candidate)];
      if (coordinate != null) return coordinate;
    }
    return null;
  }

  /// Test/debug seam: how many entries the table holds.
  int get sizeForDebug => _index.length;
}

/// Strip the parenthetical qualifier from a workbook name:
/// "Xi'an (Shaanxi)" -> "Xi'an". The same shape appears in
/// the coordinates table and in the destination names, so
/// both go through here -- the rule `world_map` applies
/// before its second lookup.
String cleanCityName(String name) {
  final text = name.trim();
  final match = RegExp(r'^(.*?)\s*\([^()]*\)\s*$').firstMatch(text);
  return match?.group(1)?.trim() ?? text;
}

/// `data_utils.normalize_text`, character for character:
/// lowercase, and **everything that is not a-z0-9 dropped**
/// -- accents included, not folded. That is why the table's
/// slug for "Bogotá" is "bogot": the rule is lossy, and the
/// keys were generated with it, so the lookup has to be as
/// lossy as the keys it looks up.
String normalizeText(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

/// `itinerary.geo._norm_name`: case-folded, whitespace
/// collapsed, accents kept.
String caseFolded(String name) => name
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((part) => part.isNotEmpty)
    .join(' ');

/// `itinerary.geo`'s punctuation-stripped alias, so
/// user-typed "Xian" finds "Xi'an".
String aliasOf(String name) =>
    name.toLowerCase().replaceAll("'", '').replaceAll('.', '');
