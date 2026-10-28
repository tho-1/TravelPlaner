/// The map's fly-to search, end to end: the field the page
/// wires, and the destination page it pushes.
///
/// This lives in its own file because it needs the real
/// coordinate and geometry assets. Priming them is only
/// reliable before any other page in the isolate has started
/// (and abandoned) its own load -- in `world_map_test.dart`
/// the earlier pages leave those futures hanging, and the
/// page then never gets its cities (2026-10-28).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/city_coordinates.dart';
import 'package:travel_planner/data/country_geometry.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';
import 'package:travel_planner/ui/destination_page.dart';
import 'package:travel_planner/ui/world_map_page.dart';

import 'fake_turso.dart';

void main() {
  testWidgets('the fly-to search opens a city, and opens it again',
      (tester) async {
    // The report (2026-10-28): search Okinawa, open it, go
    // back, and tapping the same suggestion again does
    // nothing. The field's own repeat pick is pinned in
    // fly_to_field_test.dart; this is the wiring -- the map
    // really pushes the destination page, twice.
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => binding.setSurfaceSize(null));
    // The coordinate index is real asset I/O, which the fake
    // clock cannot drive: prime it, or the page has no city
    // to offer (every other test here asserts things that do
    // not need coordinates, so none of them noticed).
    await tester.runAsync(() async {
      // Bounded: a load left half-open by an earlier test
      // must fail this case's assertions, not hang the suite.
      await Future.any([
        () async {
          await CoordinateIndex.load();
          await CountryGeometry.load();
        }(),
        Future<void>.delayed(const Duration(seconds: 5)),
      ]);
    });
    String months(String rating) => jsonEncode([
          for (final month in [
            'January', 'February', 'March', 'April', 'May', 'June', //
            'July', 'August', 'September', 'October', 'November', 'December',
          ])
            [month, rating],
        ]);
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['Okinawa', 'Japan', null, months('ok')],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: WorldMapPage(
        repository: DestinationRepository(
          TursoClient(
            const TursoConfig(
                url: 'https://travel-tz123.aws-eu-north-1.turso.io',
                token: 'token'),
            httpClient: fake.client(),
          ),
        ),
      ),
    ));
    // Bounded frames instead of `pumpAndSettle`: the page's
    // map tiles and the destination page's loaders keep
    // animating, and settling would spin forever.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    final view = tester.widget<WorldMapView>(find.byType(WorldMapView).first);
    expect(view.cities.map((city) => city.name), contains('Okinawa'),
        reason: 'the plot holds the city the search offers');

    /// Types [query] and taps the suggestion that is exactly
    /// [query]. Frames, not `pumpAndSettle`: the destination
    /// page keeps animating its own loaders and would never
    /// settle.
    Future<void> search(String query) async {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.widgetWithText(ListTile, query), findsWidgets,
          reason: 'the query has a suggestion to tap');
      await tester.tap(find.widgetWithText(ListTile, query).last);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 80));
        if (find.byType(DestinationPage).evaluate().isNotEmpty) break;
      }
    }

    await search('Okinawa');
    expect(find.byType(DestinationPage), findsOneWidget,
        reason: 'the first pick opens the destination');

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DestinationPage), findsNothing);

    await search('Okinawa');
    expect(find.byType(DestinationPage), findsOneWidget,
        reason: 'the same suggestion must open it again');
  });
}
