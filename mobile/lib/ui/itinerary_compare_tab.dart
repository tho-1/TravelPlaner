/// The Compare tab: every variant of the open
/// trip side by side, with the totals the
/// route summary computes, and the control to
/// make one of them the active variant.
///
/// The Dart port of `pages/itinerary.py`'s
/// `_render_compare_tab`. The legacy renders a
/// dataframe; this port renders a horizontally
/// scrollable `DataTable` (the same scroll
/// semantics at phone width) plus the
/// "Make active variant" selector.
library;

import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../models/trip_ops.dart';

class ItineraryCompareTab extends StatelessWidget {
  final Trip trip;
  final void Function(String variantId) onActivate;

  const ItineraryCompareTab({
    super.key,
    required this.trip,
    required this.onActivate,
  });

  @override
  Widget build(BuildContext context) {
    final variants = trip.variants;
    if (variants.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No variants yet.'),
      );
    }
    final active = trip.activeVariant;
    // The vertical scroll view is the outer one:
    // the activate selector's Row needs a bounded
    // width, which only a vertical scroll view
    // gives -- inside the horizontal one the
    // width is unbounded and a Row with an
    // Expanded child cannot layout.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A fade on the right edge says "there is more
          // sideways" without hiding the active row's data.
          Stack(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
              columns: const [
                DataColumn(label: Text('')),
                DataColumn(label: Text('Variant')),
                DataColumn(label: Text('Rating')),
                DataColumn(label: Text('Months')),
                DataColumn(label: Text('Start')),
                DataColumn(label: Text('End')),
                DataColumn(label: Text('Stops')),
                DataColumn(label: Text('Nights')),
                DataColumn(label: Text('Flights')),
                DataColumn(label: Text('Trains')),
                DataColumn(label: Text('Other')),
                DataColumn(label: Text('Warnings')),
                DataColumn(label: Text('Comment')),
              ],
              rows: [
                for (final variant in variants)
                  DataRow(
                    // One indicator language: the active row
                    // is tinted and checked; every row is
                    // tappable to activate itself.
                    color: WidgetStateProperty.resolveWith((_) =>
                        variant.id == trip.activeVariantId
                            ? Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                            : Theme.of(context).colorScheme.surface),
                    onSelectChanged: (_) {
                      if (variant.id != trip.activeVariantId) {
                        onActivate(variant.id);
                      }
                    },
                    cells: _cells(context, variant),
                  ),
              ],
            ),
          ),
              // The right-edge fade: "more columns this way".
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: 36,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Theme.of(context).colorScheme.surface,
                          Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Tap a row to make it the active variant · '
              'the table scrolls sideways.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (variants.length > 1 && active != null) ...[
            const SizedBox(height: 16),
            _ActivateSelector(
              key: ValueKey(trip.id),
              trip: trip,
              onActivate: onActivate,
            ),
          ],
        ],
      ),
    );
  }

  List<DataCell> _cells(BuildContext context, Variant variant) {
    final t = totals(variant);
    final active = variant.id == trip.activeVariantId;
    return [
      // A single indicator: the check on the active row.
      // The old pair (check plus radio on the others) read
      // as two different controls.
      DataCell(active
          ? Icon(
              Icons.check_circle,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            )
          : const SizedBox.shrink()),
      DataCell(Text(variant.name)),
      DataCell(Text(variant.rating?.toString() ?? '—')),
      DataCell(Text(
        [for (final month in variant.months) month.substring(0, 3)]
            .join(', '),
      )),
      DataCell(Text(t.start ?? '—')),
      DataCell(Text(t.end ?? '—')),
      DataCell(Text('${t.stops}')),
      DataCell(Text('${t.nights}')),
      DataCell(Text('${t.flights}')),
      DataCell(Text('${t.trains}')),
      DataCell(Text('${t.other}')),
      DataCell(Text('${warningsFor(variant).length}')),
      DataCell(Text(
        variant.comment.length > 60
            ? '${variant.comment.substring(0, 60)}…'
            : variant.comment,
      )),
    ];
  }
}

/// "Make active variant": a dropdown that
/// disambiguates duplicate names with a short
/// id suffix (the legacy's label rule), plus
/// the activate button.
class _ActivateSelector extends StatefulWidget {
  final Trip trip;
  final void Function(String variantId) onActivate;

  const _ActivateSelector({
    super.key,
    required this.trip,
    required this.onActivate,
  });

  @override
  State<_ActivateSelector> createState() => _ActivateSelectorState();
}

class _ActivateSelectorState extends State<_ActivateSelector> {
  late String _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.trip.activeVariant?.id ??
        widget.trip.variants.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final variants = widget.trip.variants;
    // Labels carry a short id suffix whenever
    // names collide, so a duplicate name can
    // never target the wrong variant.
    final labels = [
      for (final variant in variants)
        _labelFor(variant, variants),
    ];
    final selectedIndex = variants
        .indexWhere((variant) => variant.id == _selectedId);
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: selectedIndex < 0 ? 0 : selectedIndex,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Make active variant',
              border: OutlineInputBorder(),
            ),
            items: [
              for (var i = 0; i < labels.length; i++)
                DropdownMenuItem(value: i, child: Text(labels[i])),
            ],
            onChanged: (value) => setState(() {
              if (value != null) {
                _selectedId = variants[value].id;
              }
            }),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: () => widget.onActivate(_selectedId),
          child: const Text('Activate'),
        ),
      ],
    );
  }

  String _labelFor(Variant variant, List<Variant> variants) {
    final names = [for (final v in variants) v.name];
    final unique = names.where((n) => n == variant.name).length == 1;
    return unique
        ? variant.name
        : '${variant.name} · ${variant.id.substring(
            variant.id.length > 6 ? variant.id.length - 6 : 0)}';
  }
}
