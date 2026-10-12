/// Matching a weekend-finder city to a catalogue
/// destination: "is this city one I already have a page
/// for?"
///
/// The Dart port of `airport_city.match_catalogue` (plus
/// `clean_city_name`, `normalize_key`, the country-name
/// table from `country_names.json`, and the two small
/// explicit tables below). The catalogue index itself is
/// built from the app's own destinations -- the workbook's
/// `Result sheet`, reached through Turso -- instead of a
/// separate load, because that is the table the app has.
///
/// The explicit tables are the project convention: the
/// heuristics that came before them were rewritten three
/// times, and these eleven aliases plus one not-a-city are
/// the entire correction surface.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/destination.dart';

/// Country code -> English name, generated from
/// `airport_city.COUNTRY_NAMES` (the single source of
/// truth; regenerate with the documented script if the
/// Python table changes).
class CountryNames {
  static final Map<String, String> _names = {};
  static var _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final text = await rootBundle.loadString('assets/country_names.json');
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    for (final entry in decoded.entries) {
      _names[entry.key.toUpperCase()] = '${entry.value}';
    }
    _loaded = true;
  }

  static String nameFor(String code) =>
      _names[code.trim().toUpperCase()] ?? '';

  /// Test seam.
  static void installForTesting(Map<String, String> names) {
    _names
      ..clear()
      ..addAll({for (final entry in names.entries) entry.key.toUpperCase(): entry.value});
    _loaded = true;
  }
}

/// A workbook spelling of a finder city, for the pairs the
/// plain name match cannot resolve. Literal, like the
/// Python dict.
const catalogueAliases = <String, String>{
  'Bengaluru|IN': 'Bangalore',
  'Cebu City|PH': 'Cebu City',
  'New Delhi|IN': 'Delhi',
  'Saiss|MA': 'Fez',
  'Bandar Seri Begawan|BN': 'Brunei (capital)',
  'Kaohsiung|TW': 'Tainan',
  'Denpasar|ID': 'Denpasar',
  'Saigon|VN': 'Saigon',
  'Phu Quoc|VN': 'Phu Quoc',
  'Montevideo|UY': 'Montevideo',
  'Kota Kinabalu|MY': 'Kota Kinabalu',
};

/// A catalogue row that names a country, not a city:
/// linking it would put "Sri Lanka (LK)" in a list of
/// cities.
const notACity = {'Sri Lanka|LK'};

/// Strip a district/qualifier suffix from a city name:
/// "Hanoi (Soc Son)" -> "Hanoi". The same shape appears in
/// the workbook and in the airport table, so both go
/// through here.
String cleanCityName(Object? raw) {
  final text = (raw ?? '').toString().trim();
  final match = RegExp(r'^([^(]+?)\s*\([^()]+\)\s*$').firstMatch(text);
  return match?.group(1)?.trim() ?? text;
}

/// Lowercase alphanumeric key used for city-name matching.
String normalizeKey(Object? value) {
  var text = (value ?? '').toString().toLowerCase();
  for (final entry in _transliterations.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  return text.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

/// Latin-1 accents the city names actually use (Zürich,
/// São Paulo, ...). An explicit table, not a heuristic.
const _transliterations = <String, String>{
  'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'å': 'a',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u',
  'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ø': 'o', 'æ': 'ae',
};

/// The catalogue destinations, indexed for matching. Built
/// once from a loaded destination list.
class CatalogueIndex {
  final Map<String, String> _byCityCountry = {};
  final Map<String, List<String>> _byCity = {};

  CatalogueIndex(Iterable<Destination> destinations) {
    for (final destination in destinations) {
      final city = cleanCityName(destination.name);
      final country = destination.country ?? '';
      if (city.isEmpty || country.isEmpty) continue;
      _byCityCountry['${normalizeKey(city)}|${normalizeKey(country)}'] =
          destination.name;
      _byCity.putIfAbsent(normalizeKey(city), () => []).add(country);
    }
  }

  /// The workbook's name for this city/country, or `null`
  /// when absent.
  String? match(String city, String countryCode) {
    final country = CountryNames.nameFor(countryCode);
    if (country.isEmpty) return null;
    final rawCity = cleanCityName(city);
    final iso = countryCode.trim().toUpperCase();
    if (notACity.contains('$rawCity|$iso')) return null;
    final alias = catalogueAliases['$rawCity|$iso'];
    if (alias != null) return alias;
    final key = '${normalizeKey(rawCity)}|${normalizeKey(country)}';
    final found = _byCityCountry[key];
    if (found != null) return found;
    // Fall back to matching on the city alone, but only
    // when the country's English name and the workbook's
    // country agree.
    final cities = _byCity[normalizeKey(rawCity)] ?? const [];
    for (final candidate in cities) {
      if (normalizeKey(candidate) == normalizeKey(country)) {
        return _byCityCountry[
            '${normalizeKey(rawCity)}|${normalizeKey(candidate)}'];
      }
    }
    return null;
  }
}

/// One country's section of the catalogue: the country
/// name (`null` when the destination has none) and its
/// destinations, in the legacy's order.
typedef CountryGroup = ({String? country, List<Destination> destinations});

/// The legacy overview's grouping, ported rule for rule
/// (`pages/overview.py`): destinations sorted by country
/// (case-insensitive), then by name (case-insensitive),
/// then grouped — each country one tinted section whose
/// header carries its count. A destination without a
/// country forms its own headerless group, exactly like
/// the legacy's `groupby(country, sort=False,
/// dropna=False)` with the blank header.
///
/// The sort key is the lowercased country, but the
/// group key is the original spelling: "Italy" and
/// "italy" sort next to each other yet stay two
/// sections, which is what the legacy does.
List<CountryGroup> groupByCountry(List<Destination> destinations) {
  final sorted = [...destinations]
    ..sort((a, b) {
      final countryA = (a.country ?? '').toLowerCase();
      final countryB = (b.country ?? '').toLowerCase();
      if (countryA != countryB) return countryA.compareTo(countryB);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  final groups = <CountryGroup>[];
  for (final destination in sorted) {
    final country = (destination.country ?? '').trim();
    final key = country.isEmpty ? null : country;
    if (groups.isEmpty || groups.last.country != key) {
      groups.add((country: key, destinations: [destination]));
    } else {
      groups.last.destinations.add(destination);
    }
  }
  return groups;
}
