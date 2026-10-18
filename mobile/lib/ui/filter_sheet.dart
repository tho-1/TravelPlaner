/// The shared filter panel — the legacy `🔍 Filters`
/// expander, ported as a modal sheet that the catalogue and
/// the world map both open.
///
/// One panel for both pages, because the legacy filters
/// both with the same helper set and the two must never
/// drift: the controls, their defaults and the blank-row
/// invariant all come from
/// [../models/catalogue_filters.dart]. A change applies
/// immediately, like Streamlit's rerun-per-widget.
///
/// The map's city-label toggle is page-specific, so the
/// sheet takes it as an optional extra control and renders
/// nothing when it is null.
library;

import 'package:flutter/material.dart';

import '../models/catalogue_filters.dart';
import '../models/destination.dart';
import '../models/destination_profile.dart';

class CatalogueFilterSheet extends StatefulWidget {
  final CatalogueFilters value;

  /// The unfiltered catalogue: option lists and slider
  /// bounds come from it.
  final List<Destination> destinations;

  /// The map's "show city text labels" toggle, when the
  /// caller is the map page.
  final bool? showCityLabels;
  final ValueChanged<bool>? onShowCityLabelsChanged;

  final ValueChanged<CatalogueFilters> onChanged;

  const CatalogueFilterSheet({
    super.key,
    required this.value,
    required this.destinations,
    required this.onChanged,
    this.showCityLabels,
    this.onShowCityLabelsChanged,
  });

  @override
  State<CatalogueFilterSheet> createState() => _CatalogueFilterSheetState();
}

class _CatalogueFilterSheetState extends State<CatalogueFilterSheet> {
  late CatalogueFilters _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.value;
  }

  void _update(CatalogueFilters next) {
    setState(() => _draft = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final safety = numericBounds(
      [for (final destination in widget.destinations)
        destination.core['safety_rating']],
      fallback: (0.0, 5.0),
    );
    final reviews = numericBounds(
      [for (final destination in widget.destinations)
        destination.column('Reviews')],
      fallback: (0.0, 10.0),
    );
    final continents = continentOptions(widget.destinations);
    final countries = countryOptions(widget.destinations, _draft.continent);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.filter_list),
                  const SizedBox(width: 8),
                  // Expanded: the title shrinks before the
                  // actions do — a fixed title row overflowed
                  // a phone-width sheet by 53 px.
                  Expanded(
                    child: Text('Filters', style: text.titleLarge),
                  ),
                  if (_draft.isActive)
                    TextButton(
                      onPressed: () =>
                          _update(CatalogueFilters.initial()),
                      child: const Text('Clear filters'),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Text(
                'A filter only ever removes a destination whose field is '
                'filled in — rows without a value stay visible.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _draft.continent,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Continent'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All')),
                  for (final continent in continents)
                    DropdownMenuItem(value: continent, child: Text(continent)),
                ],
                onChanged: (value) =>
                    _update(_draft.copyWith(clearContinent: true, continent: value)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: countries.contains(_draft.country)
                    ? _draft.country
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Country'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All')),
                  for (final country in countries)
                    DropdownMenuItem(value: country, child: Text(country)),
                ],
                onChanged: (value) =>
                    _update(_draft.copyWith(clearCountry: true, country: value)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<bool>(
                initialValue: _draft.eu,
                decoration: const InputDecoration(labelText: 'EU?'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('All')),
                  DropdownMenuItem(value: true, child: Text('Yes')),
                  DropdownMenuItem(value: false, child: Text('No')),
                ],
                onChanged: (value) =>
                    _update(_draft.copyWith(clearEu: true, eu: value)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _draft.weatherMonth,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Weather at least ok in'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final month in fullMonths)
                    DropdownMenuItem(value: month, child: Text(month)),
                ],
                onChanged: (value) => _update(
                    _draft.copyWith(clearWeatherMonth: true, weatherMonth: value)),
              ),
              const SizedBox(height: 12),
               _SliderRow(
                 label: 'Minimum safety rating',
                 value: _draft.minSafety,
                 bounds: (0.0, safety.$2),
                 onChanged: (value) => _update(_draft.copyWith(minSafety: value)),
               ),
               _SliderRow(
                 label: 'Minimum review score',
                 value: _draft.minReviews,
                 bounds: (0.0, reviews.$2),
                 onChanged: (value) => _update(_draft.copyWith(minReviews: value)),
               ),
              DropdownButtonFormField<bool>(
                initialValue: _draft.requiresResearch,
                decoration: const InputDecoration(labelText: 'Requires research?'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('All')),
                  DropdownMenuItem(value: true, child: Text('Yes')),
                  DropdownMenuItem(value: false, child: Text('No')),
                ],
                onChanged: (value) => _update(
                    _draft.copyWith(clearRequiresResearch: true, requiresResearch: value)),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Only show unvisited'),
                value: _draft.onlyUnvisited,
                onChanged: (value) =>
                    _update(_draft.copyWith(onlyUnvisited: value)),
              ),
              if (widget.showCityLabels != null &&
                  widget.onShowCityLabelsChanged != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show city text labels on map'),
                  value: widget.showCityLabels!,
                  onChanged: widget.onShowCityLabelsChanged,
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One labelled slider: the legacy's
/// "Minimum safety rating" row, with the value and bounds
/// spelled out (a bare slider gives no feedback on a
/// phone).
class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final (double, double) bounds;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.bounds,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(bounds.$1, bounds.$2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label — ${clamped.toStringAsFixed(1)}'),
        Slider(
          min: bounds.$1,
          max: bounds.$2,
          value: clamped,
          label: clamped.toStringAsFixed(1),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Opens the filter sheet and applies every change at once.
Future<void> openCatalogueFilterSheet(
  BuildContext context, {
  required CatalogueFilters value,
  required List<Destination> destinations,
  required ValueChanged<CatalogueFilters> onChanged,
  bool? showCityLabels,
  ValueChanged<bool>? onShowCityLabelsChanged,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => CatalogueFilterSheet(
      value: value,
      destinations: destinations,
      onChanged: onChanged,
      showCityLabels: showCityLabels,
      onShowCityLabelsChanged: onShowCityLabelsChanged,
    ),
  );
}
