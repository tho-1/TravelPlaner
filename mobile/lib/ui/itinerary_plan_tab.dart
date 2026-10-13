/// The Plan tab of the itinerary editor: the
/// ordered stops with their editors, the
/// transport legs between them, the add-stop
/// panel, the route summary, the variant meta
/// editor, the warnings and the JSON export.
///
/// The Dart port of `pages/itinerary.py`'s
/// `_render_plan_tab` and its helpers. The
/// legacy mutates plain dicts and autosaves on
/// every widget change; this port holds pending
/// values in the editor widgets and commits on
/// Save -- the same fields, the same validation
/// (HH:MM times, departure >= arrival, nights
/// 0 = unset), one explicit save per edit.
///
/// Pure display + callbacks: every mutation
/// flows up to `TripsPage`, which owns the
/// load → mutate → save → reload cycle.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/geocode_repository.dart';
import '../models/destination.dart';
import '../models/trip.dart';
import '../models/trip_ops.dart';

/// The stop roles, with the legacy's badge
/// semantics (`itinerary.itinerary.ROLES`).
const _roleLabels = {
  'origin': 'Origin',
  'stop': 'Stop',
  'return': 'Return',
};

/// `pages/itinerary.py`'s `TIME_RE`: a valid
/// 24h HH:MM time.
final RegExp _timeRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

class ItineraryPlanTab extends StatelessWidget {
  final Trip trip;
  final Variant variant;
  final List<Destination> catalogue;
  final GeocodeRepository geocoder;

  final void Function(String stopId) onRemoveStop;
  final void Function(String stopId, int direction) onMoveStop;
  final void Function(String stopId, Stop updated) onUpdateStop;
  final void Function(int legIndex, String mode) onSetLegMode;
  final void Function(
    StopRef ref,
    String role,
    int? nights,
  ) onAddStop;
  final void Function(Variant updated) onUpdateVariant;
  final VoidCallback onExport;

  /// The stop the eye button picked, shown
  /// with a halo on the Map tab.
  final String? selectedStopId;
  final void Function(String stopId) onToggleHighlight;

  const ItineraryPlanTab({
    super.key,
    required this.trip,
    required this.variant,
    required this.catalogue,
    required this.geocoder,
    required this.onRemoveStop,
    required this.onMoveStop,
    required this.onUpdateStop,
    required this.onSetLegMode,
    required this.onAddStop,
    required this.onUpdateVariant,
    required this.onExport,
    required this.selectedStopId,
    required this.onToggleHighlight,
  });

  @override
  Widget build(BuildContext context) {
    // The legacy's two-column plan (stops left,
    // summary right) collapses to one column at
    // phone width, where a Row would overflow.
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final plan = _StopsColumn(
          variant: variant,
          onRemoveStop: onRemoveStop,
          onMoveStop: onMoveStop,
          onUpdateStop: onUpdateStop,
          onSetLegMode: onSetLegMode,
          onAddStop: onAddStop,
          geocoder: geocoder,
          catalogue: catalogue,
          selectedStopId: selectedStopId,
          onToggleHighlight: onToggleHighlight,
        );
        final side = _SideColumn(
          trip: trip,
          variant: variant,
          catalogue: catalogue,
          onUpdateVariant: onUpdateVariant,
          onExport: onExport,
        );
        if (constraints.maxWidth < 860) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [plan, const Divider(), side],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 12, child: plan),
            const SizedBox(width: 24),
            Expanded(flex: 10, child: side),
          ],
        );
      },
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: body,
    );
  }
}

// ── stops column ─────────────────────────────────────────────

class _StopsColumn extends StatefulWidget {
  final Variant variant;
  final GeocodeRepository geocoder;
  final List<Destination> catalogue;
  final void Function(String stopId) onRemoveStop;
  final void Function(String stopId, int direction) onMoveStop;
  final void Function(String stopId, Stop updated) onUpdateStop;
  final void Function(int legIndex, String mode) onSetLegMode;
  final void Function(StopRef ref, String role, int? nights) onAddStop;
  final String? selectedStopId;
  final void Function(String stopId) onToggleHighlight;

  const _StopsColumn({
    required this.variant,
    required this.geocoder,
    required this.catalogue,
    required this.onRemoveStop,
    required this.onMoveStop,
    required this.onUpdateStop,
    required this.onSetLegMode,
    required this.onAddStop,
    required this.selectedStopId,
    required this.onToggleHighlight,
  });

  @override
  State<_StopsColumn> createState() => _StopsColumnState();
}

class _StopsColumnState extends State<_StopsColumn> {
  /// The one stop whose editor is open — the accordion.
  /// Every editor used to sit permanently expanded, which
  /// turned the column into a wall of fields.
  String? _expandedStopId;

  @override
  Widget build(BuildContext context) {
    final variant = widget.variant;
    final stops = variant.stops;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stops.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('No stops yet — add your first '
                'destination below.'),
          ),
        for (var i = 0; i < stops.length; i++) ...[
          _StopCard(
            // Keyed by the stop's id, not its
            // position: the editor's pending
            // values must follow the stop through
            // a reorder or a variant switch, or
            // a save writes them into whichever
            // stop sits at the position now.
            key: ValueKey(stops[i].id),
            index: i,
            stop: stops[i],
            total: stops.length,
            selected: widget.selectedStopId == stops[i].id,
            expanded: _expandedStopId == stops[i].id,
            onToggleExpand: () => setState(() {
              _expandedStopId =
                  _expandedStopId == stops[i].id ? null : stops[i].id;
            }),
            onRemove: widget.onRemoveStop,
            onMove: widget.onMoveStop,
            onUpdate: widget.onUpdateStop,
            onToggleHighlight: widget.onToggleHighlight,
          ),
          if (i < stops.length - 1)
            _LegRow(
              variant: variant,
              legIndex: i,
              onSetMode: widget.onSetLegMode,
            ),
        ],
        const SizedBox(height: 8),
        _AddStopPanel(
          // Keyed by the variant: the panel's
          // pending search and selection belong
          // to the variant they were typed for.
          key: ValueKey(variant.id),
          variant: variant,
          geocoder: widget.geocoder,
          catalogue: widget.catalogue,
          onAddStop: widget.onAddStop,
        ),
      ],
    );
  }
}

/// One stop: the collapsed line (name, dates, role) with the
/// reorder, highlight and remove actions — tapping it opens
/// the date/time editor, one stop at a time.
class _StopCard extends StatelessWidget {
  final int index;
  final Stop stop;
  final int total;
  final bool selected;

  /// Whether this stop's editor is open (one at a time,
  /// owned by the column).
  final bool expanded;
  final VoidCallback onToggleExpand;
  final void Function(String stopId) onRemove;
  final void Function(String stopId, int direction) onMove;
  final void Function(String stopId, Stop updated) onUpdate;
  final void Function(String stopId) onToggleHighlight;

  const _StopCard({
    super.key,
    required this.index,
    required this.stop,
    required this.total,
    required this.selected,
    required this.expanded,
    required this.onToggleExpand,
    required this.onRemove,
    required this.onMove,
    required this.onUpdate,
    required this.onToggleHighlight,
  });

  bool get _isOriginRole => stop.role == 'origin';

  /// The collapsed line's facts: arrival → departure and
  /// the nights, or "no dates set".
  String get _summary {
    String? at(String? date, String? time) {
      if (date == null || date.isEmpty) return null;
      if (time == null || time.isEmpty) return date;
      return '$date $time';
    }

    final parts = <String>[];
    if (!_isOriginRole) {
      final arrival = at(stop.arrivalDate, stop.arrivalTime);
      if (arrival != null) parts.add(arrival);
      if (stop.nights != null) parts.add('${stop.nights} nights');
    }
    final departure = at(stop.departureDate, stop.departureTime);
    if (departure != null) parts.add(departure);
    return parts.isEmpty ? 'no dates set' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = _roleLabels[stop.role] ?? 'Stop';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The header line is the tap target that opens
            // the editor; the eye and the actions menu live
            // IN the header (a separate four-button row made
            // every collapsed stop twice as tall as its
            // content).
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onToggleExpand,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${index + 1}. ${stop.ref.name}'
                          '${stop.ref.country != null && stop.ref.country!.isNotEmpty ? ' · ${stop.ref.country}' : ''}',
                          style: theme.textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(_summary,
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  // The role is part of the stop's
                  // meaning (origin = trip start,
                  // return = way back home), so it is
                  // shown, not just stored.
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: theme.colorScheme.outline),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(role,
                        style: theme.textTheme.labelSmall),
                  ),
                  IconButton(
                    icon: Icon(
                      selected
                          ? Icons.visibility
                          : Icons.visibility_outlined,
                      color: selected
                          ? theme.colorScheme.primary
                          : null,
                    ),
                    tooltip: 'Highlight on map',
                    onPressed: () =>
                        onToggleHighlight(stop.id),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Stop actions',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (action) {
                      switch (action) {
                        case 'up':
                          onMove(stop.id, -1);
                        case 'down':
                          onMove(stop.id, 1);
                        case 'remove':
                          _confirmRemove(context);
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'up',
                        enabled: index > 0,
                        child: const Row(children: [
                          Icon(Icons.arrow_upward, size: 18),
                          SizedBox(width: 10),
                          Text('Move up'),
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'down',
                        enabled: index < total - 1,
                        child: const Row(children: [
                          Icon(Icons.arrow_downward, size: 18),
                          SizedBox(width: 10),
                          Text('Move down'),
                        ]),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'remove',
                        child: const Row(children: [
                          Icon(Icons.delete_outline,
                              size: 18,
                              color: Color(0xFFB3261E)),
                          SizedBox(width: 10),
                          Text('Remove stop'),
                        ]),
                      ),
                    ],
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(Icons.expand_more),
                  ),
                ],
              ),
            ),
            // Offstage rather than removed: pending edits
            // survive closing the accordion, and the Save
            // button stays meaningful per stop.
            Offstage(
              offstage: !expanded,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StopEditor(stop: stop, onUpdate: onUpdate),
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Highlighted on the Map tab',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                fontStyle: FontStyle.italic,
                                color:
                                    Theme.of(context).colorScheme.primary,
                              )),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Removing a stop also drops its leg -- always
  /// ask first, the legacy's rule.
  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove stop?'),
        content: Text(
            'Remove "${stop.ref.name}" from this trip? '
            'The transport leg into it is removed too.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      onRemove(stop.id);
    }
  }
}

/// The date/time/nights editor for one stop.
/// Holds pending values until Save, exactly the
/// legacy's form semantics.
class _StopEditor extends StatefulWidget {
  final Stop stop;
  final void Function(String stopId, Stop updated) onUpdate;

  const _StopEditor({required this.stop, required this.onUpdate});

  @override
  State<_StopEditor> createState() => _StopEditorState();
}

class _StopEditorState extends State<_StopEditor> {
  late String? _arrivalDate;
  late String? _departureDate;
  late final TextEditingController _arrivalTime;
  late final TextEditingController _departureTime;
  late final TextEditingController _nights;
  late final TextEditingController _notes;

  bool get _isOrigin => widget.stop.role == 'origin';

  @override
  void initState() {
    super.initState();
    _arrivalDate = widget.stop.arrivalDate;
    _departureDate = widget.stop.departureDate;
    _arrivalTime = TextEditingController(
        text: widget.stop.arrivalTime ?? '');
    _departureTime = TextEditingController(
        text: widget.stop.departureTime ?? '');
    // 0 in the field means "unset" (the total
    // falls back to the date span), so an unset
    // nights shows as empty, not as 0.
    _nights = TextEditingController(
        text: widget.stop.nights?.toString() ?? '');
    _notes = TextEditingController(text: widget.stop.notes);
  }

  @override
  void dispose() {
    _arrivalTime.dispose();
    _departureTime.dispose();
    _nights.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool isArrival) async {
    final current = _parseDate(isArrival ? _arrivalDate : _departureDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (isArrival) {
        _arrivalDate = _iso(picked);
      } else {
        _departureDate = _iso(picked);
      }
    });
  }

  void _save() {
    final errors = <String>[];
    final arrivalTime = _arrivalTime.text.trim();
    final departureTime = _departureTime.text.trim();
    if (_isOrigin) {
      if (departureTime.isNotEmpty && !_timeRe.hasMatch(departureTime)) {
        errors.add('Departure time: use HH:MM (24h).');
      }
    } else {
      if (arrivalTime.isNotEmpty && !_timeRe.hasMatch(arrivalTime)) {
        errors.add('Arrival time: use HH:MM (24h).');
      }
      if (departureTime.isNotEmpty &&
          !_timeRe.hasMatch(departureTime)) {
        errors.add('Departure time: use HH:MM (24h).');
      }
      final arrival = _parseDate(_arrivalDate);
      final departure = _parseDate(_departureDate);
      if (arrival != null &&
          departure != null &&
          departure.isBefore(arrival)) {
        errors.add('Departure is before arrival.');
      }
    }
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errors.join(' '))));
      return;
    }
    final nights = int.tryParse(_nights.text.trim());
    widget.onUpdate(
      widget.stop.id,
      Stop(
        id: widget.stop.id,
        ref: widget.stop.ref,
        // The origin editor only edits the
        // departure -- the legacy's `_update_stop`
        // leaves the other fields as they are.
        arrivalDate:
            _isOrigin ? widget.stop.arrivalDate : _arrivalDate,
        departureDate: _departureDate,
        arrivalTime: _isOrigin
            ? widget.stop.arrivalTime
            : (arrivalTime.isEmpty ? null : arrivalTime),
        departureTime:
            departureTime.isEmpty ? null : departureTime,
        nights: _isOrigin
            ? widget.stop.nights
            : (nights != null && nights > 0 ? nights : null),
        role: widget.stop.role,
        notes: _notes.text.trim(),
      ),
    );
  }

  /// "Auto: departure = arrival + nights" -- needs
  /// an arrival date and nights > 0.
  void _autoDeparture() {
    final arrival = _parseDate(_arrivalDate);
    final nights = int.tryParse(_nights.text.trim());
    if (arrival != null && nights != null && nights > 0) {
      setState(() {
        _departureDate = _iso(arrival.add(Duration(days: nights)));
        _nights.text = '$nights';
      });
    } else {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
            content: Text('Set an arrival date and nights > 0 first.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isOrigin) ...[
          _DateField(
            label: 'Trip start — departure',
            value: _departureDate,
            onPick: () => _pickDate(false),
            onClear: _departureDate == null
                ? null
                : () => setState(() => _departureDate = null),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _departureTime,
              maxLength: 5,
              decoration: const InputDecoration(
                labelText: 'Departure time',
                hintText: '18:45',
                counterText: '',
              ),
            ),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Arrival',
                  value: _arrivalDate,
                  onPick: () => _pickDate(true),
                  onClear: _arrivalDate == null
                      ? null
                      : () => setState(() => _arrivalDate = null),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateField(
                  label: 'Departure',
                  value: _departureDate,
                  onPick: () => _pickDate(false),
                  onClear: _departureDate == null
                      ? null
                      : () => setState(() => _departureDate = null),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nights,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Nights',
                    helperText: 'Leave empty to keep nights '
                        'unset (total falls back to dates).',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _arrivalTime,
                  maxLength: 5,
                  decoration: const InputDecoration(
                    labelText: 'Arrival time',
                    hintText: '09:30',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _departureTime,
                  maxLength: 5,
                  decoration: const InputDecoration(
                    labelText: 'Departure time',
                    hintText: '18:45',
                    counterText: '',
                  ),
                ),
              ),
            ],
          ),
        ],
        TextField(
          controller: _notes,
          decoration: const InputDecoration(labelText: 'Notes'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(onPressed: _save, child: const Text('Save stop')),
            if (!_isOrigin) ...[
              const SizedBox(width: 8),
              // The auto button's label is the longest
              // in the editor: it takes the remaining
              // width and wraps instead of overflowing
              // the row.
              Expanded(
                child: OutlinedButton(
                  onPressed: _autoDeparture,
                  child: const Text(
                    'Auto: departure = arrival + nights',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// A date field: the value (or "unset"), a pick
/// button and a clear button.
class _DateField extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              value ?? 'unset',
              style: value == null
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)
                  : theme.textTheme.bodyMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            tooltip: 'Pick a date',
            onPressed: onPick,
          ),
          if (onClear != null)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Clear',
              onPressed: onClear,
            ),
        ],
      ),
    );
  }
}

DateTime? _parseDate(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso);
}

String _iso(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// The transport between two consecutive stops.
/// `legs[i]` sits between `stops[i]` and
/// `stops[i+1]` -- the positional invariant the
/// whole model keeps.
class _LegRow extends StatelessWidget {
  final Variant variant;
  final int legIndex;
  final void Function(int legIndex, String mode) onSetMode;

  const _LegRow({
    required this.variant,
    required this.legIndex,
    required this.onSetMode,
  });

  @override
  Widget build(BuildContext context) {
    final leg = variant.legs[legIndex];
    final from = variant.stops[legIndex].ref;
    final to = variant.stops[legIndex + 1].ref;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.route, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${from.name}  →  ${to.name}',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DropdownButton<String>(
            value: transportModes.contains(leg.mode)
                ? leg.mode
                : 'other',
            underline: const SizedBox(),
            onChanged: (mode) {
              if (mode != null) {
                onSetMode(legIndex, mode);
              }
            },
            items: [
              for (final mode in transportModes)
                DropdownMenuItem(
                  value: mode,
                  child: Text(_modeLabel(mode)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// `itinerary.map.MODE_STYLES`' labels.
  String _modeLabel(String mode) => switch (mode) {
        'flight' => '✈ Flight',
        'train' => '🚆 Train',
        'bus' => '🚌 Bus',
        'car' => '🚗 Car',
        'boat' => '⛴ Boat',
        _ => '• Other',
      };
}

// ── add-stop panel ───────────────────────────────────────────

/// The "➕ Add a stop" panel: workbook
/// destination, custom city (geocoded) or the
/// home gateway, with the stop's role and nights.
class _AddStopPanel extends StatefulWidget {
  final Variant variant;
  final GeocodeRepository geocoder;
  final List<Destination> catalogue;
  final void Function(StopRef ref, String role, int? nights) onAddStop;

  const _AddStopPanel({
    super.key,
    required this.variant,
    required this.geocoder,
    required this.catalogue,
    required this.onAddStop,
  });

  @override
  State<_AddStopPanel> createState() => _AddStopPanelState();
}

class _AddStopPanelState extends State<_AddStopPanel> {
  static const _homeGateway = StopRef(
    kind: 'gateway',
    name: 'Frankfurt',
    country: 'Germany',
    lat: 50.1109,
    lon: 8.6821,
  );

  var _source = 0; // 0 workbook, 1 custom, 2 gateway
  var _role = 'stop';
  var _nights = 0;
  var _destination = '';
  var _query = '';
  List<GeocodeResult> _matches = [];
  var _searching = false;
  var _matchIndex = 0;

  /// Origin/return stops are never slept in, so
  /// offering a nights field for them only created
  /// invisible data the editor cannot show.
  bool get _staysOvernight => _role == 'stop';

  Future<void> _search() async {
    final query = _query.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _matches = [];
      _matchIndex = 0;
    });
    final results = await widget.geocoder.search(query, count: 5);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _matches = results;
    });
  }

  /// The dropdown's value must be one of the
  /// options; a stale selection (the catalogue
  /// changed) falls back to the first name.
  /// The visible selection is the effective
  /// one: the Add button and `_add` use it,
  /// so a displayed destination is always the
  /// one that gets added.
  String get _effectiveDestination {
    final names = [
      for (final dest in widget.catalogue) dest.name,
    ];
    return names.contains(_destination)
        ? _destination
        : (names.isNotEmpty ? names.first : '');
  }

  void _add() {
    switch (_source) {
      case 0: // workbook destination
        final destination = _effectiveDestination;
        if (destination.isEmpty) return;
        widget.onAddStop(
          StopRef(kind: 'destination', name: destination),
          _role,
          _staysOvernight && _nights > 0 ? _nights : null,
        );
      case 1: // custom city
        if (_matches.isEmpty || _matchIndex >= _matches.length) return;
        final match = _matches[_matchIndex];
        widget.onAddStop(
          StopRef(
            kind: 'custom',
            name: match.name,
            country: match.country,
            lat: match.lat,
            lon: match.lon,
          ),
          _role,
          _staysOvernight && _nights > 0 ? _nights : null,
        );
        setState(() {
          _matches = [];
          _query = '';
        });
      default: // home gateway
        widget.onAddStop(_homeGateway, _role,
            _staysOvernight && _nights > 0 ? _nights : null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final destinationNames = [
      for (final dest in widget.catalogue) dest.name,
    ];
    // The dropdown's value must be one of the
    // options; a stale selection (the catalogue
    // changed) falls back to the first name.
    final effectiveDestination = _effectiveDestination;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add a stop', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Source', style: theme.textTheme.labelLarge),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                    value: 0,
                    label: Text('Workbook'),
                    icon: Icon(Icons.book_outlined)),
                ButtonSegment(
                    value: 1,
                    label: Text('Custom city'),
                    icon: Icon(Icons.edit_location_outlined)),
                ButtonSegment(
                    value: 2,
                    label: Text('Home gateway'),
                    icon: Icon(Icons.home_outlined)),
              ],
              selected: {_source},
              onSelectionChanged: (selection) =>
                  setState(() => _source = selection.first),
            ),
            const SizedBox(height: 8),
            Text('Role', style: theme.textTheme.labelLarge),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'stop',
                    label: Text('Stop'),
                    icon: Icon(Icons.place_outlined)),
                ButtonSegment(
                    value: 'origin',
                    label: Text('Origin'),
                    icon: Icon(Icons.north_east)),
                ButtonSegment(
                    value: 'return',
                    label: Text('Return'),
                    icon: Icon(Icons.flag_outlined)),
              ],
              selected: {_role},
              onSelectionChanged: (selection) =>
                  setState(() => _role = selection.first),
            ),
            const SizedBox(height: 8),
            if (_staysOvernight)
              Row(
                children: [
                  Text('Nights', style: theme.textTheme.labelLarge),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) =>
                          _nights = int.tryParse(value) ?? 0,
                    ),
                  ),
                ],
              )
            else
              Text('No nights for an origin or return stop.',
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_source == 0) ...[
            if (destinationNames.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No destinations available.'),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: effectiveDestination,
                decoration: const InputDecoration(
                  labelText: 'Destination',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final name in destinationNames)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) =>
                    setState(() => _destination = value ?? ''),
              ),
            ] else if (_source == 1) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: 'City name',
                        hintText: 'e.g. Chengdu',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => _query = value,
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _searching ? null : _search,
                    child: const Text('Search'),
                  ),
                ],
              ),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              if (!_searching && _query.trim().isNotEmpty && _matches.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No geocode match — check spelling or add '
                      'the city to the workbook first.'),
                ),
              if (_matches.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (var i = 0; i < _matches.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _matchIndex == i
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(_matchLabel(_matches[i])),
                    onTap: () => setState(() => _matchIndex = i),
                  ),
              ],
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${_homeGateway.name}, ${_homeGateway.country}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _source == 0
                  ? _effectiveDestination.isEmpty
                      ? null
                      : _add
                  : _source == 1
                      ? _matches.isEmpty
                          ? null
                          : _add
                      : _add,
              child: const Text('Add stop'),
            ),
          ],
        ),
      ),
    );
  }

  String _matchLabel(GeocodeResult match) => [
        match.name,
        if (match.admin1 != null && match.admin1!.isNotEmpty)
          match.admin1,
        if (match.country != null && match.country!.isNotEmpty)
          match.country,
      ].join(' · ');
}

// ── side column: summary, meta, warnings, export ─────────────

class _SideColumn extends StatelessWidget {
  final Trip trip;
  final Variant variant;
  final List<Destination> catalogue;
  final void Function(Variant updated) onUpdateVariant;
  final VoidCallback onExport;

  const _SideColumn({
    required this.trip,
    required this.variant,
    required this.catalogue,
    required this.onUpdateVariant,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final t = totals(variant);
    final warnings = warningsFor(variant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Route summary',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            _Metric(label: 'Stops', value: '${t.stops}'),
            const SizedBox(width: 12),
            _Metric(label: 'Nights', value: '${t.nights}'),
            const SizedBox(width: 12),
            _Metric(
                label: 'Rating',
                value: variant.rating?.toString() ?? '—'),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          t.start != null
              ? '${t.start} → ${t.end}'
              : 'no dates set',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          [
            if (t.flights > 0)
              '${t.flights} flight${t.flights == 1 ? '' : 's'}',
            if (t.trains > 0)
              '${t.trains} train${t.trains == 1 ? '' : 's'}',
            if (t.other > 0)
              '${t.other} other leg${t.other == 1 ? '' : 's'}',
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (variant.comment.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(variant.comment,
              style: Theme.of(context).textTheme.bodyMedium),
        ],
        const SizedBox(height: 16),
        _VariantMetaPanel(
          key: ValueKey(variant.id),
          variant: variant,
          catalogue: catalogue,
          onUpdate: onUpdateVariant,
        ),
        const SizedBox(height: 16),
        Text('Check results',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (warnings.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(Icons.check_circle_outline, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('All good — route is consistent.')),
            ]),
          )
        else
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_outlined, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(warning)),
                ],
              ),
            ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onExport,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Export trip (JSON)'),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: theme.textTheme.headlineSmall),
        Text(label, style: theme.textTheme.labelMedium),
      ],
    );
  }
}

/// The variant meta editor (E5): rating, the
/// months multiselect pre-filled with the
/// workbook suggestion, comment and notes.
class _VariantMetaPanel extends StatefulWidget {
  final Variant variant;
  final List<Destination> catalogue;
  final void Function(Variant updated) onUpdate;

  const _VariantMetaPanel({
    super.key,
    required this.variant,
    required this.catalogue,
    required this.onUpdate,
  });

  @override
  State<_VariantMetaPanel> createState() => _VariantMetaPanelState();
}

class _VariantMetaPanelState extends State<_VariantMetaPanel> {
  late String? _rating;
  late Set<String> _months;
  late final TextEditingController _comment;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    _rating = widget.variant.rating?.toString();
    // The multiselect's default: the stored
    // months, else the workbook suggestion for
    // the whole route -- the legacy's
    // `default=stored_months or
    // _trip_wide_suggestion(...)`. Saving
    // persists whatever is displayed.
    _months = widget.variant.months.isNotEmpty
        ? widget.variant.months.toSet()
        : tripWideSuggestion(
            suggestedMonths(widget.variant, widget.catalogue),
          ).toSet();
    _comment = TextEditingController(text: widget.variant.comment);
    _notes = TextEditingController(text: widget.variant.notes);
  }

  @override
  void dispose() {
    _comment.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    widget.onUpdate(
      updateMeta(
        widget.variant,
        notes: _notes.text,
        rating: _rating == null ? null : int.tryParse(_rating!),
        months: [
          for (final month in months)
            if (_months.contains(month)) month,
        ],
        comment: _comment.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions =
        suggestedMonths(widget.variant, widget.catalogue);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rating, months & notes',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _rating,
              decoration: const InputDecoration(
                labelText: 'Rating (1-10)',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('—')),
                for (var rating = 1; rating <= 10; rating++)
                  DropdownMenuItem(
                      value: '$rating', child: Text('$rating')),
              ],
              onChanged: (value) =>
                  setState(() => _rating = value),
            ),
            const SizedBox(height: 12),
            Text('Best travel months',
                style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                for (final month in months)
                  FilterChip(
                    label: Text(month.substring(0, 3)),
                    selected: _months.contains(month),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _months.add(month);
                      } else {
                        _months.remove(month);
                      }
                    }),
                  ),
              ],
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Workbook says good: ${suggestions.entries.map((entry) => '${entry.key}: ${entry.value.map((m) => m.substring(0, 3)).join(', ')}').join(' · ')}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _comment,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Comment',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Variant notes',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}
