/// The open-destination tabs: the Turso repository (the
/// ported `storage_turso.load/save_open_tabs` contract),
/// the per-device settings file, and the two tab-strip
/// widgets.
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

  group('OpenTabsPanel (desktop)', () {
    testWidgets('renders one closeable row per tab', (tester) async {
      var opened = '';
      var closed = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            OpenTabsPanel(
              tabs: const ['Kyoto', 'Sarajevo'],
              destinations: {
                'Kyoto': _destination('Kyoto', favourite: true),
              },
              active: 'Kyoto',
              problems: const [],
              onOpen: (name) => opened = name,
              onClose: (name) => closed = name,
            ),
          ]),
        ),
      ));

      expect(find.text('Kyoto'), findsOneWidget);
      expect(find.text('Sarajevo'), findsOneWidget);
      // The favourite star rides the row that has one.
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);

      await tester.tap(find.text('Sarajevo'));
      expect(opened, 'Sarajevo');

      await tester.tap(find.byIcon(Icons.close).first);
      expect(closed, 'Kyoto');
    });

    testWidgets('an empty list is a hint, read problems are a warning',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpenTabsPanel(
            tabs: const [],
            destinations: const {},
            active: null,
            problems: const ['Turso is down'],
            onOpen: (_) {},
            onClose: (_) {},
          ),
        ),
      ));
      // A failed read is never silently "no tabs open": the
      // header carries the warning and the tooltip the text.
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.text('Destinations you open collect here.'),
          findsOneWidget);
    });
  });

  group('OpenTabsStrip (phone)', () {
    testWidgets('chips open and close tabs', (tester) async {
      var opened = '';
      var closed = '';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpenTabsStrip(
            tabs: const ['Kyoto'],
            active: null,
            onOpen: (name) => opened = name,
            onClose: (name) => closed = name,
          ),
        ),
      ));

      await tester.tap(find.text('Kyoto'));
      expect(opened, 'Kyoto');
      await tester.tap(find.byIcon(Icons.close));
      expect(closed, 'Kyoto');
    });
  });

  group('SettingsPage', () {
    testWidgets('the switch reports changes', (tester) async {
      var enabled = true;
      await tester.pumpWidget(MaterialApp(
        home: SettingsPage(
          openTabsEnabled: enabled,
          onToggleTabs: (value) => enabled = value,
        ),
      ));

      expect(find.text('Open-destination tabs'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      expect(enabled, isFalse);
    });
  });
}
