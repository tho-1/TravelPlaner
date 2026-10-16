/// The open-destination tabs: the Turso repository (the
/// ported `storage_turso.load/save_open_tabs` contract),
/// the per-device settings file, and the floating-button /
/// bottom-sheet widgets (report i).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/data/app_settings.dart';
import 'package:travel_planner/data/open_tabs_repository.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';
import 'package:travel_planner/ui/open_tabs.dart';
import 'package:travel_planner/ui/settings_page.dart';

import 'fake_turso.dart';

OpenTabsRepository _repo(FakeTurso fake) => OpenTabsRepository(TursoClient(
      const TursoConfig(url: 'https://db.example.turso.io', token: 'token'),
      httpClient: fake.client(),
    ));

Destination _destination(String name, {bool favourite = false}) =>
    Destination(
      core: {'destination': name, if (favourite) 'favourite': true},
      columns: const [],
    );

void main() {
  group('OpenTabsRepository', () {
    test('loadTabs reads the persisted names in order', () async {
      final fake = FakeTurso((statements) {
        expect(statements,
            ['SELECT destination FROM open_tabs ORDER BY destination']);
        return okRows(['destination'], [
          ['Kyoto'],
          ['Sarajevo'],
        ]);
      });
      final (tabs, problems) = await _repo(fake).loadTabs();
      expect(problems, isEmpty);
      expect(tabs, ['Kyoto', 'Sarajevo']);
    });

    test('an empty table is an empty list without problems', () async {
      final fake = FakeTurso((_) => okRows(['destination'], const []));
      final (tabs, problems) = await _repo(fake).loadTabs();
      expect(problems, isEmpty);
      expect(tabs, isEmpty);
    });

    test('a database without the table creates it and reads again',
        () async {
      final selects = <int>[];
      final fake = FakeTurso((statements) {
        final sql = statements.first;
        if (sql.startsWith('SELECT')) {
          selects.add(selects.length);
          // The first read fails (the table predates the
          // feature's deployment); the retry succeeds.
          return selects.length == 1
              ? pipelineError('no such table: open_tabs')
              : okRows(['destination'], [
                  ['Kyoto'],
                ]);
        }
        expect(sql,
            'CREATE TABLE IF NOT EXISTS open_tabs '
            '(destination TEXT PRIMARY KEY, updated_at TEXT)');
        return okEmpty();
      });
      final (tabs, problems) = await _repo(fake).loadTabs();
      expect(problems, isEmpty);
      expect(tabs, ['Kyoto']);
    });

    test('a failed read is an empty list with problems, never "no tabs"',
        () async {
      final fake = FakeTurso((statements) {
        if (statements.first.startsWith('SELECT')) {
          return pipelineError('Turso is down');
        }
        return okEmpty();
      });
      final (tabs, problems) = await _repo(fake).loadTabs();
      expect(tabs, isEmpty);
      expect(problems, isNotEmpty);
    });

    test('saveTabs replaces the whole list and escapes names', () async {
      final fake = FakeTurso((statements) {
        expect(statements.first, 'DELETE FROM open_tabs');
        expect(statements, hasLength(3));
        expect(
            statements[1],
            startsWith('INSERT OR IGNORE INTO open_tabs '
                '(destination, updated_at) VALUES (\'Kyoto\', '));
        expect(statements[2], contains("'O''Brien'"));
        return okEmpty(3);
      });
      final ok = await _repo(fake).saveTabs(['Kyoto', "O'Brien"]);
      expect(ok, isTrue);
    });

    test('saving an empty list just deletes', () async {
      final fake = FakeTurso((statements) {
        expect(statements, ['DELETE FROM open_tabs']);
        return okEmpty();
      });
      expect(await _repo(fake).saveTabs([]), isTrue);
    });

    test('a failed write is false, never a silent success', () async {
      final fake = FakeTurso((_) => pipelineError('read-only token'));
      final ok = await _repo(fake).saveTabs(['Kyoto']);
      expect(ok, isFalse);
    });
  });

  group('AppSettings', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('app_settings_test');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('a missing file is the defaults', () {
      expect(AppSettings.load(dir.path).openTabsEnabled, isTrue);
    });

    test('a saved switch survives the round trip', () {
      expect(const AppSettings(openTabsEnabled: false).save(dir.path),
          isTrue);
      expect(AppSettings.load(dir.path).openTabsEnabled, isFalse);
      expect(const AppSettings(openTabsEnabled: true).save(dir.path),
          isTrue);
      expect(AppSettings.load(dir.path).openTabsEnabled, isTrue);
    });

    test('a corrupt file is the defaults, not a crash', () {
      File(AppSettings.filePath(dir.path))
          .writeAsStringSync('{not json');
      expect(AppSettings.load(dir.path).openTabsEnabled, isTrue);
    });

    test('a failed write is false', () {
      // The directory path is a file: createSync must fail
      // and the save must report it.
      final file = File('${dir.path}/not-a-dir');
      file.writeAsStringSync('x');
      expect(
          const AppSettings().save('${dir.path}/not-a-dir'), isFalse);
    });
  });

  group('OpenTabsFab (the floating button, report i)', () {
    testWidgets('shows the open count and reports taps', (tester) async {
      var pressed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          floatingActionButton: OpenTabsFab(
            count: 3,
            hasProblems: false,
            onPressed: () => pressed = true,
          ),
        ),
      ));
      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      expect(pressed, isTrue);
    });

    testWidgets('a read problem shows its icon instead of a count',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          floatingActionButton: OpenTabsFab(
            count: 0,
            hasProblems: true,
            onPressed: () {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    });
  });

  group('OpenTabsSheet (the open items)', () {
    testWidgets('renders one closeable row per tab and opens on tap',
        (tester) async {
      var opened = '';
      var closed = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpenTabsSheet(
            tabs: const ['Kyoto', 'Sarajevo'],
            destinations: {
              'Kyoto': _destination('Kyoto', favourite: true),
            },
            active: 'Kyoto',
            problems: const [],
            onOpen: (name) => opened = name,
            onClose: (name) => closed = name,
            onCloseAll: () {},
          ),
        ),
      ));

      expect(find.text('Kyoto'), findsOneWidget);
      expect(find.text('Sarajevo'), findsOneWidget);
      // The favourite star rides the row that has one.
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);

      await tester.tap(find.text('Sarajevo'));
      expect(opened, 'Sarajevo');

      await tester.tap(find.byTooltip('Close Kyoto'));
      expect(closed, 'Kyoto');
    });

    testWidgets('close all is offered, and an empty list is a hint',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpenTabsSheet(
            tabs: const [],
            destinations: const {},
            active: null,
            problems: const ['Turso is down'],
            onOpen: (_) {},
            onClose: (_) {},
            onCloseAll: () {},
          ),
        ),
      ));
      // A failed read is never silently "no tabs open".
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.text('Destinations you open collect here.'),
          findsOneWidget);
      // With no tabs there is nothing to close.
      expect(find.text('Close all'), findsNothing);
    });

    testWidgets('close all is wired when tabs are open', (tester) async {
      var closedAll = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpenTabsSheet(
            tabs: const ['Kyoto'],
            destinations: const {},
            active: null,
            problems: const [],
            onOpen: (_) {},
            onClose: (_) {},
            onCloseAll: () => closedAll = true,
          ),
        ),
      ));
      await tester.tap(find.text('Close all'));
      expect(closedAll, isTrue);
    });
  });

  group('SettingsPage', () {
    testWidgets('the switch moves only after the write confirms',
        (tester) async {
      var saved = true;
      bool? reported;
      await tester.pumpWidget(MaterialApp(
        home: SettingsPage(
          openTabsEnabled: true,
          onToggleTabs: (value) async {
            reported = value;
            return saved;
          },
        ),
      ));

      expect(find.text('Open-destination tabs'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(reported, isFalse);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);

      // A failed write must not look saved: the switch stays.
      saved = false;
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(reported, isTrue);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);
    });
  });
}
