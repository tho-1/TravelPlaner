/// The route map's spherical math and style table
/// -- the Dart port of `itinerary/geo.py`'s
/// great-circle helpers and `itinerary/map.py`'s
/// mode styles.
///
/// Every function is pure and testable without a
/// map, like the Python originals: the great-circle
/// path is densified so the polyline follows the
/// sphere instead of cutting a straight chord
/// through it, longitudes are unwrapped so a
/// transpacific hop (Tokyo 139.7E -> Los Angeles
/// 118.2W) runs through 180, 200, 220... instead
/// of snapping back to -180 and drawing a line
/// across the whole map, and the view is fitted to
/// the route's bounding box so a China trip does
/// not show Frankfurt.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'geo.dart' show bearingDegrees;

/// One transport mode's look on the route map --
/// `itinerary/map.py`'s MODE_STYLES. Dashed for
/// flight and "other", the two modes that are not
/// a surface line.
class RouteModeStyle {
  final Color color;
  final bool dashed;
  final String label;
  final double width;

  const RouteModeStyle({
    required this.color,
    required this.dashed,
    required this.label,
    required this.width,
  });
}

const routeModeStyles = <String, RouteModeStyle>{
  'flight': RouteModeStyle(
      color: Color(0xFF3B82F6),
      dashed: true,
      label: '✈ Flight',
      width: 2.0),
  'train': RouteModeStyle(
      color: Color(0xFFF59E0B),
      dashed: false,
      label: '🚆 Train',
      width: 2.4),
  'bus': RouteModeStyle(
      color: Color(0xFF3ECF8E),
      dashed: false,
      label: '🚌 Bus',
      width: 2.2),
  'car': RouteModeStyle(
      color: Color(0xFF8B98AB),
      dashed: false,
      label: '🚗 Car',
      width: 2.2),
  'boat': RouteModeStyle(
      color: Color(0xFF2DD4BF),
      dashed: false,
      label: '⛴ Boat',
      width: 2.2),
  'other': RouteModeStyle(
      color: Color(0xFF94A3B8),
      dashed: true,
      label: '• Other',
      width: 2.0),
};

/// The route map's fixed colours
/// (`itinerary/map.py`).
const stopColor = Color(0xFFFBBF24);
const stopFinalOutline = Color(0xFFB45309);
const gatewayColor = Color(0xFF8B98AB);
const selectColor = Color(0xFF40C4FF);

/// The central angle between two points, in
/// degrees (the haversine form the legacy uses
/// for its arrowhead sizing).
double angularDistanceDeg(
    double latitude1, double longitude1, double latitude2, double longitude2) {
  final phi1 = latitude1 * math.pi / 180.0;
  final phi2 = latitude2 * math.pi / 180.0;
  final deltaLambda = (longitude2 - longitude1) * math.pi / 180.0;
  final a = math.sin((phi2 - phi1) / 2) * math.sin((phi2 - phi1) / 2) +
      math.cos(phi1) * math.cos(phi2) *
          math.sin(deltaLambda / 2) * math.sin(deltaLambda / 2);
  return 2 * math.asin(math.min(1.0, math.sqrt(a))) * 180.0 / math.pi;
}

/// The point reached from (lat, lon) going
/// [bearingDegrees] for [angularDegrees] of
/// central angle.
({double lat, double lon}) directPoint(
    double latitude, double longitude, double bearingDegrees,
    double angularDegrees) {
  final phi1 = latitude * math.pi / 180.0;
  final delta = angularDegrees * math.pi / 180.0;
  final brg = bearingDegrees * math.pi / 180.0;
  final phi2 = math.asin(math.sin(phi1) * math.cos(delta) +
      math.cos(phi1) * math.sin(delta) * math.cos(brg));
  final lambda1 = longitude * math.pi / 180.0;
  final lambda2 = lambda1 + math.atan2(
      math.sin(brg) * math.sin(delta) * math.cos(phi1),
      math.cos(delta) - math.sin(phi1) * math.sin(phi2));
  final lon = (lambda2 * 180.0 / math.pi + 540.0) % 360.0 - 180.0;
  return (lat: phi2 * 180.0 / math.pi, lon: lon);
}

/// A densified great-circle path (n segments,
/// inclusive endpoints): the spherical
/// interpolation the legacy draws as one leg.
/// Identical points return the two endpoints.
List<({double lat, double lon})> greatCirclePoints(
    double latitude1, double longitude1, double latitude2, double longitude2,
    {int n = 24}) {
  if (n < 1) n = 1;
  final phi1 = latitude1 * math.pi / 180.0;
  final phi2 = latitude2 * math.pi / 180.0;
  final lambda1 = longitude1 * math.pi / 180.0;
  final lambda2 = longitude2 * math.pi / 180.0;
  final d = 2 * math.asin(math.min(1.0, math.sqrt(
      math.sin((phi2 - phi1) / 2) * math.sin((phi2 - phi1) / 2) +
          math.cos(phi1) * math.cos(phi2) *
              math.sin((lambda2 - lambda1) / 2) *
              math.sin((lambda2 - lambda1) / 2))));
  if (d < 1e-9) {
    return [
      (lat: latitude1, lon: longitude1),
      (lat: latitude2, lon: longitude2),
    ];
  }
  final sinD = math.sin(d);
  return [
    for (var i = 0; i <= n; i++)
      () {
        final t = i / n;
        final a = math.sin((1 - t) * d) / sinD;
        final b = math.sin(t * d) / sinD;
        final x = a * math.cos(phi1) * math.cos(lambda1) +
            b * math.cos(phi2) * math.cos(lambda2);
        final y = a * math.cos(phi1) * math.sin(lambda1) +
            b * math.cos(phi2) * math.sin(lambda2);
        final z = a * math.sin(phi1) + b * math.sin(phi2);
        return (
          lat: math.atan2(z, math.sqrt(x * x + y * y)) * 180.0 / math.pi,
          lon: math.atan2(y, x) * 180.0 / math.pi,
        );
      }(),
  ];
}

/// Arrowhead V-wings for a densified polyline.
///
/// The bearing is measured from a LOCAL segment
/// (t=0.50 -> t=0.55) so the arrow points the way
/// the line actually draws even on curved long
/// legs. The wing length scales with the leg
/// length (clamped 0.5°..2°). Returns [] for
/// degenerate paths; otherwise the wing points are
/// [tip, left, tip, right] -- two segments that
/// meet at the tip, drawn separated from the line
/// by a gap.
List<({double lat, double lon})> arrowWings(
    List<({double lat, double lon})> points) {
  if (points.length < 3) return [];
  final iTail = math.max(0, (points.length * 0.50).floor() - 1);
  final iTip = math.min(points.length - 1, (points.length * 0.55).floor() + 1);
  final tail = points[iTail];
  final tip = points[iTip];
  final brg = bearingDegrees(
      tail.lat, tail.lon, tip.lat, tip.lon);
  final wingLength = math.min(
      2.0,
      math.max(
          0.5,
          0.008 *
              angularDistanceDeg(points.first.lat, points.first.lon,
                  points.last.lat, points.last.lon)));
  final left = directPoint(tip.lat, tip.lon, (brg + 140) % 360, wingLength);
  final right =
      directPoint(tip.lat, tip.lon, (brg - 140) % 360, wingLength);
  return [tip, left, tip, right];
}

/// Shifts each longitude by multiples of 360 so
/// the path stays continuous: great-circle
/// interpolation runs off the end of the longitude
/// scale, and feeding those raw values to the view
/// fit produced a 398°-wide frame centred nowhere
/// (what a transpacific itinerary used to render
/// as).
List<({double lat, double lon})> unwrapLongitudes(
    List<({double lat, double lon})> points) {
  if (points.isEmpty) return [];
  final out = <({double lat, double lon})>[points.first];
  var offset = 0.0;
  var previous = points.first.lon;
  for (final point in points.skip(1)) {
    var candidate = point.lon + offset;
    while (candidate - previous > 180) {
      offset -= 360.0;
      candidate -= 360.0;
    }
    while (previous - candidate > 180) {
      offset += 360.0;
      candidate += 360.0;
    }
    out.add((lat: point.lat, lon: candidate));
    previous = candidate;
  }
  return out;
}

/// Shifts [longitude] by whole turns so it sits
/// closest to [centerLongitude]: the view frame may
/// be unwrapped (e.g. 140..242° for a Tokyo ->
/// Los Angeles route), and markers must be shifted
/// into that same frame or they end up a full turn
/// away from the line they belong to.
double alignLongitude(double longitude, double centerLongitude) =>
    longitude + 360.0 * ((centerLongitude - longitude) / 360.0).round();

/// The fitted view of a set of points: the centre
/// and the padded longitude/latitude ranges the
/// route map frames itself to.
class RouteView {
  final double latitude;
  final double longitude;
  final double longitudeMin;
  final double longitudeMax;
  final double latitudeMin;
  final double latitudeMax;

  const RouteView({
    required this.latitude,
    required this.longitude,
    required this.longitudeMin,
    required this.longitudeMax,
    required this.latitudeMin,
    required this.latitudeMax,
  });
}

/// The bounding box of the points, padded, with
/// the longitudes unwrapped first (a transpacific
/// route's box is 102° wide, not 258°).
RouteView fitView(List<({double lat, double lon})> points,
    {double padFrac = 0.06}) {
  if (points.isEmpty) {
    return const RouteView(
      latitude: 20,
      longitude: 10,
      longitudeMin: -140,
      longitudeMax: 140,
      latitudeMin: -60,
      latitudeMax: 75,
    );
  }
  final unwrapped = unwrapLongitudes(points);
  final lats = [for (final point in unwrapped) point.lat];
  final lons = [for (final point in unwrapped) point.lon];
  final latMin = lats.reduce(math.min);
  final latMax = lats.reduce(math.max);
  final lonMin = lons.reduce(math.min);
  final lonMax = lons.reduce(math.max);
  final latPad = math.max(1.5, (latMax - latMin) * padFrac);
  final lonPad = math.max(1.5, (lonMax - lonMin) * padFrac);
  return RouteView(
    latitude: (latMin + latMax) / 2,
    longitude: (lonMin + lonMax) / 2,
    longitudeMin: lonMin - lonPad,
    longitudeMax: lonMax + lonPad,
    latitudeMin: latMin - latPad,
    latitudeMax: latMax + latPad,
  );
}
