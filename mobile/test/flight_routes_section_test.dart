/// The transport routes section: the research
/// button, the airport card, and the flights
/// and high-speed trains tables -- against a
/// scripted cache directory and a scripted
/// DeepSeek response.
///
/// The section is a StatefulWidget with test
/// seams (cache directory, AI client), so the
/// whole flow -- cache read, research, filter,
/// search, tab switch, wishlist link -- runs
/// here without the network or the real config.
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
import 'package:travel_planner/data/flight_routes.dart';
import 'package:travel_planner/data/flight_routes_repository.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';
import 'package:travel_planner/ui/flight_routes_section.dart';

import 'fake_turso.dart';
import 'destination_page_test.dart' show alexandria;

const _config = TursoConfig(
  url: 'https://db.example.turso.io',
  token: 'token',
);

/// The catalogue the planner lookup is built
/// from: Cairo is in the planner (typed Prio 6,
/// tail Reviews 7). Athens is deliberately
/// absent, so it is the unmatched city the
/// table shows the dash for. The typed `prio`
/// column is what the table's Prio cell reads,
/// exactly like a real `SELECT *` row.
FakeTurso _catalogue() => FakeTurso((_) => okRows(
      ['destination', 'country', 'prio', 'data'],
      [
        [
          'Alexandria',
          'Egypt',
          8,
          jsonEncode([['Reviews', 7.5]])
        ],
        ['Cairo', 'Egypt', 6, jsonEncode([['Reviews', 7]])],
      ],
    ));

/// The cached research for Alexandria: Cairo
/// (75 min, in the planner) and Athens
/// (130 min, not in the planner).
Map<String, dynamic> _cacheJson() => {
      'city': 'Alexandria',
      'country': 'Egypt',
      'airport_name': 'Borg El Arab Airport',
      'iata_code': 'HBE',
      'last_updated': '11 Oct 2026',
      'routes': [
        {
          'destination_city': 'Athens',
          'destination_country': 'Greece',
          'destination_iata': 'ATH',
          'flight_time': '2h 10m',
          'airlines': ['Aegean Airlines'],
          'frequency_notes': 'Daily',
        },
        {
          'destination_city': 'Cairo',
          'destination_country': 'Egypt',
          'destination_iata': 'CAI',
          'flight_time': '1h 15m',
          'airlines': ['EgyptAir', 'Nile Air'],
          'frequency_notes': 'Daily',
        },
      ],
    };

Destination beijing() => Destination(
      core: {
        'destination': 'Beijing',
        'country': 'China',
        'continent': 'Asia',
      },
      columns: const [
        ('Destination', 'Beijing'),
        ('Country', 'China'),
      ],
    );

/// The cached research for Beijing: one HSR
/// connection and the station list.
Map<String, dynamic> _chinaCacheJson() => {
      'city': 'Beijing',
      'country': 'China',
      'airport_name': 'Beijing Capital International Airport',
      'iata_code': 'PEK',
      'last_updated': '11 Oct 2026',
      'routes': const [],
      'hsr_routes': [
        {
          'destination_city': 'Shanghai',
          'destination_station': 'Shanghai Hongqiao',
          'duration': '4h 18m',
          'train_types': 'G-Train',
          'frequency_notes': 'Hourly',
        },
      ],
      'train_stations': ['Beijing South', 'Beijing West'],
    };

/// A writable cache directory that is removed
/// again when the test ends.
String _tempCacheDir() {
  final dir = Directory.systemTemp.createTempSync();
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

Future<void> _pump(
  WidgetTester tester, {
  required String cacheDir,
  required Destination destination,
  DeepSeekClient? aiClient,
  void Function(Destination)? onOpenDestination,
}) async {
  tester.view.physicalSize = const Size(420, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
  });
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      // The destination page hosts its sections in a
      // scrollable; the bare section must be too, or
      // the tall tables overflow the phone surface.
      body: SingleChildScrollView(
        child: FlightRoutesSection(
          repository: DestinationRepository(
            TursoClient(_config, httpClient: _catalogue().client()),
          ),
          destination: destination,
          onOpenDestination: onOpenDestination,
          cacheDir: cacheDir,
          // The bundled loaders read through
          // rootBundle, whose cache never
          // completes a second load inside
          // the test binding — so the config
          // and the colors are injected.
          config: _config,
          colors: const AirlineColors({}),
          aiClient: aiClient,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the empty state offers the research button',
      (tester) async {
    final dir = _tempCacheDir();
    await _pump(tester, cacheDir: dir, destination: alexandria());
    expect(find.text('Research Flight Connections'),
        findsOneWidget);
    expect(
      find.text('Research all direct flight routes '
          '(inbound & outbound) for Alexandria.'),
      findsOneWidget,
    );
    expect(find.text('Transport & Direct Connections'),
        findsOneWidget);
  });

  testWidgets('a China destination offers the combined research',
      (tester) async {
    final dir = _tempCacheDir();
    await _pump(tester, cacheDir: dir, destination: beijing());
    expect(find.text('Research Flights & Trains'), findsOneWidget);
  });

  testWidgets('the cached research renders the airport card '
      'and the duration-sorted table', (tester) async {
    final dir = _tempCacheDir();
    FlightRoutesRepository(dir).save('Alexandria', _cacheJson());
    await _pump(tester, cacheDir: dir, destination: alexandria());

    expect(find.text('Last updated: 11 Oct 2026'), findsOneWidget);
    expect(find.text('Primary Airport (Inbound & Outbound '
        'Direct Flights)'), findsOneWidget);
    expect(find.text('Borg El Arab Airport'), findsOneWidget);
    expect(find.text('HBE'), findsOneWidget);

    // Sorted by duration: Cairo (75 min) before Athens (130 min).
    expect(find.text('Cairo'), findsOneWidget);
    expect(find.text('1h 15m'), findsOneWidget);
    // The airlines are separate cells, comma-separated.
    expect(find.text('EgyptAir'), findsOneWidget);
    expect(find.text('Nile Air'), findsOneWidget);
    // The catalogue match carries Prio and Reviews; the
    // unmatched city shows the dash (wishlist, Prio and
    // Reviews of the Athens row).
    expect(find.text('6/10'), findsOneWidget);
    expect(find.text('7/10'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(3));
  });

  testWidgets('the In Planner filter narrows the table',
      (tester) async {
    final dir = _tempCacheDir();
    FlightRoutesRepository(dir).save('Alexandria', _cacheJson());
    await _pump(tester, cacheDir: dir, destination: alexandria());
    await tester.tap(find.text('In Planner (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Cairo'), findsOneWidget);
    expect(find.text('Athens'), findsNothing);
  });

  testWidgets('the search narrows the table and says when '
      'nothing matches', (tester) async {
    final dir = _tempCacheDir();
    FlightRoutesRepository(dir).save('Alexandria', _cacheJson());
    await _pump(tester, cacheDir: dir, destination: alexandria());

    await tester.enterText(find.byType(TextField), 'athens');
    await tester.pumpAndSettle();
    expect(find.text('Athens'), findsOneWidget);
    expect(find.text('Cairo'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(
        find.text('No flight routes match the current filter/search.'),
        findsOneWidget);
  });

  testWidgets('a China destination shows the trains tab',
      (tester) async {
    final dir = _tempCacheDir();
    FlightRoutesRepository(dir)
        .save('Beijing', _chinaCacheJson());
    await _pump(tester, cacheDir: dir, destination: beijing());

    expect(find.text('Direct Flights (0)'), findsOneWidget);
    expect(find.text('High-Speed Trains (1)'), findsOneWidget);
    await tester.tap(find.text('High-Speed Trains (1)'));
    await tester.pumpAndSettle();

    expect(find.text('CHINA HIGH-SPEED RAIL HUB (CRH / 高铁)'),
        findsOneWidget);
    // The station list carries the legacy's emoji prefix.
    expect(find.text('🚄 Beijing South, Beijing West'),
        findsOneWidget);
    expect(find.text('Shanghai'), findsOneWidget);
    expect(find.text('Shanghai Hongqiao'), findsOneWidget);
    expect(find.text('4h 18m'), findsOneWidget);
    expect(find.text('G-Train'), findsOneWidget);
  });

  testWidgets('the research button asks DeepSeek and caches '
      'the result', (tester) async {
    final dir = _tempCacheDir();
    final client = DeepSeekClient(
      const AiConfig(apiKey: 'sk-test'),
      httpClient: MockClient((request) async {
        final body = jsonEncode({
          'choices': [
            {'message': {'content': jsonEncode(_cacheJson())}}
          ]
        });
        return http.Response(body, 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    await _pump(
        tester,
        cacheDir: dir,
        destination: alexandria(),
        aiClient: client);

    await tester.tap(find.text('Research Flight Connections'));
    await tester.pumpAndSettle();

    expect(find.text('Borg El Arab Airport'), findsOneWidget);
    expect(find.text('Transport connections updated'),
        findsOneWidget);
    // The result landed in the per-destination cache file.
    expect(File('$dir/alexandria.json').existsSync(), isTrue);
  });

  testWidgets('the wishlist link opens the matching destination',
      (tester) async {
    final dir = _tempCacheDir();
    FlightRoutesRepository(dir).save('Alexandria', _cacheJson());
    Destination? opened;
    await _pump(
        tester,
        cacheDir: dir,
        destination: alexandria(),
    onOpenDestination: (destination) => opened = destination);

    // The table is wider than the phone surface;
    // the Wishlist column is off-screen to the
    // right, so scroll it into view before
    // tapping — a tap at an off-screen
    // coordinate never reaches the button.
    final link = find.text('In Planner');
    await tester.scrollUntilVisible(
      link,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened!.name, 'Cairo');
  });
}
