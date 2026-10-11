/// The IQAir ranking matcher: the normalisation,
/// the country filter, and the resolution chain.
/// Fixtures are hand-built cities, the same shapes
/// the snapshot holds.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/iqair_ranking.dart';

IqairCity city(int rank, String name, String country,
    [Map<String, double>? pm25]) {
  return IqairCity(
    rank: rank,
    city: name,
    country: country,
    pm25: pm25 ?? const {},
  );
}

void main() {
  group('norm', () {
    test('folds case, punctuation and spacing', () {
      expect(norm('  New   York '), 'new york');
      expect(norm("Xi'an"), 'xian');
      expect(norm('Côte d’Ivoire'), 'cote divoire');
    });

    test('decomposes the accented Latin names', () {
      expect(norm('Cancún'), 'cancun');
      expect(norm('Montréal'), 'montreal');
      expect(norm('Zürich'), 'zurich');
      expect(norm('Kraków'), 'krakow');
      expect(norm('Đà Nẵng'), 'da nang');
    });
  });

  group('country filter', () {
    final index = IqairIndex.build([
      city(1, 'Abu Dhabi', 'United Arab Emirates'),
      city(2, 'Dubai', 'United Arab Emirates'),
      city(3, 'Abu Dhabi', 'USA'),
    ]);

    test('the UAE alias matches the full spelling', () {
      final result = lookup('Abu Dhabi', index, country: 'UAE');
      expect(result.status, 'city');
      expect(result.entry?.country, 'United Arab Emirates');
    });

    test('connector words are ignored', () {
      final result =
          lookup('X', index, country: 'United Arab Emirates');
      expect(result.status, 'unmatched');
      // 'Bosnia and Herzegovina' == 'Bosnia Herzegovina'
      final bosnia = IqairIndex.build([
        city(1, 'Sarajevo', 'Bosnia and Herzegovina'),
      ]);
      expect(
        lookup('Sarajevo', bosnia,
            country: 'Bosnia Herzegovina').status,
        'city',
      );
    });

    test('token sets must be equal, not a subset', () {
      // 'Guinea' must not match 'Equatorial Guinea'.
      final index = IqairIndex.build([
        city(1, 'Malabo', 'Equatorial Guinea'),
      ]);
      expect(
        lookup('Malabo', index, country: 'Guinea').status,
        'wrong-country',
      );
    });
  });

  group('lookup chain', () {
    test('an exact match resolves', () {
      final index = IqairIndex.build([
        city(10, 'Loni', 'India', {'2025': 112.5, '2024': 91.7}),
      ]);
      final result = lookup('Loni', index, country: 'India');
      expect(result.status, 'city');
      expect(result.rank, 10);
      expect(result.pm25Avg, closeTo(102.1, 0.05));
      expect(result.guessed, isFalse);
    });

    test('the alias table renames the query', () {
      final index = IqairIndex.build([
        city(5, 'Ho Chi Minh City', 'Vietnam'),
      ]);
      expect(
        lookup('Saigon', index, country: 'Vietnam').status,
        'city',
      );
    });

    test('a parenthetical gives the base name', () {
      final index = IqairIndex.build([
        city(7, 'Kota Kinabalu', 'Malaysia'),
      ]);
      expect(
        lookup('KK (Kota Kinabalu)', index,
            country: 'Malaysia').status,
        'city',
      );
    });

    test('a region row falls back to its capital', () {
      final index = IqairIndex.build([
        city(3, 'Colombo', 'Sri Lanka'),
      ]);
      final result = lookup('Sri Lanka', index, country: 'Sri Lanka');
      expect(result.status, 'capital');
      expect(result.via, 'Colombo');
      expect(result.rank, 3);
    });

    test('a renamed city matches by prefix (two tokens)', () {
      final index = IqairIndex.build([
        city(9, 'Santa Cruz de la Sierra', 'Bolivia'),
      ]);
      expect(
        lookup('Santa Cruz', index, country: 'Bolivia').status,
        'city',
      );
      // One token never prefix-matches: Salvador != San Salvador.
      final index2 = IqairIndex.build([
        city(1, 'San Salvador', 'El Salvador'),
      ]);
      expect(
        lookup('Salvador', index2, country: 'El Salvador').status,
        'unmatched',
      );
    });

    test('several same-country hits resolve by best rank, flagged',
        () {
      final index = IqairIndex.build([
        city(20, 'Suzhou', 'China'),
        city(40, 'Suzhou', 'China'),
      ]);
      final result = lookup('Suzhou', index, country: 'China');
      expect(result.status, 'city');
      expect(result.rank, 20);
      expect(result.guessed, isTrue);
    });

    test('a candidate in another country is a wrong-country miss', () {
      final index = IqairIndex.build([
        city(1, 'Abu Dhabi', 'United Arab Emirates'),
      ]);
      final result = lookup('Abu Dhabi', index, country: 'India');
      expect(result.status, 'wrong-country');
      expect(result.candidates, isNotEmpty);
    });

    test('an ambiguous name reports its candidates', () {
      final index = IqairIndex.build([
        city(2, 'Springfield', 'USA'),
        city(8, 'Springfield', 'USA'),
      ]);
      // Two same-country hits are a guess, not ambiguous; a
      // name with no country filter and several countries is.
      final result = lookup('Springfield', index);
      expect(result.status, 'city');
      expect(result.guessed, isTrue);
    });
  });

  group('pm25Avg', () {
    test('averages the up-to-five most recent years', () {
      final city = IqairCity(
        rank: 1,
        city: 'X',
        country: 'Y',
        pm25: {
          '2025': 100.0,
          '2024': 80.0,
          '2023': 60.0,
          '2020': 40.0, // outside the 5-year window
        },
      );
      expect(city.pm25Avg, closeTo(80.0, 0.001));
    });

    test('is null with no values', () {
      expect(
        IqairCity(rank: 1, city: 'X', country: 'Y', pm25: {})
            .pm25Avg,
        isNull,
      );
    });
  });
}
