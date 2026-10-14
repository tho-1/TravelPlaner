/// The world map: the legacy map's month/condition choropleth,
/// on real tiles.
///
/// The legacy `pages/world_map.py` asks one question — "how
/// good is the time to go **in the selected month**?" — and
/// answers it twice: every country is filled with the best
/// condition among its destinations (Ideal > Ok > Bad >
/// Unknown), and every city carries its own condition as a
/// pin. Tapping a country (or picking it from the picker)
/// lists that country's cities for the month, and a city
/// opens its full detail. This is that map, ported:
///
/// * the **month selector** defaults to the current month and
///   re-colours the whole map, exactly like the PC page;
/// * the **country fills** come from the bundled
///   `assets/world_countries.geojson`, painted under the
///   slippy-map tiles;
/// * a country the filters hid is a *translucent* fill, the
///   legacy's "filtered" look;
/// * the **country borders** and a **hover highlight with a
///   name tooltip** (desktop) so the political map reads and
///   a tap lands where you aimed;
/// * **wheel zoom, pinch zoom and drag panning**, tile sets
///   re-fetched per zoom level (2–8), region presets via a
///   controller;
/// * the **filters** are the legacy ones: continent,
///   weather-at-least-ok-in (a month), minimum safety,
///   minimum review score, only-unvisited, requires-research
///   — and a filter only ever removes a destination whose
///   field is populated.
///
/// Basemap: Esri World Light Gray Canvas (English labels).
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';

import '../data/city_coordinates.dart';
import '../data/country_geometry.dart';
import '../data/destination_repository.dart';
import '../models/catalogue_filters.dart';
import '../models/condition.dart';
import '../models/destination.dart';
import '../models/destination_profile.dart';
import '../models/geo.dart';
import 'destination_page.dart';
import 'filter_sheet.dart';

/// A focused mini-map for the destination page: framed on
/// the destination's **country** (bounds auto-fitted, so a
/// coastal city like Salvador shows the whole coastline
/// instead of an unreadable close-up), every landmass
/// tinted so water reads as water, and the country filled
/// with its month colour.
class DestinationMiniMap extends StatelessWidget {
  final CityCoordinate coordinate;

  /// The condition colour for the destination's current month,
  /// when the caller parsed the profile. Null leaves the
  /// country uncoloured.
  final Color? countryColor;

  const DestinationMiniMap({
    super.key,
    required this.coordinate,
    this.countryColor,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CountryGeometry>(
      future: CountryGeometry.load(),
      builder: (context, snapshot) {
        final geometry = snapshot.data;
        // Land tint for every known country: on the pale
        // basemap, coastlines used to be invisible -- "which
        // part is the country, which is the water?".
        final fills = <String, Color>{
          if (geometry != null)
            for (final shape in geometry.shapes)
              shape.name: const Color(0xFFE3E9EE),
        };
        if (coordinate.country.isNotEmpty) {
          fills[coordinate.country] =
              countryColor ?? const Color(0xFFB0BEC5);
        }

        return LayoutBuilder(builder: (context, constraints) {
          // Frame the country: the largest zoom whose tile
          // span still holds the country's bounding box,
          // centred between the country's middle and the
          // city. Clamped to 3-7 -- a huge country zooms out
          // to its continent, a small one stays put.
          var latitude = coordinate.lat;
          var longitude = coordinate.lon;
          var zoom = 5;
          final shape = geometry?.lookup(coordinate.country);
          if (shape != null) {
            final (minLon, minLat, maxLon, maxLat) = shape.bounds;
            final width = constraints.maxWidth;
            const height = 220.0;
            var fit = 3;
            for (var z = 7; z >= 3; z--) {
              final worldSize = math.pow(2, z) * 256.0;
              final latPixels = (latitudeToWorldY(minLat) -
                      latitudeToWorldY(maxLat)) *
                  worldSize;
              final lonPixels =
                  (maxLon - minLon) / 360.0 * worldSize;
              if (latPixels <= height * 0.8 &&
                  lonPixels <= width * 0.8) {
                fit = z;
                break;
              }
            }
            zoom = fit;
            // Centre between the country's middle and the
            // city: the whole country stays in frame while
            // the destination keeps the emphasis.
            latitude = (minLat + maxLat) / 2 * 0.55 +
                coordinate.lat * 0.45;
            longitude = (minLon + maxLon) / 2 * 0.55 +
                coordinate.lon * 0.45;
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WorldMapView(
                latitude: latitude,
                longitude: longitude,
                zoom: zoom,
                height: 220,
                interactive: false,
                cities: [
                  MapCity(
                    latitude: coordinate.lat,
                    longitude: coordinate.lon,
                    name: coordinate.name,
                    country: coordinate.country,
                    condition: Condition.unknown,
                    filteredOut: true,
                  ),
                ],
                countryFills: fills,
              ),
              const SizedBox(height: 6),
              Text(
                '${coordinate.lat.toStringAsFixed(3)}, '
                '${coordinate.lon.toStringAsFixed(3)}'
                '${coordinate.country.isEmpty ? '' : ' · ${coordinate.country}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        });
      },
    );
  }
}

/// The tile URL for one slippy-map tile. The Esri light-grey
/// canvas labels places in English wherever an English name
/// exists — the standard OSM tiles render local names, which
/// reads as Chinese across China and Mongolian across
/// Mongolia. The quiet grey also lets the choropleth carry
/// the colour instead of competing with the basemap.
String tileUrl(int zoom, int x, int y) =>
    'https://server.arcgisonline.com/ArcGIS/rest/services/'
    'Canvas/World_Light_Gray_Base/MapServer/tile/$zoom/$y/$x';

/// The view state the caller can move — the region presets
/// fly the map to a place through this.
class WorldMapController extends ChangeNotifier {
  double latitude;
  double longitude;
  int zoom;

  WorldMapController({
    required this.latitude,
    required this.longitude,
    this.zoom = 2,
  });

  void moveTo(double latitude, double longitude, [int? zoom]) {
    this.latitude = latitude;
    this.longitude = longitude;
    if (zoom != null) this.zoom = zoom;
    notifyListeners();
  }
}

/// Where the map is looking right now, expressed so the
/// view-aware overlays (the trip route painter) can land
/// exactly on the tiles while the user pans and zooms.
class MapViewTransform {
  final int zoom;
  final Offset topLeft;
  final double width;
  final double height;

  const MapViewTransform({
    required this.zoom,
    required this.topLeft,
    required this.width,
    required this.height,
  });

  /// A lat/lon point in view coordinates.
  Offset project(double latitude, double longitude) {
    final point = worldPixels(latitude, longitude, zoom);
    return Offset(point.x - topLeft.dx, point.y - topLeft.dy);
  }

  /// The lon/lat under a position in view coordinates —
  /// the country hit test and the anchor-zoom both run
  /// through this.
  (double, double) unproject(Offset local) {
    final worldSize = math.pow(2, zoom) * 256.0;
    final worldX = topLeft.dx + local.dx;
    final worldY = topLeft.dy + local.dy;
    final lon = worldX / worldSize * 360.0 - 180.0;
    final n = math.pi * (1.0 - 2.0 * worldY / worldSize);
    final lat = math.atan(_sinh(n)) * 180.0 / math.pi;
    return (lon, lat);
  }
}

/// Builds the map's overlay widgets against the *current*
/// view, so overlays stay glued to the tiles while the view
/// moves.
typedef WorldMapOverlayBuilder = List<Widget> Function(
    BuildContext context, MapViewTransform transform);

/// The tile-backed map with country fills and borders, city
/// dots, wheel/pinch zoom, drag panning, a hover highlight
/// (desktop) and a tap that selects a country.
class WorldMapView extends StatefulWidget {
  final double latitude;
  final double longitude;
  final int zoom;
  final List<MapCity> cities;
  final double height;

  /// Country name -> fill colour, computed by the page for
  /// the selected month and the active filters.
  final Map<String, Color> countryFills;

  /// Country outlines under the pins: without them the
  /// choropleth is unreadable — nothing tells you which
  /// country you are hovering or tapping.
  final bool showBorders;

  /// Pan and wheel/pinch zoom. The destination mini-map
  /// stays static.
  final bool interactive;

  /// The country ringed on the map — the page's tap
  /// selection. Hover reuses the same highlight.
  final String? highlightCountry;

  /// The legacy "Show city text labels on map" toggle,
  /// gated by zoom: labels only render from zoom 4 up,
  /// where they stop overlapping.
  final bool showCityLabels;

  /// Builds the map's overlay widgets against the current
  /// view — the trip route painter.
  final WorldMapOverlayBuilder? overlayBuilder;

  /// Fired when a tap lands on a country (the choropleth's
  /// click, ported).
  final void Function(String country)? onCountryTap;

  /// The presets fly the map through this.
  final WorldMapController? controller;

  /// Zoom changes are reported so the page can gate the
  /// labels on the level.
  final void Function(int zoom)? onZoomChanged;

  /// Records the open-destination tab when a city marker
  /// opens a page (null: no recording -- the mini-map
  /// passes nothing).
  final void Function(String name)? onOpenDestination;

  const WorldMapView({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.zoom,
    required this.cities,
    required this.countryFills,
    this.height = 320,
    this.showBorders = true,
    this.interactive = true,
    this.highlightCountry,
    this.showCityLabels = true,
    this.onCountryTap,
    this.controller,
    this.onZoomChanged,
    this.overlayBuilder,
    this.onOpenDestination,
  });

  @override
  State<WorldMapView> createState() => _WorldMapViewState();
}

/// One plotted city: its position, its label and the colours
/// the reader needs.
class MapCity {
  final double latitude;
  final double longitude;
  final String name;
  final String? country;
  final Condition condition;
  final bool filteredOut;
  final Destination? destination;
  final DestinationRepository? repository;

  const MapCity({
    required this.latitude,
    required this.longitude,
    required this.name,
    required this.country,
    required this.condition,
    required this.filteredOut,
    this.destination,
    this.repository,
  });
}

class _WorldMapViewState extends State<WorldMapView> {
  CountryGeometry? _geometry;
  final _tilesFailed = ValueNotifier<bool>(false);

  /// The live view: the widget fields are only the *initial*
  /// values; everything the user pans or zooms afterwards
  /// lives here.
  late double _latitude = widget.latitude;
  late double _longitude = widget.longitude;
  late int _zoom = widget.zoom;

  /// The view width, remembered from the last layout so the
  /// gesture handlers can build a transform without a
  /// BuildContext.
  double _viewWidth = 0;

  /// Hover state (desktop): the country under the cursor and
  /// where its tooltip sits.
  String? _hoveredCountry;
  Offset? _hoverPosition;

  // Drag / pinch bookkeeping.
  Offset? _scaleFocalStart;
  double? _scaleStartLatitude;
  double? _scaleStartLongitude;
  double? _lastPinchScale;
  double _pinchAccum = 1;

  /// A world view and a city street want different zooms;
  /// these bounds keep both reachable and the tile count
  /// sane.
  static const _minZoom = 2;
  static const _maxZoom = 8;

  WorldMapController? _attachedController;

  @override
  void initState() {
    super.initState();
    _loadGeometry();
    _attachController();
  }

  void _attachController() {
    _attachedController?.removeListener(_onControllerMove);
    _attachedController = widget.controller;
    _attachedController?.addListener(_onControllerMove);
  }

  void _onControllerMove() {
    final controller = _attachedController;
    if (controller == null || !mounted) return;
    setState(() {
      _latitude = controller.latitude;
      _longitude = controller.longitude;
      if (_zoom != controller.zoom) {
        _zoom = controller.zoom;
        widget.onZoomChanged?.call(_zoom);
      }
      _hoveredCountry = null;
    });
  }

  @override
  void didUpdateWidget(WorldMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _attachController();
    // Caller-driven static views (the destination mini-map)
    // re-adopt a changed centre. The interactive page owns
    // its centre through the controller instead — adopting
    // widget fields there would fight the user's pan.
    if (widget.controller == null &&
        (oldWidget.latitude != widget.latitude ||
            oldWidget.longitude != widget.longitude ||
            oldWidget.zoom != widget.zoom)) {
      _latitude = widget.latitude;
      _longitude = widget.longitude;
      if (_zoom != widget.zoom) {
        _zoom = widget.zoom;
        widget.onZoomChanged?.call(_zoom);
      }
    }
  }

  @override
  void dispose() {
    _attachedController?.removeListener(_onControllerMove);
    _tilesFailed.dispose();
    super.dispose();
  }

  Future<void> _loadGeometry() async {
    final geometry = await CountryGeometry.load();
    if (!mounted) return;
    setState(() => _geometry = geometry);
  }

  MapViewTransform _transformFor(double viewPixels) {
    final centre = worldPixels(_latitude, _longitude, _zoom);
    return MapViewTransform(
      zoom: _zoom,
      topLeft: Offset(
        centre.x - viewPixels / 2,
        centre.y - widget.height / 2,
      ),
      width: viewPixels,
      height: widget.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // The map measures its own width, not the window's:
        // the desktop shell constrains pages narrower than
        // the window, and geometry computed from the window
        // width is displaced -- tiles are fetched beyond the
        // visible area and a tap selects a country west of
        // the one tapped.
        LayoutBuilder(
          builder: (context, constraints) {
            _viewWidth = constraints.maxWidth;
            final transform = _transformFor(_viewWidth);
            final worldSize = math.pow(2, _zoom).toInt();
            final tiles = <Widget>[];
            final firstTileX = (transform.topLeft.dx / 256).floor();
            final lastTileX =
                ((transform.topLeft.dx + _viewWidth) / 256).floor();
            final firstTileY = (transform.topLeft.dy / 256).floor();
            final lastTileY =
                ((transform.topLeft.dy + widget.height) / 256).floor();
            for (var y = firstTileY; y <= lastTileY; y++) {
              for (var x = firstTileX; x <= lastTileX; x++) {
                final wrappedX = ((x % worldSize) + worldSize) % worldSize;
                tiles.add(Positioned(
                  left: x * 256.0 - transform.topLeft.dx,
                  top: y * 256.0 - transform.topLeft.dy,
                  width: 256,
                  height: 256,
                  child: Image.network(
                    tileUrl(_zoom, wrappedX, y),
                    fit: BoxFit.cover,
                    // The caption follows the tiles instead of
                    // sticking: one failed tile used to pin the
                    // "needs a connection" note forever. The
                    // post-frame callback checks mounted --
                    // navigating away in the same frame must
                    // not write to the disposed notifier.
                    errorBuilder: (context, error, stack) {
                      _postTilesFailed(true);
                      return Container(
                        color: const Color(0xFFE8ECEF),
                        child: const Center(
                          child: Icon(Icons.map_outlined,
                              color: Colors.grey, size: 28),
                        ),
                      );
                    },
                    frameBuilder:
                        (context, child, frame, wasSynchronouslyLoaded) {
                      if (frame != null || wasSynchronouslyLoaded) {
                        _postTilesFailed(false);
                      }
                      return child;
                    },
                  ),
                ));
              }
            }

            String? highlight;
            if (_hoveredCountry != null) {
              highlight = normalizeCountryName(_hoveredCountry!);
            } else if (widget.highlightCountry != null &&
                _geometry != null) {
              final shape = _geometry!.lookup(widget.highlightCountry);
              if (shape != null) highlight = normalizeCountryName(shape.name);
            }

            return ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: MouseRegion(
                // Hover is a pointer thing: on the phone the
                // region never fires and the tap carries the
                // selection instead.
                onHover: (widget.interactive)
                    ? (event) => _onHover(event.localPosition, transform)
                    : null,
                onExit: (_) => _clearHover(),
                child: GestureDetector(
                  // A tap on the map hits a country (the choropleth
                  // click): the hit test runs on the geometry, before
                  // any marker would claim the tap.
                  onTapUp: (details) =>
                      _selectCountryAt(details.localPosition, transform),
                  onScaleStart:
                      widget.interactive ? _onScaleStart : null,
                  onScaleUpdate:
                      widget.interactive ? _onScaleUpdate : null,
                  onScaleEnd: widget.interactive ? _onScaleEnd : null,
                  child: Listener(
                    onPointerSignal: widget.interactive
                        ? _onPointerSignal
                        : null,
                    child: Container(
                      height: widget.height,
                      color: const Color(0xFFE8ECEF),
                      child: Stack(children: [
                        ...tiles,
                        // The choropleth paints ABOVE the tiles:
                        // opaque tile images used to cover it
                        // completely, and the month colours were
                        // invisible.
                        CustomPaint(
                          size: Size(_viewWidth, widget.height),
                          painter: _ChoroplethPainter(
                            geometry: _geometry,
                            fills: widget.countryFills,
                            zoom: _zoom,
                            topLeft: transform.topLeft,
                            showBorders: widget.showBorders,
                            highlight: highlight,
                          ),
                        ),
                        if (widget.overlayBuilder != null)
                          ...widget.overlayBuilder!(context, transform),
                        ...[
                          for (final city in widget.cities)
                            _cityMarker(city, transform),
                        ],
                        if (_hoveredCountry != null &&
                            _hoverPosition != null)
                          _hoverTooltip(),
                      ]),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _tilesFailed,
          builder: (context, failed, _) {
            if (!failed) return const SizedBox.shrink();
            return const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_outlined, size: 14),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text('The map tiles need a connection.',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  // ── interactions ─────────────────────────────────────────

  /// Wheel zoom, anchored at the cursor: the world point
  /// under the pointer becomes the centre, so the map does
  /// not lurch away from where the user is looking.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _zoomBy(event.scrollDelta.dy > 0 ? -1 : 1,
        anchor: event.localPosition);
  }

  void _zoomBy(int steps, {Offset? anchor}) {
    final newZoom = (_zoom + steps).clamp(_minZoom, _maxZoom);
    if (newZoom == _zoom) return;
    (double, double)? anchorPoint;
    if (anchor != null) {
      anchorPoint = _transformFor(_viewWidth).unproject(anchor);
    }
    setState(() {
      _zoom = newZoom;
      if (anchorPoint != null) {
        _longitude = anchorPoint.$1;
        _latitude = anchorPoint.$2;
      }
      _clampCentre();
      _hoveredCountry = null;
    });
    widget.onZoomChanged?.call(_zoom);
  }

  void _clampCentre() {
    _latitude = _latitude.clamp(-80.0, 80.0);
    _longitude = ((_longitude + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;
  }

  void _onScaleStart(ScaleStartDetails details) {
    _scaleFocalStart = details.localFocalPoint;
    _scaleStartLatitude = _latitude;
    _scaleStartLongitude = _longitude;
    _lastPinchScale = 1;
    _pinchAccum = 1;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final focalStart = _scaleFocalStart;
    if (focalStart == null) return;
    if ((details.scale - 1).abs() < 0.01) {
      // One pointer (or the mouse): a drag pans. The centre
      // moves by the focal point's pixel delta at the current
      // zoom.
      final worldSize = math.pow(2, _zoom) * 256.0;
      final startCentre =
          worldPixels(_scaleStartLatitude!, _scaleStartLongitude!, _zoom);
      final delta = details.localFocalPoint - focalStart;
      setState(() {
        _longitude = worldXToLongitude(
            (startCentre.x - delta.dx) / worldSize);
        _latitude = worldYToLatitude(
            (startCentre.y - delta.dy) / worldSize);
        _clampCentre();
      });
      return;
    }
    // A pinch: accumulate the scale and step one zoom level
    // per factor ~1.35, anchored at the pinch midpoint.
    final last = _lastPinchScale ?? details.scale;
    _pinchAccum *= details.scale / last;
    _lastPinchScale = details.scale;
    var steps = 0;
    while (_pinchAccum >= 1.35 && _zoom + steps < _maxZoom) {
      steps++;
      _pinchAccum /= 1.35;
    }
    while (_pinchAccum <= 1 / 1.35 && _zoom + steps > _minZoom) {
      steps--;
      _pinchAccum *= 1.35;
    }
    if (steps != 0) {
      _zoomBy(steps, anchor: details.localFocalPoint);
      // The anchor-zoom recentred the map; the drag baseline
      // follows so the next pan does not jump.
      _scaleStartLatitude = _latitude;
      _scaleStartLongitude = _longitude;
      _scaleFocalStart = details.localFocalPoint;
      _lastPinchScale = 1;
      _pinchAccum = 1;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _scaleFocalStart = null;
    _lastPinchScale = null;
  }

  void _onHover(Offset local, MapViewTransform transform) {
    final geometry = _geometry;
    if (geometry == null) return;
    final (lon, lat) = transform.unproject(local);
    final shape = geometry.hitTest(lon, lat);
    // Only rebuild when something visible changes: moving
    // within one country repositions the tooltip, crossing a
    // border swaps the highlight.
    if (shape?.name != _hoveredCountry || _hoverPosition == null) {
      setState(() {
        _hoveredCountry = shape?.name;
        _hoverPosition = local;
      });
    } else {
      _hoverPosition = local;
      // The tooltip follows the cursor without a rebuild;
      // the next paint of anything else picks it up.
      setState(() {});
    }
  }

  void _clearHover() {
    if (_hoveredCountry == null && _hoverPosition == null) return;
    setState(() {
      _hoveredCountry = null;
      _hoverPosition = null;
    });
  }

  Widget _hoverTooltip() {
    final name = _hoveredCountry!;
    Color? fill;
    final normalised = normalizeCountryName(name);
    for (final entry in widget.countryFills.entries) {
      if (normalizeCountryName(entry.key) == normalised) {
        fill = entry.value;
        break;
      }
    }
    return Positioned(
      left: (_hoverPosition!.dx + 14).clamp(0.0, math.max(_viewWidth - 170, 0.0)),
      top: (_hoverPosition!.dy - 34).clamp(0.0, math.max(widget.height - 30, 0.0)),
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.93),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFB0BEC5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (fill != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF607D8B), width: 0.8),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                name,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF263238),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectCountryAt(Offset position, MapViewTransform transform) {
    if (widget.onCountryTap == null) return;
    final geometry = _geometry;
    if (geometry == null) return;
    final (lon, lat) = transform.unproject(position);
    final shape = geometry.hitTest(lon, lat);
    if (shape != null) widget.onCountryTap!(shape.name);
  }

  /// The tile caption is written from post-frame
  /// callbacks (both the error and the success
  /// paths): navigating away in the same frame must
  /// not write to the disposed notifier.
  void _postTilesFailed(bool failed) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tilesFailed.value = failed;
    });
  }

  /// The city pin: a small dot with a white ring (the big
  /// Material pins turned Europe into a pile of blobs), the
  /// name beside it — and only from zoom 4 up, where labels
  /// stop overlapping. The invisible 28px square keeps the
  /// tap target reachable.
  Widget _cityMarker(MapCity city, MapViewTransform transform) {
    final point = transform.project(city.latitude, city.longitude);
    final visible = point.dx >= -24 &&
        point.dx <= transform.width + 24 &&
        point.dy >= -28 &&
        point.dy <= transform.height + 24;
    final color = city.filteredOut
        ? Color(city.condition.colorValue).withValues(alpha: 0.35)
        : Color(city.condition.colorValue);
    final showLabel = widget.showCityLabels && _zoom >= 4;
    return Positioned(
      left: point.dx - 14,
      top: point.dy - 14,
      width: 28,
      height: 28,
      child: IgnorePointer(
        ignoring: !visible,
        child: GestureDetector(
          onTap: (city.destination != null && city.repository != null)
              ? () {
                  widget.onOpenDestination?.call(city.destination!.name);
                  Navigator.of(context).push(MaterialPageRoute(
                    settings: RouteSettings(
                        name: 'destination/${city.destination!.name}'),
                    builder: (_) => DestinationPage(
                      repository: city.repository!,
                      destination: city.destination!,
                    ),
                  ));
                }
              : null,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Align(
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.4),
                  ),
                ),
              ),
              if (showLabel)
                Positioned(
                  left: 13,
                  top: 7,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                    color: Colors.white.withValues(alpha: 0.78),
                    child: Text(
                      city.name,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF263238),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The choropleth: fills, country borders and the hover /
/// selection highlight, painted ABOVE the tiles (they used
/// to sit under the opaque tile images and were invisible).
class _ChoroplethPainter extends CustomPainter {
  final CountryGeometry? geometry;
  final Map<String, Color> fills;
  final int zoom;
  final Offset topLeft;
  final bool showBorders;

  /// The normalised dataset name of the country to ring
  /// (hover on desktop, tap selection on the phone).
  final String? highlight;

  const _ChoroplethPainter({
    required this.geometry,
    required this.fills,
    required this.zoom,
    required this.topLeft,
    required this.showBorders,
    required this.highlight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final shapes = geometry;
    if (shapes == null) return;
    final worldSize = math.pow(2, zoom) * 256.0;
    // The visible lon/lat window: shapes outside it skip
    // their path build entirely, which keeps panning smooth
    // at high zoom (the geometry holds ~180 countries).
    final viewLonMin = topLeft.dx / worldSize * 360.0 - 180.0 - 2.0;
    final viewLonMax =
        (topLeft.dx + size.width) / worldSize * 360.0 - 180.0 + 2.0;
    final viewLatMax = worldYToLatitude(topLeft.dy / worldSize) + 2.0;
    final viewLatMin =
        worldYToLatitude((topLeft.dy + size.height) / worldSize) - 2.0;

    final borderPaint = Paint()
      ..color = const Color(0xFF78909C).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    final highlightFill = Paint()
      ..color = Colors.orange.withValues(alpha: 0.18);
    final highlightStroke = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;

    for (final entry in fills.entries) {
      final shape = shapes.lookup(entry.key);
      if (shape == null) continue;
      if (!_inView(shape, viewLonMin, viewLatMin, viewLonMax, viewLatMax)) {
        continue;
      }
      final path = _pathFor(shape, worldSize);
      if (path == null) continue;
      canvas.drawPath(path, Paint()..color = entry.value);
      canvas.drawPath(path, borderPaint);
      if (highlight != null &&
          normalizeCountryName(shape.name) == highlight) {
        canvas.drawPath(path, highlightFill);
        canvas.drawPath(path, highlightStroke);
      }
    }

    // Borders for countries without a fill: the political
    // map stays legible even where the catalogue has no
    // destination (and the hover needs the outline to make
    // sense of).
    if (showBorders) {
      final filled = {
        for (final key in fills.keys)
          normalizeCountryName(shapes.lookup(key)?.name ?? key),
      };
      for (final shape in shapes.shapes) {
        if (!_inView(shape, viewLonMin, viewLatMin, viewLonMax, viewLatMax)) {
          continue;
        }
        if (filled.contains(normalizeCountryName(shape.name))) continue;
        if (highlight != null &&
            normalizeCountryName(shape.name) == highlight) {
          final path = _pathFor(shape, worldSize);
          if (path == null) continue;
          canvas.drawPath(path, borderPaint);
          canvas.drawPath(path, highlightStroke);
          continue;
        }
        final path = _pathFor(shape, worldSize);
        if (path == null) continue;
        canvas.drawPath(path, borderPaint);
      }
    }
  }

  bool _inView(CountryShape shape, double lonMin, double latMin,
      double lonMax, double latMax) {
    final (minLon, minLat, maxLon, maxLat) = shape.bounds;
    // The bounds may sit past ±180° (unwrapped antimeridian
    // rings); test the point and its shifts the same way the
    // hit test does.
    for (final shift in const [0.0, -360.0, 360.0]) {
      if (maxLon + shift >= lonMin &&
          minLon + shift <= lonMax &&
          maxLat >= latMin &&
          minLat <= latMax) {
        return true;
      }
    }
    return false;
  }

  Path? _pathFor(CountryShape shape, double worldSize) {
    final path = Path();
    var drew = false;
    for (final ring in shape.rings) {
      if (ring.length < 3) continue;
      for (var i = 0; i < ring.length; i++) {
        final x = (ring[i][0] + 180.0) / 360.0 * worldSize - topLeft.dx;
        final sine = math.sin(ring[i][1] * math.pi / 180.0)
            .clamp(-0.9999, 0.9999);
        final y = (0.5 -
                0.25 *
                    math.log((1.0 + sine) / (1.0 - sine)) /
                    math.pi) *
            worldSize -
            topLeft.dy;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        drew = true;
      }
      path.close();
    }
    return drew ? path : null;
  }

  @override
  bool shouldRepaint(_ChoroplethPainter old) =>
      old.fills != fills ||
      old.zoom != zoom ||
      old.topLeft != topLeft ||
      old.showBorders != showBorders ||
      old.highlight != highlight;
}

/// The map tab: month selector, the map, the country
/// drill-down and the legacy filter set.
class WorldMapPage extends StatefulWidget {
  final DestinationRepository repository;

  /// Called when a city marker or result opens a
  /// destination page, so the shell records the
  /// open-destination tab. Null when the feature is off.
  final void Function(String name)? onOpenDestination;

  const WorldMapPage({
    super.key,
    required this.repository,
    this.onOpenDestination,
  });

  @override
  State<WorldMapPage> createState() => _WorldMapPageState();
}

/// The region presets the legacy page does not have (it uses
/// plotly's own world extent), so the reader can jump to a
/// region without panning.
const _mapPresets = <({String label, double lat, double lon, int zoom})>[
  (label: 'World', lat: 20.0, lon: 10.0, zoom: 2),
  (label: 'Europe', lat: 50.0, lon: 10.0, zoom: 4),
  (label: 'Asia', lat: 30.0, lon: 105.0, zoom: 3),
  (label: 'Americas', lat: 10.0, lon: -75.0, zoom: 3),
];

class _WorldMapPageState extends State<WorldMapPage> {
  late Future<(List<Destination>, List<String>)> _destinations;

  /// The coordinate index and the country geometry, loaded
  /// together: the KPI cards need the geometry too (a
  /// country the dataset does not know is "unmapped", the
  /// legacy's warning).
  late Future<(CoordinateIndex, CountryGeometry)> _index;
  var _preset = 0;

  /// The legacy month selector: the map's whole question is
  /// "how good is the time to go *in this month*".
  var _monthIndex = DateTime.now().month - 1;
  String? _selectedCountry;

  /// The shared filter set (legacy defaults: only-unvisited
  /// on).
  CatalogueFilters _filters = CatalogueFilters.initial();

  /// Labels start off on the desktop (the hover tooltip
  /// identifies countries) and on for the phone (no hover
  /// there); either way they only render from zoom 4 up,
  /// where they stop overlapping.
  var _showCityLabels = false;
  var _labelsInitialised = false;
  var _zoom = _mapPresets.first.zoom;

  /// The presets fly the map through this; the fly-to
  /// search rides the same controller.
  final _mapController = WorldMapController(
    latitude: _mapPresets.first.lat,
    longitude: _mapPresets.first.lon,
    zoom: _mapPresets.first.zoom,
  );

  @override
  void initState() {
    super.initState();
    _destinations = widget.repository.loadDestinations();
    _index = _loadIndex();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_labelsInitialised) {
      _labelsInitialised = true;
      _showCityLabels = MediaQuery.sizeOf(context).width < 600;
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<(CoordinateIndex, CountryGeometry)> _loadIndex() async {
    final coordinates = await CoordinateIndex.load();
    final geometry = await CountryGeometry.load();
    return (coordinates, geometry);
  }

  void _reload() {
    setState(() {
      _destinations = widget.repository.loadDestinations();
      _index = _loadIndex();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        actions: [
          // The month selector IS the page's question; it
          // lives in the app bar so the map starts higher.
          PopupMenuButton<int>(
            tooltip: 'Select month',
            onSelected: (index) => setState(() => _monthIndex = index),
            itemBuilder: (_) => [
              for (var i = 0; i < fullMonths.length; i++)
                CheckedPopupMenuItem(
                  value: i,
                  checked: _monthIndex == i,
                  child: Text(fullMonths[i]),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_month_outlined, size: 20),
                  const SizedBox(width: 6),
                  Text(fullMonths[_monthIndex]),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: _filters.isActive,
              child: const Icon(Icons.filter_list),
            ),
            tooltip: 'Filters',
            onPressed: _openFilters,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: FutureBuilder<(List<Destination>, List<String>)>(
        future: _destinations,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (destinations, problems) =
              snapshot.data ?? (<Destination>[], <String>['no result']);
          if (problems.isNotEmpty) {
            return _ProblemView(problems: problems, onRetry: _reload);
          }
          if (destinations.isEmpty) {
            return const Center(
                child: Text('The database holds no destinations.'));
          }
          return _MapBody(
            destinations: destinations,
            index: _index,
            repository: widget.repository,
            monthIndex: _monthIndex,
            onMonthChanged: (index) =>
                setState(() => _monthIndex = index),
            preset: _preset,
            onPresetChanged: (index) => setState(() => _preset = index),
            selectedCountry: _selectedCountry,
            onCountrySelected: (country) =>
                setState(() => _selectedCountry = country),
            filters: _filters,
            showCityLabels: _showCityLabels,
            mapController: _mapController,
            zoom: _zoom,
            onZoomChanged: (zoom) => setState(() => _zoom = zoom),
            onDataChanged: _reload,
            onOpenDestination: widget.onOpenDestination,
          );
        },
      ),
    );
  }

  Future<void> _openFilters() async {
    final (destinations, problems) = await _destinations;
    if (!mounted || problems.isNotEmpty) return;
    await openCatalogueFilterSheet(
      context,
      value: _filters,
      destinations: destinations,
      onChanged: (filters) => setState(() => _filters = filters),
      showCityLabels: _showCityLabels,
      onShowCityLabelsChanged: (value) =>
          setState(() => _showCityLabels = value),
    );
  }
}

class _MapBody extends StatelessWidget {
  final List<Destination> destinations;
  final Future<(CoordinateIndex, CountryGeometry)> index;
  final DestinationRepository repository;
  final int monthIndex;
  final void Function(int) onMonthChanged;
  final int preset;
  final void Function(int) onPresetChanged;
  final String? selectedCountry;
  final void Function(String?) onCountrySelected;
  final CatalogueFilters filters;
  final bool showCityLabels;
  final WorldMapController mapController;
  final int zoom;
  final void Function(int zoom) onZoomChanged;

  /// Fired after a destination was edited from the
  /// drill-down: the map recomputes fills and the
  /// city list, which used to keep showing the
  /// pre-edit state until a manual refresh.
  final VoidCallback onDataChanged;

  /// Records the open-destination tab (null when the
  /// feature is off); the drill-down rows pass it on.
  final void Function(String name)? onOpenDestination;

  const _MapBody({
    required this.destinations,
    required this.index,
    required this.repository,
    required this.monthIndex,
    required this.onMonthChanged,
    required this.preset,
    required this.onPresetChanged,
    required this.selectedCountry,
    required this.onCountrySelected,
    required this.filters,
    required this.showCityLabels,
    required this.mapController,
    required this.zoom,
    required this.onZoomChanged,
    required this.onDataChanged,
    this.onOpenDestination,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(CoordinateIndex, CountryGeometry)>(
      future: index,
      builder: (context, coordinateSnapshot) {
        final coordinates = coordinateSnapshot.data?.$1;
        final geometry = coordinateSnapshot.data?.$2;
        final theme = Theme.of(context);
        final month = fullMonths[monthIndex];
        final profiles = {
          for (final destination in destinations)
            destination.name: DestinationProfile.from(destination),
        };
        // The shared filter set — the same model the
        // catalogue uses, blanks kept.
        final outcome = applyCatalogueFilters(
          destinations,
          filters,
          (destination) => profiles[destination.name]!,
        );
        final plotted = outcome.kept;

        // Cities with a position; a city without coordinates
        // keeps its country count but cannot be plotted.
        final cities = <MapCity>[];
        for (final destination in plotted) {
          final coordinate = coordinates?.lookup(destination.name);
          if (coordinate == null) continue;
          final condition = conditionOfMonth(
              profiles[destination.name]!.months[monthIndex]);
          cities.add(MapCity(
            latitude: coordinate.lat,
            longitude: coordinate.lon,
            name: destination.name,
            country: destination.country,
            condition: condition,
            filteredOut: false,
            destination: destination,
            repository: repository,
          ));
        }

        // The country fills: every country that has any
        // destination, coloured with its best condition for
        // the month. A country the filters hid is translucent.
        final fills = <String, Color>{};
        final byCountry = <String, List<Destination>>{};
        for (final destination in destinations) {
          final country = destination.country;
          if (country == null || country.isEmpty) continue;
          byCountry.putIfAbsent(country, () => []).add(destination);
        }
        final visibleCountries = {
          for (final destination in plotted)
            if (destination.country != null) destination.country!,
        };
        byCountry.forEach((country, rows) {
          final conditions = [
            for (final row in rows)
              conditionOfMonth(profiles[row.name]!.months[monthIndex]),
          ];
          final fill = Color(countryCondition(conditions).colorValue);
          final visible = visibleCountries.contains(country);
          fills[country] =
              visible ? fill : fill.withValues(alpha: 0.15);
        });

        final selectedRows = [
          for (final destination in plotted)
            if (destination.country == selectedCountry) destination,
        ];
        final countryNames = byCountry.keys.toList()..sort();

        // The KPI cards: the mapped countries and the
        // destination conditions for the month, over the
        // rows that pass the filters.
        final mapped = byCountry.keys
            .where((country) => geometry?.lookup(country) != null)
            .length;
        final unmapped = [
          for (final country in byCountry.keys)
            if (geometry != null && geometry.lookup(country) == null) country,
        ]..sort();
        var idealCount = 0;
        var okCount = 0;
        var badCount = 0;
        for (final destination in plotted) {
          switch (conditionOfMonth(
              profiles[destination.name]!.months[monthIndex])) {
            case Condition.ideal:
              idealCount++;
            case Condition.ok:
              okCount++;
            case Condition.bad:
              badCount++;
            case Condition.unknown:
              break;
          }
        }

        // The map takes most of the viewport: it is the
        // page's subject, not a strip between two stat rows.
        final mapHeight =
            (MediaQuery.sizeOf(context).height * 0.58).clamp(420.0, 760.0);

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // The legacy's unmapped-countries warning: the
            // dataset does not know every country the
            // catalogue holds, and a silent gap in the
            // choropleth is unexplainable otherwise.
            if (geometry != null && unmapped.isNotEmpty)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'No map outline for: ${unmapped.join(', ')} — '
                          'the cities are plotted, the country has no fill.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            // Fly-to: type a city or country and the map
            // jumps there — panning the world to find
            // Bucharest was the slow path.
            _FlyToField(
              cities: cities,
              countries: countryNames,
              onPickCity: (city) {
                mapController.moveTo(city.latitude, city.longitude, 6);
                final country = city.country;
                if (country != null && byCountry.containsKey(country)) {
                  onCountrySelected(country);
                }
              },
              onPickCountry: (country) {
                final centre = countryCentre(country, coordinates, cities);
                if (centre != null) {
                  mapController.moveTo(centre.$1, centre.$2, 4);
                }
                onCountrySelected(country);
              },
            ),
            const SizedBox(height: 8),
            // The map is the page: the stats overlay its
            // top-left corner and the legend its bottom-left,
            // where four stacked rows used to eat ~140px of
            // map height.
            Stack(
              children: [
                WorldMapView(
                  latitude: _mapPresets[preset].lat,
                  longitude: _mapPresets[preset].lon,
                  zoom: _mapPresets[preset].zoom,
                  cities: cities,
                  countryFills: fills,
                  height: mapHeight,
                  // Labels only once the zoom makes room for
                  // them (and only if the toggle allows).
                  showCityLabels: showCityLabels && zoom >= 4,
                  controller: mapController,
                  onZoomChanged: onZoomChanged,
                  onOpenDestination: onOpenDestination,
                  highlightCountry: selectedCountry,
                  onCountryTap: (tapped) {
                    // The shapes carry the dataset's long names
                    // ("United States of America"); the data is
                    // keyed by the catalogue's Country column
                    // ("United States") -- the same mismatch the
                    // alias table paints over, resolved in
                    // reverse. A country the catalogue has no
                    // rows for (Antarctica) is ignored: the
                    // legacy has no map tap at all, and
                    // selecting it would only break the
                    // drill-down below.
                    final country =
                        countryAliases.containsValue(tapped)
                            ? countryAliases.entries
                                .firstWhere(
                                    (entry) => entry.value == tapped)
                                .key
                            : tapped;
                    if (byCountry.containsKey(country)) {
                      onCountrySelected(country);
                    }
                  },
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: _StatStrip(
                    mappedCountries: mapped,
                    ideal: idealCount,
                    ok: okCount,
                    bad: badCount,
                  ),
                ),
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFB0BEC5)),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        for (final condition in Condition.values)
                          _LegendDot(
                              color: Color(condition.colorValue),
                              label: condition.label),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    color: Colors.white.withValues(alpha: 0.7),
                    child: const Text(
                      '© Esri',
                      style: TextStyle(fontSize: 9, color: Colors.black54),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < _mapPresets.length; i++)
                  ChoiceChip(
                    label: Text(_mapPresets[i].label),
                    selected: preset == i,
                    onSelected: (_) {
                      onPresetChanged(i);
                      mapController.moveTo(
                        _mapPresets[i].lat,
                        _mapPresets[i].lon,
                        _mapPresets[i].zoom,
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // The invariant caption: how many rows the
            // filters removed, and which fields were too
            // empty to hide anything by.
            Text(
              '${plotted.length} of ${destinations.length} destinations '
              'match the filters ($month). ${outcome.missingCaption}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            const _SectionHeader('Country'),
            DropdownButtonFormField<String>(
              // The selected country must be one of the
              // items: a stale or unresolvable selection
              // (a country the catalogue has no rows for)
              // shows as "no choice", never as an
              // assertion.
              initialValue:
                  countryNames.contains(selectedCountry)
                      ? selectedCountry
                      : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Country',
                prefixIcon: Icon(Icons.public),
              ),
              items: [
                for (final name in countryNames)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: onCountrySelected,
            ),
            const SizedBox(height: 8),
            if (selectedCountry == null)
              Text(
                'Tap a country on the map or choose one to list its cities '
                'for $month.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text(
                '${selectedRows.length} of '
                '${byCountry[selectedCountry]?.length ?? 0} destinations in '
                '$selectedCountry match the filters ($month)',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (selectedRows.isEmpty)
                const _EmptyText(
                    'No destination in this country passes the filters. '
                    'A destination without a value for a filter is never '
                    'hidden.')
              else
                for (final destination in selectedRows)
                  _CountryCityRow(
                    destination: destination,
                    condition: conditionOfMonth(
                        profiles[destination.name]!.months[monthIndex]),
                    month: month,
                    repository: repository,
                    onChanged: onDataChanged,
                    onOpenDestination: onOpenDestination,
                  ),
            ],
          ],
        );
      },
    );
  }
}

/// The centre of a country, averaged over the coordinates
/// of the destinations it holds — the fly-to target. Null
/// when the country has no plotted city.
(double, double)? countryCentre(
  String country,
  CoordinateIndex? coordinates,
  List<MapCity> cities,
) {
  var latSum = 0.0;
  var lonSum = 0.0;
  var count = 0;
  for (final city in cities) {
    if (city.country != country) continue;
    latSum += city.latitude;
    lonSum += city.longitude;
    count++;
  }
  if (count == 0) return null;
  return (latSum / count, lonSum / count);
}

/// The fly-to search: an autocomplete over the plotted
/// cities and the countries that hold them.
class _FlyToField extends StatelessWidget {
  final List<MapCity> cities;
  final List<String> countries;
  final void Function(MapCity city) onPickCity;
  final void Function(String country) onPickCountry;

  const _FlyToField({
    required this.cities,
    required this.countries,
    required this.onPickCity,
    required this.onPickCountry,
  });

  @override
  Widget build(BuildContext context) {
    final options = <String>{
      for (final city in cities) city.name,
      ...countries,
    }.toList()
      ..sort();
    return LayoutBuilder(
      builder: (context, constraints) => Autocomplete<String>(
        optionsBuilder: (value) {
          final query = value.text.trim().toLowerCase();
          if (query.isEmpty) return const Iterable<String>.empty();
          return options.where(
              (option) => option.toLowerCase().contains(query)).take(12);
        },
        onSelected: (value) {
          for (final city in cities) {
            if (city.name == value) {
              onPickCity(city);
              return;
            }
          }
          if (countries.contains(value)) onPickCountry(value);
        },
        fieldViewBuilder: (context, controller, focusNode, onSubmit) =>
            TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Fly to',
            hintText: 'Bucharest, Romania…',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        optionsViewBuilder: (context, onSelected, matches) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: 260, maxWidth: constraints.maxWidth),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final match in matches)
                    ListTile(
                      dense: true,
                      title: Text(match),
                      onTap: () => onSelected(match),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The month's stats, overlaid on the map's top-left
/// corner: icon beside the number, four chips in a wrap.
/// The old vertical KPI cards stacked above the map and
/// ate its height.
class _StatStrip extends StatelessWidget {
  final int mappedCountries;
  final int ideal;
  final int ok;
  final int bad;

  const _StatStrip({
    required this.mappedCountries,
    required this.ideal,
    required this.ok,
    required this.bad,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _StatChip(
            value: '$mappedCountries',
            label: 'mapped',
            icon: Icons.public,
            color: const Color(0xFF0E7C86)),
        _StatChip(
            value: '$ideal',
            label: 'ideal',
            icon: Icons.star,
            color: const Color(0xFF2ECC71)),
        _StatChip(
            value: '$ok',
            label: 'ok',
            icon: Icons.balance,
            color: const Color(0xFFB7950B)),
        _StatChip(
            value: '$bad',
            label: 'bad / off-season',
            icon: Icons.warning_amber,
            color: const Color(0xFFE74C3C)),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color color;

  const _StatChip({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFB0BEC5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(value,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.black87)),
        ],
      ),
    );
  }
}

class _CountryCityRow extends StatelessWidget {
  final Destination destination;
  final Condition condition;
  final DestinationRepository repository;

  /// Fired after an edit inside the destination page,
  /// so the map reflects it without a manual refresh.
  final VoidCallback onChanged;

  /// Records the open-destination tab (null when the
  /// feature is off).
  final void Function(String name)? onOpenDestination;

  /// The **selected** month's name. The caption must name
  /// the month the reader picked, not today's — selecting
  /// July in October used to read "Ideal in Oct" because the
  /// subtitle asked DateTime.now().
  final String month;

  const _CountryCityRow({
    required this.destination,
    required this.condition,
    required this.month,
    required this.repository,
    required this.onChanged,
    this.onOpenDestination,
  });

  @override
  Widget build(BuildContext context) {
    // The legacy drill-down line: Prio, Reviews, Population,
    // each only when the cell is populated.
    final prio = _prioText(destination.prio);
    final reviews = coerceNumber(destination.column('Reviews'))?.round();
    final population = _populationText(destination.column('Population (Metro Area)'));
    final details = <String>[
      if (prio != null) 'Prio: $prio/10',
      if (reviews != null) 'Reviews: $reviews/10',
      if (population != null) 'Population: $population',
    ];
    return Card(
      child: ListTile(
        leading: Icon(Icons.location_on,
            color: Color(condition.colorValue)),
        title: Text(destination.toBeResearched
            ? '${destination.name} ❓'
            : destination.name),
        subtitle: Text([
          '${condition.label} in $month',
          if (destination.country != null) destination.country!,
          if (details.isNotEmpty) details.join(' · '),
        ].join(' · ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          onOpenDestination?.call(destination.name);
          Navigator.of(context).push(MaterialPageRoute(
            settings: RouteSettings(name: 'destination/${destination.name}'),
            builder: (_) => DestinationPage(
              repository: repository,
              destination: destination,
              onChanged: onChanged,
            ),
          ));
        },
      ),
    );
  }
}

/// The legacy city card's Prio text: the number when the
/// cell is numeric ("8"), otherwise the raw text — never a
/// blank line.
String? _prioText(Object? value) {
  if (isBlank(value)) return null;
  final number = coerceNumber(value);
  if (number == null) return '$value'.trim();
  final rounded = number.round();
  return number == rounded ? '$rounded' : '$number';
}

/// The legacy city card's population text: an integer with
/// thousands separators, or the raw text when it is not a
/// number.
String? _populationText(Object? value) {
  if (isBlank(value)) return null;
  final number = coerceNumber(value);
  if (number == null) return '$value'.trim();
  final digits = number.round().toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return grouped.toString();
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _EmptyText extends StatelessWidget {
  final String text;

  const _EmptyText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.bodyMedium);
  }
}

class _ProblemView extends StatelessWidget {
  final List<String> problems;
  final VoidCallback onRetry;

  const _ProblemView({required this.problems, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      const SizedBox(height: 80),
      Padding(
        padding: const EdgeInsets.all(20),
        child: Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.cloud_off),
                  SizedBox(width: 8),
                  Expanded(child: Text('Could not load destinations')),
                ]),
                const SizedBox(height: 8),
                for (final problem in problems)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(problem),
                  ),
                const SizedBox(height: 8),
                OutlinedButton(
                    onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      ),
    ]);
  }
}

/// \sinh\ as dart:math spells it; the map's own inverse
/// projection uses it, and naming it here keeps the import
/// list honest.
double _sinh(double value) {
  final exponential = math.exp(value);
  return 0.5 * (exponential - 1.0 / exponential);
}
