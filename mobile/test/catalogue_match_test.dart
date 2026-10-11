/// Catalogue matching: which finder cities already have a
/// page, the alias table, and the qualifier stripping. The
/// index is built from destinations, the country names from
/// the generated table.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/catalogue_match.dart';
import 'package:travel_planner/models/destination.dart';

Destination _destination(String name, {String? country}) => Destination(
      core: {'destination': name, 'country': country},
      columns: const [],
    );

void main() {
  setUp(() {
    CountryNames.installForTesting({
      'GB': 'United Kingdom',
      'ES': 'Spain',
      'IN': 'India',
    });
  });

  test('a plain city/country match finds the catalogue name', () {
    final index = CatalogueIndex([_destination('London', country: 'United Kingdom')]);
    expect(index.match('London', 'GB'), 'London');
  });

  test('the match is case- and accent-insensitive', () {
    final index = CatalogueIndex([_destination('Zürich', country: 'Switzerland')]);
    CountryNames.installForTesting({'CH': 'Switzerland'});
    expect(index.match('Zurich', 'CH'), 'Zürich');
  });

  test('a workbook qualifier is stripped on both sides', () {
    final index = CatalogueIndex([
      _destination('Chongqing (Chongqing)', country: 'China'),
    ]);
    CountryNames.installForTesting({'CN': 'China'});
    expect(index.match('Chongqing (Chongqing)', 'CN'), 'Chongqing (Chongqing)');
  });

  test('the alias table resolves the workbook spelling', () {
    final index = CatalogueIndex([_destination('Bangalore', country: 'India')]);
    // The airport table says Bengaluru; the workbook says Bangalore.
    expect(index.match('Bengaluru', 'IN'), 'Bangalore');
  });

  test('a country row is not a city', () {
    final index = CatalogueIndex([_destination('Sri Lanka', country: 'Sri Lanka')]);
    expect(index.match('Sri Lanka', 'LK'), isNull);
  });

  test('an unknown country code does not match', () {
    final index = CatalogueIndex([_destination('London', country: 'United Kingdom')]);
    expect(index.match('London', 'ZZ'), isNull);
  });

  test('cleanCityName strips one qualifier', () {
    expect(cleanCityName('Hanoi (Soc Son)'), 'Hanoi');
    expect(cleanCityName('London'), 'London');
    expect(cleanCityName(''), '');
  });
}
