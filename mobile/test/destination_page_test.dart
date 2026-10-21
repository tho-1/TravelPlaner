/// The destination page's profile sections render real data
/// without crashing: metrics, overview, best months, climate
/// KPIs and the chart, plus the write path through the fake
/// repository. The page is a ListView that builds lazily, so
/// the tests walk down the page and assert each section in
/// document order.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:travel_planner/data/ai_config.dart';
import 'package:travel_planner/data/deepseek_client.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/gallery_cache.dart';
import 'package:travel_planner/data/gallery_repository.dart';
import 'package:travel_planner/data/gallery_search.dart';
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

class _FakePhotoSearchProvider implements PhotoSearchProvider {
  final String imagePath;
  final List<int> requestedPages = [];
  final List<String> requestedQueries = [];

  _FakePhotoSearchProvider(this.imagePath);

  @override
  Future<List<GalleryEntry>> search(
    String query, {
    int page = 1,
    int perPage = 8,
  }) async {
    requestedPages.add(page);
    requestedQueries.add(query);
    final ids = page == 1 ? ['first', 'second'] : ['replacement'];
    return [
      for (final id in ids)
        GalleryEntry(
          imagePath: imagePath,
          photoId: id,
          caption: 'Photographer $id',
          source: 'Unsplash',
          photographerUrl: 'https://unsplash.com/@photo-maker',
          photoPageUrl: 'https://unsplash.com/photos/$id',
        ),
    ];
  }
}

class _MemoryGalleryCache implements GalleryMetadataCache {
  List<GalleryEntry>? entries;

  @override
  Future<List<GalleryEntry>?> load(String destinationName) async => entries;

  @override
  Future<void> save(String destinationName, List<GalleryEntry> value) async {
    entries = List.of(value);
  }
}

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
  testWidgets('the profile sections render the workbook data', (tester) async {
    final repository = repositoryFor(
      FakeTurso((_) => okRows(['destination'], [])),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Egypt'), findsOneWidget);

    await scrollTo(tester, find.text('Overview'));
    expect(find.text('A unique blend of history and sea.'), findsOneWidget);
    expect(find.text('Travellers praise the history.'), findsOneWidget);
    expect(find.text('Highlights'), findsOneWidget);

    await scrollTo(tester, find.text('Best months'));
    // The best-months chips show the month and the rating;
    // the long reason lives in the chip's tooltip (uniform
    // chip heights in the row).
    expect(find.text('Ideal'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').contains('very hot and humid'),
      ),
      findsOneWidget,
    );

    await scrollTo(tester, find.text('Climate'));
    // The climate KPIs.
    expect(find.text('31°C (Jul)'), findsOneWidget);
    expect(find.text('44mm (Jan)'), findsOneWidget);
    expect(find.textContaining('Moderate'), findsOneWidget);
    // The chart painted without an exception.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a destination with no climate data says so', (tester) async {
    final repository = repositoryFor(
      FakeTurso((_) => okRows(['destination'], [])),
    );
    final empty = Destination(
      core: {'destination': 'Nowhere', 'country': 'Atlantis'},
      columns: const [],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(repository: repository, destination: empty),
      ),
    );
    await tester.pumpAndSettle();

    // The workbook is gone; the empty note names the
    // destination, not a file the reader never had.
    await scrollTo(
      tester,
      find.text('No overview text was found for this destination.'),
    );
    expect(
      find.text('No overview text was found for this destination.'),
      findsOneWidget,
    );
    await scrollTo(tester, find.textContaining('being populated'));
    expect(find.textContaining('being populated'), findsOneWidget);
  });

  testWidgets('a comment write updates the field and stays quiet', (
    tester,
  ) async {
    // updateField is a read-modify-write: one SELECT for the
    // read, one upsert for the write; the fake answers both.
    var selects = 0;
    var writes = 0;
    final fake = FakeTurso((statements) {
      final statement = statements.single;
      if (statement.startsWith('SELECT')) {
        selects++;
        return okRows(
          ['destination', 'data'],
          [
            [
              'Alexandria',
              jsonEncode([
                ['Comment', 'old'],
              ]),
            ],
          ],
        );
      }
      writes++;
      return okEmpty();
    });
    final repository = repositoryFor(fake);

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Beach day');
    await scrollTo(
      tester,
      find.widgetWithIcon(FilledButton, Icons.save_outlined),
    );
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    expect(selects, greaterThanOrEqualTo(1));
    expect(writes, greaterThanOrEqualTo(1));
    // Success shows in the field itself; the page does
    // not pop a "Saved" bar on every write -- the one
    // bar it pops is the failure.
    expect(find.text('Saved'), findsNothing);
    expect(find.text('Nothing written'), findsNothing);
  });

  testWidgets('a failed write pops the problem instead of staying silent', (
    tester,
  ) async {
    final fake = FakeTurso((statements) {
      final statement = statements.single;
      if (statement.startsWith('SELECT')) {
        return okRows(
          ['destination', 'data'],
          [
            [
              'Alexandria',
              jsonEncode([
                ['Comment', 'old'],
              ]),
            ],
          ],
        );
      }
      return pipelineError('read-only database');
    });
    final repository = repositoryFor(fake);

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Beach day');
    await scrollTo(
      tester,
      find.widgetWithIcon(FilledButton, Icons.save_outlined),
    );
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing written'), findsOneWidget);
  });

  testWidgets('the AI populate applies the profile and reports it', (
    tester,
  ) async {
    var writes = 0;
    final fake = FakeTurso((statements) {
      final statement = statements.single;
      if (statement.startsWith('SELECT')) {
        return okRows(
          ['destination', 'data'],
          [
            [
              'Alexandria',
              jsonEncode([
                ['Data Status', 'PLACEHOLDER'],
              ]),
            ],
          ],
        );
      }
      writes++;
      return okEmpty();
    });
    final repository = repositoryFor(fake);
    final client = DeepSeekClient(
      const AiConfig(apiKey: 'sk-test', model: 'deepseek-chat'),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'destination': 'Alexandria',
                    'country': 'Egypt',
                    'continent': 'Africa',
                    'profile': {
                      'why_to_go': 'A hill town of towers.',
                      'month_ratings': {'March': 'ideal'},
                    },
                  }),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria().withField(
            'data_status',
            'PLACEHOLDER - UPDATE REQUIRED',
          ),
          aiClient: client,
          aiConfig: const AiConfig(apiKey: 'sk-test'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The banner button runs the whole pipeline.
    await scrollTo(
      tester,
      find.widgetWithIcon(OutlinedButton, Icons.auto_awesome_outlined),
    );
    await tester.tap(
      find.widgetWithIcon(OutlinedButton, Icons.auto_awesome_outlined),
    );
    await tester.pumpAndSettle();

    expect(writes, greaterThanOrEqualTo(1));
    expect(find.text('Populated with DeepSeek AI'), findsOneWidget);
    await scrollTo(tester, find.text('A hill town of towers.'));
    expect(find.text('A hill town of towers.'), findsOneWidget);
  });

  testWidgets('the research flag toggles', (tester) async {
    var writes = 0;
    final fake = FakeTurso((statements) {
      final statement = statements.single;
      if (statement.startsWith('SELECT')) {
        return okRows(
          ['destination', 'data'],
          [
            ['Alexandria', jsonEncode(const [])],
          ],
        );
      }
      writes++;
      return okEmpty();
    });
    final repository = repositoryFor(fake);

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The researched flag is an icon toggle: off -> on writes the flag.
    await scrollTo(tester, find.byTooltip('Researched'));
    await tester.tap(find.byTooltip('Researched'));
    await tester.pumpAndSettle();

    expect(writes, greaterThanOrEqualTo(1));
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('clearing a comment asks before deleting it', (tester) async {
    var writes = 0;
    final fake = FakeTurso((statements) {
      final statement = statements.single;
      if (statement.startsWith('SELECT')) {
        return okRows(
          ['destination', 'data'],
          [
            [
              'Alexandria',
              jsonEncode([
                ['Comment', 'old'],
              ]),
            ],
          ],
        );
      }
      writes++;
      return okEmpty();
    });
    final repository = repositoryFor(fake);

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Empty the box and save: the legacy asks first.
    await scrollTo(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), '');
    await scrollTo(
      tester,
      find.widgetWithIcon(FilledButton, Icons.save_outlined),
    );
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    // The confirmation dialog, not a silent delete.
    expect(find.text('Delete the comment?'), findsOneWidget);
    expect(writes, 0);

    // "Keep it" leaves the comment alone.
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(writes, 0);

    // Saving empty again, then confirming, deletes it.
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.save_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, delete it'));
    await tester.pumpAndSettle();
    expect(writes, greaterThanOrEqualTo(1));
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('no matching photo keeps the typography header', (tester) async {
    final dir = Directory.systemTemp.createTempSync('banner_empty_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final repository = repositoryFor(
      FakeTurso((_) => okRows(['destination'], [])),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
          picturesDir: dir.path,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No photo decoded anywhere (the map's tile images fail
    // on purpose in tests and never decode); the header
    // falls back to the typography.
    expect(find.byType(RawImage), findsNothing);
    expect(find.text('Egypt'), findsOneWidget);
  });

  testWidgets('credited cached photos fill the hero after curated photos', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('gallery_hero_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final entry = GalleryEntry(
      imageUrl: 'https://images.unsplash.com/hero-photo',
      photoId: 'hero-photo',
      caption: 'Hero Photographer',
      source: 'Unsplash',
      photographerUrl: 'https://unsplash.com/@hero',
      photoPageUrl: 'https://unsplash.com/photos/hero',
    );
    final cache = _MemoryGalleryCache()..entries = [entry];
    final provider = _FakePhotoSearchProvider('missing-gallery-fixture.png');
    final repository = repositoryFor(
      FakeTurso((_) => okRows(['destination'], [])),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          key: const ValueKey('gallery-hero'),
          repository: repository,
          destination: alexandria(),
          photoSearchProvider: provider,
          galleryCache: cache,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hero Photographer'), findsOneWidget);
    expect(provider.requestedPages, isEmpty);

    File('${dir.path}/Alexandria_1.jpg').writeAsBytesSync([0, 1, 2]);
    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          key: const ValueKey('curated-hero'),
          repository: repository,
          destination: alexandria(),
          picturesDir: dir.path,
          bannerPhotoPath: '${dir.path}/Alexandria_1.jpg',
          photoSearchProvider: provider,
          galleryCache: cache,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final curatedBanner = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is FileImage &&
          (widget.image as FileImage).file.path.endsWith('Alexandria_1.jpg'),
    );
    for (
      var attempt = 0;
      attempt < 20 && curatedBanner.evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(curatedBanner, findsOneWidget);
    expect(provider.requestedPages, isEmpty);
  });

  testWidgets('gallery search and per-image replacement are user initiated', (
    tester,
  ) async {
    final provider = _FakePhotoSearchProvider('missing-gallery-fixture.png');
    final cache = _MemoryGalleryCache();
    final repository = repositoryFor(
      FakeTurso((_) => okRows(['destination'], [])),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
          picturesDir: '',
          photoSearchProvider: provider,
          galleryCache: cache,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(provider.requestedPages, isEmpty);

    await scrollTo(tester, find.text('Gallery'));
    await tester.pumpAndSettle();
    expect(
      find.text('Find photos'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join(' | '),
    );
    await tester.tap(find.text('Find photos'));
    await tester.pumpAndSettle();
    expect(provider.requestedPages, [1]);
    expect(provider.requestedQueries, ['Alexandria, Egypt']);
    expect(find.text('Photographer first'), findsOneWidget);

    await tester.tap(find.byTooltip('Replace photo').first);
    await tester.pumpAndSettle();
    expect(provider.requestedPages, [1, 2]);
    expect(find.text('Photographer replacement'), findsOneWidget);
    expect(find.text('Photographer first'), findsNothing);

    final saved = await cache.load('Alexandria');
    expect(saved, hasLength(2));
    expect(saved!.first.photoId, 'replacement');
    expect(saved.first.caption, 'Photographer replacement');
  });
  testWidgets('the visited toggle writes the flag and shows a footstep',
      (tester) async {
    // The visited marker is a walking person, not a plain
    // circle: a circle is what every other round icon on
    // the page is, and the meaning was lost (the user, 2026-10-20).
    var writes = 0;
    final fake = FakeTurso((statements) {
      final statement = statements.single;
      if (statement.startsWith('SELECT')) {
        return okRows(
          ['destination', 'data'],
          [
            ['Alexandria', jsonEncode(const [])],
          ],
        );
      }
      writes++;
      return okEmpty();
    });
    final repository = repositoryFor(fake);

    await tester.pumpWidget(
      MaterialApp(
        home: DestinationPage(
          repository: repository,
          destination: alexandria(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Not visited yet: the outlined walker.
    final visited = find.byTooltip('Visited');
    expect(visited, findsOneWidget);
    expect(
      find.descendant(
        of: visited,
        matching: find.byIcon(Icons.directions_walk_outlined),
      ),
      findsOneWidget,
    );

    await tester.tap(visited);
    await tester.pumpAndSettle();

    expect(writes, greaterThanOrEqualTo(1), reason: 'the flag was written');
    expect(
      find.descendant(
        of: find.byTooltip('Visited'),
        matching: find.byIcon(Icons.directions_walk),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Add to drawer button toggles label', (tester) async {
    final added = <String>[];
    final repository = repositoryFor(FakeTurso((_) => okRows(['destination'], [])));
    final dest = alexandria();
    await tester.pumpWidget(MaterialApp(
      home: DestinationPage(
        repository: repository,
        destination: dest,
        initiallyInOpenTabs: false,
        onAddToOpenTabs: added.add,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Add to drawer'), findsOneWidget);
    await tester.tap(find.text('Add to drawer'));
    await tester.pumpAndSettle();
    expect(find.text('Shown on the drawer'), findsOneWidget);
    expect(added, ['Alexandria']);
  });
}
