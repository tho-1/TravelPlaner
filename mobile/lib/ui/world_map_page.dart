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
/// * the **filters** are the legacy ones: continent,
///   weather-at-least-ok-in (a month), minimum safety,
///   minimum review score, only-unvisited, requires-research
///   — and a filter only ever removes a destination whose
///   field is populated.
///
/// Tiles © OpenStreetMap contributors.
library;

import 'dart:math' as math;

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

/// A focused mini-map for the destination page: the city and
/// its country's condition fill, with a marker and the
/// coordinate.
class DestinationMiniMap extends StatelessWidget {
  final CityCoordinate coordinate;

  /// The condition colour for the destination's current month,
  /// when the caller parsed the profile. Null leaves the
  /// country unfilled.
  final Color? countryColor;

  const DestinationMiniMap({
    super.key,
    required this.coordinate,
    this.countryColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WorldMapView(
          latitude: coordinate.lat,
          longitude: coordinate.lon,
          zoom: 6,
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
          countryFills: coordinate.country.isEmpty
              ? const {}
              : {coordinate.country: countryColor ?? Colors.transparent},
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

/// The tile URL for one slippy-map tile.
String tileUrl(int zoom, int x, int y) =>
    'https://tile.openstreetmap.org/$zoom/$x/$y.png';

/// The tile-backed map with country fills, pins and a tap
/// that selects a country.
class WorldMapView extends StatefulWidget {
  final double latitude;
  final double longitude;
  final int zoom;
  final List<MapCity> cities;
  final double height;

  /// Country name -> fill colour, computed by the page for
  /// the selected month and the active filters.
  final Map<String, Color> countryFills;

  /// Widgets painted on top of the tiles, under the city
  /// markers -- the itinerary route map draws its legs,
  /// stops and gateways here.
  final List<Widget> overlay;

  /// The legacy "Show city text labels on map" toggle.
  /// Phone map default is on — there is no hover on a
  /// touch screen, so the name under the pin is the only
  /// identification.
  final bool showCityLabels;

  /// Fired when a tap lands on a country (the choropleth's
  /// click, ported).
  final void Function(String country)? onCountryTap;

  const WorldMapView({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.zoom,
    required this.cities,
    required this.countryFills,
    this.overlay = const [],
    this.height = 320,
    this.showCityLabels = true,
    this.onCountryTap,
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

  @override
  void initState() {
    super.initState();
    _loadGeometry();
  }

  Future<void> _loadGeometry() async {
    final geometry = await CountryGeometry.load();
    if (!mounted) return;
    setState(() => _geometry = geometry);
  }

  @override
  void dispose() {
    _tilesFailed.dispose();
    super.dispose();
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
            final viewPixels = constraints.maxWidth;
            final centre = worldPixels(
                widget.latitude, widget.longitude, widget.zoom);
            final topLeft = Offset(
              centre.x - viewPixels / 2,
              centre.y - widget.height / 2,
            );

            final firstTileX = (topLeft.dx / 256).floor();
            final lastTileX = ((topLeft.dx + viewPixels) / 256).floor();
            final firstTileY = (topLeft.dy / 256).floor();
            final lastTileY = ((topLeft.dy + widget.height) / 256).floor();

            final tiles = <Widget>[];
            final worldSize = math.pow(2, widget.zoom).toInt();
            for (var y = firstTileY; y <= lastTileY; y++) {
              for (var x = firstTileX; x <= lastTileX; x++) {
                final wrappedX = ((x % worldSize) + worldSize) % worldSize;
                tiles.add(Positioned(
                  left: x * 256.0 - topLeft.dx,
                  top: y * 256.0 - topLeft.dy,
                  width: 256,
                  height: 256,
                  child: Image.network(
                    tileUrl(widget.zoom, wrappedX, y),
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
                        color: const Color(0xFFE8EDF2),
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

            final markers = <Widget>[
              for (final city in widget.cities)
                _cityMarker(city, topLeft, viewPixels),
            ];

            return ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: GestureDetector(
                // A tap on the map hits a country (the choropleth
                // click): the hit test runs on the geometry, before
                // any marker would claim the tap.
                onTapUp: (details) =>
                    _selectCountryAt(details.localPosition, topLeft),
                child: Container(
                  height: widget.height,
                  color: const Color(0xFFE8EDF2),
                  child: Stack(children: [
                    CustomPaint(
                      size: Size(viewPixels, widget.height),
                      painter: _CountryFillPainter(
                        geometry: _geometry,
                        fills: widget.countryFills,
                        zoom: widget.zoom,
                        topLeft: topLeft,
                      ),
                    ),
                    ...tiles,
                    ...widget.overlay,
                    ...markers,
                  ]),
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

  void _selectCountryAt(Offset position, Offset topLeft) {
    if (widget.onCountryTap == null) return;
    final geometry = _geometry;
    if (geometry == null) return;
    final worldX = topLeft.dx + position.dx;
    final worldY = topLeft.dy + position.dy;
    final worldSize = math.pow(2, widget.zoom) * 256.0;
    final lon = worldX / worldSize * 360.0 - 180.0;
    final n = math.pi * (1.0 - 2.0 * worldY / worldSize);
    final lat = math.atan(_sinh(n)) * 180.0 / math.pi;
    for (final shape in geometry.shapes) {
      if (pointInCountry(lon, lat, shape.rings)) {
        widget.onCountryTap!(shape.name);
        return;
      }
    }
  }

  /// The dataset's spelling for the tapped country, in
  /// the catalogue's spelling: the shapes carry the
  /// long English names ("United States of America"),
  /// the data is keyed by the catalogue's Country
  /// column ("United States") -- the same mismatch the
  /// alias table paints over, in reverse.
  Widget _cityMarker(MapCity city, Offset topLeft, double viewPixels) {
    final point = worldPixels(city.latitude, city.longitude, widget.zoom);
    final left = point.x - topLeft.dx;
    final top = point.y - topLeft.dy;
    final visible = left >= -24 &&
        left <= viewPixels + 24 &&
        top >= -28 &&
        top <= widget.height + 24;
    final color = city.filteredOut
        ? Color(city.condition.colorValue).withValues(alpha: 0.35)
        : Color(city.condition.colorValue);
    return Positioned(
      left: left - 11,
      top: top - 22,
      child: IgnorePointer(
        ignoring: !visible,
        child: GestureDetector(
          onTap: (city.destination != null && city.repository != null)
              ? () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DestinationPage(
                      repository: city.repository!,
                      destination: city.destination!,
                    ),
                  ));
                }
              : null,
          child: Column(
            children: [
              Icon(Icons.location_on, color: color, size: 26),
              if (widget.showCityLabels)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    city.name,
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

/// Fills every country in view with its condition colour, on
/// top of the tiles (the legacy choropleth's fill, drawn
/// under a real map's detail).
class _CountryFillPainter extends CustomPainter {
  final CountryGeometry? geometry;
  final Map<String, Color> fills;
  final int zoom;
  final Offset topLeft;

  const _CountryFillPainter({
    required this.geometry,
    required this.fills,
    required this.zoom,
    required this.topLeft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final shapes = geometry;
    if (shapes == null) return;
    final worldSize = math.pow(2, zoom) * 256.0;
    for (final entry in fills.entries) {
      final shape = shapes.lookup(entry.key);
      if (shape == null) continue;
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
      if (!drew) continue;
      canvas.drawPath(
        path,
        Paint()
          ..color = entry.value
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_CountryFillPainter old) =>
      old.fills != fills || old.zoom != zoom || old.topLeft != topLeft;
}

/// The map tab: month selector, the map, the country
/// drill-down and the legacy filter set.
class WorldMapPage extends StatefulWidget {
  final DestinationRepository repository;

  const WorldMapPage({super.key, required this.repository});

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
  var _showCityLabels = true;

  @override
  void initState() {
    super.initState();
    _destinations = widget.repository.loadDestinations();
    _index = _loadIndex();
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
            onDataChanged: _reload,
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

  /// Fired after a destination was edited from the
  /// drill-down: the map recomputes fills and the
  /// city list, which used to keep showing the
  /// pre-edit state until a manual refresh.
  final VoidCallback onDataChanged;

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
    required this.onDataChanged,
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

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('How good is the time to go, month by month',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            // The month selector: the legacy page's
            // "Select Month", defaulting to today.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < 12; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(monthAbbreviations[i]),
                        selected: monthIndex == i,
                        onSelected: (_) => onMonthChanged(i),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
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
            _KpiRow(
              mappedCountries: mapped,
              ideal: idealCount,
              ok: okCount,
              bad: badCount,
            ),
            const SizedBox(height: 10),
            WorldMapView(
              latitude: _mapPresets[preset].lat,
              longitude: _mapPresets[preset].lon,
              zoom: _mapPresets[preset].zoom,
              cities: cities,
              countryFills: fills,
              showCityLabels: showCityLabels,
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
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final condition in Condition.values)
                  _LegendDot(
                      color: Color(condition.colorValue),
                      label: condition.label),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < _mapPresets.length; i++)
                  ChoiceChip(
                    label: Text(_mapPresets[i].label),
                    selected: preset == i,
                    onSelected: (_) => onPresetChanged(i),
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
                  ),
            ],
          ],
        );
      },
    );
  }
}

/// The legacy KPI cards: mapped countries and the Ideal /
/// Ok / Bad destination counts for the selected month.
class _KpiRow extends StatelessWidget {
  final int mappedCountries;
  final int ideal;
  final int ok;
  final int bad;

  const _KpiRow({
    required this.mappedCountries,
    required this.ideal,
    required this.ok,
    required this.bad,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _KpiCard(
                value: '$mappedCountries',
                label: 'Mapped countries',
                icon: Icons.public)),
        const SizedBox(width: 8),
        Expanded(
            child: _KpiCard(
                value: '$ideal',
                label: 'Ideal destinations',
                icon: Icons.star,
                color: const Color(0xFF2ECC71))),
        const SizedBox(width: 8),
        Expanded(
            child: _KpiCard(
                value: '$ok',
                label: 'Ok destinations',
                icon: Icons.balance,
                color: const Color(0xFFF1C40F))),
        const SizedBox(width: 8),
        Expanded(
            child: _KpiCard(
                value: '$bad',
                label: 'Bad / off-season',
                icon: Icons.warning_amber,
                color: const Color(0xFFE74C3C))),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color? color;

  const _KpiCard({
    required this.value,
    required this.label,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Column(
          children: [
            Icon(icon, color: color ?? theme.colorScheme.primary, size: 18),
            const SizedBox(height: 4),
            Text(value, style: theme.textTheme.titleLarge),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
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
          Navigator.of(context).push(MaterialPageRoute(
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
