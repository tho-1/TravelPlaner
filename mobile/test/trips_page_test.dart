/// The trip planner: the trip and variant switchers, the
/// three sub-tabs and the failure states.
///
/// The planner is where the user's work lives, and the two
/// rules that matter most are the ones a page-level test
/// can pin: a failed read is a *problem view*, never an
/// ambiguous "no trips", and switching a trip or a variant
/// really switches what the editor shows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/geocode_repository.dart';
import 'package:travel_planner/data/trip_repository.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';
import 'package:travel_planner/ui/trips_page.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
  url: 'https://db.example.turso.io',
  token: 'token',
);

void main() {
  late DestinationRepository destinationRepository;

  setUp(() {
    destinationRepository = DestinationRepository(
      TursoClient(
        _config,
        httpClient: FakeTurso((_) => okRows([], const [])).client(),
      ),
    );
  });

  Widget page(TripRepository repository) => MaterialApp(
        home: TripsPage(
          repository: repository,
          destinations: destinationRepository,
          geocoder: GeocodeRepository(''),
        ),
      );

  testWidgets('a failed read is a problem view with a retry',
      (tester) async {
    final repository = TripRepository(
      TursoClient(_config, httpClient: FakeTurso((_) => httpStatus(503)).client()),
    );
    await tester.pumpWidget(page(repository));
    await tester.pumpAndSettle();

    expect(find.text('Could not load trips'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No trips stored'), findsNothing,
        reason: 'a failed read is never an empty list');
  });

  testWidgets('an empty store says so', (tester) async {
    final repository = TripRepository(
      TursoClient(_config, httpClient: FakeTurso((_) => okMulti([
        (['id', 'name', 'created', 'active_variant_id', 'updated_at'], []),
        (['id', 'trip_id', 'name', 'updated_at'], []),
        (['id', 'variant_id', 'position', 'name'], []),
        (['variant_id', 'position', 'mode'], []),
      ])).client()),
    );
    await tester.pumpWidget(page(repository));
    await tester.pumpAndSettle();

    expect(find.text('No trips stored'), findsOneWidget);
    expect(find.text('New trip'), findsOneWidget);
  });

  testWidgets('the trip and variant switchers show the open trip',
      (tester) async {
    final repository = TripRepository(
      TursoClient(_config, httpClient: FakeTurso((_) => okMulti([
        (
          ['id', 'name', 'created', 'active_variant_id', 'updated_at'],
          [
            ['t-1', 'Japan', '2026-01-01T00:00:00+00:00', 'v-1', '2026-01-01T00:00:00+00:00'],
          ],
        ),
        (
          ['id', 'trip_id', 'name', 'updated_at'],
          [
            ['v-1', 't-1', 'Spring', '2026-01-01T00:00:00+00:00'],
            ['v-2', 't-1', 'Autumn', '2026-01-01T00:00:00+00:00'],
          ],
        ),
        (['id', 'variant_id', 'position', 'name'], []),
        (['variant_id', 'position', 'mode'], []),
      ])).client()),
    );
    await tester.pumpWidget(page(repository));
    await tester.pumpAndSettle();

    // The trip name is in the title and in the trip
    // switcher.
    expect(find.text('Japan'), findsWidgets);
    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Variant'), findsOneWidget);
    expect(find.text('Spring'), findsOneWidget);
    // The three sub-tabs.
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Compare'), findsOneWidget);
  });

  testWidgets('switching the variant writes the new active variant',
      (tester) async {
    // The variant switcher is a write, not a local
    // selection: the active variant is stored with the
    // trip, so a switch that only changed the screen would
    // be lost on the next reload.
    final writes = <String>[];
    final fake = FakeTurso((statements) {
      final isRead = statements.any((s) => s.trimLeft().startsWith('SELECT'));
      if (isRead) {
        return okMulti([
          (
            ['id', 'name', 'created', 'active_variant_id', 'updated_at'],
            [
              [
                't-1',
                'Japan',
                '2026-01-01T00:00:00+00:00',
                'v-1',
                '2026-01-01T00:00:00+00:00'
              ],
            ],
          ),
          (
            ['id', 'trip_id', 'name', 'updated_at'],
            [
              ['v-1', 't-1', 'Spring', '2026-01-01T00:00:00+00:00'],
              ['v-2', 't-1', 'Autumn', '2026-01-01T00:00:00+00:00'],
            ],
          ),
          (['id', 'variant_id', 'position', 'name'], []),
          (['variant_id', 'position', 'mode'], []),
        ]);
      }
      for (final statement in statements) {
        if (statement.contains('INSERT INTO trips')) {
          writes.add(statement);
        }
      }
      return okEmpty(1, 1);
    });
    final repository =
        TripRepository(TursoClient(_config, httpClient: fake.client()));
    await tester.pumpWidget(page(repository));
    await tester.pumpAndSettle();

    // Open the variant switcher and pick the other variant.
    await tester.tap(find.text('Spring'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Autumn').last);
    await tester.pumpAndSettle();

    expect(writes, isNotEmpty, reason: 'the switch was written');
    expect(writes.first, contains('v-2'),
        reason: 'the new active variant is the one that was written');
  });
}
