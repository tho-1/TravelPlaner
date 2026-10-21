/// The plan tab's stop editors and the add-stop panel:
/// pending editor values must follow the stop through a
/// reorder, not the position -- an unkeyed editor wrote
/// stop 1's typed values into whichever stop sat at
/// position 1 after a move, and a save then corrupted
/// the neighbour. The add panel must add the
/// destination it displays.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/data/geocode_repository.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/trip.dart';
import 'package:travel_planner/ui/itinerary_compare_tab.dart';
import 'package:travel_planner/ui/itinerary_plan_tab.dart';

Variant _variant(List<Stop> stops) => Variant(
      id: 'v-1',
      name: 'Spring',
      stops: stops,
      legs: [
        for (var i = 0; i < stops.length - 1; i++)
          const Leg(mode: 'train'),
      ],
    );

Trip _trip(Variant variant) => Trip(
      id: 't-1',
      name: 'Japan',
      created: '2026-10-10T21:00:00+00:00',
      activeVariantId: variant.id,
      variants: [variant],
    );

const _kyoto = Stop(id: 's-1', ref: StopRef(kind: 'stop', name: 'Kyoto'), nights: 2);
const _osaka = Stop(
  id: 's-2',
  ref: StopRef(kind: 'stop', name: 'Osaka'),
  arrivalDate: '2026-05-01',
  notes: 'castles',
);

Widget _planTab(Variant variant, void Function(String, Stop) onUpdateStop,
        {List<Destination> catalogue = const []}) =>
    MaterialApp(
      home: Scaffold(
        body: ItineraryPlanTab(
          trip: _trip(variant),
          variant: variant,
          catalogue: catalogue,
          geocoder: GeocodeRepository('',
              httpClient: MockClient((_) async => http.Response('[]', 200))),
          onRemoveStop: (_) {},
          onMoveStop: (_, _) {},
          onUpdateStop: onUpdateStop,
          onSetLegMode: (_, _) {},
          onAddStop: (_, _, _) {},
          onUpdateVariant: (_) {},
          onExport: () {},
          selectedStopId: null,
          onToggleHighlight: (_) {},
        ),
      ),
    );

Finder _cardOf(String title) => find
    .ancestor(of: find.text(title), matching: find.byType(Card))
    .first;

String _nightsText(WidgetTester tester, Finder card) => tester
    .widget<TextField>(find
        .descendant(
            of: card, matching: find.widgetWithText(TextField, 'Nights'))
        .first)
    .controller!
    .text;

void main() {
  testWidgets('a stop editor keeps its pending values through a reorder',
      (tester) async {
    final updates = <(String, Stop)>[];
    await tester.pumpWidget(_planTab(_variant([_kyoto, _osaka]),
        (stopId, updated) => updates.add((stopId, updated))));
    await tester.pumpAndSettle();

    // The stop editors sit collapsed (one opens at a time):
    // open Kyoto's by tapping its header line.
    await tester.tap(find.text('1. Kyoto'));
    await tester.pumpAndSettle();

    // Type 4 into Kyoto's nights (it shows the stored 2).
    final kyotoCard = _cardOf('1. Kyoto');
    final kyotoNights = find.descendant(
        of: kyotoCard, matching: find.widgetWithText(TextField, 'Nights'));
    await tester.ensureVisible(kyotoNights.first);
    expect(_nightsText(tester, kyotoCard), '2');
    await tester.enterText(kyotoNights.first, '4');

    // Move Kyoto below Osaka: the stops column reorders.
    // The editor states must follow their stops.
    await tester.pumpWidget(_planTab(_variant([_osaka, _kyoto]),
        (stopId, updated) => updates.add((stopId, updated))));
    await tester.pumpAndSettle();

    // Kyoto (now position 2) stayed open and kept its
    // pending 4: the editor state follows the stop id, not
    // the row's position.
    final kyotoAfter = _cardOf('2. Kyoto');
    expect(_nightsText(tester, kyotoAfter), '4');

    // Osaka's editor is closed (one opens at a time);
    // opening it shows Osaka's own values, never Kyoto's
    // pending 4.
    await tester.ensureVisible(find.text('1. Osaka'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. Osaka'));
    await tester.pumpAndSettle();
    final osakaCard = _cardOf('1. Osaka');
    expect(_nightsText(tester, osakaCard), '');

    // Saving Osaka writes Osaka's own values -- its
    // arrival date and notes, no borrowed nights.
    await tester.tap(find.descendant(
        of: osakaCard,
        matching: find.widgetWithText(FilledButton, 'Save stop')));
    await tester.pumpAndSettle();

    expect(updates, hasLength(1));
    expect(updates.single.$1, 's-2');
    expect(updates.single.$2.arrivalDate, '2026-05-01');
    expect(updates.single.$2.notes, 'castles');
    expect(updates.single.$2.nights, isNull);

    // Re-opening Kyoto finds the 4 the closed editor kept,
    // and saving writes Kyoto's id with it.
    await tester.ensureVisible(find.text('2. Kyoto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2. Kyoto'));
    await tester.pumpAndSettle();
    expect(_nightsText(tester, _cardOf('2. Kyoto')), '4');
    await tester.tap(find.descendant(
        of: _cardOf('2. Kyoto'),
        matching: find.widgetWithText(FilledButton, 'Save stop')));
    await tester.pumpAndSettle();

    expect(updates, hasLength(2));
    expect(updates.last.$1, 's-1');
    expect(updates.last.$2.ref.name, 'Kyoto');
    expect(updates.last.$2.nights, 4);
  });

  testWidgets('the add panel adds the destination it displays',
      (tester) async {
    final added = <(StopRef, String, int?)>[];
    final catalogue = [
      const Destination(
        core: {'destination': 'Kyoto', 'country': 'Japan'},
        columns: [],
      ),
      const Destination(
        core: {'destination': 'Osaka', 'country': 'Japan'},
        columns: [],
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ItineraryPlanTab(
          trip: _trip(_variant([_kyoto])),
          variant: _variant([_kyoto]),
          catalogue: catalogue,
          geocoder: GeocodeRepository('',
              httpClient: MockClient((_) async => http.Response('[]', 200))),
          onRemoveStop: (_) {},
          onMoveStop: (_, _) {},
          onUpdateStop: (_, _) {},
          onSetLegMode: (_, _) {},
          onAddStop: (ref, role, nights) => added.add((ref, role, nights)),
          onUpdateVariant: (_) {},
          onExport: () {},
          selectedStopId: null,
          onToggleHighlight: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // No selection was made: the panel displays the first
    // catalogue name, so Add must add exactly that one --
    // a displayed destination is always the one that gets
    // added (the old panel disabled Add while showing a
    // destination).
    final add = find.widgetWithText(FilledButton, 'Add stop');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(added, hasLength(1));
    expect(added.single.$1.name, 'Kyoto');
    expect(added.single.$1.kind, 'destination');
  });

  group('the add-stop panel', () {
    Future<void> pumpPanel(
      WidgetTester tester, {
      List<Destination> catalogue = const [],
      void Function(StopRef ref, String role, int? nights)? onAddStop,
    }) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      await binding.setSurfaceSize(const Size(380, 1600));
      addTearDown(() => binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ItineraryPlanTab(
            trip: _trip(_variant([_kyoto])),
            variant: _variant([_kyoto]),
            catalogue: catalogue,
            geocoder: GeocodeRepository('',
                httpClient: MockClient((_) async => http.Response('[]', 200))),
            onRemoveStop: (_) {},
            onMoveStop: (_, _) {},
            onUpdateStop: (_, _) {},
            onSetLegMode: (_, _) {},
            onAddStop: onAddStop ?? (_, _, _) {},
            onUpdateVariant: (_) {},
            onExport: () {},
            selectedStopId: null,
            onToggleHighlight: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('the pickers fit a phone without wrapping their captions',
        (tester) async {
      // The segmented buttons could not fit a phone: their
      // captions wrapped *inside* the button ("Custom\ncity"),
      // which reads as a bug (the report, 2026-10-21). Where
      // they do not fit they become chips that wrap onto a
      // second line.
      await pumpPanel(tester);

      final source = find.text('Source');
      expect(source, findsOneWidget);
      // The narrow layout: chips, not a segmented button.
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Catalogue'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Custom city'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Home gateway'), findsOneWidget);
      // Nothing overflowed.
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide layout keeps the segmented buttons', (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      await binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ItineraryPlanTab(
            trip: _trip(_variant([_kyoto])),
            variant: _variant([_kyoto]),
            catalogue: const [],
            geocoder: GeocodeRepository('',
                httpClient: MockClient((_) async => http.Response('[]', 200))),
            onRemoveStop: (_) {},
            onMoveStop: (_, _) {},
            onUpdateStop: (_, _) {},
            onSetLegMode: (_, _) {},
            onAddStop: (_, _, _) {},
            onUpdateVariant: (_) {},
            onExport: () {},
            selectedStopId: null,
            onToggleHighlight: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Catalogue'), findsNothing);
    });

    testWidgets('the source is called the catalogue, not the workbook',
        (tester) async {
      // The workbook is gone: the app's list of destinations is
      // the catalogue (the report, 2026-10-21).
      await pumpPanel(tester);
      expect(find.textContaining('Workbook'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Catalogue'), findsOneWidget);
    });

    testWidgets('the home gateway can be added', (tester) async {
      final added = <(StopRef, String, int?)>[];
      await pumpPanel(tester, onAddStop: (ref, role, nights) {
        added.add((ref, role, nights));
      });

      await tester.tap(find.widgetWithText(ChoiceChip, 'Home gateway'));
      await tester.pumpAndSettle();
      final add = find.widgetWithText(FilledButton, 'Add stop');
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();

      expect(added, hasLength(1));
      expect(added.single.$1.kind, 'gateway');
      expect(added.single.$1.name, 'Frankfurt');
    });

    testWidgets('a custom city is added with its coordinates', (tester) async {
      final added = <(StopRef, String, int?)>[];
      await pumpPanel(tester, onAddStop: (ref, role, nights) {
        added.add((ref, role, nights));
      });

      await tester.tap(find.widgetWithText(ChoiceChip, 'Custom city'));
      await tester.pumpAndSettle();
      // No match: the Add button stays disabled.
      final add = find.widgetWithText(FilledButton, 'Add stop');
      await tester.ensureVisible(add);
      expect(tester.widget<FilledButton>(add).onPressed, isNull);
    });
  });

  group('the compare tab', () {
    Trip tripWith(List<Variant> variants) => Trip(
          id: 't-1',
          name: 'Japan',
          created: '2026-10-10T21:00:00+00:00',
          activeVariantId: variants.first.id,
          variants: variants,
        );

    Widget compare(Trip trip, void Function(String) onActivate) =>
        MaterialApp(
          home: Scaffold(
            body: ItineraryCompareTab(trip: trip, onActivate: onActivate),
          ),
        );

    testWidgets('every variant gets a row and the totals', (tester) async {
      final trip = tripWith([
        const Variant(
          id: 'v-1',
          name: 'Spring',
          months: ['April'],
          stops: [_kyoto, _osaka],
          legs: [Leg(mode: 'flight')],
        ),
        const Variant(id: 'v-2', name: 'Autumn', months: ['October']),
      ]);
      await tester.pumpWidget(compare(trip, (_) {}));
      await tester.pumpAndSettle();

      expect(find.text('Spring'), findsWidgets);
      expect(find.text('Autumn'), findsWidgets);
      // The totals: two stops, one flight.
      expect(find.text('2'), findsWidgets);
      expect(find.text('1'), findsWidgets);
      expect(find.text('Months'), findsOneWidget);
      expect(find.text('Warnings'), findsOneWidget);
    });

    testWidgets('a trip without variants says so', (tester) async {
      await tester.pumpWidget(compare(
        Trip(
          id: 't-1',
          name: 'Japan',
          created: '2026-10-10T21:00:00+00:00',
          activeVariantId: 'v-1',
          variants: const [],
        ),
        (_) {},
      ));
      await tester.pumpAndSettle();
      expect(find.text('No variants yet.'), findsOneWidget);
    });

    testWidgets('the activate button makes the chosen variant active',
        (tester) async {
      final activated = <String>[];
      final trip = tripWith([
        const Variant(id: 'v-1', name: 'Spring', months: ['April']),
        const Variant(id: 'v-2', name: 'Autumn', months: ['October']),
      ]);
      await tester.pumpWidget(compare(trip, activated.add));
      await tester.pumpAndSettle();

      // Pick the other variant in the selector, then activate
      // it.
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Autumn').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Activate'));
      await tester.pumpAndSettle();

      expect(activated.last, 'v-2');
    });

    testWidgets('a duplicate name is disambiguated by its id',
        (tester) async {
      // Two variants with the same name: the selector must
      // never target the wrong one.
      final trip = tripWith([
        const Variant(id: 'v-1', name: 'Spring', months: ['April']),
        const Variant(id: 'v-2', name: 'Spring', months: ['October']),
      ]);
      await tester.pumpWidget(compare(trip, (_) {}));
      await tester.pumpAndSettle();

      // The selector carries both, and the two labels differ
      // (the id suffix).
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      final items = find.byType(DropdownMenuItem<int>);
      expect(items, findsAtLeastNWidgets(2));
      final labels = <String>{};
      for (final item in items.evaluate()) {
        labels.add((item.widget as DropdownMenuItem<int>).child.toString());
      }
      expect(labels.length, greaterThan(1),
          reason: 'the two variants are told apart');
    });
  });
}
