/// Trips: the itinerary editor. trips →
/// variants → ordered stops with transport
/// legs, the route summary, the compare table
/// and the JSON export.
///
/// The Dart port of `pages/itinerary.py`. The
/// legacy autosaves to `trips.json` on every
/// mutation (load → mutate → save → rerun);
/// this port does the same cycle through
/// `TripRepository` (load → mutate → save →
/// reload), so every edit is one atomic
/// pipeline write. A failed write returns
/// `false` and is surfaced — never reported
/// as success.
///
/// Turso is last-write-wins: the reload before
/// every edit keeps the write window small,
/// and the explicit optimistic-concurrency
/// guard is a later parity item.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../data/city_coordinates.dart';
import '../data/destination_repository.dart';
import '../data/geocode_repository.dart';
import '../data/trip_repository.dart';
import '../models/destination.dart';
import '../models/trip.dart';
import '../models/trip_ops.dart';
import 'itinerary_compare_tab.dart';
import 'itinerary_map_tab.dart';
import 'itinerary_plan_tab.dart';

class TripsPage extends StatefulWidget {
  final TripRepository repository;
  final DestinationRepository destinations;
  final GeocodeRepository geocoder;

  const TripsPage({
    super.key,
    required this.repository,
    required this.destinations,
    required this.geocoder,
  });

  @override
  State<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends State<TripsPage> {
  List<Trip> _trips = [];
  List<String> _problems = [];
  var _loading = true;
  String? _activeTripId;

  /// The catalogue: the workbook destination
  /// picker and the month suggestions read it.
  List<Destination> _catalogue = [];

  /// The coordinate table, loaded once: a
  /// workbook stop gets its lat/lon filled at
  /// creation time (`geo.resolve_ref`).
  CoordinateIndex? _coordinates;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadCatalogue();
    CoordinateIndex.load().then((index) {
      if (mounted) setState(() => _coordinates = index);
    });
  }

  Trip? get _activeTrip {
    if (_activeTripId == null) return null;
    for (final trip in _trips) {
      if (trip.id == _activeTripId) return trip;
    }
    return _trips.isEmpty ? null : _trips.first;
  }

  Future<void> _refresh() async {
    final (trips, problems) = await widget.repository.loadTrips();
    if (!mounted) return;
    setState(() {
      _trips = trips;
      _problems = problems;
      _loading = false;
      if (_activeTripId == null ||
          !trips.any((trip) => trip.id == _activeTripId)) {
        _activeTripId = trips.isEmpty ? null : trips.first.id;
      }
    });
  }

  Future<void> _loadCatalogue() async {
    final (catalogue, _) = await widget.destinations.loadDestinations();
    if (!mounted) return;
    setState(() => _catalogue = catalogue);
  }

  // ── mutation cycle ──────────────────────────────────────────

  /// Reload, transform the trip, save it, reload
  /// again. The reload before the edit is the
  /// same read-modify-write the legacy performs
  /// and keeps the last-write-wins window
  /// small.
  Future<void> _editTrip(
    String tripId,
    Trip Function(Trip trip) transform,
  ) async {
    final (trips, problems) =
        await widget.repository.loadTrips();
    if (problems.isNotEmpty) {
      _showError('Could not load trips: ${problems.first}');
      return;
    }
    final trip = trips.where((trip) => trip.id == tripId).firstOrNull;
    if (trip == null) return;
    final status =
        await widget.repository.saveTrip(transform(trip));
    if (status == TripSaveStatus.conflict) {
      _showConflict();
      return;
    }
    if (status != TripSaveStatus.saved) {
      _showError('Nothing written — the save failed. '
          'Check the token and the connection.');
      return;
    }
    await _refresh();
  }

  Future<void> _editActiveTrip(Trip Function(Trip trip) transform) {
    final trip = _activeTrip;
    if (trip == null) return Future.value();
    return _editTrip(trip.id, transform);
  }

  /// A trip transform that applies [edit] to the
  /// trip's ACTIVE variant, leaving the others
  /// untouched. Curried so it can be handed
  /// straight to `_editActiveTrip`.
  Trip Function(Trip) withActiveVariant(
      Variant Function(Variant variant) edit) {
    return (trip) {
      final active = trip.activeVariant;
      if (active == null) return trip;
      return _copyTrip(
        trip,
        variants: [
          for (final variant in trip.variants)
            variant.id == active.id ? edit(variant) : variant,
        ],
      );
    };
  }

  Trip Function(Trip trip) _editVariantById(
      String variantId, Variant Function(Variant variant) edit) {
    return (trip) => _copyTrip(
          trip,
          variants: [
            for (final variant in trip.variants)
              variant.id == variantId ? edit(variant) : variant,
          ],
        );
  }

  Trip _copyTrip(
    Trip trip, {
    String? name,
    String? activeVariantId,
    List<Variant> variants = const [],
  }) =>
      Trip(
        id: trip.id,
        name: name ?? trip.name,
        created: trip.created,
        activeVariantId: activeVariantId ?? trip.activeVariantId,
        variants: variants.isEmpty ? trip.variants : variants,
      );

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The legacy's `TripsFileChanged` message with
  /// its "Reload latest data" action: another device
  /// saved the trip after this copy was loaded, so
  /// the edit was not written and the other change
  /// stays intact.
  void _showConflict() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'The trip was saved on another device '
            'after this copy was loaded. Saving now '
            'would silently discard that change.',
          ),
          action: SnackBarAction(
            label: 'Reload latest data',
            onPressed: _refresh,
          ),
        ),
      );
  }

  // ── trip operations ─────────────────────────────────────────

  Future<void> _newTrip(String name) async {
    final (trips, problems) =
        await widget.repository.loadTrips();
    if (problems.isNotEmpty) {
      _showError('Could not load trips: ${problems.first}');
      return;
    }
    final trip = createTrip(name.trim().isEmpty ? 'New trip' : name.trim());
    final status = await widget.repository.saveTrip(trip);
    if (status != TripSaveStatus.saved) {
      _showError('Nothing written — the save failed. '
          'Check the token and the connection.');
      return;
    }
    await _refresh();
    if (mounted) setState(() => _activeTripId = trip.id);
  }

  Future<void> _duplicateTrip(String tripId) async {
    final (trips, problems) =
        await widget.repository.loadTrips();
    if (problems.isNotEmpty) {
      _showError('Could not load trips: ${problems.first}');
      return;
    }
    final src = trips.where((trip) => trip.id == tripId).firstOrNull;
    if (src == null) return;
    final clone = duplicateTrip(src);
    final status = await widget.repository.saveTrip(clone);
    if (status != TripSaveStatus.saved) {
      _showError('Nothing written — the save failed. '
          'Check the token and the connection.');
      return;
    }
    await _refresh();
    if (mounted) setState(() => _activeTripId = clone.id);
  }

  Future<void> _deleteTrip(String tripId) async {
    final ok = await widget.repository.deleteTrip(tripId);
    if (!ok) {
      _showError('Nothing deleted — the write failed. '
          'Check the token and the connection.');
      return;
    }
    await _refresh();
  }

  // ── variant operations ──────────────────────────────────────

  /// The legacy's "New" button creates a BLANK
  /// variant (not a copy of the active one) and
  /// activates it.
  Future<void> _newVariant(String name) => _editActiveTrip((trip) {
        final label = name.trim().isEmpty
            ? 'Variant ${trip.variants.length + 1}'
            : name.trim();
        final variant = makeVariant(label);
        return _copyTrip(
          trip,
          activeVariantId: variant.id,
          variants: [...trip.variants, variant],
        );
      });

  Future<void> _duplicateVariant(String variantId) =>
      _editActiveTrip((trip) {
        final updated = duplicateVariant(trip, variantId);
        if (updated == null) return trip;
        final clone = updated.variants.last;
        return _copyTrip(updated, activeVariantId: clone.id);
      });

  Future<void> _deleteVariant(String variantId) =>
      _editActiveTrip((trip) => deleteVariant(trip, variantId));

  Future<void> _renameVariant(String variantId, String name) =>
      _editActiveTrip(_editVariantById(
          variantId, (variant) => renameVariant(variant, name)));

  Future<void> _activateVariant(String variantId) =>
      _editActiveTrip((trip) => setActiveVariant(trip, variantId));

  // ── stop / leg operations ───────────────────────────────────

  /// A workbook destination gets its lat/lon
  /// filled at creation time; custom refs keep
  /// the geocoded coordinates, the gateway its
  /// fixed ones (`_add_stop` in the legacy).
  StopRef _resolveRef(StopRef ref) {
    if (ref.lat != null && ref.lon != null) return ref;
    final hit = _coordinates?.lookup(ref.name);
    if (hit == null) return ref;
    return StopRef(
      kind: ref.kind,
      name: ref.name,
      country: ref.country != null && ref.country!.isNotEmpty
          ? ref.country
          : hit.country,
      lat: hit.lat,
      lon: hit.lon,
    );
  }

  Future<void> _addStop(StopRef ref, String role, int? nights) =>
      _editActiveTrip(withActiveVariant((variant) {
        return addStop(
          variant,
          _resolveRef(ref),
          role: role,
          nights: nights != null && nights > 0 ? nights : null,
        );
      }));

  Future<void> _removeStop(String stopId) => _editActiveTrip(
        withActiveVariant((variant) {
          final index =
              variant.stops.indexWhere((stop) => stop.id == stopId);
          if (index < 0) return variant;
          return removeStop(variant, index);
        }),
      );

  Future<void> _moveStop(String stopId, int direction) =>
      _editActiveTrip(
        withActiveVariant((variant) {
          final index =
              variant.stops.indexWhere((stop) => stop.id == stopId);
          if (index < 0) return variant;
          return moveStop(variant, index, direction);
        }),
      );

  Future<void> _updateStop(String stopId, Stop updated) =>
      _editActiveTrip(
        withActiveVariant((variant) {
          final index =
              variant.stops.indexWhere((stop) => stop.id == stopId);
          if (index < 0) return variant;
          return updateStop(variant, index, updated);
        }),
      );

  Future<void> _setLegMode(int legIndex, String mode) =>
      _editActiveTrip(
          withActiveVariant((variant) => setLegMode(variant, legIndex, mode)));

  Future<void> _updateVariant(Variant updated) =>
      _editActiveTrip((trip) => _copyTrip(
            trip,
            variants: [
              for (final variant in trip.variants)
                variant.id == updated.id ? updated : variant,
            ],
          ));

  // ── export ──────────────────────────────────────────────────

  /// The legacy sidebar's workbook download, in
  /// its Turso-world shape: the whole trips
  /// store as one JSON snapshot. Same
  /// mechanism as the per-trip export --
  /// selectable text plus the clipboard, no
  /// file plugin (the user's decision, G4).
  void _backup() {
    final json = exportTrips(_trips);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backup all trips'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(json),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: json)),
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// The legacy's download button: the trip as
  /// pretty JSON. Flutter desktop has no
  /// download-to-disk affordance without a file
  /// plugin, so the JSON is shown selectable
  /// and copyable — same content, same file
  /// name in the dialog title.
  void _export(Trip trip) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Export "${trip.name}"'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(exportTrip(trip)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: exportTrip(trip))),
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ── build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trips'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Backup all trips (JSON)',
            onPressed: _backup,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _body(),
    );
  }

  Widget _body() {
    if (_problems.isNotEmpty) {
      return _ProblemView(
        problems: _problems,
        onRetry: _refresh,
      );
    }
    if (_trips.isEmpty) {
      return _EmptyTripsView(onNewTrip: () => _promptForName(
        context,
        title: 'New trip',
        onSubmit: _newTrip,
      ));
    }
    final trip = _activeTrip;
    if (trip == null) return _EmptyTripsView(onNewTrip: () {});
    return _ItineraryView(
      key: ValueKey(trip.id),
      trip: trip,
      trips: _trips,
      catalogue: _catalogue,
      geocoder: widget.geocoder,
      onSelectTrip: (id) => setState(() => _activeTripId = id),
      onNewTrip: () => _promptForName(
        context,
        title: 'New trip',
        onSubmit: _newTrip,
      ),
      onDuplicateTrip: _duplicateTrip,
      onRenameTrip: (name) =>
          _editTrip(trip.id, (trip) => renameTrip(trip, name)),
      onDeleteTrip: _deleteTrip,
      onNewVariant: () => _promptForName(
        context,
        title: 'New variant',
        initial:
            'Variant ${trip.variants.length + 1}',
        onSubmit: _newVariant,
      ),
      onDuplicateVariant: () =>
          _duplicateVariant(trip.activeVariant?.id ?? ''),
      onRenameVariant: (name) =>
          _renameVariant(trip.activeVariant?.id ?? '', name),
      onDeleteVariant: () =>
          _deleteVariant(trip.activeVariant?.id ?? ''),
      onAddStop: _addStop,
      onRemoveStop: _removeStop,
      onMoveStop: _moveStop,
      onUpdateStop: _updateStop,
      onSetLegMode: _setLegMode,
      onUpdateVariant: _updateVariant,
      onActivateVariant: _activateVariant,
      onExport: () => _export(trip),
    );
  }
}

/// A one-field dialog that feeds a name to a
/// create/rename action — the port of the
/// legacy's `st.popover` + text_input + button.
Future<void> _promptForName(
  BuildContext context, {
  required String title,
  required Future<void> Function(String name) onSubmit,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null) {
    await onSubmit(name);
  }
}

/// The switchers, toolbars and tabs for one open
/// trip. Keyed by the trip id: a different trip
/// is a fresh widget tree.
class _ItineraryView extends StatefulWidget {
  final Trip trip;
  final List<Trip> trips;
  final List<Destination> catalogue;
  final GeocodeRepository geocoder;

  final void Function(String tripId) onSelectTrip;
  final VoidCallback onNewTrip;
  final Future<void> Function(String tripId) onDuplicateTrip;
  final Future<void> Function(String name) onRenameTrip;
  final Future<void> Function(String tripId) onDeleteTrip;
  final VoidCallback onNewVariant;
  final VoidCallback onDuplicateVariant;
  final Future<void> Function(String name) onRenameVariant;
  final VoidCallback onDeleteVariant;

  final Future<void> Function(StopRef ref, String role, int? nights)
      onAddStop;
  final Future<void> Function(String stopId) onRemoveStop;
  final Future<void> Function(String stopId, int direction) onMoveStop;
  final Future<void> Function(String stopId, Stop updated) onUpdateStop;
  final Future<void> Function(int legIndex, String mode) onSetLegMode;
  final Future<void> Function(Variant updated) onUpdateVariant;
  final Future<void> Function(String variantId) onActivateVariant;
  final VoidCallback onExport;

  const _ItineraryView({
    super.key,
    required this.trip,
    required this.trips,
    required this.catalogue,
    required this.geocoder,
    required this.onSelectTrip,
    required this.onNewTrip,
    required this.onDuplicateTrip,
    required this.onRenameTrip,
    required this.onDeleteTrip,
    required this.onNewVariant,
    required this.onDuplicateVariant,
    required this.onRenameVariant,
    required this.onDeleteVariant,
    required this.onAddStop,
    required this.onRemoveStop,
    required this.onMoveStop,
    required this.onUpdateStop,
    required this.onSetLegMode,
    required this.onUpdateVariant,
    required this.onActivateVariant,
    required this.onExport,
  });

  @override
  State<_ItineraryView> createState() => _ItineraryViewState();
}

class _ItineraryViewState extends State<_ItineraryView> {
  /// The stop the Plan tab's eye button picked,
  /// haloed on the Map tab. The legacy keeps it
  /// in session state; here it lives with the
  /// trip's widget tree, so switching trips
  /// clears it.
  String? _selectedStopId;

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final trips = widget.trips;
    final catalogue = widget.catalogue;
    final geocoder = widget.geocoder;
    final onSelectTrip = widget.onSelectTrip;
    final onNewTrip = widget.onNewTrip;
    final onDuplicateTrip = widget.onDuplicateTrip;
    final onRenameTrip = widget.onRenameTrip;
    final onDeleteTrip = widget.onDeleteTrip;
    final onNewVariant = widget.onNewVariant;
    final onDuplicateVariant = widget.onDuplicateVariant;
    final onRenameVariant = widget.onRenameVariant;
    final onDeleteVariant = widget.onDeleteVariant;
    final onAddStop = widget.onAddStop;
    final onRemoveStop = widget.onRemoveStop;
    final onMoveStop = widget.onMoveStop;
    final onUpdateStop = widget.onUpdateStop;
    final onSetLegMode = widget.onSetLegMode;
    final onUpdateVariant = widget.onUpdateVariant;
    final onActivateVariant = widget.onActivateVariant;
    final onExport = widget.onExport;
    final theme = Theme.of(context);
    final variants = trip.variants;
    final active = trip.activeVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      trip.name,
                      style: theme.textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete trip',
                    onPressed: () => _confirmDelete(
                      context,
                      title: 'Delete trip?',
                      message:
                          'Delete "${trip.name}" with all its variants? '
                          'This cannot be undone.',
                      onConfirm: () => onDeleteTrip(trip.id),
                    ),
                  ),
                ],
              ),
              // The action buttons wrap onto their
              // own line: three buttons plus the
              // delete icon never fit a phone-width
              // row (the test font measures every
              // glyph a full em wide).
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: onNewTrip,
                    child: const Text('New'),
                  ),
                  OutlinedButton(
                    onPressed: () => onDuplicateTrip(trip.id),
                    child: const Text('Copy'),
                  ),
                  OutlinedButton(
                    onPressed: () => _promptForName(
                      context,
                      title: 'Rename trip',
                      initial: trip.name,
                      onSubmit: onRenameTrip,
                    ),
                    child: const Text('Rename'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Labels carry a short id suffix when
              // names collide, so a duplicate trip
              // name can never make the dropdown
              // switch to the wrong trip.
               DropdownButtonFormField<String>(
                 initialValue: trip.id,
                 isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Trip',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final option in trips)
                    DropdownMenuItem(
                      value: option.id,
                      child: Text(_tripLabel(option, trips)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) onSelectTrip(value);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: active?.id,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Variant',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final variant in variants)
                          DropdownMenuItem(
                            value: variant.id,
                            child: Text(_variantLabel(variant, variants)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null && value != active?.id) {
                          // Switching the active variant
                          // is the same write cycle as
                          // every other edit.
                          onActivateVariant(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete variant',
                    onPressed: variants.length <= 1 ? null : onDeleteVariant,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: onNewVariant,
                    child: const Text('New'),
                  ),
                  OutlinedButton(
                    onPressed: onDuplicateVariant,
                    child: const Text('Copy'),
                  ),
                  OutlinedButton(
                    onPressed: () => _promptForName(
                      context,
                      title: 'Rename variant',
                      initial: active?.name ?? '',
                      onSubmit: onRenameVariant,
                    ),
                    child: const Text('Rename'),
                  ),
                ],
              ),
],
          ),
        ),
        DefaultTabController(
          length: 3,
          child: Expanded(
            child: Column(
              children: [
                const TabBar(tabs: [
                  Tab(text: 'Plan'),
                  Tab(text: 'Map'),
                  Tab(text: 'Compare'),
                ]),
                Expanded(
                  child: TabBarView(
                    children: [
                      if (active == null)
                        const Center(
                          child: Text(
                              'This trip has no variants — '
                              'create one above.'),
                        )
                      else
                        ItineraryPlanTab(
                          trip: trip,
                          variant: active,
                          catalogue: catalogue,
                          geocoder: geocoder,
                          onRemoveStop: onRemoveStop,
                          onMoveStop: onMoveStop,
                          onUpdateStop: onUpdateStop,
                          onSetLegMode: onSetLegMode,
                          onAddStop: onAddStop,
                          onUpdateVariant: onUpdateVariant,
                          onExport: onExport,
                          selectedStopId: _selectedStopId,
                          onToggleHighlight: (stopId) => setState(() {
                            // The eye toggles: picking the
                            // highlighted stop again
                            // clears it.
                            _selectedStopId =
                                _selectedStopId == stopId ? null : stopId;
                          }),
                        ),
                      ItineraryMapTab(
                        key: ValueKey(active?.id ?? 'no-variant'),
                        variant: active,
                        selectedStopId: _selectedStopId,
                      ),
                      ItineraryCompareTab(
                        trip: trip,
                        onActivate: onActivateVariant,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The trips problem view: the load failed with
/// a reason, never an ambiguous empty list.
class _ProblemView extends StatelessWidget {
  final List<String> problems;
  final Future<void> Function() onRetry;

  const _ProblemView({required this.problems, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        const SizedBox(height: 40),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.cloud_off),
                    SizedBox(width: 8),
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
                      onPressed: () => onRetry(),
                      child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyTripsView extends StatelessWidget {
  final VoidCallback onNewTrip;

  const _EmptyTripsView({required this.onNewTrip});

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
            Text('No trips stored',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Create an itinerary to combine destinations into '
              'multi-stop trips with variants, dates and transport '
              'legs.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onNewTrip,
              icon: const Icon(Icons.add),
              label: const Text('New trip'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The trip dropdown's label: a duplicate name
/// gets a short id suffix, so a duplicate trip
/// name can never make the dropdown switch to
/// the wrong trip (the legacy's rule).
String _tripLabel(Trip trip, List<Trip> trips) {
  final count =
      trips.where((option) => option.name == trip.name).length;
  return count == 1 ? trip.name : '${trip.name} · ${_suffix(trip.id)}';
}

/// The variant dropdown's label, with the same
/// duplicate-name disambiguation.
String _variantLabel(Variant variant, List<Variant> variants) {
  final count = variants
      .where((option) => option.name == variant.name)
      .length;
  return count == 1
      ? variant.name
      : '${variant.name} · ${_suffix(variant.id)}';
}

String _suffix(String id) =>
    id.length > 6 ? id.substring(id.length - 6) : id;

/// The confirmation dialog every destructive
/// itinerary action goes through: removing a
/// stop, deleting a variant or a trip.
Future<void> _confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  required VoidCallback onConfirm,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
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
  if (confirmed == true) {
    onConfirm();
  }
}
