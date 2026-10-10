/// One destination: the typed-core metrics and the flag
/// editors. Every edit goes through
/// `DestinationRepository.updateField` -- the
/// read-modify-write that keeps the typed core and the
/// lossless tail in sync. A `false` return is surfaced,
/// never reported as success.
library;

import 'package:flutter/material.dart';

import '../data/destination_repository.dart';
import '../models/destination.dart';

class DestinationPage extends StatefulWidget {
  final DestinationRepository repository;
  final Destination destination;

  /// Called after every successful write, so the caller
  /// (the catalogue) can refresh instead of showing a
  /// stale row.
  final void Function()? onChanged;

  const DestinationPage({
    super.key,
    required this.repository,
    required this.destination,
    this.onChanged,
  });

  @override
  State<DestinationPage> createState() => _DestinationPageState();
}

class _DestinationPageState extends State<DestinationPage> {
  late Destination _dest;
  late TextEditingController _comment;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _dest = widget.destination;
    _comment = TextEditingController(text: _dest.comment ?? '');
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _update(String field, Object? value) async {
    setState(() => _busy = true);
    final ok = await widget.repository.updateField(_dest.name, field, value);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _dest = _dest.withField(field, value);
    });
    if (ok) widget.onChanged?.call();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Saved'
          : 'Nothing written -- the read or the write failed. '
              'Check the token and the connection.'),
    ));
  }

  Future<void> _editPrio() async {
    final controller =
        TextEditingController(text: _dest.prio?.toString() ?? '');
    final value = await showDialog<Object?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Prio Thorsten'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration:
              const InputDecoration(hintText: '1-10, empty to clear'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final raw = controller.text.trim();
              Navigator.pop(
                  context, raw.isEmpty ? null : num.tryParse(raw) ?? raw);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value != null) _update('prio', value);
  }

  @override
  Widget build(BuildContext context) {
    final dest = _dest;
    return Scaffold(
      appBar: AppBar(title: Text(dest.name)),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text([
              if (dest.country != null && dest.country!.isNotEmpty)
                dest.country!,
              if (dest.continent != null && dest.continent!.isNotEmpty)
                dest.continent!,
            ].join(' · '), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                _Metric(label: 'Prio', value: dest.prioInt?.toString()),
                _Metric(
                    label: 'Safety',
                    value: dest.safetyRating?.toStringAsFixed(1)),
                _Metric(
                    label: 'Cost/day',
                    value: dest.avgCostDay == null
                        ? null
                        : '${dest.avgCostDay!.toStringAsFixed(0)} €'),
                _Metric(
                    label: 'FRA flight',
                    value: dest.flightTimeFra == null
                        ? null
                        : '${dest.flightTimeFra!.toStringAsFixed(1)} h'),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Visited'),
              value: dest.visited,
              onChanged: (value) => _update('visited', value),
            ),
            SwitchListTile(
              title: const Text('Favourite'),
              value: dest.favourite,
              onChanged: (value) => _update('favourite', value),
            ),
            SwitchListTile(
              title: const Text('To be researched'),
              value: dest.toBeResearched,
              onChanged: (value) => _update('to_be_researched', value),
            ),
            ListTile(
              title: const Text('Prio'),
              subtitle: Text(dest.prio == null ? 'not set' : '${dest.prio}'),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _busy ? null : _editPrio,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _comment,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Comment',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save comment'),
                onPressed: _busy
                    ? null
                    : () => _update('comment', _comment.text.trim()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String? value;

  const _Metric({required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Text(value ?? '–',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
