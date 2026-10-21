/// The catalogue: the shared filter sheet applies live,
/// the quick chips stack on top of it, and the count
/// caption reports the missing-value counts.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';
import 'package:travel_planner/ui/catalogue_page.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
  url: 'https://travel-tz123.aws-eu-north-1.turso.io',
  token: 'token',
);

void main() {
  testWidgets('the filter sheet applies and the caption counts',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    // Two destinations: one visited, one fresh. Neither
    // carries a safety rating, so the safety filter must
    // not hide either of them.
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['Alexandria', 'Egypt', 1, jsonEncode(const [])],
            ['Rome', 'Italy', null, jsonEncode(const [])],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();

    // The legacy default (only-unvisited) hides the
    // visited destination.
    expect(find.textContaining('1 of 2 destinations'), findsOneWidget);
    expect(find.text('Rome'), findsOneWidget);
    expect(find.text('Alexandria'), findsNothing);

    // The sheet opens; turning only-unvisited off shows
    // both destinations.
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    expect(find.text('Only show unvisited'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Only show unvisited'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 of 2 destinations'), findsOneWidget);
    expect(find.text('Alexandria'), findsOneWidget);

    // The quick chips stack on top of the shared set.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Visited'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 of 2 destinations'), findsOneWidget);
    expect(find.text('Alexandria'), findsOneWidget);
    expect(find.text('Rome'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Visited view wins over the default only-unvisited filter',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['Alexandria', 'Egypt', 1, jsonEncode(const [])],
            ['Rome', 'Italy', null, jsonEncode(const [])],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();

    // The legacy default hides the visited row...
    expect(find.textContaining('1 of 2 destinations'), findsOneWidget);
    expect(find.text('Alexandria'), findsNothing);

    // ...which used to dead-end the Visited chip (the
    // visited rows were filtered out before it ran). The
    // explicit view must win while it is selected.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Visited'));
    await tester.pumpAndSettle();
    expect(find.text('Alexandria'), findsOneWidget);
    expect(find.text('Rome'), findsNothing);

    // Switching back restores the stored default view.
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(find.text('Rome'), findsOneWidget);
    expect(find.text('Alexandria'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('the safety filter keeps destinations without a rating',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'data'],
          [
            ['Alexandria', 'Egypt', jsonEncode(const [])],
            ['Rome', 'Italy', jsonEncode(const [])],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();
    // Both rows have no safety rating: the minimum
    // slider must not hide them (the invariant).
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    final slider = find.byType(Slider).first;
    await tester.tap(slider);
    await tester.pumpAndSettle();
    await tester.drag(slider, const Offset(120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Alexandria'), findsOneWidget);
    expect(find.text('Rome'), findsOneWidget);
    expect(find.textContaining('2 of 2 destinations'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ── the search and the empty states ─────────────────────────
  //
  // An empty list must always say *why* it is empty. "The
  // database holds no destinations", "No destination matches
  // ..." and "no unvisited destination matches ... (3 matched
  // before the filter)" are three different facts, and a user
  // who cannot tell them apart thinks the data is gone.

  testWidgets('a failed read is a problem, not an empty catalogue',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((_) => httpStatus(503));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('The database holds no destinations.'), findsNothing,
        reason: 'a failed read is never an empty catalogue');
    expect(find.text('Could not load destinations'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('an empty database says so', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          const [],
        ));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('The database holds no destinations.'), findsOneWidget);
  });

  testWidgets('the search narrows the list by name and by country',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['Rome', 'Italy', null, jsonEncode(const [])],
            ['Kyoto', 'Japan', null, jsonEncode(const [])],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Rome'), findsOneWidget);
    expect(find.text('Kyoto'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'kyoto');
    await tester.pumpAndSettle();
    expect(find.text('Rome'), findsNothing);
    expect(find.text('Kyoto'), findsOneWidget);

    // The country counts too.
    await tester.enterText(find.byType(TextField), 'japan');
    await tester.pumpAndSettle();
    expect(find.text('Rome'), findsNothing);
    expect(find.text('Kyoto'), findsOneWidget);
  });

  testWidgets('a search that matches nothing says what it searched for',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['Rome', 'Italy', null, jsonEncode(const [])],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'atlantis');
    await tester.pumpAndSettle();

    expect(find.text('No destination matches "atlantis".'), findsOneWidget);
  });

  testWidgets('the groups are per country', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['Rome', 'Italy', null, jsonEncode(const [])],
            ['Milan', 'Italy', null, jsonEncode(const [])],
            ['Kyoto', 'Japan', null, jsonEncode(const [])],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: CataloguePage(
        repository:
            DestinationRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Italy'), findsOneWidget);
    expect(find.text('Japan'), findsOneWidget);
  });
}
