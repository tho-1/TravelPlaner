/// Web Mercator projection and the spherical helpers the
/// map and the stop distances need.
///
/// Web Mercator is the projection every slippy-map tile
/// server uses: the whole world is one square, x runs east
/// from -180° to 180°, y runs north in the same metres but
/// *clipped* at ~±85.05°, because the poles are infinitely
/// far away at this projection. The clip matters: a
/// destination at exactly ±90° would otherwise project to
/// an infinite pixel.
///
/// Every function is pure and testable without a map.
library;

import 'dart:math' as math;

const earthRadiusKm = 6371.0;

/// The latitude a Web Mercator y=0.5 tile row corresponds
/// to, about ±85.051129°.
const maxMercatorLatitude = 85.05112877980659;

/// Longitude (-180..180) to a world x fraction (0..1).
double longitudeToWorldX(double longitude) =>
    (longitude + 180.0) / 360.0;

/// Latitude (-85.05..85.05) to a world y fraction (0..1),
/// 0 at the top (north).
double latitudeToWorldY(double latitude) {
  final clamped = latitude.clamp(-maxMercatorLatitude, maxMercatorLatitude);
  final sine = math.sin(clamped * math.pi / 180.0);
  return 0.5 -
      0.25 *
          math.log((1.0 + sine) / (1.0 - sine)) /
          math.pi;
}

/// The world-fraction x back to longitude.
double worldXToLongitude(double x) => x * 360.0 - 180.0;

/// The world-fraction y back to latitude.
double worldYToLatitude(double y) {
  final n = math.pi * (1.0 - 2.0 * y);
  final exponential = math.exp(n);
  return math.atan(0.5 * (exponential - 1.0 / exponential)) * 180.0 / math.pi;
}

/// The tile rect of one slippy-map tile: zoom, x, y.
///
/// A tile at zoom `z` covers a square of the world; its
/// pixel corner in "world pixels at zoom z" is
/// `(x * tileSize, y * tileSize)`.
({int zoom, int x, int y}) tileFor(
    double latitude, double longitude, int zoom) {
  final worldSize = math.pow(2, zoom).toDouble();
  var x = (longitudeToWorldX(longitude) * worldSize).floor();
  var y = (latitudeToWorldY(latitude) * worldSize).floor();
  x = x.clamp(0, worldSize.toInt() - 1);
  y = y.clamp(0, worldSize.toInt() - 1);
  return (zoom: zoom, x: x, y: y);
}

/// The position of one point in world pixels at a zoom,
/// for drawing a marker on a tile mosaic.
({double x, double y}) worldPixels(
    double latitude, double longitude, int zoom) {
  final worldSize = math.pow(2, zoom) * 256.0;
  return (
    x: longitudeToWorldX(longitude) * worldSize,
    y: latitudeToWorldY(latitude) * worldSize,
  );
}

/// The great-circle distance between two points, the same
/// spherical law of cosines `itinerary/geo.py` uses for its
/// stop distances.
double distanceKm(
    double latitude1, double longitude1, double latitude2, double longitude2) {
  final phi1 = latitude1 * math.pi / 180.0;
  final phi2 = latitude2 * math.pi / 180.0;
  final deltaLambda = (longitude2 - longitude1) * math.pi / 180.0;
  final cosines = math.sin(phi1) * math.sin(phi2) +
      math.cos(phi1) * math.cos(phi2) * math.cos(deltaLambda);
  final arc = math.acos(cosines.clamp(-1.0, 1.0));
  return earthRadiusKm * arc;
}

/// The initial bearing from one point to another (degrees
/// clockwise from north), for a route arrowhead.
double bearingDegrees(
    double latitude1, double longitude1, double latitude2, double longitude2) {
  final phi1 = latitude1 * math.pi / 180.0;
  final phi2 = latitude2 * math.pi / 180.0;
  final deltaLambda = (longitude2 - longitude1) * math.pi / 180.0;
  final y = math.sin(deltaLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);
  return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
}
