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
import 'package:travel_planner/data/geocode_repository.dart';
import 'package:travel_planner/data/trip_repository.dart';
import 'package:travel_planner/data/weekend_repository.dart';
import 'package:travel_planner/models/timetable.dart';
import 'package:travel_planner/models/weekend_match.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Render one screen at phone width and assert the
  /// framework threw nothing (a render overflow is an
  /// exception, not a silent clip).
  Future<void> render(WidgetTester tester, Widget screen) async {
    _setSurface(tester, _phone);
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

  testWidgets('the catalogue renders its country groups on a wide window',
      (tester) async {
    // The legacy overview's structure: country
    // sections with counts, the destinations in
    // a multi-column grid. Rendered wide so the
    // grid path (not just the phone's single
    // column) is exercised.
    _setSurface(tester, const Size(1200, 900));
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'data'],
          [
            for (final row in [
              ['Alexandria', 'Egypt', jsonEncode([['Why to Go There', 'x']])],
              ['Rome', 'Italy', jsonEncode(const [])],
              ['Milan', 'Italy', jsonEncode(const [])],
            ])
              row,
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      theme: _themeFor(),
      home: CataloguePage(
        repository: DestinationRepository(
          TursoClient(_config, httpClient: fake.client()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Each country's header carries its count.
    expect(find.text('Egypt'), findsOneWidget);
    expect(find.text('(1)'), findsOneWidget);
    expect(find.text('Italy'), findsOneWidget);
    expect(find.text('(2)'), findsOneWidget);
    expect(find.text('Rome'), findsOneWidget);
    expect(find.text('Milan'), findsOneWidget);
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

  testWidgets('the weekend finder searches and shows the summary table',
      (tester) async {
    // The search runs on an injected board (no network);
    // the airport table is installed so the lookup needs
    // no asset. The benefits come from the seed list
    // (the config carries no benefits URL), so the
    // carrier is spelled the way the seed spells it.
    AirportLookup.installForTesting({'LHR': ('London', 'GB')});
    final fake = FakeTurso((_) => okRows(['destination'], []));
    final repository =
        DestinationRepository(TursoClient(_config, httpClient: fake.client()));
    await render(
      tester,
      WeekendFinderPage(
        benefits: BenefitsRepository(_config, httpClient: fake.client()),
        destinations: repository,
        board: _FakeBoard(),
      ),
    );
    // The cards stack taller than a phone screen;
    // scroll to the button before tapping it.
    await tester.drag(
        find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find weekends'));
    await tester.pumpAndSettle();
    // The report lands below the fold; a ListView
    // builds its children lazily, so scroll it into
    // view before asserting on it.
    await tester.drag(
        find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    // The summary table (City, Options, Earliest out,
    // Nights, Airlines) above the per-city cards.
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('London (GB)'), findsWidgets);
    expect(find.text('LH1000 · Lufthansa'), findsWidgets);
    expect(find.text('LH2000 · Lufthansa'), findsWidgets);
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

  /// The trips editor: the trips repository, the
  /// catalogue the add-stop panel and the month
  /// suggestions read, and a cache-less geocoder.
  TripsPage tripsPage(FakeTurso fake) => TripsPage(
        repository: TripRepository(
            TursoClient(_config, httpClient: fake.client())),
        destinations: DestinationRepository(
            TursoClient(_config, httpClient: fake.client())),
        geocoder: GeocodeRepository(''),
      );

  testWidgets('the trips page renders its problem view', (tester) async {
    final fake = FakeTurso((_) => pipelineError('trips table missing'));
    await render(tester, tripsPage(fake));
  });

  testWidgets('the trips page renders the editor with a route',
      (tester) async {
    final fake = FakeTurso((statements) {
      // The trips load pipeline: four SELECTs in one
      // request, answered with four results.
      if (statements.length == 4 &&
          statements.first.startsWith('SELECT * FROM trips')) {
        return okMulti([
          (['id', 'name', 'created', 'active_variant_id'], [
            ['t1', 'Italy 2026', '2026-01-01T10:00:00', 'v1'],
          ]),
          (['id', 'trip_id', 'name', 'notes', 'rating', 'months',
            'comment'], [
            ['v1', 't1', 'Two cities', 'notes', 4,
                '["April","May"]', ''],
          ]),
          (['id', 'variant_id', 'kind', 'name', 'country', 'lat',
            'lon', 'role', 'arrival_date', 'departure_date',
            'arrival_time', 'departure_time', 'nights', 'notes'], [
            [
              's1', 'v1', 'gateway', 'Frankfurt', 'Germany', 50.11,
              8.68, 'origin', null, '2027-04-01', null, '18:45',
              null, ''
            ],
            [
              's2', 'v1', 'destination', 'Rome', 'Italy', 41.9, 12.5,
              'stop', '2027-04-01', '2027-04-04', '09:30', '18:00',
              3, 'colosseum'
            ],
            [
              's3', 'v1', 'destination', 'Florence', 'Italy', 43.77,
              11.26, 'stop', '2027-04-04', '2027-04-06', '09:00',
              null, 2, ''
            ],
          ]),
          (['variant_id', 'position', 'mode', 'note'], [
            ['v1', 0, 'flight', ''],
            ['v1', 1, 'train', ''],
          ]),
        ]);
      }
      if (statements.first.startsWith('SELECT * FROM destinations')) {
        return okRows(
          ['destination', 'country', 'data'],
          [
            ['Rome', 'Italy', jsonEncode([
              ['Destination', 'Rome'],
              ['April', 'ideal'],
            ])],
          ],
        );
      }
      return pipelineError('unexpected statement');
    });
    await render(tester, tripsPage(fake));
    // The editor shows the trip, its stops and the
    // transport legs, not a "read-only" hint. The
    // stop cards carry the index and the country
    // ("1. Frankfurt · Germany"), so the city
    // names are matched by content.
    expect(find.text('Italy 2026'), findsWidgets);
    expect(find.textContaining('Frankfurt'), findsWidgets);
    expect(find.textContaining('Rome'), findsWidgets);
    expect(find.textContaining('Florence'), findsWidgets);
    expect(find.byType(TabBar), findsOneWidget);
  });

  testWidgets('the trips page backs up all trips as JSON',
      (tester) async {
    final fake = FakeTurso((statements) {
      // The trips load pipeline: four SELECTs in
      // one request, answered with four results.
      if (statements.length == 4 &&
          statements.first.startsWith('SELECT * FROM trips')) {
        return okMulti([
          (['id', 'name', 'created', 'active_variant_id'], [
            ['t1', 'Italy 2026', '2026-01-01T10:00:00', 'v1'],
          ]),
          (['id', 'trip_id', 'name', 'notes', 'rating', 'months',
            'comment'], [
            ['v1', 't1', 'Two cities', '', 4, '[]', ''],
          ]),
          (['id', 'variant_id', 'kind', 'name', 'country', 'lat',
            'lon', 'role', 'arrival_date', 'departure_date',
            'arrival_time', 'departure_time', 'nights', 'notes'], []),
          (['variant_id', 'position', 'mode', 'note'], []),
        ]);
      }
      return okEmpty(4);
    });
    await render(tester, tripsPage(fake));
    // The backup action -- the legacy sidebar's
    // workbook download in its Turso-world
    // shape -- shows the whole store as JSON.
    await tester.tap(find.byIcon(Icons.download));
    await tester.pumpAndSettle();
    expect(find.text('Backup all trips'), findsOneWidget);
    expect(find.textContaining('"schema_version": 1'),
        findsOneWidget);
    expect(find.textContaining('"name": "Italy 2026"'),
        findsOneWidget);
    // The dialog's Copy sits alongside the trip
    // and variant duplicate buttons, which share
    // the label.
    expect(find.text('Copy'), findsWidgets);
  });

  testWidgets('the trips page renders the compare tab', (tester) async {
    final fake = FakeTurso((statements) {
      // The trips load pipeline: four SELECTs in one
      // request, answered with four results.
      if (statements.length == 4 &&
          statements.first.startsWith('SELECT * FROM trips')) {
        return okMulti([
          (['id', 'name', 'created', 'active_variant_id'], [
            ['t1', 'Italy 2026', '2026-01-01T10:00:00', 'v1'],
          ]),
          (['id', 'trip_id', 'name', 'notes', 'rating', 'months',
            'comment'], [
            ['v1', 't1', 'Two cities', '', 4, '[]', ''],
            ['v2', 't1', 'Two cities alt', '', 3, '[]', ''],
          ]),
          (['id', 'variant_id', 'kind', 'name', 'country', 'lat',
            'lon', 'role', 'arrival_date', 'departure_date',
            'arrival_time', 'departure_time', 'nights', 'notes'], []),
          (['variant_id', 'position', 'mode', 'note'], []),
        ]);
      }
      return okEmpty(4);
    });
    await render(tester, tripsPage(fake));
    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('Two cities alt'), findsWidgets);
  });

  testWidgets('the app shell renders all tabs', (tester) async {
    _setSurface(tester, _phone);
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
    expect(find.byType(NavigationRail), findsNothing);
    // The tab label and the app bar share the word.
    expect(find.text('Catalogue'), findsWidgets);
    expect(find.text('Map'), findsWidgets);
    expect(find.text('Finder'), findsWidgets);
  });

  testWidgets('the shell switches to the rail on wide windows',
      (tester) async {
    _setSurface(tester, const Size(1200, 900));
    await tester.pumpWidget(MaterialApp(
      theme: _themeFor(),
      darkTheme: _themeFor(brightness: Brightness.dark),
      home: const HomeShell(config: _config),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The desktop layout: a side rail, no bottom bar,
    // and the content constrained to a column.
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Catalogue'), findsWidgets);
    expect(find.text('Map'), findsWidgets);
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

/// Set the test surface to [size]. The old
/// `binding.setSurfaceSize` is deprecated and a
/// no-op in this Flutter version, so the view's
/// physical size is set directly — without this,
/// every "phone-width" test here would actually
/// render at the 800x600 default.
void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
  });
}

/// A board that answers the weekend finder's five
/// queries with one qualifying pair: a Lufthansa
/// outbound on the Friday and a Lufthansa return on
/// the Saturday, whichever weekend the page is on.
class _FakeBoard implements FlightBoardProvider {
  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    if (direction == 'departures') {
      if (day.weekday != DateTime.friday) {
        return _empty();
      }
      return FetchResult(
        flights: [
          Flight(
            flightNo: 'LH1000',
            airline: 'Lufthansa',
            origin: 'FRA',
            destination: 'LHR',
            departure: DateTime(day.year, day.month, day.day, 15, 10),
            arrival: DateTime(day.year, day.month, day.day, 15, 55),
          ),
        ],
        source: 'fake',
        fetchedAt: DateTime.now().toIso8601String(),
      );
    }
    if (day.weekday != DateTime.saturday) {
      return _empty();
    }
    return FetchResult(
      flights: [
        Flight(
          flightNo: 'LH2000',
          airline: 'Lufthansa',
          origin: 'LHR',
          destination: 'FRA',
          departure: DateTime(day.year, day.month, day.day, 17, 30),
          arrival: DateTime(day.year, day.month, day.day, 19, 30),
        ),
      ],
      source: 'fake',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }

  FetchResult _empty() => FetchResult(
        flights: const <Flight>[],
        source: 'fake',
        fetchedAt: DateTime.now().toIso8601String(),
      );
}
