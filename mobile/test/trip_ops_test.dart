/// The itinerary core: trip/variant/stop
/// operations, totals, warnings and month
/// suggestions.
///
/// The Dart twin of `tests/test_itinerary.py`
/// (minus the storage, sample and map cases,
/// which the Turso repository and the map
/// section own). Every case mirrors the
/// legacy test of the same name, so the port
/// keeps the same behaviour the Python side
/// asserts.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/trip.dart';
import 'package:travel_planner/models/trip_ops.dart';

/// The legacy's `_variant_3_stops`: FRA (origin)
/// → A (flight) → B (train).
Variant _variant3Stops() => makeVariant(
      'V',
      stops: [
        makeStop(makeRef('gateway', 'FRA', 'Germany', 50.11, 8.68),
            role: 'origin'),
        makeStop(makeRef('custom', 'A', 'China', 39.9, 116.4)),
        makeStop(makeRef('custom', 'B', 'China', 31.2, 121.5)),
      ],
      legs: [makeLeg('flight'), makeLeg('train')],
    );

StopRef _ref(String name,
        {String country = 'X', double? lat, double? lon}) =>
    makeRef('custom', name, country, lat, lon);

void main() {
  group('stop / leg operations', () {
    test('removeStop first deletes leg 0 only', () {
      final variant = removeStop(_variant3Stops(), 0);
      expect(variant.stops.map((s) => s.ref.name), ['A', 'B']);
      expect(variant.legs.length, 1);
      expect(variant.legs.first.mode, 'train');
    });

    test('removeStop middle deletes the incoming leg', () {
      final variant = removeStop(_variant3Stops(), 1);
      expect(variant.stops.map((s) => s.ref.name), ['FRA', 'B']);
      expect(variant.legs.length, 1);
      // The gap FRA->B inherits the old A->B train:
      // the incoming-leg removal policy.
      expect(variant.legs.first.mode, 'train');
    });

    test('moveStop swaps and keeps the gap transport', () {
      final variant = _variant3Stops();
      final modes = [for (final leg in variant.legs) leg.mode];
      final moved = moveStop(variant, 1, 1);
      expect(moved.stops.map((s) => s.ref.name), ['FRA', 'B', 'A']);
      expect([for (final leg in moved.legs) leg.mode], modes);
      expect(moved.legs.length, moved.stops.length - 1);
    });

    test('moving the origin stop swaps and keeps legs', () {
      final variant = _variant3Stops();
      final modes = [for (final leg in variant.legs) leg.mode];
      final moved = moveStop(variant, 0, 1);
      expect(moved.stops.map((s) => s.ref.name), ['A', 'FRA', 'B']);
      expect([for (final leg in moved.legs) leg.mode], modes);
    });

    test('moveStop at the edges is a no-op', () {
      final variant = _variant3Stops();
      final before = [for (final stop in variant.stops) stop.ref.name];
      expect(
          moveStop(variant, 0, -1).stops.map((s) => s.ref.name), before);
      expect(moveStop(variant, 2, 1).stops.map((s) => s.ref.name), before);
    });

    test('addStop inserts a matching leg placeholder', () {
      final variant = addStop(
        _variant3Stops(),
        _ref('C', country: 'China', lat: 30.5, lon: 114.3),
        at: 1,
      );
      expect(
          variant.stops.map((s) => s.ref.name), ['FRA', 'C', 'A', 'B']);
      expect(variant.legs.length, 3);
      // The placeholder covers the new FRA->C gap;
      // C->A inherits the old flight.
      expect(variant.legs.map((leg) => leg.mode),
          ['flight', 'flight', 'train']);
    });

    test('addStop into empty and remove to zero', () {
      var variant = makeVariant('V');
      expect(variant.stops, isEmpty);
      variant = addStop(variant, _ref('A'), at: 0);
      expect(variant.stops.length, 1);
      expect(variant.legs, isEmpty);
      variant = addStop(variant, _ref('B'));
      expect(variant.stops.length, 2);
      expect(variant.legs.length, 1);
      variant = removeStop(variant, 0);
      variant = removeStop(variant, 0);
      expect(variant.stops, isEmpty);
      expect(variant.legs, isEmpty);
      // empty: no crash
      expect(removeStop(variant, 0).stops, isEmpty);
    });

    test('setLegMode invalid becomes other, out of range is a no-op', () {
      final variant = setLegMode(_variant3Stops(), 0, 'hyperloop');
      expect(variant.legs.first.mode, 'other');
      expect(setLegMode(variant, 99, 'flight').legs.length, 2);
      expect(setLegMode(variant, -1, 'flight').legs.length, 2);
    });

    test('a new leg defaults to flight; makeLeg maps unknown to other', () {
      final variant = addStop(_variant3Stops(), _ref('C'));
      expect(variant.legs.last.mode, 'flight');
      expect(variant.legs.last.note, '');
      expect(makeLeg('hyperloop').mode, 'other');
    });
  });

  group('trip / variant management', () {
    test('deleteVariant keeps one and fixes the active variant', () {
      final a = makeVariant('A');
      final b = makeVariant('B');
      var trip = Trip(
        id: 't',
        name: 'Trip',
        activeVariantId: b.id,
        variants: [a, b],
      );
      trip = deleteVariant(trip, b.id);
      expect(trip.variants.length, 1);
      expect(trip.activeVariantId, a.id);
      // deleting the last variant is refused
      expect(deleteVariant(trip, a.id).variants.length, 1);
    });

    test('duplicateVariant gets new ids and a (copy) suffix', () {
      final a = makeVariant(
        'Return via Beijing',
        stops: [
          makeStop(makeRef('custom', 'A', 'CN')),
          makeStop(makeRef('custom', 'B', 'CN')),
        ],
        legs: [makeLeg('train')],
      );
      final trip = Trip(id: 't', name: 'Trip', variants: [a]);
      final duplicate = duplicateVariant(trip, a.id);
      expect(duplicate, isNotNull);
      final clone = duplicate!.variants.last;
      expect(clone.id, isNot(a.id));
      expect(clone.name, 'Return via Beijing (copy)');
      final oldIds = {for (final stop in a.stops) stop.id};
      final newIds = {for (final stop in clone.stops) stop.id};
      expect(oldIds.intersection(newIds), isEmpty);
      expect(clone.stops.length, a.stops.length);
    });

    test('duplicateVariant of an unknown id is a no-op', () {
      final trip =
          Trip(id: 't', name: 'Trip', variants: [makeVariant('A')]);
      expect(duplicateVariant(trip, 'nope'), isNull);
    });

    test('duplicateTrip gets new ids and the (copy) suffix', () {
      final one = makeVariant('One');
      final two = makeVariant('Two');
      final src = Trip(
        id: 'trip-src',
        name: 'China Trip 2027',
        activeVariantId: two.id,
        variants: [one, two],
      );
      final duplicate = duplicateTrip(src);
      expect(duplicate.id, isNot(src.id));
      expect(duplicate.name, 'China Trip 2027 (copy)');
      final oldVariants = {for (final v in src.variants) v.id};
      final newVariants = {for (final v in duplicate.variants) v.id};
      expect(oldVariants.intersection(newVariants), isEmpty);
      // The clone keeps pointing at its cloned
      // active variant.
      expect(newVariants, contains(duplicate.activeVariantId));
      expect(duplicate.activeVariantId, isNot(src.activeVariantId));
    });

    test('renameTrip blank keeps the old name', () {
      var trip = makeTrip('Original');
      expect(renameTrip(trip, '   ').name, 'Original');
      trip = renameTrip(trip, '  New  ');
      expect(trip.name, 'New');
    });

    test('setActiveVariant ignores an unknown id', () {
      final a = makeVariant('A');
      final trip = Trip(
          id: 't', name: 'Trip', activeVariantId: a.id, variants: [a]);
      expect(setActiveVariant(trip, 'nope').activeVariantId, a.id);
    });

    test('makeTrip starts with one blank variant', () {
      final trip = makeTrip('T');
      expect(trip.variants.length, 1);
      expect(trip.activeVariantId, trip.variants.first.id);
      expect(trip.name, 'T');
      expect(trip.id, startsWith('trip-'));
    });

    test('the id shape matches the legacy: prefix-10 hex', () {
      for (final id in [newId('stop'), newId('variant'), newId('trip')]) {
        expect(id, matches(RegExp(r'^[a-z]+-[0-9a-f]{10}$')));
      }
    });
  });

  group('totals', () {
    test('counts modes and dates', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(makeRef('gateway', 'FRA', 'DE'),
              role: 'origin', departureDate: '2027-04-01'),
          makeStop(_ref('A'),
              arrivalDate: '2027-04-02', departureDate: '2027-04-04'),
          makeStop(_ref('B'),
              arrivalDate: '2027-04-04', departureDate: '2027-04-06'),
        ],
        legs: [makeLeg('flight'), makeLeg('flight')],
      );
      final t = totals(variant);
      expect(t.stops, 3);
      expect(t.flights, 2);
      expect(t.trains, 0);
      expect(t.other, 0);
      expect(t.nights, 4);
      expect(t.start, '2027-04-01');
      expect(t.end, '2027-04-06');
    });

    test('nights from a date span when unset', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('A'),
              arrivalDate: '2027-05-01', departureDate: '2027-05-04'),
          makeStop(_ref('B'), arrivalDate: '2027-05-04'),
        ],
        legs: [makeLeg()],
      );
      expect(totals(variant).nights, 3);
      expect(totals(variant).nightsKnown, isTrue);
    });

    test('explicit nights win over the date span', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('A'),
              arrivalDate: '2027-05-01',
              departureDate: '2027-05-04',
              nights: 2),
          makeStop(_ref('B'), nights: 5),
        ],
        legs: [makeLeg()],
      );
      expect(totals(variant).nights, 7);
    });

    test('a single-day span is zero nights', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('X'),
              arrivalDate: '2027-05-01', departureDate: '2027-05-01'),
        ],
      );
      final t = totals(variant);
      expect(t.nights, 0);
      expect(t.nightsKnown, isFalse);
      expect(t.start, '2027-05-01');
      expect(t.end, '2027-05-01');
    });

    test('dates only on later stops (origin has none)', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(makeRef('gateway', 'FRA', 'DE'), role: 'origin'),
          makeStop(_ref('B'),
              arrivalDate: '2027-06-03', departureDate: '2027-06-06'),
        ],
        legs: [makeLeg('flight')],
      );
      final t = totals(variant);
      expect(t.start, '2027-06-03');
      expect(t.end, '2027-06-06');
      expect(t.nights, 3);
    });

    test('a datetime string is not a date', () {
      // The legacy's date.fromisoformat rejects a
      // time component, so the span is skipped.
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('A'),
              arrivalDate: '2027-05-01',
              departureDate: '2027-05-04T10:00'),
        ],
      );
      final t = totals(variant);
      expect(t.nights, 0);
      expect(t.nightsKnown, isFalse);
    });

    test('bus/car/boat/other all count as other', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('A')),
          makeStop(_ref('B')),
          makeStop(_ref('C')),
          makeStop(_ref('D')),
          makeStop(_ref('E')),
        ],
        legs: [
          makeLeg('bus'),
          makeLeg('car'),
          makeLeg('boat'),
          makeLeg('other'),
        ],
      );
      final t = totals(variant);
      expect(t.other, 4);
      expect(t.flights, 0);
      expect(t.trains, 0);
    });
  });

  group('warnings', () {
    test('a leg that arrives before it departs', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('A', lat: 1, lon: 1),
              role: 'origin', departureDate: '2027-05-10'),
          makeStop(_ref('B', lat: 2, lon: 2),
              arrivalDate: '2027-05-09', departureDate: '2027-05-11'),
        ],
        legs: [makeLeg()],
      );
      final warnings = warningsFor(variant);
      expect(warnings.any((w) => w.contains('arrives 2027-05-09')),
          isTrue);
      expect(warnings.any((w) => w.contains('A')), isTrue);
    });

    test('cover the common problems', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('NoCoords'),
              arrivalDate: '2027-05-05',
              departureDate: '2027-05-01'), // dep < arr
          makeStop(_ref('OnlyDep', country: 'Y', lat: 1, lon: 1),
              departureDate: '2027-05-02'),
          makeStop(makeRef('gateway', 'Start', 'DE', 50, 8),
              role: 'origin', departureDate: '2027-05-02'),
        ],
      );
      final warnings = warningsFor(variant);
      expect(
          warnings.any(
              (w) => w.contains('NoCoords') && w.contains('coordinates')),
          isTrue);
      expect(
          warnings.any((w) =>
              w.contains('NoCoords') &&
              w.contains('departure before arrival')),
          isTrue);
      expect(warnings.any((w) => w.contains('OnlyDep')), isTrue);
      // An origin with only a departure date is
      // normal — no warning.
      expect(warnings.any((w) => w.contains('Start')), isFalse);
    });

    test('garbage dates and negative nights', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(_ref('X'),
              arrivalDate: 'not-a-date',
              departureDate: 'also-bad',
              nights: -2),
        ],
      );
      final warnings = warningsFor(variant);
      expect(warnings.any((w) => w.contains('invalid date')), isTrue);
      expect(warnings.any((w) => w.contains('negative nights')), isTrue);
    });

    test('an empty variant says so, a single stop notes it', () {
      expect(warningsFor(makeVariant('V')),
          ['No stops yet — add your first destination.']);
      final single =
          makeVariant('V', stops: [makeStop(_ref('A', lat: 1, lon: 1))]);
      expect(warningsFor(single).length, 1);
      expect(warningsFor(single).first, contains('Single stop'));
    });

    test('a consistent route has no warnings', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(makeRef('gateway', 'FRA', 'DE', 50.11, 8.68),
              role: 'origin', departureDate: '2027-04-01'),
          makeStop(_ref('A', lat: 40, lon: 116),
              arrivalDate: '2027-04-02', departureDate: '2027-04-05'),
          makeStop(_ref('B', lat: 31, lon: 121),
              arrivalDate: '2027-04-05', departureDate: '2027-04-08'),
        ],
        legs: [makeLeg('flight'), makeLeg('flight')],
      );
      expect(warningsFor(variant), isEmpty);
    });

    test('more than twelve months selected', () {
      // A variant without stops returns the
      // "no stops" warning before the months
      // check -- the legacy's early return.
      final variant = makeVariant('V',
          stops: [makeStop(_ref('A'))],
          months: [...months, months.first]);
      expect(
          warningsFor(variant).any((w) => w.contains('More than 12')), isTrue);
    });

    test('routeSummary matches the legacy wording', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(makeRef('gateway', 'FRA', 'DE', 50, 8),
              role: 'origin', departureDate: '2027-04-01'),
          makeStop(_ref('A', lat: 40, lon: 116),
              arrivalDate: '2027-04-02',
              departureDate: '2027-04-05',
              nights: 3),
          makeStop(_ref('B', lat: 31, lon: 121),
              arrivalDate: '2027-04-05',
              departureDate: '2027-04-07',
              nights: 2),
        ],
        legs: [makeLeg('flight'), makeLeg('flight')],
      );
      final summary = routeSummary(variant);
      expect(summary, contains('3 stops'));
      expect(summary, contains('5 nights'));
      expect(summary, contains('2 flights'));
      // The legacy appends the date span when any date is set.
      expect(summary, contains('2027-04-01 → 2027-04-07'));
    });
  });

  group('suggested months', () {
    /// A workbook-shaped catalogue: the month
    /// columns the destination model exposes
    /// through its tail.
    Destination destination(String name, Map<String, String> byMonth) =>
        Destination(
          core: {'destination': name},
          columns: [
            ('Destination', name),
            for (final month in months) (month, byMonth[month] ?? ''),
          ],
        );

    final kyoto = destination('Kyoto', {
      'April': 'ideal',
      'May': 'good',
      'June': 'hot',
      'September': 'good',
      'October': 'ideal',
    });

    final xiAn = destination("Xi'an (Shaanxi)", {
      'April': 'ideal',
      'May': 'good',
      'September': 'good',
      'October': 'ideal',
    });

    final nowhere = destination('Nowhere', {});

    final reykjavik = destination('Reykjavik', {
      'June': 'ideal',
      'July': 'good',
    });

    test('uses the workbook shape', () {
      final variant = makeVariant(
        'V',
        stops: [
          makeStop(makeRef('destination', 'Kyoto', 'JP')),
          makeStop(makeRef('destination', 'Nowhere', 'X')),
          makeStop(makeRef('gateway', 'FRA', 'DE')),
        ],
      );
      final out = suggestedMonths(variant, [kyoto, nowhere]);
      expect(out['Kyoto'], ['April', 'May', 'September', 'October']);
      // An unknown destination has no entry.
      expect(out.containsKey('Nowhere'), isFalse);
      // Only destination-kind stops count.
      expect(out.containsKey('FRA'), isFalse);
    });

    test('matches normalised (province-suffixed) names', () {
      final variant = makeVariant(
        'V',
        stops: [makeStop(makeRef('destination', "Xi'an", 'CN'))],
      );
      final out = suggestedMonths(variant, [xiAn]);
      expect(out["Xi'an"], ['April', 'May', 'September', 'October']);
    });

    test('tripWideSuggestion intersects, in calendar order', () {
      final both = suggestedMonths(
        makeVariant(
          'V',
          stops: [
            makeStop(makeRef('destination', 'Kyoto', 'JP')),
            makeStop(makeRef('destination', "Xi'an", 'CN')),
          ],
        ),
        [kyoto, xiAn],
      );
      expect(tripWideSuggestion(both),
          ['April', 'May', 'September', 'October']);
      // A stop the workbook has no opinion about is simply not
      // part of the intersection -- the legacy only intersects
      // the stops `suggested_months` returned an entry for.
      final withUnknown = suggestedMonths(
        makeVariant(
          'V',
          stops: [
            makeStop(makeRef('destination', 'Kyoto', 'JP')),
            makeStop(makeRef('destination', 'Nowhere', 'X')),
          ],
        ),
        [kyoto, nowhere],
      );
      expect(tripWideSuggestion(withUnknown),
          ['April', 'May', 'September', 'October']);
      // Disjoint suggestions have nothing in common.
      final disjoint = suggestedMonths(
        makeVariant(
          'V',
          stops: [
            makeStop(makeRef('destination', 'Kyoto', 'JP')),
            makeStop(makeRef('destination', 'Reykjavik', 'IS')),
          ],
        ),
        [kyoto, reykjavik],
      );
      expect(tripWideSuggestion(disjoint), isEmpty);
    });

    test('a stop that is not in the catalogue adds nothing', () {
      final variant = makeVariant(
        'V',
        stops: [makeStop(makeRef('destination', 'Atlantis', 'X'))],
      );
      expect(suggestedMonths(variant, [kyoto]), isEmpty);
    });

    test('a non-good month value never counts', () {
      final hot = destination('Hot', {'June': 'hot', 'July': 'warm'});
      final variant = makeVariant(
        'V',
        stops: [makeStop(makeRef('destination', 'Hot', 'X'))],
      );
      expect(suggestedMonths(variant, [hot]).containsKey('Hot'), isFalse);
    });
  });

  group('export', () {
    test('is valid JSON with the storage shape', () {
      final trip = makeTrip('China Trip 2027');
      final decoded = exportTrip(trip);
      expect(decoded, contains('"name": "China Trip 2027"'));
      expect(decoded, contains('"variants"'));
      expect(decoded, contains('"active_variant_id"'));
    });

    test('the all-trips backup is the store shape', () {
      // The trips.json snapshot: schema version
      // plus every trip, the shape
      // storage.normalize_all produces.
      final json = exportTrips([
        makeTrip('China Trip 2027'),
        makeTrip('Second trip'),
      ]);
      expect(json, contains('"schema_version": 1'));
      expect(json, contains('"name": "China Trip 2027"'));
      expect(json, contains('"name": "Second trip"'));
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['schema_version'], 1);
      expect((decoded['trips'] as List).length, 2);
    });

    test('the backup of no trips is an empty store', () {
      final json = exportTrips(const []);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['schema_version'], 1);
      expect(decoded['trips'], <dynamic>[]);
    });
  });

  group('variant meta editing', () {
    test('updateMeta replaces the four fields and keeps the stops', () {
      final variant = addStop(_variant3Stops(), _ref('C'));
      final updated = updateMeta(
        variant,
        notes: 'n',
        rating: 7,
        months: ['July', 'August'],
        comment: 'c',
      );
      expect(updated.notes, 'n');
      expect(updated.rating, 7);
      expect(updated.months, ['July', 'August']);
      expect(updated.comment, 'c');
      expect(updated.stops.length, variant.stops.length);
      expect(updated.id, variant.id);
    });

    test('updateStop replaces one stop, keeping ids', () {
      final variant = _variant3Stops();
      const index = 1;
      final updated =
          updateStop(variant, index, variant.stops[index]);
      expect(updated.stops.length, variant.stops.length);
      expect(updated.stops[index].id, variant.stops[index].id);
      // An out-of-range index leaves the variant
      // untouched.
      expect(
          updateStop(variant, 99, variant.stops[index]).stops.length,
          variant.stops.length);
    });

    test('renameVariant blank keeps the old name', () {
      final variant = makeVariant('Summer');
      expect(renameVariant(variant, '  ').name, 'Summer');
      expect(renameVariant(variant, ' Fall ').name, 'Fall');
    });
  });
}
