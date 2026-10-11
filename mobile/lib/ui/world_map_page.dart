/// The world map: every destination on a real map, plus a
/// focused mini-map for one destination.
///
/// The legacy app's map is a plotly choropleth; the app has
/// no offline geometry to draw coastlines with, so it uses
/// the standard slippy-map tiles -- Web Mercator mosaics
/// from OpenStreetMap, cached by Flutter's image cache for
/// the session -- and plots the destinations as markers on
/// top with the projection in `models/geo.dart`. At zoom 2
/// the whole world is 16 tiles, which is a genuine world
/// map rather than a decorated grid.
///
/// Tiles © OpenStreetMap contributors. The app fetches a
/// handful per view; it does not bulk-download.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/city_coordinates.dart';
import '../data/destination_repository.dart';
import '../models/destination.dart';
import '../models/geo.dart';
import 'destination_page.dart';

/// A map view centred on a point at a zoom, with markers.
class WorldMapView extends StatefulWidget {
  /// The centre of the view.
  final double latitude;
  final double longitude;
  final int zoom;
  final List<MapMarker> markers;
  final double height;

  /// Shown under the map when a tile could not be loaded
  /// (the offline case). Empty hides the hint.
  final String offlineHint;

  const WorldMapView({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.zoom,
    required this.markers,
    this.height = 320,
    this.offlineHint = 'The map tiles need a connection.',
  });

  @override
  State<WorldMapView> createState() => _WorldMapViewState();
}

class MapMarker {
  final double latitude;
  final double longitude;
  final String label;
  final Color color;
  final Destination? destination;
  final DestinationRepository? repository;

  const MapMarker({
    required this.latitude,
    required this.longitude,
    required this.label,
    this.color = Colors.red,
    this.destination,
    this.repository,
  });
}

class _WorldMapViewState extends State<WorldMapView> {
  /// Set when a tile fails to load, so the offline hint can
  /// appear. A notifier, because the failure happens inside
  /// a builder during layout -- calling setState there would
  /// be a build-phase error.
  final _tilesFailed = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _tilesFailed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final centre = worldPixels(widget.latitude, widget.longitude, widget.zoom);
    // The view is a square of pixels centred on the point:
    // the widget is wider than tall, so the width decides
    // how many pixels fit.
    final viewPixels = MediaQuery.of(context).size.width;
    final topLeft = Offset(
      centre.x - viewPixels / 2,
      centre.y - widget.height / 2,
    );

    final firstTileX = (topLeft.dx / 256).floor();
    final lastTileX = ((topLeft.dx + viewPixels) / 256).floor();
    final firstTileY = (topLeft.dy / 256).floor();
    final lastTileY = ((topLeft.dy + widget.height) / 256).floor();

    final tiles = <Widget>[];
    for (var y = firstTileY; y <= lastTileY; y++) {
      for (var x = firstTileX; x <= lastTileX; x++) {
        final worldSize = math.pow(2, widget.zoom).toInt();
        final wrappedX = ((x % worldSize) + worldSize) % worldSize;
        tiles.add(Positioned(
          left: x * 256.0 - topLeft.dx,
          top: y * 256.0 - topLeft.dy,
          width: 256,
          height: 256,
          child: Image.network(
            tileUrl(widget.zoom, wrappedX, y),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) {
              // A tile that will not load (offline) is a
              // placeholder -- and it says so, so a blank
              // grey box is never mistaken for an empty map.
              // The flag is set after the frame: the builder
              // runs while the tree builds, and a rebuild in
              // that phase is a framework error.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _tilesFailed.value = true;
              });
              return Container(
                color: const Color(0xFFE8EDF2),
                child: const Center(
                  child: Icon(Icons.map_outlined, color: Colors.grey, size: 28),
                ),
              );
            },
          ),
        ));
      }
    }

    final markerWidgets = <Widget>[
      for (final marker in widget.markers)
        _markerFor(marker, topLeft, viewPixels),
    ];

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: widget.height,
            color: const Color(0xFFE8EDF2),
            child: Stack(children: [...tiles, ...markerWidgets]),
          ),
        ),
        if (widget.offlineHint.isNotEmpty)
          ValueListenableBuilder<bool>(
            valueListenable: _tilesFailed,
            builder: (context, failed, _) {
              if (!failed) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.offlineHint,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _markerFor(MapMarker marker, Offset topLeft, double viewPixels) {
    final point = worldPixels(marker.latitude, marker.longitude, widget.zoom);
    final left = point.x - topLeft.dx;
    final top = point.y - topLeft.dy;
    // Off-view markers are still positioned (the stack
    // clips them), and taps on them are ignored.
    final visible = left >= -20 &&
        left <= viewPixels + 20 &&
        top >= -20 &&
        top <= widget.height + 20;
    return Positioned(
      left: left - 12,
      top: top - 24,
      child: IgnorePointer(
        ignoring: !visible,
        child: GestureDetector(
          onTap: (marker.destination != null &&
                  marker.repository != null)
              ? () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DestinationPage(
                      repository: marker.repository!,
                      destination: marker.destination!,
                    ),
                  ));
                }
              : null,
          child: Column(
            children: [
              Icon(Icons.location_on, color: marker.color, size: 28),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  marker.label,
                  style: const TextStyle(fontSize: 9, color: Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tile URL for one slippy-map tile. Standard
/// OpenStreetMap tiles, no key needed.
String tileUrl(int zoom, int x, int y) =>
    'https://tile.openstreetmap.org/$zoom/$x/$y.png';

/// The map tab: every destination with coordinates, plus
/// the counts the legacy world map's header reports.
class WorldMapPage extends StatefulWidget {
  final DestinationRepository repository;

  const WorldMapPage({super.key, required this.repository});

  @override
  State<WorldMapPage> createState() => _WorldMapPageState();
}

class _WorldMapPageState extends State<WorldMapPage> {
  late Future<List<Destination>> _destinations;
  CoordinateIndex? _coordinates;

  @override
  void initState() {
    super.initState();
    _destinations = _load();
  }

  Future<List<Destination>> _load() async {
    final coordinates = await CoordinateIndex.load();
    final (destinations, _) = await widget.repository.loadDestinations();
    if (!mounted) return destinations;
    setState(() => _coordinates = coordinates);
    return destinations;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Map')),
      body: FutureBuilder<List<Destination>>(
        future: _destinations,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final destinations = snapshot.data ?? const <Destination>[];
          if (destinations.isEmpty) {
            return const Center(
                child: Text('The database holds no destinations.'));
          }
          return _MapBody(
            destinations: destinations,
            coordinates: _coordinates,
            repository: widget.repository,
          );
        },
      ),
    );
  }
}

class _MapBody extends StatefulWidget {
  final List<Destination> destinations;
  final CoordinateIndex? coordinates;
  final DestinationRepository repository;

  const _MapBody({
    required this.destinations,
    required this.coordinates,
    required this.repository,
  });

  @override
  State<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends State<_MapBody> {
  static const _presets = <({String label, double lat, double lon, int zoom})>[
    (label: 'World', lat: 20.0, lon: 10.0, zoom: 2),
    (label: 'Europe', lat: 50.0, lon: 10.0, zoom: 4),
    (label: 'Asia', lat: 30.0, lon: 105.0, zoom: 3),
    (label: 'Americas', lat: 10.0, lon: -75.0, zoom: 3),
  ];
  var _preset = 0;
  var _filter = _MapFilter.all;

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final destination in widget.destinations)
        if (_filter.accepts(destination)) destination,
    ];
    final markers = <MapMarker>[];
    var missing = 0;
    for (final destination in visible) {
      final coordinate = widget.coordinates?.lookup(destination.name);
      if (coordinate == null) {
        missing++;
        continue;
      }
      markers.add(MapMarker(
        latitude: coordinate.lat,
        longitude: coordinate.lon,
        label: destination.name,
        color: destination.visited
            ? Colors.green.shade700
            : destination.favourite
                ? Colors.orange.shade700
                : Colors.red,
        destination: destination,
        repository: widget.repository,
      ));
    }

    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < _presets.length; i++)
              ChoiceChip(
                label: Text(_presets[i].label),
                selected: _preset == i,
                onSelected: (_) => setState(() => _preset = i),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<_MapFilter>(
          segments: const [
            ButtonSegment(value: _MapFilter.all, label: Text('All')),
            ButtonSegment(value: _MapFilter.visited, label: Text('Visited')),
            ButtonSegment(value: _MapFilter.favourites, label: Text('Favourites')),
          ],
          selected: {_filter},
          onSelectionChanged: (selection) =>
              setState(() => _filter = selection.first),
        ),
        const SizedBox(height: 8),
        Text(
          widget.coordinates == null
              ? 'Reading the coordinate table…'
              : markers.isEmpty
                  ? 'No ${_filter.label.toLowerCase()} destination has a map '
                      'position${missing > 0 ? ' ($missing without coordinates)' : ''}.'
                  : '$missing of ${visible.length} destinations have no map '
                      'position.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        WorldMapView(
          latitude: _presets[_preset].lat,
          longitude: _presets[_preset].lon,
          zoom: _presets[_preset].zoom,
          markers: markers,
          height: 340,
        ),
        const SizedBox(height: 8),
        Text(
          'Green: visited · Orange: favourite · Red: not visited yet. '
          'Tiles © OpenStreetMap contributors.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// The map's destination filter, applied before plotting.
/// A filter that can empty the map says so.
enum _MapFilter {
  all('All'),
  visited('Visited'),
  favourites('Favourites');

  final String label;
  const _MapFilter(this.label);

  bool accepts(Destination destination) {
    switch (this) {
      case _MapFilter.all:
        return true;
      case _MapFilter.visited:
        return destination.visited;
      case _MapFilter.favourites:
        return destination.favourite;
    }
  }
}

/// A focused mini-map for the destination page: the city on
/// its own, with a marker and a scale line.
class DestinationMiniMap extends StatelessWidget {
  final CityCoordinate coordinate;

  const DestinationMiniMap({super.key, required this.coordinate});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WorldMapView(
          latitude: coordinate.lat,
          longitude: coordinate.lon,
          zoom: 6,
          markers: [
            MapMarker(
              latitude: coordinate.lat,
              longitude: coordinate.lon,
              label: coordinate.name,
            ),
          ],
          height: 220,
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
  }
}
