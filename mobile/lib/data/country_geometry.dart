/// Country geometry: the world's country shapes, loaded from
/// the bundled `assets/world_countries.geojson`.
///
/// The legacy world map is a Plotly **choropleth** — countries
/// filled with a colour, which is the feature that says "how
/// good is the time to go" at a glance. The app draws the same
/// thing on top of its tile map: this module loads the
/// geometry, indexes the features by normalised country name
/// (the same name the destinations carry), and answers the
/// hit test that turns a tap on the map into a country.
///
/// The geometry is bundled rather than fetched, so the map
/// works offline and a slow connection never leaves a blank
/// map. It is the public `world.geo.json` dataset (180
/// features), reduced to what a choropleth needs: each
/// country's name and its outer rings.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/geo.dart' show pointInCountry, unwrapRing;

/// One country's shape: the name, the outer rings as flat
/// [longitude, latitude] pairs, and the rings' bounding box
/// (post-unwrap, so it may extend past ±180° for
/// antimeridian countries) — the cheap pre-filter both the
/// hover hit test and the painters run before touching
/// points.
class CountryShape {
  final String name;
  final List<List<List<double>>> rings;

  /// (minLon, minLat, maxLon, maxLat) over the unwrapped
  /// rings.
  final (double, double, double, double) bounds;

  // Not const: the bounds derive from the rings at
  // construction, and a const initializer cannot call a
  // function.
  CountryShape({required this.name, required this.rings})
      : bounds = CountryShape._boundsOf(rings);

  static (double, double, double, double) _boundsOf(
      List<List<List<double>>> rings) {
    var minLon = 999.0, minLat = 999.0, maxLon = -999.0, maxLat = -999.0;
    for (final ring in rings) {
      for (final point in ring) {
        if (point[0] < minLon) minLon = point[0];
        if (point[1] < minLat) minLat = point[1];
        if (point[0] > maxLon) maxLon = point[0];
        if (point[1] > maxLat) maxLat = point[1];
      }
    }
    return (minLon, minLat, maxLon, maxLat);
  }

  /// Whether the shape's bounds (tested against the point
  /// and its ±360° shifts for the antimeridian) can hold it.
  bool boundsMayContain(double lon, double lat) {
    for (final candidate in [lon, lon - 360.0, lon + 360.0]) {
      if (candidate >= bounds.$1 &&
          candidate <= bounds.$3 &&
          lat >= bounds.$2 &&
          lat <= bounds.$4) {
        return true;
      }
    }
    return false;
  }

  int get pointCount {
    var total = 0;
    for (final ring in rings) {
      total += ring.length;
    }
    return total;
  }
}

/// The dataset spells a few countries longer than the
/// travel catalogue does.
///
/// An explicit table, not a heuristic (the house rule: a
/// fuzzy name match here would silently paint the wrong
/// country, and "Tanzania" missing its fill looks like a
/// data bug). These are the two workbook spellings the
/// bundled dataset does not carry verbatim — the legacy
/// solved the same mismatch with its COUNTRY_ISO3_MAP. An
/// entry whose target the dataset does not hold is simply
/// not registered: a missing shape is never an error.
const countryAliases = <String, String>{
  'Tanzania': 'United Republic of Tanzania',
  'UAE': 'United Arab Emirates',
  // The dataset's English names are longer than the
  // catalogue's Country column: the legacy resolves
  // both spellings to the same ISO-3 code
  // (COUNTRY_ISO3_MAP in world_map.py). Without
  // these, the choropleth leaves the United States
  // and the Bahamas unpainted while their cities
  // are plotted.
  'United States': 'United States of America',
  'Bahamas': 'The Bahamas',
};

/// The loaded geometry, indexed like the Python side's
/// country lookup: `data_utils.normalize_text` on the
/// dataset's English names.
class CountryGeometry {
  final Map<String, CountryShape> _shapes;

  const CountryGeometry(this._shapes);

  static final Map<String, CountryShape> _cache = {};
  static var _loaded = false;
  static Object? _loadError;

  /// Load the asset once. A missing or malformed asset
  /// leaves the index empty, which the map page reports as
  /// "no country outlines" instead of crashing.
  static Future<CountryGeometry> load() async {
    if (_loaded) return CountryGeometry(_cache);
    try {
      final text =
          await rootBundle.loadString('assets/world_countries.geojson');
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final features = decoded['features'] as List;
      for (final feature in features) {
        if (feature is! Map) continue;
        final properties = feature['properties'];
        final name = properties is Map ? '${properties['name']}' : '';
        if (name.isEmpty || name == 'null') continue;
        final geometry = feature['geometry'];
        if (geometry is! Map) continue;
        final rings = _ringsOf(geometry);
        if (rings.isEmpty) continue;
        final shape = CountryShape(name: name, rings: rings);
        _cache.putIfAbsent(normalizeCountryName(name), () => shape);
      }
      // Register the catalogue's shorter spellings against
      // the shapes the dataset does hold.
      for (final entry in countryAliases.entries) {
        final shape = _cache[normalizeCountryName(entry.value)];
        if (shape != null) {
          _cache.putIfAbsent(normalizeCountryName(entry.key), () => shape);
        }
      }
    } catch (problem) {
      _loadError = problem;
    }
    _loaded = true;
    return CountryGeometry(_cache);
  }

  static Object? get loadError => _loadError;

  /// Polygon/MultiPolygon -> the outer rings, in the same
  /// [lon, lat] pair order the file uses. Holes are dropped:
  /// a filled country ignores them anyway.
  static List<List<List<double>>> _ringsOf(Map geometry) {
    final type = '${geometry['type']}';
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) return const [];
    if (type == 'Polygon') {
      return [
        if (coordinates.isNotEmpty && coordinates.first is List)
          _ring(coordinates.first as List),
      ];
    }
    if (type == 'MultiPolygon') {
      final out = <List<List<double>>>[];
      for (final polygon in coordinates) {
        if (polygon is List && polygon.isNotEmpty && polygon.first is List) {
          out.add(_ring(polygon.first as List));
        }
      }
      return out;
    }
    return const [];
  }

  static List<List<double>> _ring(List raw) {
    final out = <List<double>>[];
    for (final point in raw) {
      if (point is List && point.length >= 2) {
        final lon = point[0];
        final lat = point[1];
        if (lon is num && lat is num) {
          out.add([lon.toDouble(), lat.toDouble()]);
        }
      }
    }
    // Unwrap before storing: a ring that crosses the
    // antimeridian (Fiji, Russia's Chukotka) must paint and
    // hit-test as the strip it means, not as a rectangle
    // around the planet — see geo.unwrapRing.
    return out.length < 3 ? out : unwrapRing(out);
  }

  /// The shape for a country name, or `null` when the dataset
  /// does not know the country (then the map shows no fill
  /// for it, and still plots its cities).
  CountryShape? lookup(String? country) {
    if (country == null || country.trim().isEmpty) return null;
    return _shapes[normalizeCountryName(country)];
  }

  /// Every shape, for the tap hit test.
  Iterable<CountryShape> get shapes => _shapes.values;

  /// The country under a lon/lat point, or `null`. The
  /// bounding box runs first, so a hover move only pays the
  /// ray-cast for the one or two shapes it can be in.
  CountryShape? hitTest(double longitude, double latitude) {
    for (final shape in _shapes.values) {
      if (!shape.boundsMayContain(longitude, latitude)) continue;
      if (pointInCountry(longitude, latitude, shape.rings)) return shape;
    }
    return null;
  }

  /// Test/debug seam.
  int get shapeCount => _shapes.length;
}

/// `data_utils.normalize_text`: lowercase, everything but
/// a-z0-9 dropped. The dataset's names are English, and the
/// destinations' country column is English, so this is what
/// has to match.
String normalizeCountryName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
