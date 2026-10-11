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
import '../models/destination.dart';
import 'destination_page.dart';

class CataloguePage extends StatefulWidget {
  final DestinationRepository repository;

  const CataloguePage({super.key, required this.repository});

  @override
  State<CataloguePage> createState() => _CataloguePageState();
}

class _CataloguePageState extends State<CataloguePage> {
  late Future<(List<Destination>, List<String>)> _future;
  var _query = '';

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
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search name or country',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
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
                  final filtered = needle.isEmpty
                      ? destinations
                      : [
                          for (final dest in destinations)
                            if (dest.name.toLowerCase().contains(needle) ||
                                (dest.country ?? '')
                                    .toLowerCase()
                                    .contains(needle))
                            dest,
                        ];
                  if (filtered.isEmpty) {
                    // Never an ambiguous "no results": say whether
                    // the database is empty or the search dropped
                    // everything.
                    return ListView(children: [
                      const SizedBox(height: 120),
                      Center(
                        child: Text(
                          destinations.isEmpty
                              ? 'The database holds no destinations.'
                              : 'No destination matches "$_query".',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    ]);
                  }
                  return ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final dest = filtered[index];
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
                  Text('Could not load destinations',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 8),
                for (final problem in problems) Text(problem),
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
