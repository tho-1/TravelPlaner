/// The settings page: the open-tabs switch, the API-key
/// rows and the offline section.
///
/// The switch has a rule that is invisible in the app but
/// expensive to get wrong: it only moves when the write
/// *confirmed*. The page is a pushed route and does not
/// rebuild with the shell, so a switch that moved on the
/// tap looked saved even when the write failed (the bug
/// found on the phone, 2026-10-14).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/ui/settings_page.dart';

void main() {
  Widget page({
    bool openTabsEnabled = true,
    required Future<bool> Function(bool value) onToggleTabs,
    Map<String, (String, bool, String)> apiKeys = const {},
    Future<bool> Function(String name, String value)? onRotateKey,
    String? stateDir,
    int pendingWrites = 0,
    VoidCallback? onSyncNow,
  }) =>
      MaterialApp(
        home: SettingsPage(
          openTabsEnabled: openTabsEnabled,
          onToggleTabs: onToggleTabs,
          apiKeys: apiKeys,
          onRotateKey: onRotateKey ?? (_, _) async => true,
          stateDir: stateDir,
          pendingWrites: pendingWrites,
          onSyncNow: onSyncNow,
        ),
      );

  testWidgets('the switch moves only when the write confirmed',
      (tester) async {
    final saved = <bool>[];
    await tester.pumpWidget(page(
      onToggleTabs: (value) async {
        saved.add(value);
        return false; // the write failed
      },
    ));
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
      reason: 'the switch starts where the shell says it is',
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(saved, [false], reason: 'the change was reported');
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
      reason: 'a failed write must not look saved',
    );
  });

  testWidgets('a confirmed write moves the switch', (tester) async {
    final saved = <bool>[];
    await tester.pumpWidget(page(
      onToggleTabs: (value) async {
        saved.add(value);
        return true;
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(saved, [false]);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });

  testWidgets('the key rows show the masked value, or that it is not set',
      (tester) async {
    await tester.pumpWidget(page(
      onToggleTabs: (_) async => true,
      apiKeys: {
        'turso_token': ('Turso database token', true, '••••abcd'),
        'deepseek_api_key': ('DeepSeek AI key', false, ''),
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('Turso database token'), findsOneWidget);
    expect(find.text('••••abcd'), findsOneWidget);
    expect(find.text('DeepSeek AI key'), findsOneWidget);
    expect(find.textContaining('Not set'), findsOneWidget);
  });

  testWidgets('rotating a key reports a failure to the user',
      (tester) async {
    await tester.pumpWidget(page(
      onToggleTabs: (_) async => true,
      apiKeys: {
        'turso_token': ('Turso database token', true, '••••abcd'),
      },
      onRotateKey: (_, _) async => false,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turso database token'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'new-token');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Could not save the key.'), findsOneWidget,
        reason: 'a failed write must not stay silent');
  });

  testWidgets('the offline section is only there with a state directory',
      (tester) async {
    await tester.pumpWidget(page(onToggleTabs: (_) async => true));
    await tester.pumpAndSettle();
    expect(find.text('Offline data'), findsNothing);

    await tester.pumpWidget(page(
      onToggleTabs: (_) async => true,
      stateDir: '/tmp/state',
      pendingWrites: 2,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Offline data'), findsOneWidget);
    expect(find.text('2 changes waiting to sync'), findsOneWidget);
  });

  testWidgets('the sync-now action is offered while writes are owed',
      (tester) async {
    var synced = 0;
    await tester.pumpWidget(page(
      onToggleTabs: (_) async => true,
      stateDir: '/tmp/state',
      pendingWrites: 1,
      onSyncNow: () => synced++,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(synced, 1);
  });
}
