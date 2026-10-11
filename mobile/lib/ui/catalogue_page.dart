/// The catalogue: every destination, text search on top.
///
/// Thin on purpose -- the logic lives in the repositories
/// and models, like the Streamlit pages do.
library;

import 'package:flutter/material.dart';

import '../data/ai_config.dart';
import '../data/deepseek_client.dart';
import '../data/destination_repository.dart';
import '../data/ai_populator.dart';
import '../models/catalogue_filters.dart';
import '../models/destination.dart';
import '../models/destination_profile.dart';
import 'destination_page.dart';
import 'filter_sheet.dart';

class CataloguePage extends StatefulWidget {
  final DestinationRepository repository;

  const CataloguePage({super.key, required this.repository});

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

  @override
  void initState() {
    super.initState();
    _future = widget.repository.loadDestinations();
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
    final continentController = TextEditingController(text: 'Unknown');
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
            TextField(
              controller: countryController,
              decoration: const InputDecoration(labelText: 'Country'),
            ),
            TextField(
              controller: continentController,
              decoration: const InputDecoration(labelText: 'Continent'),
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
    if (choice == null) return;
    final (mode, withAi) = choice;
    final name = nameController.text.trim();
    if (name.isEmpty) return;
    final country = countryController.text.trim().isEmpty
        ? 'Unknown'
        : countryController.text.trim();
    final continent = continentController.text.trim().isEmpty
        ? 'Unknown'
        : continentController.text.trim();

    final added = await widget.repository.addDestination(
      name: name,
      country: country,
      continent: continent,
    );
    if (!mounted) return;
    if (!added) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not add the destination -- it exists already, '
            'or the write failed.'),
      ));
      return;
    }
    _reload();
    if (withAi) {
      await _populate(name, country, continent);
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
                  // chip on top of it.
                  final outcome = applyCatalogueFilters(
                    matches,
                    _filters,
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
                      const SizedBox(height: 120),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                destinations.isEmpty
                                    ? Icons.public_off_outlined
                                    : Icons.filter_alt_off_outlined,
                                size: 48,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              const SizedBox(height: 12),
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
                            ],
                          ),
                        ),
                      ),
                    ]);
                  }
                  return ListView.builder(
                    itemCount: filtered.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
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
                        );
                      }
                      final dest = filtered[index - 1];
                      return ListTile(
                        title: Text(dest.name),
                        subtitle: Text([
                          if (dest.country != null &&
                              dest.country!.isNotEmpty)
                            dest.country!,
                          if (dest.continent != null &&
                              dest.continent!.isNotEmpty)
                            dest.continent!,
                        ].join(' · ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (dest.visited)
                              Icon(Icons.check_circle,
                                  size: 18,
                                  color:
                                      Theme.of(context).colorScheme.primary),
                            if (dest.favourite)
                              Icon(Icons.star,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.tertiary),
                          ],
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => DestinationPage(
                                repository: widget.repository,
                                destination: dest,
                                onChanged: _reload,
                              ),
                            ),
                          );
                        },
                      );
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
