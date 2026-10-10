/// App shell: load the Turso config once, then a bottom
/// nav with Catalogue and Trips. Unconfigured is a normal
/// state -- the config file is git-ignored -- so the shell
/// explains how to configure instead of crashing, the
/// same state the Python side is in without a token.
library;

import 'package:flutter/material.dart';

import '../data/destination_repository.dart';
import '../data/trip_repository.dart';
import '../turso/config.dart';
import '../turso/pipeline_client.dart';
import 'catalogue_page.dart';
import 'trips_page.dart';

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
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
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
  var _tab = 0;

  @override
  void initState() {
    super.initState();
    final client = TursoClient(widget.config);
    destinations = DestinationRepository(client);
    trips = TripRepository(client);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          CataloguePage(repository: destinations),
          TripsPage(repository: trips),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
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
        ],
      ),
    );
  }
}
