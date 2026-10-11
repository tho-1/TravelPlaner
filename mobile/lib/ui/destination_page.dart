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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/ai_config.dart';
import '../data/ai_populator.dart';
import '../data/city_coordinates.dart';
import '../data/deepseek_client.dart';
import '../data/destination_repository.dart';
import '../data/gallery_cache.dart';
import '../data/gallery_repository.dart';
import '../data/photo_repository.dart';
import '../models/destination.dart';
import '../models/destination_profile.dart';
import '../turso/config.dart';
import 'climate_chart.dart';
import 'aqi_chart.dart';
import 'iqair_table.dart';
import 'world_map_page.dart';

class DestinationPage extends StatefulWidget {
  final DestinationRepository repository;
  final Destination destination;

  /// Called after every successful write, so the caller
  /// (the catalogue) can refresh instead of showing a
  /// stale row.
  final void Function()? onChanged;

  /// Test seam: the AI client and config. Null loads the
  /// bundled one, exactly like the running app.
  final DeepSeekClient? aiClient;
  final AiConfig? aiConfig;

  /// Test seam: the `Pictures/` folder the banner photo
  /// is read from. Null loads the bundled config (the
  /// running app); a path reads that folder directly,
  /// so the banner can be exercised without a machine
  /// Pictures folder.
  final String? picturesDir;

  const DestinationPage({
    super.key,
    required this.repository,
    required this.destination,
    this.onChanged,
    this.aiClient,
    this.aiConfig,
    this.picturesDir,
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
  var _populating = false;
  var _aiConfigured = false;

  @override
  void initState() {
    super.initState();
    _dest = widget.destination;
    _profile = DestinationProfile.from(_dest);
    _comment = TextEditingController(text: _dest.comment ?? '');
    _loadCoordinate();
    _loadAiConfig();
  }

  Future<void> _loadAiConfig() async {
    final config = widget.aiConfig ?? await AiConfig.load();
    if (!mounted) return;
    setState(() => _aiConfigured = config.isConfigured);
  }

  Future<void> _loadCoordinate() async {
    final index = await CoordinateIndex.load();
    if (!mounted) return;
    setState(() => _coordinate = index.lookup(_dest.name));
  }

  /// The AI populate: ask DeepSeek, apply the profile, save
  /// once. Failure is a message, never a crash -- the same
  /// contract the legacy `populate_existing_destination_
  /// with_ai` has.
  Future<void> _populateWithAi() async {
    setState(() => _populating = true);
    final client = widget.aiClient ??
        DeepSeekClient(widget.aiConfig ?? await AiConfig.load());
    try {
      final profile = await client.generateDestinationProfile(
        destination: _dest.name,
        country: _dest.country ?? '',
        continent: _dest.continent ?? '',
      );
      final updated = AiPopulator(_dest).apply(profile);
      final ok = await widget.repository.saveDestination(updated);
      if (!mounted) return;
      setState(() {
        _populating = false;
        if (ok) {
          _dest = updated;
          _profile = DestinationProfile.from(updated);
        }
      });
      if (ok) widget.onChanged?.call();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Populated with DeepSeek AI'
            : 'The profile was generated but nothing was written.'),
      ));
    } on DeepSeekError catch (error) {
      if (!mounted) return;
      setState(() => _populating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.message),
      ));
    }
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

  /// Save the comment box. An empty box over an
  /// existing comment is a delete, and the legacy
  /// made that explicit — so it asks first instead
  /// of losing the text to a stray select-all.
  Future<void> _saveComment() async {
    final typed = _comment.text.trim();
    if (typed.isEmpty &&
        _dest.comment != null &&
        _dest.comment!.trim().isNotEmpty) {
      await _confirmDeleteComment();
      return;
    }
    _update('comment', typed);
  }

  Future<void> _confirmDeleteComment() async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete the comment?'),
        content: const Text('This will delete the saved comment.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, delete it'),
          ),
        ],
      ),
    );
    if (delete == true) {
      _comment.clear();
      _update('comment', null);
    }
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            _DestinationHeader(
                destination: dest, profile: profile, picturesDir: widget.picturesDir),
            if (profile.dataStatus != null) ...[
              const SizedBox(height: 12),
              _StatusBanner(
                status: profile.dataStatus!,
                aiConfigured: _aiConfigured,
                populating: _populating,
                onPopulate: _populating ? null : _populateWithAi,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilterChip(
                  avatar: Icon(dest.visited
                      ? Icons.check_circle_outline
                      : Icons.circle_outlined),
                  label: const Text('Visited'),
                  selected: dest.visited,
                  onSelected: (value) => _update('visited', value),
                ),
                FilterChip(
                  avatar: Icon(dest.favourite
                      ? Icons.star_outline
                      : Icons.star_border_outlined),
                  label: const Text('Favourite'),
                  selected: dest.favourite,
                  onSelected: (value) => _update('favourite', value),
                ),
                // The legacy header's research button: a
                // toggle, not a static note — the ❔/❓
                // button that marks the row as researched.
                FilterChip(
                  avatar: Icon(dest.toBeResearched
                      ? Icons.help_outline
                      : Icons.help_outline_outlined),
                  label: Text(dest.toBeResearched
                      ? 'Needs research'
                      : 'Researched'),
                  selected: dest.toBeResearched,
                  onSelected: (value) =>
                      _update('to_be_researched', value),
                ),
                ActionChip(
                  avatar: const Icon(Icons.priority_high_outlined),
                  label: Text(dest.prio == null
                      ? 'Prio: not set'
                      : 'Prio: ${dest.prio}'),
                  onPressed: _busy ? null : _editPrio,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _FactGrid(destination: dest, profile: profile),
            const SizedBox(height: 20),
            TextField(
              controller: _comment,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Comment',
                hintText: 'Worth a long weekend…',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // The legacy's explicit delete: saving an
                // empty box over an existing comment asks
                // first — one stray select-all + Save
                // used to lose the text outright.
                if (_dest.comment != null &&
                    _dest.comment!.trim().isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : _confirmDeleteComment,
                    child: const Text('Delete'),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save comment'),
                  onPressed: _busy
                      ? null
                      : () => _saveComment(),
                ),
              ],
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
              const _EmptyNote(
                icon: Icons.notes_outlined,
                text: 'No overview text was found in the workbook.',
              ),
            const _SectionTitle('Highlights'),
            if (profile.highlights != null && profile.highlights!.isNotEmpty)
              Text(profile.highlights!)
            else
              const _EmptyNote(
                icon: Icons.emoji_events_outlined,
                text: 'No highlight notes were found in the workbook.',
              ),
            const _SectionTitle('Logistics'),
            _LogisticsGrid(profile: profile),
            const _SectionTitle('Food'),
            if (profile.hasFood)
              _FoodSection(profile: profile)
            else
              const Text('No food notes yet.'),
            const _SectionTitle('Best months'),
            _BestMonths(profile: profile),
            const _SectionTitle('Climate'),
            _ClimateSection(profile: profile),
            _GallerySection(
                destinationName: dest.name, picturesDir: widget.picturesDir),
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
    final labelStyle = subheader
        ? theme.textTheme.titleSmall
        : theme.textTheme.labelLarge;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: labelStyle),
          const SizedBox(height: 2),
          Text(value!, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// The food section: the spiciness and the main
/// dishes side by side, the description below —
/// the legacy's flex layout. Each dish is a link
/// to a Google Images search for the dish in this
/// destination, the legacy's `tbm=isch` link.
class _FoodSection extends StatelessWidget {
  final DestinationProfile profile;

  const _FoodSection({required this.profile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dishes = profile.foodDishList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Spiciness', style: theme.textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(profile.foodSpicinessText,
                    style: theme.textTheme.bodyMedium),
              ],
            ),
            const SizedBox(width: 40),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Main dishes (in local language)',
                      style: theme.textTheme.labelLarge),
                  const SizedBox(height: 2),
                  if (dishes.isEmpty)
                    const Text('—')
                  else
                    Wrap(
                      spacing: 0,
                      runSpacing: 2,
                      children: [
                        for (var i = 0; i < dishes.length; i++) ...[
                          _DishLink(
                            dish: dishes[i],
                            destination: profile.name,
                          ),
                          if (i < dishes.length - 1)
                            const Text(', '),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _LabelledText('Description', profile.foodDescription),
      ],
    );
  }
}

/// One dish, underlined, opening a Google Images
/// search for the dish in this destination — the
/// legacy's `tbm=isch` link.
class _DishLink extends StatelessWidget {
  final String dish;
  final String destination;

  const _DishLink({required this.dish, required this.destination});

  Future<void> _launch(BuildContext context) async {
    final url = Uri.https('www.google.com', '/search', {
      'tbm': 'isch',
      'q': '$dish $destination',
    });
    final launched =
        await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the image search.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => _launch(context),
      child: Text(
        dish,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          fontWeight: FontWeight.w500,
        ),
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
        AqiChart(data: climate),
        if (profile.aqiSource != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(profile.aqiSource!, style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 16),
        IqairPm25Table(
          destinationName: profile.destination.name,
          country: profile.destination.country,
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

/// The destination's identity: name, where it is, and
/// the facts that identify it at a glance.
///
/// On the desktop the legacy page leads with a banner
/// photo read from `Pictures/` (a panoramic crop); this
/// header loads the same photo with `PhotoRepository`
/// and overlays the name on it. When there is no photo
/// -- on the phone, or a machine without the folder --
/// the header leads with typography and colour instead:
/// a large name, the country and continent, and the
/// chips below.
class _DestinationHeader extends StatefulWidget {
  final Destination destination;
  final DestinationProfile profile;
  final String? picturesDir;

  const _DestinationHeader({
    required this.destination,
    required this.profile,
    this.picturesDir,
  });

  @override
  State<_DestinationHeader> createState() => _DestinationHeaderState();
}

class _DestinationHeaderState extends State<_DestinationHeader> {
  String? _bannerPath;

  Destination get _destination => widget.destination;

  @override
  void initState() {
    super.initState();
    _loadBanner();
  }

  /// The banner is a per-machine folder the app cannot
  /// assume exists; a missing folder or photo is a normal
  /// state (the header falls back to typography), never a
  /// crash.
  Future<void> _loadBanner() async {
    final dir =
        widget.picturesDir ?? (await TursoConfig.load()).picturesDir;
    if (dir.trim().isEmpty) return;
    final file = await PhotoRepository(dir).findBanner(
      _destination.name,
      _destination.name,
    );
    if (mounted && file != null) {
      setState(() => _bannerPath = file.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = [
      if (_destination.country != null && _destination.country!.isNotEmpty)
        _destination.country!,
      if (_destination.continent != null &&
          _destination.continent!.isNotEmpty)
        _destination.continent!,
    ].join(' · ');
    final bannerPath = _bannerPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bannerPath != null)
          _BannerPhoto(
              path: bannerPath,
              name: _destination.name,
              location: location)
        else
          Text(_destination.name, style: theme.textTheme.headlineSmall),
        if (bannerPath == null && location.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(location, style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          )),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (_destination.visited)
              const _HeaderChip(
                  icon: Icons.check_circle_outline,
                  label: 'Visited',
                  tone: _HeaderChipTone.positive),
            if (_destination.favourite)
              const _HeaderChip(
                  icon: Icons.star_outline,
                  label: 'Favourite',
                  tone: _HeaderChipTone.accent),
            if (widget.profile.reviewsCount != null)
              _HeaderChip(
                  icon: Icons.reviews_outlined,
                  label: '${widget.profile.reviewsCount}/10 reviews'),
            if (_destination.prioInt != null)
              _HeaderChip(
                  icon: Icons.priority_high_outlined,
                  label: 'Prio ${_destination.prioInt}'),
          ],
        ),
      ],
    );
  }
}

/// The banner photo: the image, a darkening scrim, and
/// the destination name over the bottom. The panoramic
/// crop the legacy performs with PIL is achieved here
/// with a fixed height and `BoxFit.cover` — no image
/// library is needed. A file that vanished between the
/// match and the paint falls back to a tinted panel so
/// the overlay stays readable.
class _BannerPhoto extends StatelessWidget {
  final String path;
  final String name;
  final String location;

  const _BannerPhoto({
    required this.path,
    required this.name,
    required this.location,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 200,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(path),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) =>
                  ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.6),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 12,
              child: IgnorePointer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(color: Colors.white),
                    ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        location,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: Colors.white70),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An empty note with an icon: "no data" is information,
/// and it reads better than a grey line.
class _EmptyNote extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyNote({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )),
        ),
      ],
    );
  }
}

enum _HeaderChipTone { plain, positive, accent }

class _HeaderChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final _HeaderChipTone tone;

  const _HeaderChip({required this.icon, required this.label, this.tone = _HeaderChipTone.plain});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = switch (tone) {
      _HeaderChipTone.positive => scheme.primaryContainer,
      _HeaderChipTone.accent => scheme.tertiaryContainer,
      _HeaderChipTone.plain => scheme.surfaceContainerHighest,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 5),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

/// The placeholder warning, its AI button, and the
/// explanation -- one card, not a wall of text.
class _StatusBanner extends StatelessWidget {
  final String status;
  final bool aiConfigured;
  final bool populating;
  final VoidCallback? onPopulate;

  const _StatusBanner({
    required this.status,
    required this.aiConfigured,
    required this.populating,
    required this.onPopulate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: theme.colorScheme.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      )),
                  const SizedBox(height: 2),
                  Text(
                    'The details below are incomplete until this destination '
                    'is researched.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                  if (aiConfigured) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: populating
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: Text(populating
                          ? 'Asking DeepSeek…'
                          : 'Populate with AI'),
                      onPressed: onPopulate,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The typed-core numbers as a 3-across grid of fact cards.
/// Five across was cramped on a 420-pixel screen: this is
/// the same data, two readable rows.
class _FactGrid extends StatelessWidget {
  final Destination destination;
  final DestinationProfile profile;

  const _FactGrid({required this.destination, required this.profile});

  @override
  Widget build(BuildContext context) {
    final facts = <(IconData, String, String?)>[
      (
        Icons.shield_outlined,
        'Safety',
        destination.safetyRating?.toStringAsFixed(1),
      ),
      (
        Icons.payments_outlined,
        'Cost / day',
        destination.avgCostDay == null
            ? null
            : '${destination.avgCostDay!.round()} €',
      ),
      (
        Icons.flight_takeoff_outlined,
        'FRA flight',
        destination.flightTimeFra == null
            ? null
            : '${destination.flightTimeFra!.toStringAsFixed(1)} h',
      ),
      (
        Icons.hotel_outlined,
        'Stay',
        profile.recommendedStay,
      ),
      (
        Icons.public_outlined,
        'Population',
        profile.population == null
            ? null
            : _compactNumber(profile.population!.round()),
      ),
      (
        Icons.reviews_outlined,
        'Reviews',
        profile.reviewsCount?.toString(),
      ),
    ];
    return Column(
      children: [
        for (var row = 0; row < facts.length; row += 3)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // IntrinsicHeight: equal-height cards in a row
            // inside a scrolling ListView (a Row with
            // stretch would demand an infinite height).
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var column = 0; column < 3; column++)
                    if (row + column < facts.length)
                      Expanded(child: _FactCard(fact: facts[row + column]))
                    else
                      const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static String _compactNumber(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)}k';
    }
    return value.toString();
  }
}

class _FactCard extends StatelessWidget {
  final (IconData, String, String?) fact;

  const _FactCard({required this.fact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label, value) = fact;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Column(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(height: 6),
            Text(
              value ?? '–',
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The photo gallery: the cached photos the
/// legacy app populated under `Pictures/`,
/// shown as a wrap of images with their
/// captions. The photos load from disk, so
/// the section stays empty until the cache
/// is read; a destination with no cache
/// shows nothing, the same "no data" the
/// legacy treats a missing gallery as.
///
/// The per-photo replace button the legacy
/// offers is not ported yet — the grid is
/// read-only for now.
class _GallerySection extends StatefulWidget {
  final String destinationName;
  final String? picturesDir;

  const _GallerySection({
    required this.destinationName,
    this.picturesDir,
  });

  @override
  State<_GallerySection> createState() => _GallerySectionState();
}

class _GallerySectionState extends State<_GallerySection> {
  List<GalleryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The gallery is a per-machine cache the
  /// app cannot assume exists; a missing
  /// folder or cache is a normal state (the
  /// section stays empty), never a crash.
  Future<void> _load() async {
    final dir =
        widget.picturesDir ?? (await TursoConfig.load()).picturesDir;
    if (dir.trim().isEmpty) return;
    final entries =
        await GalleryRepository(dir).load(widget.destinationName);
    if (mounted && entries != null && entries.isNotEmpty) {
      setState(() => _entries = entries);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    if (entries == null || entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Gallery'),
        Text(
          'Photos from DuckDuckGo & Unsplash.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in entries)
              SizedBox(
                width: 220,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 3 / 2,
                      child: Image.file(
                        File(entry.imagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) =>
                            ColoredBox(
                          color: theme
                              .colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                    if (entry.caption.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          entry.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
