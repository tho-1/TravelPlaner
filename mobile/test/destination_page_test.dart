/// The destination page's profile sections render real data
/// without crashing: metrics, overview, best months, climate
/// KPIs and the chart, plus the write path through the fake
/// repository. The page is a ListView that builds lazily, so
/// the tests walk down the page and assert each section in
/// document order.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/ui/destination_page.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';

Destination alexandria() {
  final columns = <String, Object?>{
    'Destination': 'Alexandria',
    'In näherer Auswahl 2025?': true,
    'Continent': 'Africa',
    'Country': 'Egypt',
    'Why to Go There': 'A unique blend of history and sea.',
    'Tourist Reviews': 'Travellers praise the history.',
    'Highlights': 'Bibliotheca Alexandrina, Qaitbay Citadel',
    'Visa Requirement': 'Apply beforehand',
    'Malaria risk?': 'no — no city transmission',
    'Avg. Cost/Day (3* Hotel & Food)': 45,
    'Recommended Stay': '2-3 days',
    'Population (Metro Area)': 5200000,
    'January': 'ok',
    'March': 'ideal',
    'July': 'bad',
    'Jan High (C)': 17.7,
    'Jul High (C)': 31,
    'Jan Low (C)': 11,
    'Jul Low (C)': 23.8,
    'Jan Rain (mm)': 44.4,
    'Jul Rain (mm)': 0.2,
    'Jan AQI': 76,
    'Jul AQI': 59,
    'Reviews': 7,
    'Avoid Going There': 'Summer (June-August) (very hot and humid)',
  };
  return Destination(
    core: {
      'destination': 'Alexandria',
      'country': 'Egypt',
      'continent': 'Africa',
      'favourite': true,
      'visited': false,
      'safety_rating': 6,
      'avg_cost_day': 45,
      'comment': 'Worth a long weekend',
    },
    columns: [for (final entry in columns.entries) (entry.key, entry.value)],
  );
}

DestinationRepository repositoryFor(FakeTurso fake) => DestinationRepository(
      TursoClient(
        const TursoConfig(url: 'https://db.example.turso.io', token: 'token'),
        httpClient: fake.client(),
      ),
    );

/// Walk down the ListView until `finder` is built and fully
/// visible, then return.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  for (var step = 0; step < 40; step++) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder.first);
      await tester.pumpAndSettle();
      if (finder.evaluate().isNotEmpty) return;
    }
    await tester.drag(find.byType(ListView).first, const Offset(0, -250));
    await tester.pumpAndSettle();
  }
  fail('never became visible: $finder');
}

void main() {
  testWidgets('the profile sections render the workbook data',
      (tester) async {
    final repository =
        repositoryFor(FakeTurso((_) => okRows(['destination'], [])));

    await tester.pumpWidget(MaterialApp(
      home: DestinationPage(repository: repository, destination: alexandria()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Egypt · Africa'), findsOneWidget);

    await scrollTo(tester, find.text('Overview'));
    expect(find.text('A unique blend of history and sea.'), findsOneWidget);
    expect(find.text('Travellers praise the history.'), findsOneWidget);
    expect(find.text('Highlights'), findsOneWidget);

    await scrollTo(tester, find.text('Best months'));
    // The best-months chips show the rating and the reason.
    expect(find.text('Ideal'), findsWidgets);
    expect(find.text('very hot and humid'), findsOneWidget);

    await scrollTo(tester, find.text('Climate'));
    // The climate KPIs.
    expect(find.text('31°C (Jul)'), findsOneWidget);
    expect(find.text('44mm (Jan)'), findsOneWidget);
    expect(find.textContaining('Moderate'), findsOneWidget);
    // The chart painted without an exception.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a destination with no climate data says so', (tester) async {
    final repository =
        repositoryFor(FakeTurso((_) => okRows(['destination'], [])));
    final empty = Destination(
      core: {'destination': 'Nowhere', 'country': 'Atlantis'},
      columns: const [],
    );
    await tester.pumpWidget(MaterialApp(
      home: DestinationPage(repository: repository, destination: empty),
    ));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('No overview text was found in the workbook.'));
    expect(
        find.text('No overview text was found in the workbook.'), findsOneWidget);
    await scrollTo(tester, find.textContaining('being populated'));
    expect(find.textContaining('being populated'), findsOneWidget);
  });

  testWidgets('a comment write reports success', (tester) async {
    // updateField is a read-modify-write: one SELECT for the
    // read, one upsert for the write; the fake answers both.
    var selects = 0;
    var writes = 0;
    final fake = FakeTurso((statements) {
      final statement = statements.single;
      if (statement.startsWith('SELECT')) {
        selects++;
        return okRows(['destination', 'data'], [
          ['Alexandria', jsonEncode([['Comment', 'old']])],
        ]);
      }
      writes++;
      return okEmpty();
    });
    final repository = repositoryFor(fake);

    await tester.pumpWidget(MaterialApp(
      home: DestinationPage(repository: repository, destination: alexandria()),
    ));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Beach day');
    await scrollTo(tester, find.widgetWithIcon(FilledButton, Icons.save_outlined));
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    expect(selects, greaterThanOrEqualTo(1));
    expect(writes, greaterThanOrEqualTo(1));
    expect(find.text('Saved'), findsOneWidget);
  });
}
