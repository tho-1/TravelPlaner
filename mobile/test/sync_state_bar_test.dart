/// The sync-state line (Phase 5, commit 3): visible only when
/// it has something true to say, and honest about which it is
/// -- writes waiting, or a change that could not sync.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/ui/sync_state_bar.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Column(children: [child])));

void main() {
  testWidgets('says nothing when there is nothing to say', (tester) async {
    await tester.pumpWidget(_wrap(const SyncStateBar(pending: 0)));
    expect(find.byType(Text), findsNothing);
    expect(find.text('Sync now'), findsNothing);
  });

  testWidgets('counts the writes waiting, with one verb', (tester) async {
    await tester.pumpWidget(_wrap(const SyncStateBar(pending: 1)));
    expect(find.textContaining('1 change waiting to sync'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
  });

  testWidgets('pluralises and shows the last drain note', (tester) async {
    await tester.pumpWidget(_wrap(const SyncStateBar(
      pending: 2,
      notes: ['2 queued changes synced'],
    )));
    expect(find.textContaining('2 changes waiting to sync'),
        findsOneWidget);
    expect(find.textContaining('2 queued changes synced'), findsOneWidget);
  });

  testWidgets('a conflict is stated even with nothing queued',
      (tester) async {
    await tester.pumpWidget(_wrap(const SyncStateBar(
      pending: 0,
      notes: ['trip “Japan”: the trip changed elsewhere since this copy '
          'was loaded'],
    )));
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing,
        reason: 'there is nothing left to send');
  });

  testWidgets('Sync now reports the tap, and is disabled while busy',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_wrap(SyncStateBar(
      pending: 1,
      onSyncNow: () => taps++,
    )));
    await tester.tap(find.text('Sync now'));
    expect(taps, 1);

    // A drain in progress passes a null callback: the
    // button must not be tappable twice.
    await tester.pumpWidget(_wrap(const SyncStateBar(pending: 1)));
    await tester.tap(find.text('Sync now'));
    expect(taps, 1);
  });
}
