/// One destination: the typed-core metrics, the flag
/// editors, and the profile sections the legacy detail page
/// renders (overview, highlights, logistics, food, best
/// months, climate dashboard).
///
/// Every edit goes through `DestinationRepository.updateField`
/// -- the read-modify-write that keeps the typed core and
/// the lossless tail in sync. A `false` return is surfaced,
/// never reported as success.
library;

import 'package:flutter/material.dart';

import '../data/city_coordinates.dart';
import '../data/destination_repository.dart';
import '../models/destination.dart';
import '../models/destination_profile.dart';
import 'climate_chart.dart';
import 'world_map_page.dart';

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
  late DestinationProfile _profile;
  late TextEditingController _comment;
  CityCoordinate? _coordinate;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _dest = widget.destination;
    _profile = DestinationProfile.from(_dest);
    _comment = TextEditingController(text: _dest.comment ?? '');
    _loadCoordinate();
  }

  Future<void> _loadCoordinate() async {
    final index = await CoordinateIndex.load();
    if (!mounted) return;
    setState(() => _coordinate = index.lookup(_dest.name));
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
      if (ok) {
        _dest = _dest.withField(field, value);
        _profile = DestinationProfile.from(_dest);
      }
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
    final profile = _profile;
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
                _Metric(
                    label: 'Reviews',
                    value: profile.reviewsCount?.toString()),
              ],
            ),
            if (profile.dataStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${profile.dataStatus}. The details below are incomplete '
                      'until this destination is researched.',
                    ),
                  ),
                ),
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
            const _SectionTitle('Overview'),
            if (_coordinate != null) ...[
              DestinationMiniMap(coordinate: _coordinate!),
              const SizedBox(height: 12),
            ],
            if (profile.hasOverviewText) ...[
              if (profile.introduction != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(profile.introduction!,
                      style: Theme.of(context).textTheme.bodyLarge),
                ),
              _LabelledText('Why to Go There', profile.whyToGo),
              _LabelledText('What to Expect', profile.whatToExpect),
              if (profile.touristReviews != null)
                _LabelledText(
                    'Tourist Reviews', profile.touristReviews, subheader: true),
              _LabelledText('What do the reviews praise?', profile.praises),
              _LabelledText('What do they dislike?', profile.dislikes),
            ] else
              const Text('No overview text was found in the workbook.'),
            const _SectionTitle('Highlights'),
            Text(profile.highlights ??
                'No highlight notes were found in the workbook.'),
            const _SectionTitle('Logistics'),
            _LogisticsGrid(profile: profile),
            const _SectionTitle('Food'),
            if (profile.hasFood) ...[
              _LabelledText('Spiciness', profile.foodSpiciness),
              _LabelledText('Description', profile.foodDescription),
              _LabelledText('Main dishes', profile.foodDishes),
            ] else
              const Text('No food notes yet.'),
            const _SectionTitle('Best months'),
            _BestMonths(profile: profile),
            const _SectionTitle('Climate'),
            _ClimateSection(profile: profile),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _LabelledText extends StatelessWidget {
  final String label;
  final String? value;
  final bool subheader;

  const _LabelledText(this.label, this.value, {this.subheader = false});

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: subheader
                  ? theme.textTheme.titleSmall
                  : theme.textTheme.labelLarge),
          const SizedBox(height: 2),
          Text(value!, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _LogisticsGrid extends StatelessWidget {
  final DestinationProfile profile;

  const _LogisticsGrid({required this.profile});

  @override
  Widget build(BuildContext context) {
    final malaria = profile.malariaRisk;
    final risky = malaria != null &&
        malaria.trim().toLowerCase().startsWith('yes');
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LogisticsCell(
                label: 'Visa requirement',
                value: profile.visaRequirement ?? '—'),
            _LogisticsCell(
              label: 'Malaria risk?',
              value: malaria ?? '—',
              highlight: risky,
            ),
            _LogisticsCell(
              label: 'Avg. cost/day',
              value: profile.costPerDay == null
                  ? '—'
                  : '${profile.costPerDay!.round()} €',
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LogisticsCell(
                label: 'Rent a car?', value: profile.rentACar ?? '—'),
            _LogisticsCell(
                label: 'Recommended stay',
                value: profile.recommendedStay ?? '—'),
            _LogisticsCell(
              label: 'Population (metro)',
              value: profile.population == null
                  ? '—'
                  : _thousands(profile.population!.round()),
            ),
          ],
        ),
        if (profile.idealTime != null || profile.avoidTime != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LogisticsCell(
                    label: 'Ideal time to go', value: profile.idealTime ?? '—'),
                _LogisticsCell(
                    label: 'Avoid going there',
                    value: profile.avoidTime ?? '—'),
              ],
            ),
          ),
      ],
    );
  }

  static String _thousands(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

class _LogisticsCell extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _LogisticsCell({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 2),
            Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: highlight ? theme.colorScheme.error : null,
                fontWeight: highlight ? FontWeight.bold : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BestMonths extends StatelessWidget {
  final DestinationProfile profile;

  const _BestMonths({required this.profile});

  @override
  Widget build(BuildContext context) {
    if (profile.months.isEmpty) {
      return const Text('No month ratings in the workbook.');
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final month in profile.months)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _colorFor(month.bucket, theme.colorScheme),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: _borderFor(month.bucket, theme.colorScheme)),
                ),
                child: Column(
                  children: [
                    Text(month.abbreviation,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text(_labelFor(month.bucket),
                        style: theme.textTheme.labelSmall),
                    if (month.showReason)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: SizedBox(
                          width: 80,
                          child: Text(
                            month.reason!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontStyle: FontStyle.italic,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        if (profile.idealTime != null || profile.avoidTime != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              [
                if (profile.idealTime != null)
                  'Ideal: ${profile.idealTime}',
                if (profile.avoidTime != null)
                  'Avoid: ${profile.avoidTime}',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  static Color _colorFor(MonthLevel level, ColorScheme scheme) {
    switch (level) {
      case MonthLevel.ideal:
        return Colors.green.withValues(alpha: 0.18);
      case MonthLevel.ok:
        return Colors.amber.withValues(alpha: 0.18);
      case MonthLevel.bad:
        return Colors.red.withValues(alpha: 0.18);
      case MonthLevel.unknown:
        return scheme.surfaceContainerHighest;
    }
  }

  static Color _borderFor(MonthLevel level, ColorScheme scheme) {
    switch (level) {
      case MonthLevel.ideal:
        return Colors.green.withValues(alpha: 0.45);
      case MonthLevel.ok:
        return Colors.amber.withValues(alpha: 0.45);
      case MonthLevel.bad:
        return Colors.red.withValues(alpha: 0.45);
      case MonthLevel.unknown:
        return scheme.outlineVariant;
    }
  }

  static String _labelFor(MonthLevel level) {
    switch (level) {
      case MonthLevel.ideal:
        return 'Ideal';
      case MonthLevel.ok:
        return 'Ok';
      case MonthLevel.bad:
        return 'Bad';
      case MonthLevel.unknown:
        return '—';
    }
  }
}

class _ClimateSection extends StatelessWidget {
  final DestinationProfile profile;

  const _ClimateSection({required this.profile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final climate = profile.climate;
    if (!climate.hasData) {
      return Text(
        'Detailed monthly climate and air quality data is currently being '
        'populated for ${profile.name}.',
      );
    }
    final peak = profile.peakHigh;
    final wettest = profile.wettestMonth;
    final averageAqi = profile.averageAqi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _KpiCard(
              label: 'Peak high',
              value: peak == null
                  ? '—'
                  : '${peak.$1.round()}°C (${peak.$2})',
            ),
            _KpiCard(
              label: 'Wettest month',
              value: wettest == null
                  ? '—'
                  : '${wettest.$1.round()}mm (${wettest.$2})',
              color: Colors.blue,
            ),
            _KpiCard(
              label: 'Average AQI',
              value: averageAqi == null
                  ? '—'
                  : '${averageAqi.round()} ('
                      '${DestinationProfile.aqiBand(averageAqi)})',
            ),
            _KpiCard(
              label: 'IQAir rank',
              value: profile.iqairRank == null
                  ? 'not in ranking'
                  : '#${_formatRank(profile.iqairRank!)}'
                      '${profile.iqairPm25 == null ? '' : ' (${profile.iqairPm25!.toStringAsFixed(1)} µg/m³)'}',
            ),
            _KpiCard(
              label: 'Best months',
              value: profile.bestMonths.isEmpty
                  ? 'Varies'
                  : profile.bestMonths.join(', '),
              color: Colors.green,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Monthly temperature & rainfall',
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ClimateChart(data: climate),
        const SizedBox(height: 16),
        Text('Air quality by month', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _AqiRow(values: climate.aqi),
        if (profile.aqiSource != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(profile.aqiSource!, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }

  static String _formatRank(int rank) {
    final digits = rank.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _KpiCard({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 150,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                value,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: color, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AqiRow extends StatelessWidget {
  final List<double?> values;

  const _AqiRow({required this.values});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < 3; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                for (var i = row * 4; i < row * 4 + 4 && i < values.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: _bandColor(values[i]),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            Text(monthAbbreviations[i],
                                style: theme.textTheme.labelSmall),
                            Text(
                              values[i] == null
                                  ? '—'
                                  : values[i]!.round().toString(),
                              style: theme.textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static Color _bandColor(double? value) {
    if (value == null) return const Color(0x1F94A3B8);
    if (value <= 50) return Colors.green.withValues(alpha: 0.35);
    if (value <= 100) return Colors.amber.withValues(alpha: 0.35);
    if (value <= 150) return Colors.orange.withValues(alpha: 0.35);
    return Colors.red.withValues(alpha: 0.35);
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String? value;

  const _Metric({required this.label, required this.value});

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
