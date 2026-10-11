/// Live verification of the IQAir matcher against
/// the real snapshot.
///
/// The snapshot (`iqair_cache/world_cities.json`)
/// is a git-ignored, rebuildable cache, so it is
/// absent on a fresh checkout and on CI — the
/// whole group skips there. Where it exists, the
/// lookups below are the destinations the legacy
/// workbook actually holds, so a regression in the
/// normalisation or the country filter shows up
/// as a wrong city, rank or average.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/iqair_ranking.dart';

void main() {
  final snapshot = File(
      '../iqair_cache/world_cities.json');
  final exists = snapshot.existsSync();

  group('live snapshot', () {
    late IqairIndex index;

    setUpAll(() {
      if (!exists) return;
      final map = jsonDecode(
          snapshot.readAsStringSync()) as Map<String, dynamic>;
      final cities = [
        for (final entry in (map['cities'] as List))
          if (entry is Map<String, dynamic>)
            IqairCity.fromJson(entry),
      ];
      index = IqairIndex.build(cities);
    });

    test('the snapshot is populated', () {
      if (!exists) return;
      expect(index.names.length, greaterThan(1000));
    });

    test('an exact match resolves the rank and average', () {
      if (!exists) return;
      final result = lookup('Loni', index, country: 'India');
      expect(result.status, 'city');
      expect(result.rank, 1);
      expect(result.pm25Avg, isNotNull);
    });

    test('the alias table resolves Saigon', () {
      if (!exists) return;
      final result =
          lookup('Saigon', index, country: 'Vietnam');
      expect(result.status, 'city');
      expect(result.entry?.city, 'Ho Chi Minh City');
    });

    test('a country mismatch is a wrong-country miss', () {
      if (!exists) return;
      final result =
          lookup('Loni', index, country: 'Vietnam');
      expect(result.status, 'wrong-country');
    });

    test('a real destination with a capital fallback', () {
      if (!exists) return;
      // Sri Lanka is a region row in the workbook;
      // the matcher falls back to its capital. The
      // snapshot holds a Colombo in Brazil too, so
      // the country filter must keep Sri Lanka's.
      final result =
          lookup('Sri Lanka', index, country: 'Sri Lanka');
      expect(result.status, 'capital');
      expect(result.via, 'Colombo');
      expect(result.entry?.country, 'Sri Lanka');
    });

    test('the alias table resolves Bangalore', () {
      if (!exists) return;
      final result =
          lookup('Bangalore', index, country: 'India');
      expect(result.status, 'city');
      expect(result.entry?.city, 'Bengaluru');
    });

    test('a real destination resolves its rank', () {
      if (!exists) return;
      final result = lookup('Delhi', index, country: 'India');
      expect(result.status, 'city');
      expect(result.rank, 4);
      expect(result.entry?.city, 'Delhi');
    });
  });
}
