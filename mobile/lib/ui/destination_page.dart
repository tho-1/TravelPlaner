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
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/ai_config.dart';
import '../data/ai_populator.dart';
import '../data/city_coordinates.dart';
import '../data/deepseek_client.dart';
import '../data/destination_repository.dart';
import '../data/food_populator.dart';
import '../data/gallery_cache.dart';
import '../data/gallery_repository.dart';
import '../data/gallery_search.dart';
import '../data/photo_repository.dart';
import '../models/destination.dart';
import '../models/condition.dart';
import '../models/destination_profile.dart';
import '../turso/config.dart';
import 'climate_chart.dart';
import 'aqi_chart.dart';
import 'iqair_table.dart';
import 'flight_routes_section.dart';
import 'theme.dart';
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

  /// Optional direct banner path for deterministic widget tests.
  final String? bannerPhotoPath;

  /// Injectable photo seams for deterministic gallery and cache tests.
  final PhotoSearchProvider? photoSearchProvider;
  final GalleryMetadataCache? galleryCache;

  /// Called when a destination is opened from this page's
  /// related links, so the shell records the open tab.
  /// Passed on to the pushed page, so the chain records
  /// every hop.
  final void Function(String name)? onOpenDestination;

  const DestinationPage({
    super.key,
    required this.repository,
    required this.destination,
    this.onChanged,
    this.aiClient,
    this.aiConfig,
    this.picturesDir,
    this.bannerPhotoPath,
    this.photoSearchProvider,
    this.galleryCache,
    this.onOpenDestination,
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
  var _populatingFood = false;
  var _aiConfigured = false;
  GalleryRepository? _galleryRepository;
  List<GalleryEntry> _galleryEntries = const [];
  String? _bannerPhotoPath;

  /// The comment editor is only mounted when there is
  /// something to edit: an empty destination used to open
  /// with a huge blank box. Adding starts the editor; the
  /// Delete flow folds it back to the add button.
  var _commentEditing = false;

  @override
  void initState() {
    super.initState();
    _dest = widget.destination;
    _profile = DestinationProfile.from(_dest);
    _comment = TextEditingController(text: _dest.comment ?? '');
    _loadCoordinate();
    _loadAiConfig();
    _loadPhotoServices();
  }

  Future<void> _loadPhotoServices() async {
    final hasInjectedServices =
        widget.galleryCache != null && widget.photoSearchProvider != null;
    final config = hasInjectedServices ? null : await TursoConfig.load();
    GalleryMetadataCache? cache = widget.galleryCache;
    if (cache == null) {
      try {
        final documents = await getApplicationDocumentsDirectory();
        cache = FileGalleryMetadataCache(
          p.join(documents.path, 'travel_planner'),
        );
      } catch (_) {
        // Legacy desktop folders remain readable if app storage is unavailable.
      }
    }
    final picturesDir = widget.picturesDir ?? config?.picturesDir ?? '';
    final repository = GalleryRepository(
      picturesDir,
      cache: cache,
      provider:
          widget.photoSearchProvider ??
          UnsplashPhotoSearchProvider(config?.unsplashAccessKey ?? ''),
    );
    List<GalleryEntry> entries = const [];
    try {
      entries = await repository.load(_dest.name) ?? const [];
    } catch (_) {
      // A missing or unreadable cache is an ordinary empty-gallery state.
    }

    if (!mounted) return;
    setState(() {
      _galleryRepository = repository;
      _galleryEntries = entries;
    });

    var bannerPath = widget.bannerPhotoPath;
    if (bannerPath == null && picturesDir.trim().isNotEmpty) {
      final banner = await PhotoRepository(picturesDir)
          .findBanner(_dest.name, _dest.name);
      bannerPath = banner?.path;
    }
    if (!mounted) return;
    setState(() => _bannerPhotoPath = bannerPath);
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
    final client =
        widget.aiClient ??
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Populated with DeepSeek AI'
                : 'The profile was generated but nothing was written.',
          ),
        ),
      );
    } on DeepSeekError catch (error) {
      if (!mounted) return;
      setState(() => _populating = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// The food populate: ask DeepSeek for the food
  /// profile, apply it, save once. Offered only
  /// while the food columns are blank -- the legacy
  /// shows the button only then. Failure is a
  /// message, never a crash.
  Future<void> _populateFood() async {
    setState(() => _populatingFood = true);
    final client =
        widget.aiClient ??
        DeepSeekClient(widget.aiConfig ?? await AiConfig.load());
    try {
      final food = await client.generateFoodProfile(
        destination: _dest.name,
        country: _dest.country ?? '',
      );
      final updated = FoodPopulator(_dest).apply(food);
      final ok = await widget.repository.saveDestination(updated);
      if (!mounted) return;
      setState(() {
        _populatingFood = false;
        if (ok) {
          _dest = updated;
          _profile = DestinationProfile.from(updated);
        }
      });
      if (ok) widget.onChanged?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Food information saved'
                : 'The food profile was generated but nothing was written.',
          ),
        ),
      );
    } on DeepSeekError catch (error) {
      if (!mounted) return;
      setState(() => _populatingFood = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
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
    if (ok) {
      widget.onChanged?.call();
    } else {
      // Success is visible in the field itself; only a
      // failed write pops a bar. Every save used to pop
      // "Saved", burying the one message that matters.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing written -- the read or the write failed. '
            'Check the token and the connection.',
          ),
        ),
      );
    }
  }

  Future<void> _editPrio() async {
    final controller = TextEditingController(
      text: _dest.prio?.toString() ?? '',
    );
    try {
      final value = await showDialog<Object?>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Prio Thorsten'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: '1-10, empty to clear'),
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
                  context,
                  raw.isEmpty ? null : num.tryParse(raw) ?? raw,
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (value != null) await _update('prio', value);
    } finally {
      controller.dispose();
    }
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
      // Fold the editor away: with nothing saved there is
      // nothing to edit, and the add button returns.
      setState(() => _commentEditing = false);
      _update('comment', null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dest = _dest;
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(dest.name),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
                  ),
                  IconButton(
                    tooltip: 'Prio',
                    icon: const Icon(Icons.priority_high_outlined),
                    onPressed: _busy ? null : _editPrio,
                  ),
              ],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            _DestinationHeader(
              destination: dest,
              profile: profile,
              bannerPath: _bannerPhotoPath,
              galleryEntries: _galleryEntries,
            ),
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
                IconButton(
                  tooltip: 'Visited',
                  icon: Icon(
                    dest.visited ? Icons.check_circle : Icons.circle_outlined,
                    color: dest.visited ? accentSafety : null,
                  ),
                  onPressed: _busy
                      ? null
                      : () => _update('visited', !dest.visited),
                ),
                IconButton(
                  tooltip: 'Favourite',
                  icon: Icon(
                    dest.favourite ? Icons.star : Icons.star_border_outlined,
                    color: dest.favourite ? accentFavourite : null,
                  ),
                  onPressed: _busy
                      ? null
                      : () => _update('favourite', !dest.favourite),
                ),
                IconButton(
                  tooltip: 'Researched',
                  icon: Icon(
                    dest.toBeResearched ? Icons.help : Icons.help_outline,
                    color: dest.toBeResearched ? Colors.orange : null,
                  ),
                  onPressed: _busy
                      ? null
                      : () => _update('to_be_researched', !dest.toBeResearched),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _FactGrid(destination: dest, profile: profile),
            const SizedBox(height: 20),
            // The comment editor only exists when there is
            // something in it: an empty destination opened
            // with a giant blank box before.
            if (_comment.text.trim().isEmpty && !_commentEditing)
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Add comment'),
                  onPressed: _busy
                      ? null
                      : () => setState(() => _commentEditing = true),
                ),
              )
            else ...[
              TextField(
                controller: _comment,
                autofocus: _commentEditing,
                minLines: 2,
                maxLines: 6,
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
                  if (_dest.comment != null && _dest.comment!.trim().isNotEmpty)
                    TextButton(
                      onPressed: _busy ? null : _confirmDeleteComment,
                      child: const Text('Delete'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save comment'),
                    onPressed: _busy ? null : () => _saveComment(),
                  ),
                ],
              ),
            ],
            const _SectionTitle('Overview'),
            if (_coordinate != null) ...[
              DestinationMiniMap(
                coordinate: _coordinate!,
                // The country wears its current-month
                // colour: on the pale basemap, a coastal
                // city's view used to read as "grey and
                // grey".
                countryColor: Color(
                  conditionOfMonth(
                    DestinationProfile.from(_dest)
                        .months[DateTime.now().month - 1],
                  ).colorValue,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (profile.hasOverviewText) ...[
              if (profile.introduction != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    profile.introduction!,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              _LabelledText('Why to Go There', profile.whyToGo),
              _LabelledText('What to Expect', profile.whatToExpect),
              if (profile.touristReviews != null) ...[
                const _SectionTitle('Reviews'),
                _LabelledText(
                  'Tourist Reviews',
                  profile.touristReviews,
                  subheader: true,
                ),
              ],
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
              _FoodEmpty(
                aiConfigured: _aiConfigured,
                populating: _populatingFood,
                onPopulate: _populatingFood ? null : _populateFood,
              ),
            const _SectionTitle('Best months'),
            _BestMonths(profile: profile),
            const _SectionTitle('Climate'),
            _ClimateSection(profile: profile),
            _GallerySection(
              destinationName: dest.name,
              country: dest.country,
              repository: _galleryRepository,
              entries: _galleryEntries,
              onEntriesChanged: (entries) {
                if (mounted) setState(() => _galleryEntries = entries);
              },
            ),
            // The legacy renders the transport
            // connections after the gallery.
            FlightRoutesSection(
              repository: widget.repository,
              destination: dest,
              onOpenDestination: (destination) {
                widget.onOpenDestination?.call(destination.name);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    settings: RouteSettings(
                      name: 'destination/${destination.name}',
                    ),
                    builder: (_) => DestinationPage(
                      repository: widget.repository,
                      destination: destination,
                      onChanged: widget.onChanged,
                      onOpenDestination: widget.onOpenDestination,
                    ),
                  ),
                );
              },
            ),
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 20, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
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
    // An empty dish list folds away: a labeled "—" row said
    // nothing the missing data did not already say.
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
                Text(
                  profile.foodSpicinessText,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
            const SizedBox(width: 40),
            if (dishes.isNotEmpty)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Main dishes (in local language)',
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 0,
                      runSpacing: 2,
                      children: [
                        for (var i = 0; i < dishes.length; i++) ...[
                          _DishLink(dish: dishes[i], destination: profile.name),
                          if (i < dishes.length - 1) const Text(', '),
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

/// The empty food section: the legacy shows the
/// "Populate Food with DeepSeek AI" button only
/// while the food columns are blank -- it is the
/// only way to fill them, and it disappears once
/// they are populated. Like the status banner's
/// populate button, it is offered only when the
/// DeepSeek key is configured.
class _FoodEmpty extends StatelessWidget {
  final bool aiConfigured;
  final bool populating;
  final VoidCallback? onPopulate;

  const _FoodEmpty({
    required this.aiConfigured,
    required this.populating,
    required this.onPopulate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('No food notes yet.'),
        if (aiConfigured) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: populating
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.restaurant_outlined, size: 18),
            label: Text(
              populating
                  ? 'Asking DeepSeek…'
                  : 'Populate Food with DeepSeek AI',
            ),
            onPressed: onPopulate,
          ),
        ],
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
    final launched = await launchUrl(url, mode: LaunchMode.externalApplication);
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
    final risky =
        malaria != null && malaria.trim().toLowerCase().startsWith('yes');
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LogisticsCell(
              label: 'Visa requirement',
              value: profile.visaRequirement ?? '—',
            ),
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
              label: 'Rent a car?',
              value: profile.rentACar ?? '—',
            ),
            _LogisticsCell(
              label: 'Recommended stay',
              value: profile.recommendedStay ?? '—',
            ),
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
                  label: 'Ideal time to go',
                  value: profile.idealTime ?? '—',
                ),
                _LogisticsCell(
                  label: 'Avoid going there',
                  value: profile.avoidTime ?? '—',
                ),
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
              // Uniform chip (month + condition only); the
              // long reason moved into the tooltip, whose
              // variable height used to make every row of
              // chips a different size.
              Tooltip(
                message: month.showReason ? (month.reason ?? '') : '',
                triggerMode: TooltipTriggerMode.tap,
                excludeFromSemantics: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _colorFor(month.bucket, theme.colorScheme),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _borderFor(month.bucket, theme.colorScheme),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        month.abbreviation,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _labelFor(month.bucket),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (profile.idealTime != null || profile.avoidTime != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              [
                if (profile.idealTime != null) 'Ideal: ${profile.idealTime}',
                if (profile.avoidTime != null) 'Avoid: ${profile.avoidTime}',
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
              value: peak == null ? '—' : '${peak.$1.round()}°C (${peak.$2})',
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
        Text(
          'Monthly temperature & rainfall',
          style: theme.textTheme.titleSmall,
        ),
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
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The destination identity: curated desktop art wins, then the first
/// credited Unsplash gallery entry, then typography.
class _DestinationHeader extends StatelessWidget {
  final Destination destination;
  final DestinationProfile profile;
  final String? bannerPath;
  final List<GalleryEntry> galleryEntries;

  const _DestinationHeader({
    required this.destination,
    required this.profile,
    required this.bannerPath,
    required this.galleryEntries,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = [
      if (destination.country != null && destination.country!.isNotEmpty)
        destination.country!,
    ].join(' · ');
    GalleryEntry? galleryPhoto;
    if (bannerPath == null) {
      for (final entry in galleryEntries) {
        if (entry.hasCredit &&
            (entry.hasRemoteImage || entry.imagePath.isNotEmpty)) {
          galleryPhoto = entry;
          break;
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bannerPath != null)
          _BannerPhoto(
            path: bannerPath!,
            name: destination.name,
            location: location,
          )
        else if (galleryPhoto != null)
          _GalleryHeroPhoto(
            entry: galleryPhoto,
            name: destination.name,
            location: location,
          )
        else
          Text(destination.name, style: theme.textTheme.headlineSmall),
        if (bannerPath == null &&
            galleryPhoto == null &&
            location.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            location,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 8),
        // Visited, favourite, researched and priority are editable below.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (profile.reviewsCount != null)
              _HeaderChip(
                icon: Icons.reviews_outlined,
                label: '${profile.reviewsCount}/10 reviews',
              ),
            if (destination.prio != null)
              _HeaderChip(
                icon: Icons.priority_high_outlined,
                label: 'Prio ${destination.prio}',
              ),
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
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        location,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white70,
                        ),
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

class _GalleryHeroPhoto extends StatelessWidget {
  final GalleryEntry entry;
  final String name;
  final String location;

  const _GalleryHeroPhoto({
    required this.entry,
    required this.name,
    required this.location,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = entry.hasRemoteImage
        ? Image.network(
            entry.imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) =>
                ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
          )
        : Image.file(
            File(entry.imagePath),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) =>
                ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 200,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0x99000000)],
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
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                        if (location.isNotEmpty)
                          Text(
                            location,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _PhotoAttribution(entry: entry),
      ],
    );
  }
}

class _PhotoAttribution extends StatelessWidget {
  final GalleryEntry entry;

  const _PhotoAttribution({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    if (entry.isUnsplash) {
      final photographerUrl = entry.photographerUrl;
      final sourceUrl = entry.photoPageUrl.isNotEmpty
          ? entry.photoPageUrl
          : entry.sourceUrl.isNotEmpty
          ? entry.sourceUrl
          : 'https://unsplash.com';
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Photo by ', style: style),
          if (photographerUrl.isNotEmpty)
            _PhotoTextLink(entry.caption, photographerUrl, style: style)
          else
            Text(entry.caption, style: style),
          Text(' on ', style: style),
          _PhotoTextLink('Unsplash', sourceUrl, style: style),
        ],
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          entry.caption.isEmpty ? entry.source : entry.caption,
          style: style,
        ),
        if (entry.sourceUrl.isNotEmpty) ...[
          const SizedBox(width: 6),
          _PhotoTextLink(entry.source, entry.sourceUrl, style: style),
        ],
      ],
    );
  }
}

class _PhotoTextLink extends StatelessWidget {
  final String label;
  final String url;
  final TextStyle? style;

  const _PhotoTextLink(this.label, this.url, {this.style});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () async {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.scheme == 'https') {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    },
    child: Text(
      label,
      style: style?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        decoration: TextDecoration.underline,
      ),
    ),
  );
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
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _HeaderChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The one passive chip on the page (the reviews count):
    // a soft primary tint, the only chrome in the header.
    final background = scheme.primaryContainer;
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
            Icon(
              Icons.info_outline,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
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
                      label: Text(
                        populating ? 'Asking DeepSeek…' : 'Populate with AI',
                      ),
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
    final facts = <(IconData, String, String?, Color)>[
      (
        Icons.public_outlined,
        'Population',
        _populationLabel(profile.population),
        accentPopulation,
      ),
      (
        Icons.hotel_outlined,
        'Recommended stay',
        profile.recommendedStay,
        const Color(0xFF009688),
      ),
      (
        Icons.shield_outlined,
        'Safety',
        destination.safetyRating?.toStringAsFixed(1),
        accentSafety,
      ),
      (
        Icons.payments_outlined,
        'Cost / day',
        destination.avgCostDay == null
            ? null
            : '${destination.avgCostDay!.round()} €',
        accentCost,
      ),
      (
        Icons.flight_takeoff_outlined,
        'FRA flight',
        destination.flightTimeFra == null
            ? null
            : '${destination.flightTimeFra!.toStringAsFixed(1)} h',
        accentFlight,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Horizontal stat tiles: icon in a tinted square on
        // the left, value over label on the right. The old
        // vertical cards stacked icon / number / label and
        // burned ~100 px of height on alignment padding.
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 560;
            return Column(
              children: [
                Row(
                  children: [
                    for (var i = 0; i < (wide ? 5 : 2); i++)
                      if (i < facts.length) ...[
                        if (i > 0 && wide) const SizedBox(width: 8),
                        Expanded(
                          child: _StatTile(
                            icon: facts[i].$1,
                            label: facts[i].$2,
                            value: facts[i].$3,
                            color: facts[i].$4,
                          ),
                        ),
                      ],
                  ],
                ),
                if (!wide && facts.length > 2) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (var i = 2; i < 4 && i < facts.length; i++) ...[
                        if (i > 2) const SizedBox(width: 8),
                        Expanded(
                          child: _StatTile(
                            icon: facts[i].$1,
                            label: facts[i].$2,
                            value: facts[i].$3,
                            color: facts[i].$4,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (var i = 4; i < facts.length; i++) ...[
                        if (i > 4) const SizedBox(width: 8),
                        Expanded(
                          child: _StatTile(
                            icon: facts[i].$1,
                            label: facts[i].$2,
                            value: facts[i].$3,
                            color: facts[i].$4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  /// The workbook column holds the count in millions
  /// (Ulaanbaatar stores 2); a cell that holds the absolute
  /// number instead is compacted. The "2" the old card
  /// showed was the raw value with its unit missing.
  static String _populationLabel(double? population) {
    if (population == null) return '–';
    if (population >= 1000) return _compactNumber(population.round());
    final trimmed = population == population.roundToDouble()
        ? population.toInt().toString()
        : population.toStringAsFixed(1);
    return '$trimmed M';
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

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final Color color;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value ?? '–',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// User-initiated Unsplash gallery search and per-image replacement. Cache
/// reads never trigger network requests; legacy Pictures entries remain visible.
class _GallerySection extends StatefulWidget {
  final String destinationName;
  final String? country;
  final GalleryRepository? repository;
  final List<GalleryEntry> entries;
  final ValueChanged<List<GalleryEntry>>? onEntriesChanged;

  const _GallerySection({
    required this.destinationName,
    required this.country,
    required this.repository,
    required this.entries,
    this.onEntriesChanged,
  });

  @override
  State<_GallerySection> createState() => _GallerySectionState();
}

class _GallerySectionState extends State<_GallerySection> {
  late List<GalleryEntry> _entries;
  final Set<int> _replacing = {};
  var _loading = true;
  var _fetching = false;
  var _nextPage = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _entries = widget.entries;
    _load();
  }

  @override
  void didUpdateWidget(covariant _GallerySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _entries = widget.entries;
      _load();
    } else if (oldWidget.entries != widget.entries) {
      _entries = widget.entries;
    }
  }

  Future<void> _load() async {
    final repository = widget.repository;
    if (repository == null) {
      setState(() => _loading = true);
      return;
    }
    setState(() => _loading = true);
    try {
      final entries = await repository.load(widget.destinationName) ?? const [];
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      widget.onEntriesChanged?.call(entries);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<GalleryEntry>> _searchNextPage() async {
    final repository = widget.repository;
    if (repository == null) {
      throw const PhotoSearchException('Photo search is unavailable.');
    }
    final page = _nextPage++;
    final country = widget.country?.trim() ?? '';
    final query = country.isEmpty
        ? widget.destinationName
        : '${widget.destinationName}, $country';
    return repository.search(query, page: page);
  }

  Future<void> _findPhotos() async {
    if (_fetching || widget.repository == null) return;
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final results = await _searchNextPage();
      final existing = _entries.map(_entryKey).toSet();
      final additions = results
          .where((entry) => existing.add(_entryKey(entry)))
          .toList();
      if (additions.isEmpty) {
        throw const PhotoSearchException(
          'Unsplash returned no new photos for this destination.',
        );
      }
      await _saveEntries([..._entries, ...additions]);
    } catch (error) {
      if (mounted) setState(() => _error = _photoError(error));
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _replacePhoto(int index) async {
    if (_replacing.contains(index) || index >= _entries.length) return;
    setState(() {
      _replacing.add(index);
      _error = null;
    });
    try {
      final results = await _searchNextPage();
      final current = _entries[index];
      final otherEntries = {
        for (var i = 0; i < _entries.length; i++)
          if (i != index) _entryKey(_entries[i]),
      };
      GalleryEntry? replacement;
      for (final candidate in results) {
        if (_entryKey(candidate) != _entryKey(current) &&
            !otherEntries.contains(_entryKey(candidate))) {
          replacement = candidate;
          break;
        }
      }
      if (replacement == null) {
        throw const PhotoSearchException(
          'No different Unsplash photo was found. Try again later.',
        );
      }
      final updated = [..._entries];
      updated[index] = replacement;
      await _saveEntries(updated);
    } catch (error) {
      if (mounted) setState(() => _error = _photoError(error));
    } finally {
      if (mounted) setState(() => _replacing.remove(index));
    }
  }

  Future<void> _saveEntries(List<GalleryEntry> entries) async {
    if (mounted) {
      setState(() => _entries = entries);
      widget.onEntriesChanged?.call(entries);
    }
    try {
      final repository = widget.repository;
      if (repository == null || repository.cache == null) {
        throw const FileSystemException('Photo metadata cache unavailable');
      }
      await repository.save(widget.destinationName, entries);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Photos found, but the metadata cache could not be saved.',
        );
      }
    }
  }

  String _entryKey(GalleryEntry entry) => entry.photoId.isNotEmpty
      ? entry.photoId
      : entry.imageUrl.isNotEmpty
      ? entry.imageUrl
      : entry.imagePath;

  String _photoError(Object error) => error is PhotoSearchException
      ? error.message
      : 'Photo search failed. Check the connection and try again.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repository = widget.repository;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Gallery'),
        Text(
          'Unsplash photos load only when you ask. Existing DuckDuckGo cache entries are shown as before.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (_loading || repository == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.photo_library_outlined, size: 16),
                SizedBox(width: 8),
                Text('Loading photo cache…'),
              ],
            ),
          )
        else if (_entries.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('No cached photos yet. Find photos from Unsplash.'),
          ),
        if (!_loading && repository != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _fetching ? null : _findPhotos,
              icon: _fetching
                  ? Icon(Icons.photo_library_outlined, size: 16)
                  : const Icon(Icons.search),
              label: Text(
                _entries.isEmpty ? 'Find photos' : 'Find more photos',
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (_entries.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var index = 0; index < _entries.length; index++)
                SizedBox(
                  width: 220,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 3 / 2,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _galleryImage(_entries[index], theme),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: _PhotoAttribution(entry: _entries[index]),
                          ),
                          IconButton(
                            tooltip: 'Replace photo',
                            visualDensity: VisualDensity.compact,
                            onPressed: _replacing.contains(index)
                                ? null
                                : () => _replacePhoto(index),
                            icon: _replacing.contains(index)
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _galleryImage(GalleryEntry entry, ThemeData theme) {
    if (entry.hasRemoteImage) {
      return Image.network(
        entry.imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) =>
            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
      );
    }
    return Image.file(
      File(entry.imagePath),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) =>
          ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
    );
  }
}
