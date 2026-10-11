/// Every screen renders without a layout or render error.
///
/// These tests exist because the most common crash on a
/// phone-width screen is a layout one: a `Row` that
/// overflows, or a stretched row inside a scrolling list
/// asking for an infinite height. Both happened, and both
/// were caught by rendering each screen here -- so the
/// tests render the real widgets with realistic data and
/// assert that nothing threw, rather than comparing
/// goldens (which are font- and platform-sensitive and
/// would fail on CI).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/benefits_repository.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/trip_repository.dart';
import 'package:travel_planner/ui/catalogue_page.dart';
import 'package:travel_planner/ui/destination_page.dart';
import 'package:travel_planner/ui/main.dart';
import 'package:travel_planner/ui/trips_page.dart';
import 'package:travel_planner/ui/weekend_finder_page.dart';
import 'package:travel_planner/ui/world_map_page.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';

import 'fake_turso.dart';
import 'destination_page_test.dart' show alexandria;

/// A phone-width surface: the layout bugs this suite guards
/// against only show up when the screen is narrow.
const _phone = Size(420, 1100);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  /// Render one screen at phone width and assert the
  /// framework threw nothing (a render overflow is an
  /// exception, not a silent clip).
  Future<void> render(WidgetTester tester, Widget screen) async {
    await binding.setSurfaceSize(_phone);
    await tester.pumpWidget(MaterialApp(
      theme: _themeFor(),
      darkTheme: _themeFor(brightness: Brightness.dark),
      home: screen,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('the catalogue renders', (tester) async {
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'data'],
          [
            for (final row in [
              ['Alexandria', 'Egypt', jsonEncode([['Why to Go There', 'x']])],
              ['Kyoto', 'Japan', jsonEncode(const [])],
              ['Kyiv', 'Ukraine', jsonEncode(const [])],
              ['Lisbon', 'Portugal', jsonEncode(const [])],
              ['Madrid', 'Spain', jsonEncode(const [])],
              ['Rome', 'Italy', jsonEncode(const [])],
            ])
              row,
          ],
        ));
    await render(
        tester,
        CataloguePage(
          repository: DestinationRepository(
            TursoClient(_config, httpClient: fake.client()),
          ),
        ));
  });

  testWidgets('the catalogue renders its problem view', (tester) async {
    // The problem card is where a long title used to
    // overflow; the card must wrap it instead.
    final fake = FakeTurso((_) => pipelineError(
        'the benefits database could not be reached over a long stretch of '
        'text that does not fit on one line of a phone-width card'));
    await render(
        tester,
        CataloguePage(
          repository: DestinationRepository(
            TursoClient(_config, httpClient: fake.client()),
          ),
        ));
  });

  testWidgets('the destination detail renders', (tester) async {
    await render(
      tester,
      DestinationPage(
        repository: DestinationRepository(
          TursoClient(_config,
              httpClient: FakeTurso((_) => okRows(['destination'], [])).client()),
        ),
        destination: alexandria(),
      ),
    );
  });

  testWidgets('the weekend finder renders', (tester) async {
    final fake = FakeTurso((_) => okRows(['destination'], []));
    final repository =
        DestinationRepository(TursoClient(_config, httpClient: fake.client()));
    await render(
      tester,
      WeekendFinderPage(
        benefits: BenefitsRepository(_config, httpClient: fake.client()),
        destinations: repository,
      ),
    );
  });

  testWidgets('the world map renders', (tester) async {
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'data'],
          [
            for (final name in ['Alexandria', 'Rome', 'Kyoto', 'Lima'])
              [name, 'X', jsonEncode(const [])],
          ],
        ));
    final repository =
        DestinationRepository(TursoClient(_config, httpClient: fake.client()));
    await render(tester, WorldMapPage(repository: repository));
  });

  testWidgets('the trips page renders its problem view', (tester) async {
    final fake = FakeTurso((_) => pipelineError('trips table missing'));
    await render(
      tester,
      TripsPage(
        repository:
            TripRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    );
  });

  testWidgets('the trips page renders with data', (tester) async {
    final fake = FakeTurso((_) => okRows(
          ['trip_id', 'name', 'data'],
          [
            [
              't1',
              'Italy 2026',
              jsonEncode({
                'name': 'Italy 2026',
                'variants': [
                  {
                    'name': 'Two cities',
                    'stops': [
                      {
                        'ref': {
                          'kind': 'destination',
                          'name': 'Rome',
                          'country': 'Italy',
                        },
                        'nights': 3,
                      },
                      {
                        'ref': {
                          'kind': 'destination',
                          'name': 'Florence',
                          'country': 'Italy',
                        },
                        'nights': 3,
                      },
                    ],
                    'legs': [
                      {
                        'from': 'FRA',
                        'to': 'FCO',
                        'mode': 'Flight',
                      },
                    ],
                  },
                ],
              }),
            ],
          ],
        ));
    await render(
      tester,
      TripsPage(
        repository:
            TripRepository(TursoClient(_config, httpClient: fake.client())),
      ),
    );
  });

  testWidgets('the app shell renders all tabs', (tester) async {
    await binding.setSurfaceSize(_phone);
    // The shell builds its own repository from the config,
    // so in a test itsTurso calls answer with the test
    // binding's 400 -- the pages then render their problem
    // views, which is exactly the layout this suite guards.
    await tester.pumpWidget(MaterialApp(
      theme: _themeFor(),
      darkTheme: _themeFor(brightness: Brightness.dark),
      home: const HomeShell(config: _config),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
    // The tab label and the app bar share the word.
    expect(find.text('Catalogue'), findsWidgets);
    expect(find.text('Map'), findsWidgets);
    expect(find.text('Finder'), findsWidgets);
  });
}

const _config = TursoConfig(
  url: 'https://travel-tz123.aws-eu-north-1.turso.io',
  token: 'token',
);

ThemeData _themeFor({Brightness brightness = Brightness.light}) =>
    ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0E7C86),
        brightness: brightness,
      ),
    );
