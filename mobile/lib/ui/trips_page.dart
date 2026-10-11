/// Trips: the stored itineraries with variants, stops and
/// legs. Read-only display plus trip delete -- editing
/// stays on the desktop side for now.
library;

import 'package:flutter/material.dart';

import '../data/trip_repository.dart';
import '../models/trip.dart';

class TripsPage extends StatefulWidget {
  final TripRepository repository;

  const TripsPage({super.key, required this.repository});

  @override
  State<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends State<TripsPage> {
  late Future<(List<Trip>, List<String>)> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.repository.loadTrips();
  }

  void _reload() {
    setState(() {
      _future = widget.repository.loadTrips();
    });
  }

  Future<void> _delete(Trip trip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete trip?'),
        content: Text(
            '"${trip.name}" with ${trip.variants.length} '
            'variant(s) is deleted from the database. '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await widget.repository.deleteTrip(trip.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Deleted "${trip.name}"'
          : 'Nothing deleted -- the write failed. '
              'Check the token and the connection.'),
    ));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trips'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: FutureBuilder<(List<Trip>, List<String>)>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (trips, problems) =
              snapshot.data ?? (<Trip>[], <String>['no result']);
          if (problems.isNotEmpty) {
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
                          // Expanded: the title wraps instead of
                          // overflowing a phone-width card.
                          Expanded(child: Text('Could not load trips')),
                        ]),
                        const SizedBox(height: 8),
                        for (final problem in problems)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(problem),
                          ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                            onPressed: _reload, child: const Text('Retry')),
                      ],
                    ),
                  ),
                ),
              ),
            ]);
          }
          if (trips.isEmpty) {
            return const _TripsEmptyState();
          }
          if (trips.isEmpty) {
            return const Center(child: Text('No trips stored.'));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              children: [
                for (final trip in trips)
                  TripTile(trip: trip, onDelete: () => _delete(trip)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The "no trips yet" state. Editing trips stays on the
/// desktop side, so the app says where to go next instead
/// of just "nothing here".
class _TripsEmptyState extends StatelessWidget {
  const _TripsEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.luggage_outlined,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No trips stored', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Plan a trip in the desktop app -- the variants, stops and '
              'legs appear here read-only.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TripTile extends StatelessWidget {
  final Trip trip;
  final VoidCallback onDelete;

  const TripTile({super.key, required this.trip, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.luggage_outlined),
      title: Text(trip.name),
      subtitle: Text(
        '${trip.variants.length} variant'
        '${trip.variants.length == 1 ? '' : 's'}'
        '${trip.created == null ? '' : ' · created ${trip.created}'}',
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
      children: [
        for (final variant in trip.variants)
          ExpansionTile(
            title: Text(variant.name),
            subtitle: Text([
              if (variant.months.isNotEmpty) variant.months.join(', '),
              if (variant.rating != null) 'rating ${variant.rating}',
            ].join(' · ')),
            children: [
              if (variant.notes.isNotEmpty)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.notes),
                  title: Text(variant.notes),
                ),
              for (var i = 0; i < variant.stops.length; i++)
                _StopTile(index: i, stop: variant.stops[i]),
              for (var i = 0; i < variant.legs.length; i++)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.route),
                  title: Text(
                      'Leg ${i + 1}: ${variant.legs[i].mode}'),
                  subtitle: variant.legs[i].note.isEmpty
                      ? null
                      : Text(variant.legs[i].note),
                ),
              if (variant.stops.isEmpty && variant.legs.isEmpty)
                const ListTile(
                  dense: true,
                  title: Text('No stops or legs stored.'),
                ),
            ],
          ),
      ],
    );
  }
}

class _StopTile extends StatelessWidget {
  final int index;
  final Stop stop;

  const _StopTile({required this.index, required this.stop});

  @override
  Widget build(BuildContext context) {
    final dates = [
      if (stop.arrivalDate != null && stop.arrivalDate!.isNotEmpty)
        stop.arrivalDate!,
      if (stop.departureDate != null && stop.departureDate!.isNotEmpty)
        stop.departureDate!,
    ].join(' → ');
    return ListTile(
      dense: true,
      leading: const Icon(Icons.place_outlined),
      title: Text(stop.ref.name),
      subtitle: Text([
        if (dates.isNotEmpty) dates,
        if (stop.nights != null) '${stop.nights} night(s)',
        if (stop.ref.country != null && stop.ref.country!.isNotEmpty)
          stop.ref.country!,
      ].join(' · ')),
      trailing: stop.role == 'start' || stop.role == 'end'
          ? Chip(label: Text(stop.role))
          : Text('#${index + 1}'),
    );
  }
}
