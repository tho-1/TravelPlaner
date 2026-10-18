/// The catalogue: every destination, text search on top.
///
/// Thin on purpose -- the logic lives in the repositories
/// and models, like the Streamlit pages do.
library;

import 'package:flutter/material.dart';
import 'dart:io' show File;

import '../data/ai_config.dart';
import '../data/deepseek_client.dart';
import '../data/destination_repository.dart';
import '../data/ai_populator.dart';
import '../data/catalogue_match.dart';
import '../data/photo_repository.dart';
import '../models/catalogue_filters.dart';
import '../models/destination.dart';
import '../models/destination_profile.dart';
import '../turso/config.dart';
import 'destination_page.dart';
import 'nav_icons.dart';
import 'theme.dart';
import 'filter_sheet.dart';

class CataloguePage extends StatefulWidget {
  final DestinationRepository repository;

  /// Called when a destination is opened, so the shell
  /// can record the open-destination tab. Null when the
  /// feature is off -- the open then pushes without
  /// recording, exactly the pre-tabs behavior.
  final void Function(String name)? onOpenDestination;

  /// Opens the settings page. Null hides the gear (the
  /// widget tests pump the catalogue standalone).
  final void Function()? onOpenSettings;

  const CataloguePage({
    super.key,
    required this.repository,
    this.onOpenDestination,
    this.onOpenSettings,
  });

  @override
  State<CataloguePage> createState() => _CataloguePageState();
}

class _CataloguePageState extends State<CataloguePage> {
  late Future<(List<Destination>, List<String>)> _future;
  var _query = '';
  var _quick = _QuickFilter.all;

  /// The shared filter set — the same model the map
  /// uses, so the two pages can never drift.
  CatalogueFilters _filters = CatalogueFilters.initial();

  /// Where per-destination photos live, if the machine
  /// has them: cards show a banner thumbnail when one
  /// exists (git-ignored desktop cache; empty on the
  /// phone, which simply has no photos).
  String? _picturesDir;

  /// Banner lookups are file IO — resolved once per
  /// destination per session and cached here, so a
  /// re-sort or a filter change does not re-scan.
  static final Map<String, Future<File?>> _bannerCache = {};

  @override
  void initState() {
    super.initState();
    _future = widget.repository.loadDestinations();
    TursoConfig.load().then((config) {
      if (mounted && config.picturesDir.trim().isNotEmpty) {
        setState(() => _picturesDir = config.picturesDir);
      }
    });
  }

  void _reload() {
    setState(() {
      _future = widget.repository.loadDestinations();
    });
  }

  Future<void> _openFilters() async {
    final (destinations, problems) = await _future;
    if (!mounted || problems.isNotEmpty) return;
    await openCatalogueFilterSheet(
      context,
      value: _filters,
      destinations: destinations,
      onChanged: (filters) => setState(() => _filters = filters),
    );
  }

  /// Add a new destination: a placeholder, optionally
  /// populated with DeepSeek in the same step -- the two
  /// options the legacy world-map dialog offers. Key-gated:
  /// without a key the second option is not offered, and
  /// the placeholder is still added.
  Future<void> _addDestination() async {
    final nameController = TextEditingController();
    final countryController = TextEditingController(text: 'Unknown');
    final ai = await AiConfig.load();
    if (!mounted) return;

    final choice = await showDialog<(String, bool)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a destination'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            Autocomplete<String>(
              optionsBuilder: (value) {
                final q = value.text.trim().toLowerCase();
                final names = CountryNames.allNames;
                if (q.isEmpty) return names;
                return names
                    .where((n) => n.toLowerCase().contains(q));
              },
              onSelected: (value) => countryController.text = value,
              fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                controller.text = countryController.text;
                controller.addListener(() => countryController.text = controller.text);
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(labelText: 'Country'),
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (ai.isConfigured)
            TextButton(
              onPressed: () => Navigator.pop(context, ('withAi', true)),
              child: const Text('Add & populate with AI'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ('placeholder', false)),
            child: const Text('Add placeholder'),
          ),
        ],
      ),
    );
    try {
      if (choice == null) return;
      final (mode, withAi) = choice;
      final name = nameController.text.trim();
      if (name.isEmpty) {
        // A blank name is not an add: say so instead of
        // silently doing nothing (the buttons stay
        // enabled, so this path is reachable).
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A name is required -- nothing was added.'),
        ));
        return;
      }
       final country = countryController.text.trim().isEmpty
           ? 'Unknown'
           : countryController.text.trim();
       final continent = 'Unknown';

       final added = await widget.repository.addDestination(
         name: name,
         country: country,
         continent: continent,
       );
       if (!mounted) return;
       if (!added) {
         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
           content: Text(
               'Could not add the destination -- it exists already, '
               'or the write failed.'),
         ));
         return;
       }
       _reload();
       if (withAi) {
         await _populate(name, country, continent);
       }
     } finally {
       nameController.dispose();
       countryController.dispose();
     }
  }

  /// The second half of the add: ask DeepSeek and write the
  /// profile onto the row that was just added.
  Future<void> _populate(String name, String country, String continent) async {
    final messenger = ScaffoldMessenger.of(context);
    final ai = await AiConfig.load();
    final client = DeepSeekClient(ai);
    try {
      final profile = await client.generateDestinationProfile(
        destination: name,
        country: country,
        continent: continent,
      );
      final (destination, problems) =
          await widget.repository.getDestination(name);
      if (destination == null || problems.isNotEmpty) {
        messenger.showSnackBar(const SnackBar(
            content: Text('The profile arrived but the destination '
                'could not be read back.')));
        return;
      }
      final updated = AiPopulator(destination).apply(profile);
      final ok = await widget.repository.saveDestination(updated);
      messenger.showSnackBar(SnackBar(
        content: Text(ok
            ? "Destination '$name' added and populated with DeepSeek AI"
            : 'The profile was generated but nothing was written.'),
      ));
      if (ok) _reload();
    } on DeepSeekError catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Open one destination's detail page. The shell's
  /// callback (when set) records the open tab before the
  /// push; the named route lets the shell mark the tab
  /// active and pop it on close.
  void _openDestination(Destination dest) {
    widget.onOpenDestination?.call(dest.name);
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: RouteSettings(name: 'destination/${dest.name}'),
        builder: (_) => DestinationPage(
          repository: widget.repository,
          destination: dest,
          onChanged: _reload,
          onOpenDestination: widget.onOpenDestination,
        ),
      ),
    );
  }

  /// The legacy's group header: the country name with
  /// its count. The port now gives the header a real
  /// shaded band in the theme's primary colour -- the
  /// old alternating near-invisible tints did not read
  /// as section headers.
  Widget _groupHeader(String country, int count, int groupIndex) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border(
            left: BorderSide(
                color: scheme.primary.withValues(alpha: 0.55), width: 5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              country,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// One destination on its group's tint. A travel
  /// catalogue should feel like places, not a spreadsheet:
  /// the card leads with the destination's banner photo
  /// when the machine has one (initial-letter tile when it
  /// does not), and a continent-coloured dot rides the
  /// subtitle.
  Widget _destinationCard(Destination dest, int groupIndex) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: _groupTint(groupIndex, scheme),
        borderRadius: BorderRadius.circular(8),
        border: Border(
            left:
                BorderSide(color: _groupAccent(groupIndex, scheme), width: 3)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openDestination(dest),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CardThumb(destination: dest, picturesDir: _picturesDir),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dest.name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (dest.continent != null &&
                          dest.continent!.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: _continentColor(dest.continent!),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                dest.continent!,
                                style: theme.textTheme.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 2),
                      // The facts a catalogue scan needs
                      // (review rating, prio, population).
                      // A Wrap, not a single ellipsised
                      // line: the old meta line was cut off
                      // at phone width and labelled the
                      // wrong things (2026-10-16).
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (dest.visited)
                            Icon(Icons.check_circle,
                                size: 15, color: scheme.primary),
                          if (dest.favourite)
                            Icon(Icons.star,
                                size: 15, color: accentFavourite),
                          for (final fact in _metaFacts(dest))
                            Text(fact, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Continent accents — a small repeated colour cue that
  /// makes the list scannable ("where are the Asian
  /// destinations?") without a filter.
  Color _continentColor(String continent) {
    final normalized = continent.toLowerCase();
    if (normalized.contains('europe')) return const Color(0xFF4FA3D1);
    if (normalized.contains('asia')) return const Color(0xFFE57373);
    if (normalized.contains('africa')) return const Color(0xFFE3A857);
    if (normalized.contains('north')) return const Color(0xFF81C784);
    if (normalized.contains('south')) return const Color(0xFFBA68C8);
    if (normalized.contains('oceania') ||
        normalized.contains('australia')) {
      return const Color(0xFF4DB6AC);
    }
    return const Color(0xFF90A4AE);
  }

  /// The at-a-glance facts: **Review Rating, Prio (only
  /// when the column is populated) and Population** — the
  /// three numbers that decide "is this worth opening?". It
  /// replaced the truncated safety/cost/flight line
  /// (2026-10-16, the user's report g).
  List<String> _metaFacts(Destination dest) {
    final facts = <String>[];
    final review = coerceNumber(dest.column('Reviews'));
    if (review != null) {
      facts.add('Review ${_trim(review)}/10');
    }
    final prio = dest.prio;
    if (!isBlank(prio)) {
      // `Prio Thorsten` is an object/text column ("n/a"
      // occurs): show the raw text rather than a fake 0.
      final number = coerceNumber(prio);
      facts.add('Prio ${number == null ? '$prio'.trim() : _trim(number)}');
    }
    final population = coerceNumber(dest.column('Population (Metro Area)'));
    if (population != null) {
      facts.add('Population ${_compactNumber(population)}');
    }
    return facts;
  }

  /// "10.7M" / "430K" — the same compact form the detail
  /// page's population KPI uses.
  static String _compactNumber(double value) {
    if (value >= 1000000) return '${_trim(value / 1000000)}M';
    if (value >= 1000) return '${_trim(value / 1000)}K';
    return _trim(value);
  }

  static String _trim(double value) =>
      value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toStringAsFixed(1);

  Color _groupTint(int groupIndex, ColorScheme scheme) =>
      groupIndex.isEven
          ? scheme.surfaceContainerLowest
          : scheme.surfaceContainerLow;

  Color _groupAccent(int groupIndex, ColorScheme scheme) =>
      groupIndex.isEven
          ? scheme.primary.withValues(alpha: 0.3)
          : scheme.outlineVariant;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalogue'),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _filters.isActive,
              child: const Icon(Icons.filter_list),
            ),
            tooltip: 'Filters',
            onPressed: _openFilters,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add a destination',
            onPressed: _addDestination,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
          if (widget.onOpenSettings != null)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: widget.onOpenSettings,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search name or country',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final quick in _QuickFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(quick.label),
                      avatar: Icon(quick.icon, size: 18),
                      selected: _quick == quick,
                      onSelected: (_) =>
                          setState(() => _quick = quick),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: FutureBuilder<(List<Destination>, List<String>)>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final (destinations, problems) =
                      snapshot.data ?? (<Destination>[], <String>['no result']);
                  if (problems.isNotEmpty) {
                    return _ProblemView(problems: problems, onRetry: _reload);
                  }
                  final needle = _query.trim().toLowerCase();
                  final matches = [
                    for (final dest in destinations)
                      if (needle.isEmpty ||
                          dest.name.toLowerCase().contains(needle) ||
                          (dest.country ?? '')
                              .toLowerCase()
                              .contains(needle))
                        dest,
                  ];
                  // The shared filter set, then the quick
                  // chip on top of it. The "Visited" view
                  // and the default "only unvisited" filter
                  // contradict -- together they can never
                  // match (the visited rows are filtered out
                  // before the chip sees them: the dead end
                  // found on the phone 2026-10-14), so the
                  // explicit view wins while it is selected.
                  // The stored filter is untouched and "All"
                  // restores the default view.
                  final outcome = applyCatalogueFilters(
                    matches,
                    _quick == _QuickFilter.visited
                        ? _filters.copyWith(onlyUnvisited: false)
                        : _filters,
                    (dest) => DestinationProfile.from(dest),
                  );
                  final filtered = [
                    for (final dest in outcome.kept)
                      if (_quick.accepts(dest)) dest,
                  ];
                  if (filtered.isEmpty) {
                    // Never an ambiguous "no results": say whether
                    // the database is empty or the filter dropped
                    // everything.
                    return ListView(children: [
                      const SizedBox(height: 100),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // The app's own globe illustration
                              // instead of a grey icon: even the
                              // empty state says "travel".
                              Opacity(
                                opacity: 0.85,
                                child: NavIcon(
                                  destinations.isEmpty
                                      ? NavTabIcon.globe
                                      : NavTabIcon.compass,
                                  size: 64,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                destinations.isEmpty
                                    ? 'The database holds no destinations.'
                                    : matches.isEmpty
                                        ? 'No destination matches "$_query".'
                                        : 'No ${_quick.label.toLowerCase()} '
                                            'destination matches '
                                            '"$_query" (${matches.length} '
                                            'matched before the filter).',
                                textAlign: TextAlign.center,
                                style:
                                    Theme.of(context).textTheme.bodyLarge,
                              ),
                              if (destinations.isNotEmpty &&
                                  matches.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'Loosen the search or the filters — '
                                  'the world is still out there.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ]);
                  }
                  // The legacy overview's structure:
                  // country sections with tinted
                  // headers and per-country counts,
                  // the destinations in a grid whose
                  // column count follows the width --
                  // one on a phone, three on desktop.
                  final groups = groupByCountry(filtered);
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth < 600
                          ? 1
                          : constraints.maxWidth < 900
                              ? 2
                              : 3;
                      final children = <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                          child: Text(
                            '${filtered.length} of ${destinations.length} '
                            'destinations. ${outcome.missingCaption}',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                      ];
                      for (var g = 0; g < groups.length; g++) {
                        final group = groups[g];
                        if (group.country != null) {
                          children.add(_groupHeader(
                              group.country!, group.destinations.length, g));
                        }
                        final inGroup = group.destinations;
                        for (var start = 0;
                            start < inGroup.length;
                            start += columns) {
                          final row =
                              inGroup.skip(start).take(columns).toList();
                          children.add(Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final dest in row)
                                Expanded(child: _destinationCard(dest, g)),
                            ],
                          ));
                        }
                      }
                      return ListView(children: children);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The catalogue's quick filters. A filter that empties the
/// list says so in the empty state, like every other one.
/// These are presets on top of the shared [CatalogueFilters]
/// — the legacy panel itself is the filter sheet.
enum _QuickFilter {
  all('All', Icons.public_outlined),
  visited('Visited', Icons.check_circle_outline),
  favourites('Favourites', Icons.star_outline),
  research('To research', Icons.help_outline);

  final String label;
  final IconData icon;
  const _QuickFilter(this.label, this.icon);

  bool accepts(Destination destination) {
    switch (this) {
      case _QuickFilter.all:
        return true;
      case _QuickFilter.visited:
        return destination.visited;
      case _QuickFilter.favourites:
        return destination.favourite;
      case _QuickFilter.research:
        return destination.toBeResearched;
    }
  }
}

/// The card's photo: the destination's banner from the
/// machine's `Pictures/` cache, or a tinted initial tile
/// when there is none. Resolved through the page-level
/// cache so filter changes do not re-scan the disk.
class _CardThumb extends StatelessWidget {
  final Destination destination;
  final String? picturesDir;

  const _CardThumb({required this.destination, required this.picturesDir});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (picturesDir == null) {
      return _initialTile(context, scheme);
    }
    return FutureBuilder<File?>(
      future: _CataloguePageState._bannerCache.putIfAbsent(
        destination.name,
        () => _loadBanner(picturesDir!, destination.name),
      ),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return _initialTile(context, scheme);
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            file,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _initialTile(context, scheme),
          ),
        );
      },
    );
  }

  /// One banner lookup; failures are the normal
  /// no-photos state, not errors.
  static Future<File?> _loadBanner(String dir, String name) async {
    try {
      return await PhotoRepository(dir).findBanner(name, name);
    } catch (_) {
      return null;
    }
  }

  Widget _initialTile(BuildContext context, ColorScheme scheme) {
    final initial = destination.name.isEmpty
        ? '?'
        : destination.name.substring(0, 1).toUpperCase();
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
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
                  // Expanded: the title must wrap, not overflow a
                  // phone-width card.
                  Expanded(child: Text('Could not load destinations')),
                ]),
                const SizedBox(height: 8),
                for (final problem in problems)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(problem),
                  ),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      ),
    ]);
  }
}
