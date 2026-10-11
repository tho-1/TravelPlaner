/// The shared filter model: the blank-row invariant, the
/// shared month vocabulary, the Yes/No columns, the slider
/// bounds and the option lists. These are the rules the
/// legacy implements in `filters.py` and that lost data
/// when a page re-implemented them.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/catalogue_filters.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/destination_profile.dart';

Destination _destination(
  String name, {
  String? country = 'Egypt',
  String? continent = 'Africa',
  Object? safetyRating,
  Object? reviews,
  Object? visited,
  Object? eu,
  Object? researched,
  Map<String, Object?> months = const {},
}) {
  return Destination(
    core: {
      'destination': name,
      'country': country,
      'continent': continent,
      'safety_rating': safetyRating,
      'visited': ?visited,
      'to_be_researched': ?researched,
    },
    columns: [
      if (reviews != null) ('Reviews', reviews),
      if (eu != null) ('Yes?', eu),
      for (final entry in months.entries) (entry.key, entry.value),
    ],
  );
}

DestinationProfile _profileOf(Destination destination) =>
    DestinationProfile.from(destination);

FilterOutcome _apply(
  List<Destination> destinations,
  CatalogueFilters filters,
) =>
    applyCatalogueFilters(destinations, filters, _profileOf);

void main() {
  group('the blank-row invariant', () {
    final destinations = [
      _destination('Rated', safetyRating: 8, reviews: 90),
      _destination('NotRated', safetyRating: null, reviews: null),
    ];

    test('a minimum keeps rows whose field is blank', () {
      final outcome = _apply(destinations, const CatalogueFilters(
        continent: null,
        minSafety: 5,
        minReviews: 50,
      ));
      expect(outcome.kept.map((d) => d.name), ['Rated', 'NotRated']);
    });

    test('a populated row below the minimum is removed', () {
      final outcome = _apply(destinations, const CatalogueFilters(minSafety: 9));
      expect(outcome.kept.map((d) => d.name), ['NotRated']);
    });

    test('the caption names the fields that were too empty to hide by', () {
      final outcome = _apply(destinations, const CatalogueFilters(minSafety: 5));
      expect(outcome.missing['safety'], 1);
      expect(outcome.missing['reviews'], 1);
      expect(outcome.missingCaption, contains('safety (1)'));
      expect(outcome.missingCaption, contains('reviews (1)'));
    });
  });

  group('the weather-at-least-ok filter', () {
    final destinations = [
      _destination('Ideal', months: const {'July': 'ideal'}),
      _destination('Good', months: const {'July': 'good'}),
      _destination('Okay', months: const {'July': 'okay'}),
      _destination('Bad', months: const {'July': 'poor'}),
      _destination('Blank', months: const {'July': ''}),
    ];

    test('only the shared vocabulary passes, blanks kept', () {
      final outcome = _apply(destinations, const CatalogueFilters(weatherMonth: 'July'));
      expect(outcome.kept.map((d) => d.name),
          ['Ideal', 'Good', 'Okay', 'Blank']);
    });

    test('no month selected keeps everything', () {
      final outcome = _apply(destinations, const CatalogueFilters());
      expect(outcome.kept, hasLength(5));
    });
  });

  group('the Yes/No columns', () {
    final destinations = [
      _destination('Eu', eu: 'yes'),
      _destination('NotEu', eu: 'no'),
      _destination('UnknownValue', eu: 'maybe'),
      _destination('Blank'),
    ];

    test('EU=yes keeps the yes, the non-boolean and the blank', () {
      final outcome = _apply(destinations, const CatalogueFilters(eu: true));
      expect(outcome.kept.map((d) => d.name),
          ['Eu', 'UnknownValue', 'Blank']);
    });

    test('EU=no keeps the no, the non-boolean and the blank', () {
      final outcome = _apply(destinations, const CatalogueFilters(eu: false));
      expect(outcome.kept.map((d) => d.name),
          ['NotEu', 'UnknownValue', 'Blank']);
    });

    test('the research filter is a three-state select', () {
      final rows = [
        _destination('Research', researched: 'x'),
        _destination('Done', researched: 'no'),
        _destination('Blank'),
      ];
      expect(
          _apply(rows, const CatalogueFilters(requiresResearch: true))
              .kept
              .map((d) => d.name),
          ['Research', 'Blank']);
      expect(
          _apply(rows, const CatalogueFilters(requiresResearch: false))
              .kept
              .map((d) => d.name),
          ['Done', 'Blank']);
    });

    test('only-unvisited keeps blanks and hides the visited', () {
      final rows = [
        _destination('Been', visited: 'x'),
        _destination('Fresh', visited: 'no'),
        _destination('Blank'),
      ];
      final outcome = _apply(rows, const CatalogueFilters(onlyUnvisited: true));
      expect(outcome.kept.map((d) => d.name), ['Fresh', 'Blank']);
    });

    test('only-unvisited defaults on, like both legacy pages', () {
      expect(CatalogueFilters.initial().onlyUnvisited, isTrue);
    });
  });

  group('continent and country', () {
    final destinations = [
      _destination('Cairo', country: 'Egypt', continent: 'Africa'),
      _destination('Tunis', country: 'Tunisia', continent: 'Africa'),
      _destination('Rome', country: 'Italy', continent: 'Europe'),
      _destination('NoContinent', country: 'Atlantis', continent: null),
    ];

    test('equality is case-insensitive', () {
      final outcome =
          _apply(destinations, const CatalogueFilters(continent: 'africa'));
      expect(outcome.kept.map((d) => d.name), ['Cairo', 'Tunis']);
    });

    test('the country options follow the continent', () {
      expect(countryOptions(destinations, 'Africa'), ['Egypt', 'Tunisia']);
      expect(countryOptions(destinations, null),
          ['Atlantis', 'Egypt', 'Italy', 'Tunisia']);
      expect(continentOptions(destinations), ['Africa', 'Europe']);
    });
  });

  group('numericBounds', () {
    test('junk and blanks do not break the range', () {
      expect(numericBounds([null, 'n/a', 'no idea'], fallback: (0.0, 5.0)),
          (0.0, 5.0));
    });

    test('the bounds use the real values', () {
      expect(numericBounds([2, 8, '8/10'], fallback: (0.0, 5.0)), (2.0, 8.0));
    });

    test('a single value still leaves a usable range', () {
      expect(numericBounds([3], fallback: (0.0, 5.0)), (3.0, 4.0));
    });
  });
}
