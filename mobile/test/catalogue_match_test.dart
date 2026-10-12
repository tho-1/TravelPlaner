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

  group('groupByCountry', () {
    test('groups by country, sorted by country then name', () {
      final groups = groupByCountry([
        _destination('Kyoto', country: 'Japan'),
        _destination('Rome', country: 'Italy'),
        _destination('Milan', country: 'Italy'),
        _destination('Alexandria', country: 'Egypt'),
      ]);
      // Egypt, Italy, Japan -- the legacy's
      // case-insensitive country sort.
      expect([for (final g in groups) g.country],
          ['Egypt', 'Italy', 'Japan']);
      // Within Italy: Milan before Rome (the
      // case-insensitive name sort).
      expect([for (final d in groups[1].destinations) d.name],
          ['Milan', 'Rome']);
      expect(groups[1].destinations.length, 2);
      expect(groups[0].destinations.length, 1);
    });

    test('a destination without a country forms a headerless group', () {
      final groups = groupByCountry([
        _destination('Somewhere', country: null),
        _destination('Rome', country: 'Italy'),
      ]);
      // The blank country sorts first and renders
      // without a header, like the legacy's
      // groupby(dropna=False) with the blank header.
      expect(groups.length, 2);
      expect(groups[0].country, isNull);
      expect(groups[0].destinations.single.name, 'Somewhere');
      expect(groups[1].country, 'Italy');
    });

    test('the sort key is lowercased, the group key is not', () {
      // "Italy" and "italy" sort next to each other
      // but stay two sections -- the legacy's exact
      // behavior (sort by the lowered column, group
      // by the original).
      final groups = groupByCountry([
        _destination('Rome', country: 'Italy'),
        _destination('Turin', country: 'italy'),
      ]);
      expect(groups.length, 2);
      expect(groups[0].country, 'Italy');
      expect(groups[1].country, 'italy');
    });

    test('the name sort is case-insensitive', () {
      final groups = groupByCountry([
        _destination('zurich', country: 'Switzerland'),
        _destination('Basel', country: 'Switzerland'),
        _destination('Geneva', country: 'Switzerland'),
      ]);
      expect([for (final d in groups.single.destinations) d.name],
          ['Basel', 'Geneva', 'zurich']);
    });
  });
}
