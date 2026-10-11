/// The Web Mercator projection, the spherical helpers and
/// the coordinate table's lookup contract.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:travel_planner/models/geo.dart';

void main() {
  group('projection', () {
    test('the origin and the corners are where they belong', () {
      expect(longitudeToWorldX(-180), 0);
      expect(longitudeToWorldX(0), closeTo(0.5, 1e-9));
      expect(longitudeToWorldX(180), 1);
      expect(latitudeToWorldY(0), closeTo(0.5, 1e-9));
      // North is the top of the map, so smaller y.
      expect(latitudeToWorldY(45), lessThan(0.5));
      expect(latitudeToWorldY(-45), greaterThan(0.5));
    });

    test('the poles are clipped, not infinite', () {
      // Web Mercator cannot show exactly ±90°; the y of the
      // pole is the y of the clip latitude, never infinity.
      expect(latitudeToWorldY(90), latitudeToWorldY(maxMercatorLatitude));
      expect(latitudeToWorldY(-90), latitudeToWorldY(-maxMercatorLatitude));
      expect(latitudeToWorldY(90).isFinite, isTrue);
    });

    test('the inverse round-trips a real city', () {
      const latitude = 31.2001; // Alexandria
      const longitude = 29.9187;
      final y = latitudeToWorldY(latitude);
      final x = longitudeToWorldX(longitude);
      expect(worldYToLatitude(y), closeTo(latitude, 1e-9));
      expect(worldXToLongitude(x), closeTo(longitude, 1e-9));
    });

    test('tiles cover the world as a square', () {
      final topLeft = tileFor(85, -180, 2);
      expect(topLeft, (zoom: 2, x: 0, y: 0));
      final bottomRight = tileFor(-85, 179.9, 2);
      expect(bottomRight, (zoom: 2, x: 3, y: 3));
      final alexandria = tileFor(31.2, 29.9, 2);
      expect(alexandria.x, 2);
      expect(alexandria.y, 1);
    });
  });

  group('spherical helpers', () {
    test('the distance Frankfurt to London matches the known leg', () {
      final km = distanceKm(50.1109, 8.6821, 51.5072, -0.1276);
      expect(km, closeTo(635, 3));
    });

    test('the same point is ~zero distance', () {
      // The spherical law of cosines loses precision for
      // tiny distances (acos of a value just above 1) --
      // the same behaviour the Python side has, and
      // irrelevant at the scale the app displays stops.
      expect(distanceKm(10, 20, 10, 20), lessThan(0.001));
    });

    test('an antipodal point is half the circumference', () {
      final km = distanceKm(0, 0, 0, 180);
      expect(km, closeTo(math.pi * earthRadiusKm, 1));
    });

    test('the bearing north is zero and east is 90', () {
      expect(bearingDegrees(0, 0, 1, 0), closeTo(0, 1e-9));
      expect(bearingDegrees(0, 0, 0, 1), closeTo(90, 1e-9));
    });
  });
}
