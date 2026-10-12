/// The Map tab of the itinerary editor: the
/// route on the tile map, with the legacy's
/// controls.
///
/// The Dart port of `pages/itinerary.py`'s
/// `_render_map_tab` and `itinerary/map.py`'s
/// `build_figure`. The legacy draws a Plotly
/// figure; this port draws the same route on
/// the app's tile map (the world map's
/// painter): one polyline per transport mode
/// (dashed for flight and "other"), arrowhead
/// wings on each leg, gold stop circles
/// numbered in visit order, gray gateway
/// diamonds, and a cyan halo on the stop the
/// Plan tab's eye button picked. The view
/// auto-fits to the route's bounding box, so a
/// China trip does not show Frankfurt.
///
/// The controls are the legacy's, namespaced by
/// variant id there (`itin_visible_modes_{vid}`
/// and friends) so switching variants can never
/// feed stale values into a new variant: the
/// parent keys this widget by the variant id,
/// which gives the same fresh-state guarantee.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/geo.dart' show latitudeToWorldY;
import '../models/route_geo.dart';
import '../models/trip.dart';
import '../models/trip_ops.dart' show totals;
import 'world_map_page.dart';

/// The map's height. The legacy's figure is
/// 560px tall; on a phone a square-ish map
/// keeps the controls and the caption on
/// screen.
const _mapHeight = 420.0;

/// The transport modes the variant's legs use,
/// sorted -- the legacy's `modes_in_use`.
List<String> modesInUse(Variant variant) {
  final modes = <String>{for (final leg in variant.legs) leg.mode};
  return modes.toList()..sort();
}

class ItineraryMapTab extends StatefulWidget {
  final Variant? variant;

  /// The stop the Plan tab's eye button
  /// picked, drawn with a cyan halo.
  final String? selectedStopId;

  const ItineraryMapTab({
    super.key,
    this.variant,
    this.selectedStopId,
  });

  @override
  State<ItineraryMapTab> createState() => _ItineraryMapTabState();
}

class _ItineraryMapTabState extends State<ItineraryMapTab> {
  late Set<String> _visibleModes;
  var _showGateways = true;
  var _focusCountry = '(whole route)';

  @override
  void initState() {
    super.initState();
    // Every mode in use is visible to start
    // with -- the legacy multiselect's default.
    _visibleModes = widget.variant == null
        ? {}
        : modesInUse(widget.variant!).toSet();
  }

  @override
  void didUpdateWidget(covariant ItineraryMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.variant?.id != widget.variant?.id) {
      // A different variant: the controls are
      // namespaced by variant id in the legacy,
      // so switching can never feed stale
      // values into a new variant.
      _visibleModes = widget.variant == null
          ? {}
          : modesInUse(widget.variant!).toSet();
      _showGateways = true;
      _focusCountry = '(whole route)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = widget.variant;
    if (variant == null || variant.stops.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('Add stops in the Plan tab to see the route map.'),
      );
    }
    final modes = modesInUse(variant);
    final countries = [
      for (final country in {
        for (final stop in variant.stops)
          if (stop.ref.kind != 'gateway' &&
              (stop.ref.country ?? '').isNotEmpty)
            stop.ref.country!
      })
        country
    ]..sort();

    // The view fits the focused country's stops
    // when one is picked, the whole route
    // otherwise -- the legacy's `fit_points`.
    final fitPoints = _focusCountry == '(whole route)'
        ? _routePoints(variant)
        : [
            for (final stop in variant.stops)
              if (stop.ref.kind != 'gateway' &&
                  stop.ref.country == _focusCountry &&
                  stop.ref.lat != null &&
                  stop.ref.lon != null)
                (lat: stop.ref.lat!, lon: stop.ref.lon!),
          ];
    final view = fitView(fitPoints.isEmpty ? _routePoints(variant) : fitPoints);
    final routeTotals = totals(variant);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (modes.isNotEmpty) ...[
                  Text('Show transport modes',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final mode in modes)
                        FilterChip(
                          label: Text(
                              routeModeStyles[mode]?.label ?? mode),
                          selected: _visibleModes.contains(mode),
                          onSelected: (selected) => setState(() {
                                if (selected) {
                                  _visibleModes.add(mode);
                                } else {
                                  _visibleModes.remove(mode);
                                }
                              }),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Switch(
                      value: _showGateways,
                      onChanged: (value) =>
                          setState(() => _showGateways = value),
                    ),
                    const SizedBox(width: 4),
                    const Text('Show gateways'),
                    const SizedBox(width: 16),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _focusCountry,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Focus country',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final country in ['(whole route)', ...countries])
                            DropdownMenuItem(
                                value: country, child: Text(country)),
                        ],
                        onChanged: (value) => setState(() {
                          if (value != null) _focusCountry = value;
                        }),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // The map measures its own width, not the
          // window's: the desktop shell constrains pages
          // narrower than the window, and a view fitted to
          // the window width paints the route off the
          // visible map.
          LayoutBuilder(
            builder: (context, mapConstraints) {
              final width = mapConstraints.maxWidth;
              final zoom = _zoomFor(view, width, _mapHeight);
              return WorldMapView(
                latitude: view.latitude,
                longitude: view.longitude,
                zoom: zoom,
                cities: const [],
                countryFills: const {},
                // The route rebuilds against the *current*
                // view, so it stays glued to the tiles while
                // the user pans and zooms.
                overlayBuilder: (context, transform) => [
                  CustomPaint(
                    size: Size(transform.width, transform.height),
                    painter: _RoutePainter(
                      variant: variant,
                      visibleModes: _visibleModes,
                      showGateways: _showGateways,
                      selectedStopId: widget.selectedStopId,
                      centerLongitude: view.longitude,
                      zoom: transform.zoom,
                      topLeft: transform.topLeft,
                    ),
                  ),
                ],
                height: _mapHeight,
                showCityLabels: false,
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '${routeTotals.stops} stops · ${routeTotals.nights} nights · '
              '${routeTotals.flights} flights · ${routeTotals.trains} trains · '
              'click the eye on a stop in the Plan tab to '
              'highlight it here',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// The route's stops with coordinates,
  /// gateways excluded -- the legacy's
  /// auto-fit points.
  List<({double lat, double lon})> _routePoints(Variant variant) => [
        for (final stop in variant.stops)
          if (stop.ref.kind != 'gateway' &&
              stop.ref.lat != null &&
              stop.ref.lon != null)
            (lat: stop.ref.lat!, lon: stop.ref.lon!),
      ];

  /// The largest zoom whose tile mosaic still
  /// covers the fitted longitude and latitude
  /// ranges: the mosaic is 256 * 2^zoom
  /// pixels wide, so the ranges' pixel spans
  /// must fit the view.
  int _zoomFor(RouteView view, double width, double height) {
    final latitudeSpan = latitudeToWorldY(view.latitudeMin) -
        latitudeToWorldY(view.latitudeMax);
    var zoom = 18;
    while (zoom > 1) {
      final worldSize = 256.0 * math.pow(2, zoom);
      final xSpan =
          (view.longitudeMax - view.longitudeMin) / 360.0 * worldSize;
      final ySpan = latitudeSpan * worldSize;
      if (xSpan <= width && ySpan <= height) break;
      zoom--;
    }
    return zoom;
  }
}

/// The route itself: legs grouped by mode,
/// gateways, numbered stops and the selection
/// halo, drawn in world-pixel coordinates on
/// top of the tiles.
class _RoutePainter extends CustomPainter {
  final Variant variant;
  final Set<String> visibleModes;
  final bool showGateways;
  final String? selectedStopId;
  final double centerLongitude;
  final int zoom;
  final Offset topLeft;

  const _RoutePainter({
    required this.variant,
    required this.visibleModes,
    required this.showGateways,
    required this.selectedStopId,
    required this.centerLongitude,
    required this.zoom,
    required this.topLeft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final worldSize = math.pow(2, zoom) * 256.0;

    // The legs, grouped by mode so each mode
    // becomes one legend entry (the legacy's
    // one trace per mode).
    final byMode = <String, List<List<({double lat, double lon})>>>{};
    for (var i = 0; i < variant.legs.length; i++) {
      if (i + 1 >= variant.stops.length) break;
      final a = variant.stops[i].ref;
      final b = variant.stops[i + 1].ref;
      if (a.lat == null ||
          a.lon == null ||
          b.lat == null ||
          b.lon == null) {
        continue;
      }
      final mode = variant.legs[i].mode;
      // One constant shift per leg keeps the
      // polyline continuous: a transpacific hop
      // keeps running past 180° instead of
      // snapping back to -180° and drawing a
      // line across the whole map.
      final shift = alignLongitude(a.lon!, centerLongitude) - a.lon!;
      final path = unwrapLongitudes([
        for (final point
            in greatCirclePoints(a.lat!, a.lon!, b.lat!, b.lon!))
          (lat: point.lat, lon: point.lon + shift),
      ]);
      final segments = byMode.putIfAbsent(mode, () => []);
      segments.add(path);
      // The arrowhead: two short segments that
      // meet at the tip, separated from the
      // line by a gap (the legacy's None
      // separators).
      final wings = arrowWings(path);
      if (wings.isNotEmpty) {
        segments.add([wings[0], wings[1], wings[2]]);
        segments.add([wings[2], wings[3]]);
      }
    }

    for (final entry in byMode.entries) {
      if (!visibleModes.contains(entry.key)) continue;
      final style = routeModeStyles[entry.key] ?? routeModeStyles['other']!;
      final paint = Paint()
        ..color = style.color
        ..strokeWidth = style.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (final segment in entry.value) {
        final offsets = [
          for (final point in segment)
            _offset(point.lat, point.lon, worldSize),
        ];
        if (offsets.length < 2) continue;
        if (style.dashed) {
          _drawDashed(canvas, paint, offsets);
        } else {
          canvas.drawPath(
            Path()..addPolygon(offsets, false),
            paint,
          );
        }
      }
    }

    // The gateways: gray diamonds with names.
    if (showGateways) {
      for (final stop in variant.stops) {
        final ref = stop.ref;
        if (ref.kind != 'gateway' ||
            ref.lat == null ||
            ref.lon == null) {
          continue;
        }
        final point = _offset(
            ref.lat!, alignLongitude(ref.lon!, centerLongitude), worldSize);
        canvas.drawPath(
          Path()
            ..moveTo(point.dx, point.dy - 6)
            ..lineTo(point.dx + 5, point.dy)
            ..lineTo(point.dx, point.dy + 6)
            ..lineTo(point.dx - 5, point.dy)
            ..close(),
          Paint()
            ..color = gatewayColor
            ..style = PaintingStyle.fill,
        );
        _drawText(canvas, ref.name, point.dx, point.dy + 9);
      }
    }

    // The stops: gold circles numbered in visit
    // order, the last one with a darker outline.
    final visible = [
      for (final stop in variant.stops)
        if (stop.ref.kind != 'gateway' &&
            stop.ref.lat != null &&
            stop.ref.lon != null)
          stop,
    ];
    for (var i = 0; i < visible.length; i++) {
      final ref = visible[i].ref;
      final point = _offset(
          ref.lat!, alignLongitude(ref.lon!, centerLongitude), worldSize);
      canvas.drawCircle(
        point,
        9,
        Paint()
          ..color = stopColor
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        point,
        9,
        Paint()
          ..color =
              i == visible.length - 1 ? stopFinalOutline : Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _drawText(canvas, '${i + 1}', point.dx, point.dy, centered: true);
    }

    // The selection halo: a cyan ring on the
    // stop the Plan tab's eye button picked.
    if (selectedStopId != null) {
      for (final stop in visible) {
        if (stop.id != selectedStopId) continue;
        final ref = stop.ref;
        final point = _offset(
            ref.lat!, alignLongitude(ref.lon!, centerLongitude), worldSize);
        canvas.drawCircle(
          point,
          14,
          Paint()
            ..color = selectColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
        break;
      }
    }
  }

  Offset _offset(double latitude, double longitude, double worldSize) {
    final x = (longitude + 180.0) / 360.0 * worldSize - topLeft.dx;
    final y = latitudeToWorldY(latitude) * worldSize - topLeft.dy;
    return Offset(x, y);
  }

  @override
  bool shouldRepaint(_RoutePainter old) =>
      old.variant != variant ||
      old.visibleModes != visibleModes ||
      old.showGateways != showGateways ||
      old.selectedStopId != selectedStopId ||
      old.centerLongitude != centerLongitude ||
      old.zoom != zoom ||
      old.topLeft != topLeft;
}

/// Draws [offsets] as a dashed polyline.
///
/// Flutter's Canvas has no dash pattern, so the
/// dashes are walked segment by segment: a dash
/// of 6px, a gap of 4px, alternating along the
/// whole path.
void _drawDashed(Canvas canvas, Paint paint, List<Offset> offsets) {
  const dashLength = 6.0;
  const gapLength = 4.0;
  var budget = dashLength;
  var drawing = true;
  var segmentStart = offsets.first;
  for (var i = 1; i < offsets.length; i++) {
    final segmentEnd = offsets[i];
    var cursor = segmentStart;
    while (true) {
      final remaining = (segmentEnd - cursor).distance;
      if (remaining <= budget) {
        // The rest of the segment fits in the
        // current dash or gap.
        if (drawing) {
          canvas.drawLine(cursor, segmentEnd, paint);
        }
        budget -= remaining;
        if (budget <= 0) {
          drawing = !drawing;
          budget = drawing ? dashLength : gapLength;
        }
        break;
      }
      // The budget runs out inside this segment.
      final direction = (segmentEnd - cursor) / remaining;
      final boundary = cursor + direction * budget;
      if (drawing) {
        canvas.drawLine(cursor, boundary, paint);
      }
      drawing = !drawing;
      budget = drawing ? dashLength : gapLength;
      cursor = boundary;
    }
    segmentStart = segmentEnd;
  }
}

void _drawText(
  Canvas canvas,
  String text,
  double x,
  double y, {
  bool centered = false,
  double fontSize = 9,
}) {
  final textPainter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        color: const Color(0xFF42506B),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  textPainter.paint(
    canvas,
    Offset(
      centered ? x - textPainter.width / 2 : x,
      centered ? y - textPainter.height / 2 : y,
    ),
  );
}
