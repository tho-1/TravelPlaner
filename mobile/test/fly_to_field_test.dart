/// The map's fly-to search.
///
/// The report (2026-10-28): searching Okinawa, opening it,
/// going back and tapping the same suggestion again did
/// nothing -- and retyping the query did not help. The cause
/// was Flutter's `Autocomplete`: it keeps the last pick as
/// its own selection and ignores a pick that equals it. The
/// search is a *command*, so every pick must fire.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/ui/fly_to_field.dart';

void main() {
  late List<String> picked;

  Future<void> pumpField(WidgetTester tester) async {
    picked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: FlyToField(
            cities: const ['Okinawa', 'Osaka'],
            countries: const ['Japan'],
            onPick: picked.add,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Type [query] and wait for the suggestions.
  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> tapSuggestion(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(ListTile, label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('typing shows the matching city and country', (tester) async {
    await pumpField(tester);

    await type(tester, 'ok');
    expect(find.widgetWithText(ListTile, 'Okinawa'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Japan'), findsNothing,
        reason: 'Japan does not contain "ok"');

    await type(tester, 'jap');
    expect(find.widgetWithText(ListTile, 'Japan'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Okinawa'), findsNothing);
  });

  testWidgets('an empty query offers nothing', (tester) async {
    await pumpField(tester);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a query with no match offers nothing', (tester) async {
    await pumpField(tester);
    await type(tester, 'Reykjavik');
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('picking a city reports it', (tester) async {
    await pumpField(tester);
    await type(tester, 'Okinawa');
    await tapSuggestion(tester, 'Okinawa');

    expect(picked, ['Okinawa']);
  });

  testWidgets('picking the same city twice reports it twice', (tester) async {
    // The regression: a command, not a value. Flutter's own
    // Autocomplete ignored the second pick.
    await pumpField(tester);
    await type(tester, 'Okinawa');
    await tapSuggestion(tester, 'Okinawa');
    expect(picked, ['Okinawa']);

    // The query is still there (the reader can see what was
    // searched), and asking again works.
    await type(tester, 'Okinawa');
    await tapSuggestion(tester, 'Okinawa');
    expect(picked, ['Okinawa', 'Okinawa'],
        reason: 'the second pick must open the city again');
  });

  testWidgets('picking a country reports it', (tester) async {
    await pumpField(tester);
    await type(tester, 'Japan');
    await tapSuggestion(tester, 'Japan');

    expect(picked, ['Japan']);
  });

  testWidgets('a pick closes the list but keeps the query', (tester) async {
    await pumpField(tester);
    await type(tester, 'Okinawa');
    await tapSuggestion(tester, 'Okinawa');

    expect(find.byType(ListTile), findsNothing,
        reason: 'the list closes so the map is visible');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Okinawa',
      reason: 'the query stays, so the reader can search it again',
    );
  });

  testWidgets('focusing the field again brings the suggestions back',
      (tester) async {
    await pumpField(tester);
    await type(tester, 'Okinawa');
    await tapSuggestion(tester, 'Okinawa');
    expect(find.byType(ListTile), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.widgetWithText(ListTile, 'Okinawa'), findsOneWidget);
  });

  testWidgets('the clear button empties the query and the list',
      (tester) async {
    await pumpField(tester);
    await type(tester, 'Okinawa');
    expect(find.byIcon(Icons.clear), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byIcon(Icons.clear), findsNothing,
        reason: 'nothing to clear in an empty field');
  });

  testWidgets('pressing search picks the exact match', (tester) async {
    await pumpField(tester);
    await type(tester, 'Okinawa');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(picked, ['Okinawa']);
  });

  testWidgets('a city wins over a country of the same name', (tester) async {
    // 'Singapore' is both; opening the destination is what
    // the reader wants.
    picked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: FlyToField(
            cities: const ['Singapore'],
            countries: const ['Singapore'],
            onPick: picked.add,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await type(tester, 'Singapore');

    // The name is offered once (a city and a country of the
    // same name are one suggestion), and the page decides
    // that the city wins.
    expect(find.widgetWithText(ListTile, 'Singapore'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Singapore').first);
    await tester.pump();
    expect(picked, ['Singapore']);
  });
}
