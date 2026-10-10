import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/trip.dart';

Map<String, Object?> kyotoRow() => {
      'destination': 'Kyoto',
      'continent': 'Asia',
      'country': 'Japan',
      'visited': 0,
      'favourite': 1,
      'to_be_researched': 0,
      'prio': '2',
      'safety_rating': 8.5,
      'avg_cost_day': 120,
      'flight_time_fra': 14.2,
      'malaria_risk': 'no — no local transmission',
      'data_status': null,
      'comment': 'Temples',
      'data': jsonEncode([
        ['Destination', 'Kyoto'],
        ['Prio Thorsten', '2'],
        ['Malaria risk?', 'no — no local transmission'],
        ['Comment', 'Temples'],
        ['Reviews', 4.5],
      ]),
    };

void main() {
  group('Destination', () {
    test('fromRow keeps the raw core and the tail lossless', () {
      final dest = Destination.fromRow(kyotoRow());
      expect(dest.name, 'Kyoto');
      expect(dest.continent, 'Asia');
      expect(dest.country, 'Japan');
      expect(dest.visited, isFalse);
      expect(dest.favourite, isTrue);
      expect(dest.toBeResearched, isFalse);
      expect(dest.prio, '2');
      expect(dest.prioInt, 2);
      expect(dest.safetyRating, 8.5);
      expect(dest.avgCostDay, 120.0);
      expect(dest.flightTimeFra, 14.2);
      expect(dest.malariaRisk, isFalse);
      expect(dest.comment, 'Temples');
      expect(dest.column('Reviews'), 4.5);
      expect(
        [for (final (name, _) in dest.columns) name],
        ['Destination', 'Prio Thorsten', 'Malaria risk?', 'Comment', 'Reviews'],
      );
    });

    test('a broken data tail degrades to no columns, not a crash', () {
      final dest = Destination.fromRow({...kyotoRow(), 'data': '{not json'});
      expect(dest.columns, isEmpty);
      expect(dest.name, 'Kyoto');
    });

    test('a text prio survives a flag edit', () {
      // 'Prio Thorsten' holds strings like 'n/a' next to ints;
      // a read-modify-write must never parse it away. The row
      // is consistent here: core and tail both say 'n/a', the
      // shape getDestination actually returns.
      final dest = Destination.fromRow({
        ...kyotoRow(),
        'prio': 'n/a',
        'data': jsonEncode([
          ['Destination', 'Kyoto'],
          ['Prio Thorsten', 'n/a'],
          ['Malaria risk?', 'no — no local transmission'],
          ['Comment', 'Temples'],
          ['Reviews', 4.5],
        ]),
      });
      final edited = dest.withField('favourite', false);
      expect(edited.prio, 'n/a');
      expect(edited.prioInt, isNull);
      expect(edited.column('Prio Thorsten'), 'n/a');
      expect(edited.column('In näherer Auswahl 2025?'), false);
      expect(edited.favourite, isFalse);
    });

    test('withField replaces the matching tail entry', () {
      final dest = Destination.fromRow(kyotoRow());
      final edited = dest.withField('comment', 'New comment');
      expect(edited.comment, 'New comment');
      expect(edited.column('Comment'), 'New comment');
      // Everything else stays put, tail order included.
      expect(
        [for (final (name, _) in edited.columns) name],
        ['Destination', 'Prio Thorsten', 'Malaria risk?', 'Comment', 'Reviews'],
      );
    });

    test('withField appends a missing tail entry '
        '(repository._set_field)', () {
      const dest = Destination(core: {'destination': 'Kyoto'});
      final edited = dest.withField('comment', 'hello');
      expect(edited.columns.single, ('Comment', 'hello'));
    });

    test('withField ignores an unknown field', () {
      final dest = Destination.fromRow(kyotoRow());
      expect(dest.withField('not_a_field', 1), same(dest));
    });

    test('truthy mirrors the app convention', () {
      expect(Destination.truthy(true), isTrue);
      expect(Destination.truthy(1), isTrue);
      expect(Destination.truthy('x'), isTrue);
      expect(Destination.truthy('X'), isTrue);
      expect(Destination.truthy('yes'), isTrue);
      expect(Destination.truthy('ja'), isTrue);
      expect(Destination.truthy('true'), isTrue);
      // Free text like the malaria column never counts as yes
      // unless it contains an x.
      expect(Destination.truthy('no — no local transmission'), isFalse);
      expect(Destination.truthy('near zero'), isFalse);
      expect(Destination.truthy(0), isFalse);
      expect(Destination.truthy(null), isFalse);
    });

    test('text() blanks to null and stringifies numbers', () {
      expect(Destination.text(null), isNull);
      expect(Destination.text(''), isNull);
      expect(Destination.text('Kyoto'), 'Kyoto');
      expect(Destination.text(120), '120');
    });
  });

  group('Trip models', () {
    test('activeVariant prefers the active id, falls back to the first',
        () {
      const variantA = Variant(id: 'v-a', name: 'A');
      const variantB = Variant(id: 'v-b', name: 'B');
      expect(
        const Trip(id: 't', name: 'Trip', activeVariantId: 'v-b', variants: [
          variantA,
          variantB
        ]).activeVariant?.name,
        'B',
      );
      expect(
        const Trip(id: 't', name: 'Trip', activeVariantId: 'missing', variants: [
          variantA,
          variantB
        ]).activeVariant?.name,
        'A',
      );
      expect(const Trip(id: 't', name: 'Trip').activeVariant, isNull);
    });

    test('Variant.fromRow decodes months and survives broken JSON', () {
      final variant = Variant.fromRow(
        {
          'id': 'v-1',
          'trip_id': 't-1',
          'name': 'Summer',
          'notes': 'short trip',
          'rating': 4,
          'months': '["July","August"]',
          'comment': '',
        },
        stops: const [],
        legs: const [],
      );
      expect(variant.months, ['July', 'August']);
      expect(variant.rating, 4);

      final broken = Variant.fromRow(
        {'id': 'v-2', 'name': 'Broken', 'months': '{not json'},
        stops: const [],
        legs: const [],
      );
      expect(broken.months, isEmpty);
    });
  });
}
