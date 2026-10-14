/// App shell: load the Turso config once, then a bottom
/// nav with Catalogue, Trips and the weekend Finder.
/// Unconfigured is a normal state -- the config file is
/// git-ignored -- so the shell explains how to configure
/// instead of crashing, the same state the Python side is
/// in without a token.
library;

import 'package:flutter/material.dart';

import '../data/app_dirs.dart';
import '../data/app_settings.dart';
import '../data/benefits_repository.dart';
import '../data/destination_repository.dart';
import '../data/geocode_repository.dart';
import '../data/open_tabs_repository.dart';
import '../data/trip_repository.dart';
import '../models/destination.dart';
import '../turso/config.dart';
import '../turso/pipeline_client.dart';
import 'catalogue_page.dart';
import 'destination_page.dart';
import 'nav_icons.dart';
import 'open_tabs.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'trips_page.dart';
import 'weekend_finder_page.dart';
import 'world_map_page.dart';

/// The destination whose page is on top, if any -- set by
/// the route observer from the named routes the push
/// sites create (`destination/<name>`), read by the
/// open-tabs list to mark the active tab.
final ValueNotifier<String?> activeDestinationRoute =
    ValueNotifier<String?>(null);

/// Keeps [activeDestinationRoute] in step with the
/// navigator. Every destination page is pushed with an
/// explicit name; a push of a non-destination route
/// (settings) clears the marker, a pop reveals whatever
/// destination route is below, if any.
class ActiveDestinationObserver extends NavigatorObserver {
  static String? _nameOf(Route? route) {
    final name = route?.settings.name ?? '';
    return name.startsWith('destination/')
        ? name.substring('destination/'.length)
        : null;
  }

  @override
  void didPush(Route route, Route? previousRoute) =>
      activeDestinationRoute.value = _nameOf(route);

  @override
  void didPop(Route route, Route? previousRoute) =>
      activeDestinationRoute.value = _nameOf(previousRoute);

  @override
  void didRemove(Route route, Route? previousRoute) =>
      activeDestinationRoute.value = _nameOf(previousRoute);

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) =>
      activeDestinationRoute.value = _nameOf(newRoute);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The per-device cache directories (the phone's
  // app-documents fallback) before the first frame.
  await initAppDirs();
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
      navigatorObservers: [ActiveDestinationObserver()],
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // Light is the app's mode: the map tiles and the
      // charts are imagery designed for light surfaces,
      // and a dark shell around white tiles looked broken
      // (the user's call, 2026-10-12).
      themeMode: ThemeMode.light,
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
  late final OpenTabsRepository openTabs;
  var _tab = 0;

  /// The open-destination tabs (the legacy sidebar's
  /// list): names in open order, the destination objects
  /// resolved once so a tab can open without a re-read,
  /// and the read problems -- a failed read is never
  /// presented as "no tabs open".
  var _openTabs = <String>[];
  final _tabDestinations = <String, Destination>{};
  var _tabProblems = const <String>[];

  /// The feature switch (settings page), persisted
  /// per device in `app_settings.json`.
  var _tabsEnabled = true;
  var _settingsDir = '';

  /// The width at which the shell switches from the
  /// phone bottom bar to the desktop side rail â€” the
  /// Material compact/medium boundary.
  static const _wideBreakpoint = 600.0;

  /// The desktop content is constrained and centred: a
  /// travel catalogue reads best in a column, not
  /// edge-to-edge, and the rail already owns the left
  /// of the window.
  static const _contentMaxWidth = 1100.0;

  static const _destinations = [
    NavigationDestination(
      icon: NavIcon(NavTabIcon.globe),
      selectedIcon: NavIcon(NavTabIcon.globe),
      label: 'Catalogue',
    ),
    NavigationDestination(
      icon: NavIcon(NavTabIcon.suitcase),
      selectedIcon: NavIcon(NavTabIcon.suitcase),
      label: 'Trips',
    ),
    NavigationDestination(
      icon: NavIcon(NavTabIcon.compass),
      selectedIcon: NavIcon(NavTabIcon.compass),
      label: 'Finder',
    ),
    NavigationDestination(
      icon: NavIcon(NavTabIcon.map),
      selectedIcon: NavIcon(NavTabIcon.map),
      label: 'Map',
    ),
  ];

  /// The rail's destinations are a different
  /// widget type than the bottom bar's, the same
  /// four tabs.
  static const _railDestinations = [
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.globe),
      selectedIcon: NavIcon(NavTabIcon.globe),
      label: Text('Catalogue'),
    ),
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.suitcase),
      selectedIcon: NavIcon(NavTabIcon.suitcase),
      label: Text('Trips'),
    ),
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.compass),
      selectedIcon: NavIcon(NavTabIcon.compass),
      label: Text('Finder'),
    ),
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.map),
      selectedIcon: NavIcon(NavTabIcon.map),
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
    openTabs = OpenTabsRepository(client);
    // The configured state dir wins (the desktop's repo
    // root); the phone falls back to its documents dir.
    _settingsDir = widget.config.stateDir.trim().isNotEmpty
        ? widget.config.stateDir
        : documentsDir();
    _tabsEnabled = AppSettings.load(_settingsDir).openTabsEnabled;
    _loadTabs();
  }

  /// Read the persisted tab list (and resolve its
  /// destination objects for the favourite stars). Runs
  /// once at startup; the result is shown only while the
  /// feature is enabled.
  Future<void> _loadTabs() async {
    final (tabs, problems) = await openTabs.loadTabs();
    if (!mounted) return;
    setState(() {
      _openTabs = tabs;
      _tabProblems = problems;
    });
    if (tabs.isEmpty) return;
    // One read covers every tab's object (and its
    // favourite flag); the stars are cosmetic, so a failed
    // catalogue read just leaves the plain pins.
    final (all, _) = await destinations.loadDestinations();
    if (!mounted) return;
    setState(() {
      for (final dest in all) {
        if (_openTabs.contains(dest.name)) {
          _tabDestinations[dest.name] = dest;
        }
      }
    });
  }

  /// Record a destination as opened. Called by the pages'
  /// open actions (null when the feature is off, so they
  /// skip it entirely); the push itself stays theirs.
  void _recordTab(String name) {
    if (_openTabs.contains(name)) return;
    setState(() => _openTabs.add(name));
    _persistTabs();
  }

  Future<void> _persistTabs() async {
    // Turso is last-write-wins and the tab list is a
    // whole-list value: every change replaces it all.
    final ok = await openTabs.saveTabs(_openTabs);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not save the open tabs -- '
            'they will not survive a restart.'),
      ));
    }
  }

  /// Close a tab: drop it from the list, persist, and pop
  /// the destination's page when it is the one on top
  /// (the legacy switches away when the active tab
  /// closes). A deep chain (a destination opened from
  /// another's related links) pops only its own top page.
  void _closeTab(String name) {
    setState(() => _openTabs.remove(name));
    _persistTabs();
    Navigator.of(context).popUntil(
        (route) => route.settings.name != 'destination/$name');
  }

  /// Open a tab: push the destination's page, resolving
  /// its object first when the startup catalogue read did
  /// not cover it (a tab persisted on another device).
  Future<void> _openTab(String name) async {
    var dest = _tabDestinations[name];
    dest ??= await _resolveDestination(name);
    if (dest == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      settings: RouteSettings(name: 'destination/${dest.name}'),
      builder: (_) =>
          DestinationPage(repository: destinations, destination: dest!),
    ));
  }

  Future<Destination?> _resolveDestination(String name) async {
    final (dest, problems) = await destinations.getDestination(name);
    if (!mounted) return null;
    if (dest == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(problems.isEmpty
            ? "Could not open '$name'."
            : problems.first),
      ));
      return null;
    }
    setState(() => _tabDestinations[name] = dest);
    return dest;
  }

  /// The settings page, reached from the catalogue's app
  /// bar. The shell owns the values; the page reports.
  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'settings'),
      builder: (_) => SettingsPage(
        openTabsEnabled: _tabsEnabled,
        onToggleTabs: _toggleTabs,
      ),
    ));
  }

  Future<void> _toggleTabs(bool on) async {
    final saved = AppSettings(openTabsEnabled: on).save(_settingsDir);
    if (!saved) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not save the setting.'),
      ));
      return;
    }
    setState(() => _tabsEnabled = on);
    if (on && _openTabs.isEmpty) await _loadTabs();
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final pages = IndexedStack(
      index: _tab,
      children: [
        CataloguePage(
          repository: destinations,
          // The recording callback is null while the
          // feature is off, so the pages skip it.
          onOpenDestination: _tabsEnabled ? _recordTab : null,
          onOpenSettings: _openSettings,
        ),
        TripsPage(
          repository: trips,
          destinations: destinations,
          geocoder: geocoder,
        ),
        WeekendFinderPage(
          benefits: benefits,
          destinations: destinations,
          onOpenDestination: _tabsEnabled ? _recordTab : null,
        ),
        WorldMapPage(
          repository: destinations,
          onOpenDestination: _tabsEnabled ? _recordTab : null,
        ),
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
                // The open-destination tabs: the legacy
                // sidebar's list, now a slim panel of its
                // own between the rail and the content.
                if (_tabsEnabled) ...[
                  ValueListenableBuilder<String?>(
                    valueListenable: activeDestinationRoute,
                    builder: (context, active, _) => OpenTabsPanel(
                      tabs: _openTabs,
                      destinations: _tabDestinations,
                      active: active,
                      problems: _tabProblems,
                      onOpen: _openTab,
                      onClose: _closeTab,
                    ),
                  ),
                  const VerticalDivider(thickness: 1, width: 1),
                ],
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
          : Column(
              children: [
                if (_tabsEnabled && _openTabs.isNotEmpty)
                  ValueListenableBuilder<String?>(
                    valueListenable: activeDestinationRoute,
                    builder: (context, active, _) => OpenTabsStrip(
                      tabs: _openTabs,
                      active: active,
                      onOpen: _openTab,
                      onClose: _closeTab,
                    ),
                  ),
                Expanded(child: pages),
              ],
            ),
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

