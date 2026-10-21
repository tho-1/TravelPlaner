import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/route_geo.dart';

void main() {
  test('unwrapLongitudes keeps a transpacific hop continuous', () {
    final points = [
      (lat: 35.0, lon: 139.0),
      (lat: 34.0, lon: -118.0),
    ];
    final unwrapped = unwrapLongitudes(points);
    expect(unwrapped[1].lon, greaterThan(180));
  });

  test('fitView returns a non-empty box', () {
    final view = fitView([(lat: 10.0, lon: 20.0), (lat: 12.0, lon: 22.0)]);
    expect(view.longitudeMax, greaterThan(view.longitudeMin));
    expect(view.latitudeMax, greaterThan(view.latitudeMin));
  });

  test('angularDistanceDeg is symmetric', () {
    final a = angularDistanceDeg(10, 20, 30, 40);
    final b = angularDistanceDeg(30, 40, 10, 20);
    expect(a, closeTo(b, 1e-9));
  });
}
