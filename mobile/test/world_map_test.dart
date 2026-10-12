/// The map: the month-condition model, the geometry's lookup
/// and tap hit test, the projection, and the map widget's
/// markers and country fills.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/models/condition.dart';
import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/destination_profile.dart';
import 'package:travel_planner/models/geo.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';
import 'package:travel_planner/ui/world_map_page.dart';

import 'fake_turso.dart';

void main() {
  group('condition', () {
    test('the legacy synonyms map to the three buckets', () {
      for (final value in ['ideal', 'good', 'great', 'best', 'green', 'Ideal']) {
        expect(normalizeCondition(value), Condition.ideal, reason: value);
      }
      for (final value in ['ok', 'okay', 'medium', 'yellow', 'Ok']) {
        expect(normalizeCondition(value), Condition.ok, reason: value);
      }
      for (final value in ['bad', 'poor', 'red', 'worst']) {
        expect(normalizeCondition(value), Condition.bad, reason: value);
      }
      for (final value in ['', null, 'unknown', 'n/a', 'whatever']) {
        expect(normalizeCondition(value), Condition.unknown, reason: '$value');
      }
    });

    test('the palette is the legacy hex set', () {
      expect(Condition.ideal.colorValue, 0xFF2ECC71);
      expect(Condition.ok.colorValue, 0xFFF1C40F);
      expect(Condition.bad.colorValue, 0xFFE74C3C);
      expect(Condition.unknown.colorValue, 0xFF95A5A6);
    });

    test('a country takes its best condition for the month', () {
      expect(countryCondition([Condition.bad, Condition.ideal]),
          Condition.ideal);
      expect(countryCondition([Condition.bad, Condition.ok]), Condition.ok);
      expect(countryCondition([Condition.bad, Condition.unknown]),
          Condition.bad);
      expect(countryCondition(const []), Condition.unknown);
      expect(countryCondition([Condition.unknown, Condition.unknown]),
          Condition.unknown);
    });

    test('a month rating is the same bucket the profile parses', () {
      final profile = DestinationProfile.from(Destination(
        core: const {'destination': 'X', 'country': 'Y'},
        columns: const [('March', 'great'), ('April', 'meh')],
      ));
      expect(conditionOfMonth(profile.months[2]), Condition.ideal);
      expect(conditionOfMonth(profile.months[3]), Condition.unknown);
    });
  });

  group('point in country', () {
    // A square from 0 to 10 in both axes.
    const square = [
      [
        [0.0, 0.0],
        [10.0, 0.0],
        [10.0, 10.0],
        [0.0, 10.0],
      ],
    ];

    test('inside and outside decide correctly', () {
      expect(pointInCountry(5, 5, square), isTrue);
      expect(pointInCountry(15, 5, square), isFalse);
      expect(pointInCountry(-1, 5, square), isFalse);
    });

    test('a ring that straddles the antimeridian still contains its point', () {
      // Fiji-like: from 170E to -170W.
      const straddle = [
        [
          [170.0, 0.0],
          [-170.0, 0.0],
          [-170.0, 10.0],
          [170.0, 10.0],
        ],
      ];
      expect(pointInCountry(175, 5, straddle), isTrue);
      expect(pointInCountry(-175, 5, straddle), isTrue);
      expect(pointInCountry(0, 5, straddle), isFalse);
    });
  });

  group('projection', () {
    test('the tile URLs follow the slippy-map scheme', () {
      expect(tileUrl(0, 0, 0), 'https://tile.openstreetmap.org/0/0/0.png');
      expect(tileUrl(6, 33, 22), 'https://tile.openstreetmap.org/6/33/22.png');
    });

    test('the world at zoom 2 is a 4x4 mosaic', () {
      expect(tileFor(85, -180, 2), (zoom: 2, x: 0, y: 0));
      expect(tileFor(-85, 179, 2), (zoom: 2, x: 3, y: 3));
    });
  });

  testWidgets('the map renders its markers and fills', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorldMapView(
          latitude: 31.2,
          longitude: 29.9,
          zoom: 4,
          cities: const [
            MapCity(
              latitude: 30.0444,
              longitude: 31.2357,
              name: 'Cairo',
              country: 'Egypt',
              condition: Condition.ideal,
              filteredOut: false,
            ),
            MapCity(
              latitude: 35.6762,
              longitude: 139.6503,
              name: 'Tokyo',
              country: 'Japan',
              condition: Condition.bad,
              filteredOut: false,
            ),
          ],
          countryFills: const {
            'Egypt': Colors.green,
            'Japan': Colors.red,
          },
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Cairo'), findsOneWidget);
    expect(find.text('Tokyo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the label toggle hides the city names', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorldMapView(
          latitude: 31.2,
          longitude: 29.9,
          zoom: 4,
          showCityLabels: false,
          cities: const [
            MapCity(
              latitude: 30.0444,
              longitude: 31.2357,
              name: 'Cairo',
              country: 'Egypt',
              condition: Condition.ideal,
              filteredOut: false,
            ),
          ],
          countryFills: const {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Cairo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page counts, filters and captions', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    // A tall surface: the caption sits below the map, and a
    // ListView builds lazily — a short viewport never
    // mounts it.
    await binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => binding.setSurfaceSize(null));
    // One destination per country, with a rating that is
    // the same in every month so the KPI counts do not
    // depend on when the suite runs. Alexandria is visited,
    // so the legacy default (only-unvisited) hides it.
    String months(String rating) => jsonEncode([
          for (final month in [
            'January', 'February', 'March', 'April', 'May', 'June', //
            'July', 'August', 'September', 'October', 'November', 'December',
          ])
            [month, rating],
        ]);
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['Alexandria', 'Egypt', 1, months('ideal')],
            ['Rome', 'Italy', null, months('ok')],
            ['Kyoto', 'Japan', null, months('bad')],
            ['Lima', 'Peru', null, months('best')],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: WorldMapPage(
        repository: DestinationRepository(
          TursoClient(
            const TursoConfig(
                url: 'https://travel-tz123.aws-eu-north-1.turso.io',
                token: 'token'),
            httpClient: fake.client(),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The country geometry resolves through the asset
    // channel after the first frame; give it a few frames
    // to land before the KPI assertions.
    for (var i = 0; i < 5 && find.text('4').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The legacy default hides the visited destination.
    expect(find.textContaining('3 of 4 destinations match the filters'),
        findsOneWidget);
    // The KPI cards render; the destination conditions are
    // one Ideal (Lima), one Ok (Rome) and one Bad (Kyoto)
    // over the visible rows.
    expect(find.text('Mapped countries'), findsOneWidget);
    expect(find.text('Ideal destinations'), findsOneWidget);
    expect(find.text('Ok destinations'), findsOneWidget);
    expect(find.text('Bad / off-season'), findsOneWidget);
    expect(find.text('1'), findsNWidgets(3));

    // The filter sheet opens and applies live.
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    expect(find.text('Only show unvisited'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Only show unvisited'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('4 of 4 destinations match the filters'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap on a country without destinations is ignored, '
      'a dataset spelling resolves to the catalogue', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => binding.setSurfaceSize(null));
    String months(String rating) => jsonEncode([
          for (final month in [
            'January', 'February', 'March', 'April', 'May', 'June', //
            'July', 'August', 'September', 'October', 'November', 'December',
          ])
            [month, rating],
        ]);
    // One country the catalogue holds ("United States",
    // with a city) and one it does not ("United States of
    // America" is only the dataset's shape name;
    // Antarctica has no destinations at all).
    final fake = FakeTurso((_) => okRows(
          ['destination', 'country', 'visited', 'data'],
          [
            ['New York', 'United States', null, months('ok')],
          ],
        ));
    await tester.pumpWidget(MaterialApp(
      home: WorldMapPage(
        repository: DestinationRepository(
          TursoClient(
            const TursoConfig(
                url: 'https://travel-tz123.aws-eu-north-1.turso.io',
                token: 'token'),
            httpClient: fake.client(),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5 && find.byType(WorldMapView).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The tap seam the geometry hit test drives: the name
    // that arrives is the shape's dataset name.
    final view = tester.widget<WorldMapView>(find.byType(WorldMapView));
    expect(view.onCountryTap, isNotNull);

    // Antarctica: no destinations -- the tap is ignored,
    // it must not throw the null check the old caption
    // carried.
    view.onCountryTap!('Antarctica');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('destinations in'), findsNothing);

    // The dataset's long spelling resolves to the
    // catalogue's "United States" and selects it.
    view.onCountryTap!('United States of America');
    await tester.pumpAndSettle();
    expect(find.textContaining('destinations in United States match'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
