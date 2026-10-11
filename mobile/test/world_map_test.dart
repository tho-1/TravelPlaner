/// The map widget: marker placement from the projection,
/// and the graceful tile failure (the offline case).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/geo.dart';
import 'package:travel_planner/ui/world_map_page.dart';

void main() {
  testWidgets('markers are placed and labelled', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorldMapView(
          latitude: 31.2,
          longitude: 29.9,
          zoom: 6,
          markers: const [
            MapMarker(
              latitude: 31.2001,
              longitude: 29.9187,
              label: 'Alexandria',
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Alexandria'), findsOneWidget);
    expect(find.byIcon(Icons.location_on), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the tile URLs follow the slippy-map scheme', () {
    expect(tileUrl(0, 0, 0), 'https://tile.openstreetmap.org/0/0/0.png');
    expect(tileUrl(6, 33, 22), 'https://tile.openstreetmap.org/6/33/22.png');
  });

  test('the world at zoom 2 is a 4x4 mosaic', () {
    // One tile per quarter of the world.
    expect(tileFor(85, -180, 2), (zoom: 2, x: 0, y: 0));
    expect(tileFor(-85, 179, 2), (zoom: 2, x: 3, y: 3));
  });
}
