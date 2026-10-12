/// The Transport & Direct Connections section:
/// the research button, the airport, and the
/// flights and high-speed trains tables.
///
/// The Dart port of `flight_routes.
/// render_flight_routes_section` and its two
/// tabs. The research goes through the DeepSeek
/// client and is cached per destination; the
/// tables are the pure `queryFlightRows` /
/// `queryTrainRows` output. Every failure is
/// a message, never a crash.
///
/// The Wishlist link opens the matching
/// destination through [onOpenDestination]
/// (the caller owns the navigation), so this
/// section never imports the destination page.
library;

import 'package:flutter/material.dart';

import '../data/ai_config.dart';
import '../data/app_dirs.dart';
import '../data/deepseek_client.dart';
import '../data/destination_repository.dart';
import '../data/flight_routes.dart';
import '../data/flight_routes_repository.dart';
import '../models/destination.dart';
import '../turso/config.dart';

class FlightRoutesSection extends StatefulWidget {
  final DestinationRepository repository;
  final Destination destination;

  /// Called when a Wishlist link is tapped, so
  /// the caller opens that destination's page.
  final void Function(Destination)? onOpenDestination;

  /// Test seams: the cache directory, the AI
  /// client and the config. Null loads the
  /// bundled ones, exactly like the running app.
  ///
  /// The config and the airline colors are
  /// seams for the same reason as [aiClient]:
  /// the bundled loaders read through
  /// `rootBundle`, whose cache never completes
  /// a second load inside the test binding, so
  /// a test that pumps the section more than
  /// once must inject them.
  final String? cacheDir;
  final TursoConfig? config;
  final AirlineColors? colors;
  final DeepSeekClient? aiClient;
  final AiConfig? aiConfig;

  const FlightRoutesSection({
    super.key,
    required this.repository,
    required this.destination,
    this.onOpenDestination,
    this.cacheDir,
    this.config,
    this.colors,
    this.aiClient,
    this.aiConfig,
  });

  @override
  State<FlightRoutesSection> createState() => _FlightRoutesSectionState();
}

class _FlightRoutesSectionState extends State<FlightRoutesSection> {
  Map<String, dynamic>? _cached;
  Map<String, Destination> _plannerLookup = const {};
  AirlineColors? _colors;
  var _researching = false;
  var _tab = 0;
  var _inPlannerOnly = false;
  var _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = widget.config ?? await TursoConfig.load();
    final dir = await perDeviceCacheDir(
        widget.cacheDir ?? config.flightRoutesCache);
    final cached = FlightRoutesRepository(dir).load(widget.destination.name);
    final (catalogue, _) = await widget.repository.loadDestinations();
    final colors = widget.colors ?? await AirlineColors.load();
    if (!mounted) return;
    setState(() {
      _cached = cached;
      _plannerLookup = buildPlannerLookup(catalogue);
      _colors = colors;
    });
  }

  Future<void> _research() async {
    setState(() => _researching = true);
    final config = widget.config ?? await TursoConfig.load();
    final dir = await perDeviceCacheDir(
        widget.cacheDir ?? config.flightRoutesCache);
    final client =
        widget.aiClient ?? DeepSeekClient(widget.aiConfig ?? await AiConfig.load());
    try {
      final result = await client.generateFlightRoutes(
        destination: widget.destination.name,
        country: widget.destination.country ?? '',
      );
      // A failed save is surfaced, never reported as
      // success: the writer contract is that false
      // means "nothing was written".
      final saved = FlightRoutesRepository(dir).save(
          widget.destination.name, result);
      final (catalogue, _) = await widget.repository.loadDestinations();
      if (!mounted) return;
      setState(() {
        _cached = result;
        _plannerLookup = buildPlannerLookup(catalogue);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(saved
            ? 'Transport connections updated'
            : 'Researched, but not saved on this device '
                '-- it will be researched again next time'),
      ));
    } on DeepSeekError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.message),
      ));
    } finally {
      if (mounted) setState(() => _researching = false);
    }
  }

  bool get _isChina => isChinaDestination(
        widget.destination.name,
        widget.destination.country ?? '',
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cached = _cached;
    final routes = cached == null ? null : FlightRoutes.fromJson(cached);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A Wrap, not a Row: the research button
        // is wider than the space next to the
        // title on a phone screen, and a Row
        // would overflow it off the edge.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Text('Transport & Direct Connections',
                style: theme.textTheme.titleMedium),
            _researchButton(),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'Direct non-stop flight connections (inbound & outbound) and '
          'high-speed rail transit, sorted by duration.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        if (cached == null || routes == null) ...[
          Text(
            'Research all direct flight routes (inbound & outbound)'
            '${_isChina ? ' and high-speed rail connections' : ''} for '
            '${widget.destination.name}.',
            style: theme.textTheme.bodyMedium,
          ),
        ] else ...[
          _lastUpdated(routes),
          const SizedBox(height: 10),
          _airportCard(routes),
          const SizedBox(height: 10),
          _filterAndSearch(routes),
          const SizedBox(height: 10),
          if (_hasTrains(routes)) ...[
            _tabSwitcher(routes),
            const SizedBox(height: 10),
          ],
          if (_showTrains(routes))
            _trainsTab(routes)
          else
            _flightsTab(routes),
        ],
      ],
    );
  }

  Widget _researchButton() {
    final label = _cached == null
        ? (_isChina ? 'Research Flights & Trains' : 'Research Flight Connections')
        : 'Re-research Transport Connections';
    return OutlinedButton.icon(
      icon: _researching
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.flight_takeoff, size: 18),
      label: Text(_researching ? 'Researching…' : label),
      onPressed: _researching ? null : _research,
    );
  }

  Widget _lastUpdated(FlightRoutes routes) {
    final updated =
        routes.lastUpdated.isEmpty ? todayLabel() : routes.lastUpdated;
    return Text(
      'Last updated: $updated',
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Colors.grey[600]),
    );
  }

  /// The airport card: the legacy's blue-bordered
  /// "Primary Airport" box, with the IATA code as
  /// a badge.
  Widget _airportCard(FlightRoutes routes) {
    final name = routes.airportName.isEmpty
        ? widget.destination.name
        : routes.airportName;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFf8f9fc),
        border: Border.all(color: const Color(0xFFe2e8f0)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Primary Airport (Inbound & Outbound Direct Flights)',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFF64748b),
                letterSpacing: 0.5,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: 2),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0f172a),
                  )),
              if (routes.iataCode.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFe0e7ff),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(routes.iataCode,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF3730a3),
                      )),
                ),
            ],
          ),
        ],
      ),
    );
  }

  bool _hasTrains(FlightRoutes routes) =>
      routes.hsrRoutes.isNotEmpty ||
      (_isChina && routes.trainStations.isNotEmpty);

  bool _showTrains(FlightRoutes routes) => _hasTrains(routes) && _tab == 1;

  Widget _tabSwitcher(FlightRoutes routes) {
    return SegmentedButton<int>(
      segments: [
        ButtonSegment(
            value: 0,
            label: Text('Direct Flights (${routes.routes.length})')),
        ButtonSegment(
            value: 1,
            label:
                Text('High-Speed Trains (${routes.hsrRoutes.length})')),
      ],
      selected: {_tab},
      onSelectionChanged: (selection) =>
          setState(() => _tab = selection.first),
    );
  }

  /// The filter and the search. The counts are the
  /// current tab's, exactly like the legacy's
  /// per-tab radio options.
  Widget _filterAndSearch(FlightRoutes routes) {
    final trains = _showTrains(routes);
    // The two row types share no supertype, so the
    // count is taken where the rows are still typed.
    final (all, inPlannerCount) = _tabStats(routes, trains);
    return Row(
      children: [
        Expanded(
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: false,
                label: Text(trains
                    ? 'All Train Routes (${all.length})'
                    : 'All Routes (${all.length})'),
              ),
              ButtonSegment(
                value: true,
                label: Text('In Planner ($inPlannerCount)'),
              ),
            ],
            selected: {_inPlannerOnly},
            onSelectionChanged: (selection) =>
                setState(() => _inPlannerOnly = selection.first),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            onChanged: (value) => setState(() => _searchQuery = value),
            decoration: InputDecoration(
              hintText: trains
                  ? 'Search city or station…'
                  : 'Search city, airport, airline…',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  /// The current tab's unfiltered rows and how many
  /// of them are in the planner.
  (List<Object>, int) _tabStats(FlightRoutes routes, bool trains) {
    if (trains) {
      final rows = queryTrainRows(
          routes: routes.hsrRoutes, plannerLookup: _plannerLookup);
      return (rows, rows.where((row) => row.inPlanner).length);
    }
    final rows = queryFlightRows(
        routes: routes.routes, plannerLookup: _plannerLookup);
    return (rows, rows.where((row) => row.inPlanner).length);
  }

  Widget _flightsTab(FlightRoutes routes) {
    final rows = queryFlightRows(
      routes: routes.routes,
      plannerLookup: _plannerLookup,
      inPlannerOnly: _inPlannerOnly,
      query: _searchQuery,
    );
    // The legacy distinguishes "no research
    // result" from "the filter/search emptied
    // the list" -- an ambiguous "no results"
    // is exactly what the house rules forbid.
    if (routes.routes.isEmpty) {
      return const Text(
          'No direct flight routes were found for this destination.');
    }
    if (rows.isEmpty) {
      return const Text('No flight routes match the current filter/search.');
    }
    final theme = Theme.of(context);
    final label = theme.textTheme.bodySmall;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [
          DataColumn(label: Text('Destination', style: label)),
          DataColumn(label: Text('Country', style: label)),
          DataColumn(label: Text('Airport', style: label)),
          DataColumn(label: Text('Duration', style: label)),
          DataColumn(label: Text('Airlines', style: label)),
          DataColumn(label: Text('Frequency', style: label)),
          DataColumn(label: Text('Wishlist', style: label)),
          DataColumn(label: Text('Prio', style: label)),
          DataColumn(label: Text('Reviews', style: label)),
        ],
        rows: [
          for (final row in rows)
            DataRow(cells: [
              DataCell(Text(row.city, style: label)),
              DataCell(Text(row.country, style: label)),
              DataCell(Text(row.airport, style: label)),
              DataCell(Text(row.flightTime, style: label)),
              DataCell(_airlinesCell(row.airlines)),
              DataCell(Text(row.frequency, style: label)),
              DataCell(_wishlistCell(row.planner)),
              DataCell(Text(
                  _scoreText(row.planner?.prioInt), style: label)),
              DataCell(Text(
                  _scoreText(_reviews(row.planner)), style: label)),
            ]),
        ],
      ),
    );
  }

  Widget _trainsTab(FlightRoutes routes) {
    final stations = routes.trainStations.isNotEmpty
        ? routes.trainStations.join(', ')
        : '${widget.destination.name} Railway Station';
    final rows = queryTrainRows(
      routes: routes.hsrRoutes,
      plannerLookup: _plannerLookup,
      inPlannerOnly: _inPlannerOnly,
      query: _searchQuery,
    );
    final theme = Theme.of(context);
    final label = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFf0fdf4),
            border: Border.all(color: const Color(0xFFbbf7d0)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CHINA HIGH-SPEED RAIL HUB (CRH / 高铁)',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF166534),
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(height: 2),
              Text('🚄 $stations',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF14532d),
                  )),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (routes.hsrRoutes.isEmpty)
          const Text(
              'No direct high-speed rail connections were recorded for this destination.')
        else if (rows.isEmpty)
          const Text('No train routes match the current filter/search.')
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(label: Text('Destination', style: label)),
                DataColumn(label: Text('Arrival Station', style: label)),
                DataColumn(label: Text('Travel Time', style: label)),
                DataColumn(label: Text('Train Category', style: label)),
                DataColumn(label: Text('Frequency', style: label)),
                DataColumn(label: Text('Wishlist', style: label)),
                DataColumn(label: Text('Prio', style: label)),
                DataColumn(label: Text('Reviews', style: label)),
              ],
              rows: [
                for (final row in rows)
                  DataRow(cells: [
                    DataCell(Text(row.city, style: label)),
                    DataCell(Text(row.arrivalStation, style: label)),
                    DataCell(Text(row.travelTime, style: label)),
                    DataCell(Text(row.trainType, style: label)),
                    DataCell(Text(row.frequency, style: label)),
                    DataCell(_wishlistCell(row.planner)),
                    DataCell(Text(
                        _scoreText(row.planner?.prioInt), style: label)),
                    DataCell(Text(
                        _scoreText(_reviews(row.planner)), style: label)),
                  ]),
              ],
            ),
          ),
      ],
    );
  }

  Widget _airlinesCell(List<String> airlines) {
    if (airlines.isEmpty) return const Text('—');
    final colors = _colors ?? const AirlineColors({});
    return Row(
      children: [
        for (var i = 0; i < airlines.length; i++) ...[
          Text(
            airlines[i],
            style: TextStyle(
              color: _colorFor(colors.colorFor(airlines[i])),
              fontWeight: colors.isBold(airlines[i])
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
          if (i < airlines.length - 1) const Text(', '),
        ],
      ],
    );
  }

  Widget _wishlistCell(Destination? planner) {
    if (planner == null) return const Text('—');
    return TextButton(
      onPressed: () => widget.onOpenDestination?.call(planner),
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('In Planner'),
    );
  }

  /// The Prio or Review score, "6/10" or
  /// "6.5/10" — the legacy's `_format_score_
  /// display` (one decimal only when the value
  /// is not a whole number), or "—" when the
  /// city is not in the planner or holds no
  /// number.
  String _scoreText(num? value) {
    if (value == null) return '—';
    final text = value % 1 == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text/10';
  }

  num? _reviews(Destination? planner) {
    if (planner == null) return null;
    return Destination.toDouble(planner.column('Reviews'));
  }

  Color? _colorFor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      return Color(int.parse('0xFF${hex.replaceAll('#', '')}'));
    } catch (_) {
      return null;
    }
  }
}
