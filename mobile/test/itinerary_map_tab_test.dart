/// The itinerary editor's Map tab: the route, the mode
/// chips, the gateway switch and the focus-country picker.
///
/// The map tab is where a trip's shape is checked by eye, so
/// a silent failure here hides a broken itinerary. The tests
/// below pin the parts that can break without an obvious
/// crash: the empty state, the caption's totals, the mode
/// chips (a mode that silently disappears from the route is
/// the bug the legacy's multiselect had), and the
/// focus-country picker.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/trip.dart';
import 'package:travel_planner/ui/itinerary_map_tab.dart';

Variant _variant({
  String id = 'v-1',
  List<Stop>? stops,
  List<Leg>? legs,
}) =>
    Variant(
      id: id,
      name: 'Spring',
      months: const ['April'],
      stops: stops ??
          const [
            Stop(
              id: 's-1',
              ref: StopRef(
                kind: 'stop',
                name: 'Frankfurt',
                country: 'Germany',
                lat: 50.11,
                lon: 8.68,
              ),
            ),
            Stop(
              id: 's-2',
              ref: StopRef(
                kind: 'stop',
                name: 'Kyoto',
                country: 'Japan',
                lat: 35.01,
                lon: 135.77,
              ),
            ),
          ],
      legs: legs ??
          const [
            Leg(mode: 'flight', note: 'FRA-KIX'),
            Leg(mode: 'train', note: 'Kyoto-Osaka'),
          ],
    );

void main() {
  testWidgets('no variant says what to do', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ItineraryMapTab()),
    ));
    await tester.pumpAndSettle();

    expect(
      find.text('Add stops in the Plan tab to see the route map.'),
      findsOneWidget,
    );
  });

  testWidgets('a variant without stops says the same', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ItineraryMapTab(variant: _variant(stops: const []))),
    ));
    await tester.pumpAndSettle();

    expect(
      find.text('Add stops in the Plan tab to see the route map.'),
      findsOneWidget,
    );
  });

  testWidgets('the route is drawn with the mode chips and the caption',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ItineraryMapTab(variant: _variant())),
    ));
    await tester.pumpAndSettle();

    // One chip per transport mode the variant uses.
    expect(find.text('Show transport modes'), findsOneWidget);
    expect(find.byType(FilterChip), findsNWidgets(2));
    expect(find.text('✈ Flight'), findsOneWidget);
    expect(find.text('🚆 Train'), findsOneWidget);

    // The caption's totals.
    expect(find.textContaining('stops'), findsOneWidget);
    expect(find.textContaining('2 stops'), findsOneWidget);
  });

  testWidgets('a mode chip can be switched off and on again',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ItineraryMapTab(variant: _variant())),
    ));
    await tester.pumpAndSettle();

    final flight = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, '✈ Flight'),
    );
    expect(flight.selected, isTrue, reason: 'every mode starts visible');

    await tester.tap(find.widgetWithText(FilterChip, '✈ Flight'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '✈ Flight'))
          .selected,
      isFalse,
    );

    await tester.tap(find.widgetWithText(FilterChip, '✈ Flight'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '✈ Flight'))
          .selected,
      isTrue,
    );
  });

  testWidgets('the focus-country picker offers the route\'s countries',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ItineraryMapTab(variant: _variant())),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Focus country'), findsOneWidget);
    await tester.tap(find.text('Focus country'));
    await tester.pumpAndSettle();

    expect(find.text('(whole route)'), findsWidgets);
    expect(find.text('Germany'), findsOneWidget);
    expect(find.text('Japan'), findsOneWidget);
  });

  testWidgets('the gateway switch is on by default and can be turned off',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ItineraryMapTab(variant: _variant())),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Show gateways'), findsOneWidget);
    final gateway = tester.widget<Switch>(find.byType(Switch));
    expect(gateway.value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });
}
