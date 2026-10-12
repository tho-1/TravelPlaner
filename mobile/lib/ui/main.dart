/// App shell: load the Turso config once, then a bottom
/// nav with Catalogue, Trips and the weekend Finder.
/// Unconfigured is a normal state -- the config file is
/// git-ignored -- so the shell explains how to configure
/// instead of crashing, the same state the Python side is
/// in without a token.
library;

import 'package:flutter/material.dart';

import '../data/benefits_repository.dart';
import '../data/destination_repository.dart';
import '../data/geocode_repository.dart';
import '../data/trip_repository.dart';
import '../turso/config.dart';
import '../turso/pipeline_client.dart';
import 'catalogue_page.dart';
import 'theme.dart';
import 'trips_page.dart';
import 'weekend_finder_page.dart';
import 'world_map_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(TravelPlannerApp(config: await TursoConfig.load()));
}

class TravelPlannerApp extends StatelessWidget {
  final TursoConfig config;

  const TravelPlannerApp({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Travel Planner',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: config.isConfigured
          ? HomeShell(config: config)
          : const UnconfiguredScreen(),
    );
  }
}

class UnconfiguredScreen extends StatelessWidget {
  const UnconfiguredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 40),
                  SizedBox(height: 12),
                  Text('Not configured',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text(
                    'The app reads its Turso credentials from '
                    'assets/turso_config.json, which is git-ignored. '
                    'Copy assets/turso_config.example.json to '
                    'assets/turso_config.json and fill in the token '
                    '(the same values .streamlit/secrets.toml holds).',
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

class HomeShell extends StatefulWidget {
  final TursoConfig config;

  const HomeShell({super.key, required this.config});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final DestinationRepository destinations;
  late final TripRepository trips;
  late final BenefitsRepository benefits;
  late final GeocodeRepository geocoder;
  var _tab = 0;

  /// The width at which the shell switches from the
  /// phone bottom bar to the desktop side rail — the
  /// Material compact/medium boundary.
  static const _wideBreakpoint = 600.0;

  /// The desktop content is constrained and centred: a
  /// travel catalogue reads best in a column, not
  /// edge-to-edge, and the rail already owns the left
  /// of the window.
  static const _contentMaxWidth = 1100.0;

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.public_outlined),
      selectedIcon: Icon(Icons.public),
      label: 'Catalogue',
    ),
    NavigationDestination(
      icon: Icon(Icons.luggage_outlined),
      selectedIcon: Icon(Icons.luggage),
      label: 'Trips',
    ),
    NavigationDestination(
      icon: Icon(Icons.travel_explore_outlined),
      selectedIcon: Icon(Icons.travel_explore),
      label: 'Finder',
    ),
    NavigationDestination(
      icon: Icon(Icons.map_outlined),
      selectedIcon: Icon(Icons.map),
      label: 'Map',
    ),
  ];

  /// The rail's destinations are a different
  /// widget type than the bottom bar's, the same
  /// four tabs.
  static const _railDestinations = [
    NavigationRailDestination(
      icon: Icon(Icons.public_outlined),
      selectedIcon: Icon(Icons.public),
      label: Text('Catalogue'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.luggage_outlined),
      selectedIcon: Icon(Icons.luggage),
      label: Text('Trips'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.travel_explore_outlined),
      selectedIcon: Icon(Icons.travel_explore),
      label: Text('Finder'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.map_outlined),
      selectedIcon: Icon(Icons.map),
      label: Text('Map'),
    ),
  ];

  @override
  void initState() {
    super.initState();
    final client = TursoClient(widget.config);
    destinations = DestinationRepository(client);
    trips = TripRepository(client);
    benefits = BenefitsRepository(widget.config);
    geocoder = GeocodeRepository(widget.config.geocodeCache);
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final pages = IndexedStack(
      index: _tab,
      children: [
        CataloguePage(repository: destinations),
        TripsPage(
          repository: trips,
          destinations: destinations,
          geocoder: geocoder,
        ),
        WeekendFinderPage(benefits: benefits, destinations: destinations),
        WorldMapPage(repository: destinations),
      ],
    );
    return Scaffold(
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab,
                  onDestinationSelected: (index) =>
                      setState(() => _tab = index),
                  destinations: _railDestinations,
                  labelType: NavigationRailLabelType.all,
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                          maxWidth: _contentMaxWidth),
                      child: pages,
                    ),
                  ),
                ),
              ],
            )
          : pages,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (index) =>
                  setState(() => _tab = index),
              destinations: _destinations,
            ),
    );
  }
}
