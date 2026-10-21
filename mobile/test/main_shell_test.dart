/// The shell: the four tabs, the open-destination drawer,
/// the settings switch and the sync-state line.
///
/// The shell is where the app's wiring lives -- a tab that
/// does not switch, a drawer that records the wrong name, or
/// a settings switch that does not survive a restart are
/// all invisible in a page-level test and obvious in the
/// app. The repositories are injected through the HTTP
/// client (a fake), so the whole shell runs without a
/// network and without credentials.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/ui/main.dart';
import 'package:travel_planner/ui/open_tabs.dart';
import 'package:travel_planner/ui/world_map_page.dart';

import 'fake_turso.dart';

/// A route-aware handler: the fake answers by the SQL, so
/// one client can serve the catalogue, the tab list and the
/// trips the shell asks for at startup.
FakeTurso _shellFake({
  List<String> tabs = const [],
  List<String> destinations = const ['Rome'],
}) {
  return FakeTurso((statements) {
    final sql = statements.join(' ');
    if (sql.contains('FROM open_tabs')) {
      return okRows(['destination'], [
        for (final name in tabs) [name],
      ]);
    }
    if (sql.contains('FROM trips')) {
      return okRows(
          ['id', 'name', 'created', 'active_variant_id', 'updated_at'], []);
    }
    if (sql.contains('FROM variants')) {
      return okRows(['id', 'trip_id', 'name', 'updated_at'], []);
    }
    if (sql.contains('FROM stops')) {
      return okRows(['id', 'variant_id', 'position', 'name'], []);
    }
    if (sql.contains('FROM legs')) {
      return okRows(['variant_id', 'position', 'mode'], []);
    }
    return okRows(['destination', 'country', 'visited', 'data'], [
      for (final name in destinations) [name, 'Italy', null, '[]'],
    ]);
  });
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('shell_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  TursoConfig config() => TursoConfig(
        url: 'https://travel-tz123.aws-eu-north-1.turso.io',
        token: 'token',
        stateDir: temp.path,
      );

  Future<void> pumpShell(
    WidgetTester tester, {
    List<String> tabs = const [],
    List<String> destinations = const ['Rome'],
  }) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.pumpWidget(TravelPlannerApp(
      config: config(),
      httpClient: _shellFake(tabs: tabs, destinations: destinations)
          .client(),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the shell shows the four tabs and switches between them',
      (tester) async {
    await pumpShell(tester);

    // The four destinations of the shell, by their rail
    // labels (desktop width: the rail, not the phone's
    // bottom bar).
    expect(find.text('Catalogue'), findsOneWidget);
    expect(find.text('Trip Planner'), findsOneWidget);
    expect(find.text('Finder'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Map'),
      ),
      findsOneWidget,
    );

    // The catalogue is the first tab; the map is the last.
    await tester.tap(find.byType(NavigationRail).last);
    await tester.pumpAndSettle();
    expect(find.byType(WorldMapView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the drawer button lists the persisted open destinations',
      (tester) async {
    await pumpShell(tester, tabs: ['Rome', 'Kyoto']);

    // The floating button carries the open count.
    final fab = find.byType(OpenTabsFab);
    expect(fab, findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(fab);
    await tester.pumpAndSettle();
    expect(find.text('Rome'), findsWidgets);
    expect(find.text('Kyoto'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no open destinations means no drawer button', (tester) async {
    await pumpShell(tester);
    expect(find.byType(OpenTabsFab), findsNothing);
  });

  testWidgets('a failed tab read is a warning, never "no tabs"',
      (tester) async {
    // The read fails: the button must still appear, so the
    // user is told the list could not be read (invariant 1 --
    // a failed read is not an empty list).
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => binding.setSurfaceSize(null));
    final fake = FakeTurso((statements) {
      if (statements.join(' ').contains('FROM open_tabs')) {
        return httpStatus(503);
      }
      return okRows(['destination', 'country', 'visited', 'data'], const []);
    });
    await tester.pumpWidget(TravelPlannerApp(
      config: config(),
      httpClient: fake.client(),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(OpenTabsFab), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sync line appears only when something is owed',
      (tester) async {
    await pumpShell(tester);
    // Nothing queued, nothing to say: the bar renders
    // nothing, so there is no "waiting to sync" line.
    expect(find.textContaining('waiting to sync'), findsNothing);
  });

  testWidgets('the open-tabs switch in the per-device settings governs '
      'the drawer', (tester) async {
    // The switch is stored per device in the state dir's
    // app_settings.json. Off means: no drawer button, and
    // the destination page offers no "Add to drawer" button.
    File('${temp.path}${Platform.pathSeparator}app_settings.json')
        .writeAsStringSync('{"open_tabs_enabled": false}');
    await pumpShell(tester, tabs: ['Rome']);
    expect(find.byType(OpenTabsFab), findsNothing);
  });
}
