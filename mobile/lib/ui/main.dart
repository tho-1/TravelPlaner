/// App shell: load the Turso config once, then a bottom
/// nav with Catalogue, Trips and the weekend Finder.
/// Unconfigured is a normal state -- the config file is
/// git-ignored -- so the shell explains how to configure
/// instead of crashing, the same state the Python side is
/// in without a token.
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/app_dirs.dart';
import '../data/app_settings.dart';
import '../data/offline_cache.dart';
import '../data/ai_config.dart';
import '../data/benefits_repository.dart';
import '../data/destination_repository.dart';
import '../data/error_log.dart';
import '../data/geocode_repository.dart';
import '../data/open_tabs_repository.dart';
import '../data/trip_repository.dart';
import '../models/destination.dart';
import '../models/timetable.dart';
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
  final config = await TursoConfig.load();
  // The error log (report f): one JSONL file per device,
  // next to the settings file. The global hooks mean an
  // uncaught error is on record for later analysis instead
  // of dying with the toast.
  ErrorLog.instance.bind(stateDirFor(config.stateDir));
  FlutterError.onError = (details) {
    ErrorLog.instance.record(
      'flutter',
      details.exceptionAsString(),
      details: {'stack': '${details.stack}'},
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorLog.instance
        .record('flutter', '$error', details: {'stack': '$stack'});
    return true;
  };
  runApp(TravelPlannerApp(config: config));
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

  /// The finder's second flight source (report j): built
  /// only when a FlightAware key is configured, and only
  /// ever asked about windows that look broken. Rebuilt
  /// when the user rotates the key in settings.
  late final FlightBoardProvider? flightFallback;

  /// The resolved Turso client, recreated when a key is
  /// rotated so the new token takes effect immediately.
  TursoClient? _client;
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
      icon: NavIcon(NavTabIcon.map),
      selectedIcon: NavIcon(NavTabIcon.map),
      label: 'Map',
    ),
    NavigationDestination(
      icon: NavIcon(NavTabIcon.globe),
      selectedIcon: NavIcon(NavTabIcon.globe),
      label: 'Catalogue',
    ),
    NavigationDestination(
      icon: NavIcon(NavTabIcon.suitcase),
      selectedIcon: NavIcon(NavTabIcon.suitcase),
      label: 'Trip Planner',
    ),
    NavigationDestination(
      icon: NavIcon(NavTabIcon.compass),
      selectedIcon: NavIcon(NavTabIcon.compass),
      label: 'Finder',
    ),
  ];

  /// The rail's destinations are a different
  /// widget type than the bottom bar's, the same
  /// four tabs.
  static const _railDestinations = [
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.map),
      selectedIcon: NavIcon(NavTabIcon.map),
      label: Text('Map'),
    ),
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.globe),
      selectedIcon: NavIcon(NavTabIcon.globe),
      label: Text('Catalogue'),
    ),
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.suitcase),
      selectedIcon: NavIcon(NavTabIcon.suitcase),
      label: Text('Trip Planner'),
    ),
    NavigationRailDestination(
      icon: NavIcon(NavTabIcon.compass),
      selectedIcon: NavIcon(NavTabIcon.compass),
      label: Text('Finder'),
    ),
  ];

  @override
  void initState() {
    super.initState();
    // The configured state dir wins (the desktop's repo
    // root) — but only when it is absolute on *this*
    // platform: the bundled config carries the PC path,
    // which is unwritable on the phone. There the app's
    // documents dir holds the settings file.
    _settingsDir = stateDirFor(widget.config.stateDir);
    final settings = AppSettings.load(_settingsDir);
    setConfigOverrides(settings);
    _tabsEnabled = settings.openTabsEnabled;
    _rebuildClients();
    _loadTabs();
  }

  /// Recreate the Turso clients and the finder fallback from
  /// the effective config (bundled values plus any per-device
  /// key overrides the user has set in settings). Called at
  /// startup and whenever the user rotates a key.
  void _rebuildClients() {
    final effective = _effectiveConfig();
    _client = TursoClient(effective);
    // The offline-first snapshot store (Phase 5, Option A):
    // next to the settings file in the per-device state
    // dir; null when there is no writable home (tests).
    final home = stateDirFor(effective.stateDir).trim();
    final offline = home.isEmpty ? null : OfflineCache(p.join(home, 'offline_snapshot'));
    destinations = DestinationRepository(_client!, offline: offline);
    trips = TripRepository(_client!, offline: offline);
    benefits = BenefitsRepository(effective);
    geocoder = GeocodeRepository(effective.geocodeCache);
    openTabs = OpenTabsRepository(_client!);
    flightFallback = effective.fallbackFlightsConfigured
        ? AeroApiBoardProvider(apiKey: effective.flightAwareApiKey)
        : null;
  }

  /// Bundled config with any per-device key overrides laid on
  /// top. Synchronous -- no asset re-read -- so it is safe to
  /// call from initState and from the settings callback.
  TursoConfig _effectiveConfig() {
    final bundled = widget.config;
    final overrides = configOverrides;
    return TursoConfig(
      url: bundled.url,
      token: (overrides?.tursoToken?.isNotEmpty == true
              ? overrides!.tursoToken
              : bundled.token) ??
          '',
      benefitsUrl: bundled.benefitsUrl,
      benefitsToken: (overrides?.benefitsToken?.isNotEmpty == true
              ? overrides!.benefitsToken
              : bundled.benefitsToken) ??
          '',
      iqairSnapshot: bundled.iqairSnapshot,
      picturesDir: bundled.picturesDir,
      flightRoutesCache: bundled.flightRoutesCache,
      geocodeCache: bundled.geocodeCache,
      stateDir: bundled.stateDir,
      flightAwareApiKey: (overrides?.flightAwareApiKey?.isNotEmpty == true
              ? overrides!.flightAwareApiKey
              : bundled.flightAwareApiKey) ??
          '',
    );
  }

  /// Rotate one API key: persist the override, make it the
  /// effective value for every subsequently created client,
  /// and rebuild the live clients so the change takes effect
  /// without a restart. Returns whether the write persisted.
  Future<bool> _rotateKey(String name, String value) async {
    final current = AppSettings.load(_settingsDir);
    // Preserve every other override: copyWith's null-means-clear
    // semantics would otherwise wipe the rest on a single-key
    // rotation.
    String? tursoToken = current.tursoToken;
    String? benefitsToken = current.benefitsToken;
    String? deepseekApiKey = current.deepseekApiKey;
    String? deepseekModel = current.deepseekModel;
    String? flightAwareApiKey = current.flightAwareApiKey;
    switch (name) {
      case 'turso_token':
        tursoToken = value.trim().isEmpty ? null : value.trim();
        break;
      case 'benefits_token':
        benefitsToken = value.trim().isEmpty ? null : value.trim();
        break;
      case 'deepseek_api_key':
        deepseekApiKey = value.trim().isEmpty ? null : value.trim();
        break;
      case 'deepseek_model':
        deepseekModel = value.trim().isEmpty ? null : value.trim();
        break;
      case 'flight_aware_api_key':
        flightAwareApiKey = value.trim().isEmpty ? null : value.trim();
        break;
      default:
        return false;
    }
    final updated = AppSettings(
      openTabsEnabled: current.openTabsEnabled,
      tursoToken: tursoToken,
      benefitsToken: benefitsToken,
      deepseekApiKey: deepseekApiKey,
      deepseekModel: deepseekModel,
      flightAwareApiKey: flightAwareApiKey,
    );
    final saved = updated.save(_settingsDir);
    if (!saved || !mounted) return false;
    setConfigOverrides(updated);
    _rebuildClients();
    setState(() {});
    return true;
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

  /// Close a tab: drop it from the list and persist. The
  /// destination's page is popped when it is the one on top
  /// (the legacy switches away when the active tab closes)
  /// -- except when the close comes from the open-items
  /// sheet, where popping under the sheet would tear the
  /// stack apart. A deep chain (a destination opened from
  /// another's related links) pops only its own top page.
  void _closeTab(String name, {bool popRoute = true}) {
    setState(() => _openTabs.remove(name));
    _persistTabs();
    if (!popRoute) return;
    Navigator.of(context).popUntil(
        (route) => route.settings.name != 'destination/$name');
  }

  /// Close every tab at once (the sheet's "Close all").
  void _closeAllTabs() {
    setState(() => _openTabs.clear());
    _persistTabs();
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
  Future<void> _openSettings() async {
    final effective = _effectiveConfig(); // bundled Turso + overrides
    final ai = await AiConfig.load(); // bundled DeepSeek + override
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'settings'),
      builder: (_) => SettingsPage(
        openTabsEnabled: _tabsEnabled,
        onToggleTabs: _toggleTabs,
        apiKeys: {
          'turso_token': (
            'Turso database token',
            effective.token.isNotEmpty,
            _mask(effective.token),
          ),
          'benefits_token': (
            'Benefits database token',
            effective.benefitsToken.isNotEmpty,
            _mask(effective.benefitsToken),
          ),
          'deepseek_api_key': (
            'DeepSeek AI key',
            ai.apiKey.isNotEmpty,
            _mask(ai.apiKey),
          ),
          'deepseek_model': (
            'DeepSeek model',
            ai.model.isNotEmpty,
            ai.model,
          ),
          'flight_aware_api_key': (
            'FlightAware fallback key',
            effective.flightAwareApiKey.isNotEmpty,
            _mask(effective.flightAwareApiKey),
          ),
        },
        onRotateKey: _rotateKey,
      ),
    ));
  }

  /// Show a key as bullets with the last four characters
  /// visible; empty when nothing is configured.
  static String _mask(String? value) {
    if (value == null || value.isEmpty) return '';
    if (value.length <= 4) return '•' * value.length;
    return '•' * (value.length - 4) + value.substring(value.length - 4);
  }

  /// Persist the settings switch; returns whether it was
  /// saved, so the page's switch only moves on a confirmed
  /// write. The Turso tab list itself is untouched by a
  /// toggle -- switching back on restores the list. Any
  /// key overrides already in `app_settings.json` are kept.
  Future<bool> _toggleTabs(bool on) async {
    final current = AppSettings.load(_settingsDir);
    final updated = AppSettings(
      openTabsEnabled: on,
      tursoToken: current.tursoToken,
      benefitsToken: current.benefitsToken,
      deepseekApiKey: current.deepseekApiKey,
      deepseekModel: current.deepseekModel,
      flightAwareApiKey: current.flightAwareApiKey,
    );
    final saved = updated.save(_settingsDir);
    if (!saved) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not save the setting.'),
      ));
      return false;
    }
    setConfigOverrides(updated);
    setState(() => _tabsEnabled = on);
    if (on && _openTabs.isEmpty) await _loadTabs();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final pages = IndexedStack(
      index: _tab,
       children: [
         WorldMapPage(
           repository: destinations,
           onOpenDestination: _tabsEnabled ? _recordTab : null,
         ),
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
           fallback: flightFallback,
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
      // The open destinations are one floating button now
      // (report i): the desktop panel and the phone strip
      // are gone, and the button appears only when there is
      // something to hold -- open tabs, or a read problem
      // the user must see.
      floatingActionButton: _tabsEnabled &&
              (_openTabs.isNotEmpty || _tabProblems.isNotEmpty)
          ? OpenTabsFab(
              count: _openTabs.length,
              hasProblems: _tabProblems.isNotEmpty,
              onPressed: _showOpenTabs,
            )
          : null,
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

  /// The open-items sheet behind the floating button: the
  /// rows open and close exactly like the old panel's did.
  void _showOpenTabs() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          void refresh() => setSheetState(() {});
          return ValueListenableBuilder<String?>(
            valueListenable: activeDestinationRoute,
            builder: (context, active, _) => OpenTabsSheet(
              tabs: _openTabs,
              destinations: _tabDestinations,
              active: active,
              problems: _tabProblems,
              onOpen: (name) {
                Navigator.of(sheetContext).pop();
                _openTab(name);
              },
              onClose: (name) {
                _closeTab(name, popRoute: false);
                refresh();
              },
              onCloseAll: () {
                _closeAllTabs();
                refresh();
              },
            ),
          );
        },
      ),
    );
  }
}

