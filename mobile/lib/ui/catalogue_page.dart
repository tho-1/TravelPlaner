/// The catalogue: every destination, text search on top.
///
/// Thin on purpose -- the logic lives in the repositories
/// and models, like the Streamlit pages do.
library;

import 'package:flutter/material.dart';

import '../data/destination_repository.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalogue'),
        actions: [
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
