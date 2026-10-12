/// The weekend finder: Fri→Mon possibilities from FRA.
///
/// The Flutter port of `pages/weekend_finder.py`. The
/// flight source is decided at runtime and shown in the
/// "Flight data source" card: the live Fraport board is
/// the primary source, and a pasted CSV (departures and
/// arrivals) is the escape hatch that overrides it — an
/// explicit CSV always wins, so the finder stays usable
/// with no network or when the board changes under us.
/// The rules and the data flow are the legacy ones: the
/// six time bounds narrow five board queries, the
/// matcher requires both legs, and the report explains
/// what it dropped and why -- an empty answer is never
/// ambiguous.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter;

import '../data/benefits_repository.dart';
import '../data/catalogue_match.dart';
import '../data/destination_repository.dart';
import '../data/weekend_repository.dart';
import '../models/airline_benefits.dart';
import '../models/destination.dart';
import '../models/timetable.dart';
import '../models/weekend_match.dart';
import 'destination_page.dart';

/// The working example the legacy shows next to the
/// upload: a Friday out and a Monday back, in the
/// canonical column spelling.
const csvTemplate = '''flight_no,airline,origin,destination,departure,arrival
LH1000,Lufthansa,FRA,BCN,09.10.2026 15:05,09.10.2026 17:05
LH1002,Lufthansa,BCN,FRA,11.10.2026 16:40,11.10.2026 18:35
''';

class WeekendFinderPage extends StatefulWidget {
  final BenefitsRepository benefits;
  final DestinationRepository destinations;

  /// The flight board the finder queries. The app passes
  /// nothing (the live Fraport board); tests inject a fake
  /// so a search runs without network.
  final FlightBoardProvider? board;

  const WeekendFinderPage({
    super.key,
    required this.benefits,
    required this.destinations,
    this.board,
  });

  @override
  State<WeekendFinderPage> createState() => _WeekendFinderPageState();
}

class _WeekendFinderPageState extends State<WeekendFinderPage> {
  late final FlightBoardProvider _liveBoard =
      widget.board ?? FraportBoardProvider(throttleSeconds: 1.5);
  BenefitSource _benefits = (
    flags: <String, bool>{},
    records: <AirlineRecord>[],
    sourceLabel: 'loading…',
    problems: const <String>[],
  );
  var _loadingBenefits = true;

  Weekend _weekend = Weekend(DateTime.now());
  Windows _windows = const Windows();
  var _catalogueFirst = true;

  /// The CSV override: either field non-empty wins over
  /// the live board (the weekend-finder plan's decision
  /// 1 — live board for the upcoming weekend, CSV as the
  /// override and the no-network fallback).
  final TextEditingController _departuresCsv =
      TextEditingController();
  final TextEditingController _arrivalsCsv =
      TextEditingController();

  /// The flight filters: benefit-only matching (on = the
  /// legacy behaviour) and the longest leg the user accepts.
  var _benefitsOnly = true;
  final TextEditingController _maxLegHours =
      TextEditingController(text: '6');

  WeekendSearch? _result;
  List<Destination> _catalogue = const <Destination>[];
  var _searching = false;

  /// Which result rows are expanded (keyed city|country),
  /// and the expand-all flag behind the header button.
  final _expandedCities = <String>{};
  var _allExpanded = false;
  @override
  void initState() {
    super.initState();
    _weekend = weekendContaining(DateTime.now());
    _loadBenefits();
    _loadCatalogue();
  }

  @override
  void dispose() {
    _departuresCsv.dispose();
    _arrivalsCsv.dispose();
    _maxLegHours.dispose();
    super.dispose();
  }

  Future<void> _loadBenefits() async {
    final benefits = await widget.benefits.loadFlags();
    if (!mounted) return;
    setState(() {
      _benefits = benefits;
      _loadingBenefits = false;
    });
  }

  Future<void> _loadCatalogue() async {
    await CountryNames.ensureLoaded();
    final (destinations, _) = await widget.destinations.loadDestinations();
    if (!mounted) return;
    setState(() => _catalogue = destinations);
  }

  /// The provider the search runs on: an explicit CSV
  /// always wins over the live board.
  FlightBoardProvider _activeProvider() {
    if (_departuresCsv.text.trim().isNotEmpty ||
        _arrivalsCsv.text.trim().isNotEmpty) {
      return CsvBoardProvider(
        departuresCsv: _departuresCsv.text,
        arrivalsCsv: _arrivalsCsv.text,
      );
    }
    return _liveBoard;
  }

  Future<void> _find() async {
    setState(() {
      _searching = true;
      _result = null;
    });
    final repository = WeekendRepository(_activeProvider());
    final hours = double.tryParse(_maxLegHours.text.trim());
    try {
      final search = await repository.search(
        _weekend,
        _windows,
        _benefits,
        options: WeekendSearchOptions(
          benefitsOnly: _benefitsOnly,
          maxLegDuration:
              hours == null ? null : Duration(minutes: (hours * 60).round()),
        ),
      );
      if (!mounted) return;
      setState(() {
        _result = search;
        _searching = false;
      });
    } catch (error) {
      // The provider errors surface as notes inside the
      // result; this is for anything else, so a failure
      // never leaves the spinner up forever.
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('The search failed: $error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Weekend Finder')),
      body: _searching
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(_activeProvider() is CsvBoardProvider
                      ? 'Matching flights…'
                      : 'Querying the flight board…'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _weekendCard(),
                const SizedBox(height: 12),
                _windowsCard(),
                const SizedBox(height: 12),
                _sourceCard(),
                const SizedBox(height: 12),
                _benefitsCard(),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.travel_explore_outlined),
                  label: const Text('Find weekends'),
                  onPressed: _loadingBenefits ? null : _find,
                ),
                if (result != null) ...[
                  const SizedBox(height: 16),
                  _report(result),
                ],
              ],
            ),
    );
  }

  Widget _weekendCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Weekend', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text('This weekend '
                      '(${_isoShort(weekendContaining(DateTime.now()).friday)})'),
                  selected: _isSameWeekend(weekendContaining(DateTime.now())),
                  onSelected: (_) => setState(
                      () => _weekend = weekendContaining(DateTime.now())),
                ),
                ChoiceChip(
                  label: Text(
                      'Next weekend (${_isoShort(_nextWeekend().friday)})'),
                  selected: _isSameWeekend(_nextWeekend()),
                  onSelected: (_) =>
                      setState(() => _weekend = _nextWeekend()),
                ),
                ActionChip(
                  avatar: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text('Fri ${_isoShort(_weekend.friday)}'),
                  onPressed: _pickFriday,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _isSameWeekend(Weekend other) =>
      other.friday.year == _weekend.friday.year &&
      other.friday.month == _weekend.friday.month &&
      other.friday.day == _weekend.friday.day;

  Weekend _nextWeekend() =>
      Weekend(nextFriday(DateTime.now(), minimumDaysAhead: 7));

  Future<void> _pickFriday() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _weekend.friday,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 120)),
      helpText: 'Pick the Friday',
    );
    if (picked == null) return;
    setState(() {
      var friday = picked;
      while (friday.weekday != 5) {
        friday = friday.add(const Duration(days: 1));
      }
      _weekend = Weekend(friday);
    });
  }

  Widget _windowsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Windows', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(_windows.describe(),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Text('Out on', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _dayRule(
                  day: 'Thu',
                  enabled: _windows.thursdayFrom != null,
                  boundLabel: _windows.thursdayFrom == null
                      ? ''
                      : 'from ${_hm(_windows.thursdayFrom!)}',
                  onToggle: (on) => setState(() => _windows = _windowsWith(
                      thursdayFrom: on ? 14 * 60 : null,
                      clearThursday: !on)),
                  onEditTime: _windows.thursdayFrom == null
                      ? null
                      : () => _pickBound(
                          'Thursday departure from', _windows.thursdayFrom!,
                          (value) => setState(() => _windows =
                              _windowsWith(thursdayFrom: value))),
                ),
                _dayRule(
                  day: 'Fri',
                  enabled: _windows.fridayFrom != null,
                  boundLabel: _windows.fridayFrom == null
                      ? ''
                      : 'from ${_hm(_windows.fridayFrom!)}',
                  onToggle: (on) => setState(() => _windows = _windowsWith(
                      fridayFrom: on ? 14 * 60 : null)),
                  onEditTime: _windows.fridayFrom == null
                      ? null
                      : () => _pickBound('Friday departure from',
                          _windows.fridayFrom!,
                          (value) => setState(() =>
                              _windows = _windowsWith(fridayFrom: value))),
                ),
                _dayRule(
                  day: 'Sat',
                  enabled: _windows.saturdayBefore != null,
                  boundLabel: _windows.saturdayBefore == null
                      ? ''
                      : 'before ${_hm(_windows.saturdayBefore!)}',
                  onToggle: (on) => setState(() => _windows = _windowsWith(
                      saturdayBefore: on ? 12 * 60 : null)),
                  onEditTime: _windows.saturdayBefore == null
                      ? null
                      : () => _pickBound(
                          'Saturday departure before', _windows.saturdayBefore!,
                          (value) => setState(() => _windows =
                              _windowsWith(saturdayBefore: value))),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Back on', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _dayRule(
                  day: 'Sat',
                  enabled: _windows.saturdayReturnAfter != null,
                  boundLabel: _windows.saturdayReturnAfter == null
                      ? ''
                      : 'after ${_hm(_windows.saturdayReturnAfter!)}',
                  onToggle: (on) => setState(() => _windows = _windowsWith(
                      saturdayReturnAfter: on ? 12 * 60 : null)),
                  onEditTime: _windows.saturdayReturnAfter == null
                      ? null
                      : () => _pickBound('Saturday return after',
                          _windows.saturdayReturnAfter!,
                          (value) => setState(() => _windows =
                              _windowsWith(saturdayReturnAfter: value))),
                ),
                _dayRule(
                  day: 'Sun',
                  enabled: _windows.sundayEnabled,
                  boundLabel: 'any time',
                  onToggle: (on) => setState(
                      () => _windows = _windowsWith(sundayEnabled: on)),
                  onEditTime: null,
                ),
                _dayRule(
                  day: 'Mon',
                  enabled: _windows.mondayReturnBefore != null,
                  boundLabel: _windows.mondayReturnBefore == null
                      ? ''
                      : 'before ${_hm(_windows.mondayReturnBefore!)}',
                  onToggle: (on) => setState(() => _windows = _windowsWith(
                      mondayReturnBefore: on ? 9 * 60 : null)),
                  onEditTime: _windows.mondayReturnBefore == null
                      ? null
                      : () => _pickBound('Monday return before',
                          _windows.mondayReturnBefore!,
                          (value) => setState(() => _windows =
                              _windowsWith(mondayReturnBefore: value))),
                ),
                _dayRule(
                  day: 'Tue',
                  enabled: _windows.tuesdayReturnBefore != null,
                  boundLabel: _windows.tuesdayReturnBefore == null
                      ? ''
                      : 'before ${_hm(_windows.tuesdayReturnBefore!)}',
                  onToggle: (on) => setState(() => _windows = _windowsWith(
                      tuesdayReturnBefore: on ? 9 * 60 : null,
                      clearTuesday: !on)),
                  onEditTime: _windows.tuesdayReturnBefore == null
                      ? null
                      : () => _pickBound(
                          'Tuesday return before', _windows.tuesdayReturnBefore!,
                          (value) => setState(() => _windows =
                              _windowsWith(tuesdayReturnBefore: value))),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Thursday out and Tuesday back are the '
              'holiday-bridge days — switch them on when a '
              'public holiday extends the weekend.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// One out/back day: the toggle chip (on/off) plus, when
  /// enabled, the time bound it opens a picker for. Sunday
  /// has no bound ("any time").
  Widget _dayRule({
    required String day,
    required bool enabled,
    required String boundLabel,
    required ValueChanged<bool> onToggle,
    VoidCallback? onEditTime,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilterChip(
          label: Text(day),
          selected: enabled,
          onSelected: onToggle,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        if (enabled && onEditTime != null) ...[
          const SizedBox(width: 4),
          ActionChip(
            label: Text(boundLabel,
                style: Theme.of(context).textTheme.labelSmall),
            onPressed: onEditTime,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ] else if (enabled) ...[
          const SizedBox(width: 4),
          Text(boundLabel, style: Theme.of(context).textTheme.labelSmall),
        ],
      ],
    );
  }

  Future<void> _pickBound(
      String field, int currentMinutes, ValueChanged<int> onChanged) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: currentMinutes ~/ 60, minute: currentMinutes % 60),
      helpText: field,
    );
    if (picked == null) return;
    onChanged(picked.hour * 60 + picked.minute);
  }

  /// A new Windows with the given bounds changed; the
  /// clear flags exist because the default-keep pattern
  /// cannot express "turn Thursday off".
  Windows _windowsWith({
    int? thursdayFrom,
    bool clearThursday = false,
    int? fridayFrom,
    int? saturdayBefore,
    int? saturdayReturnAfter,
    bool? sundayEnabled,
    int? mondayReturnBefore,
    int? tuesdayReturnBefore,
    bool clearTuesday = false,
  }) =>
      Windows(
        thursdayFrom:
            clearThursday ? null : (thursdayFrom ?? _windows.thursdayFrom),
        fridayFrom: fridayFrom ?? _windows.fridayFrom,
        saturdayBefore: saturdayBefore ?? _windows.saturdayBefore,
        saturdayReturnAfter:
            saturdayReturnAfter ?? _windows.saturdayReturnAfter,
        sundayEnabled: sundayEnabled ?? _windows.sundayEnabled,
        mondayReturnBefore:
            mondayReturnBefore ?? _windows.mondayReturnBefore,
        tuesdayReturnBefore: clearTuesday
            ? null
            : (tuesdayReturnBefore ?? _windows.tuesdayReturnBefore),
      );

  /// The flight source, as the legacy's "Flight data
  /// source" expander: the live board is the primary
  /// source, and a pasted CSV is the escape hatch that
  /// overrides it. The legacy's file upload becomes two
  /// paste fields here — the same CSV text, the same
  /// override semantics, and no file-picker plugin
  /// (the app stays plugin-free; see G4).
  ///
  /// The legacy's "data sources that are not available"
  /// expander has nothing to list: the Dart port has
  /// exactly one live provider and it is always
  /// available, so the expander would always be empty.
  Widget _sourceCard() {
    final theme = Theme.of(context);
    final overrideActive =
        _departuresCsv.text.trim().isNotEmpty ||
            _arrivalsCsv.text.trim().isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Flight data source',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              _benefitsOnly
                  ? 'Only airlines you have marked as having '
                      'benefits count. Source: Fraport'
                      '${overrideActive ? '' : ' — paste CSV below to override it.'}'
                  : 'Every airline on the board counts; the '
                      'benefit airlines are still named per option. '
                      'Source: Fraport'
                      '${overrideActive ? '' : ' — paste CSV below to override it.'}',
              style: theme.textTheme.bodySmall,
            ),
            SwitchListTile(
              title: const Text('Only airlines with benefits'),
              subtitle: const Text(
                  'Off: all airlines count, not only the ones '
                  'marked in the benefits database.'),
              value: _benefitsOnly,
              onChanged: (value) =>
                  setState(() => _benefitsOnly = value),
              contentPadding: EdgeInsets.zero,
            ),
            Row(
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _maxLegHours,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'^\d{0,2}(\.\d{0,1})?$')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Max flight time',
                      suffixText: 'h / leg',
                      helperText: '6 = the default cap',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Flights longer than this produce no '
                    'options, on either leg.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (overrideActive) ...[
              const SizedBox(height: 4),
              Text(
                'CSV override active — the live board '
                'is not queried.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
            const SizedBox(height: 8),
            ExpansionTile(
              title: Text(
                overrideActive
                    ? 'CSV override (active)'
                    : 'CSV override (optional)',
                style: theme.textTheme.bodyMedium,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Two files, or leave one empty. '
                        'Columns: flight_no, airline, '
                        'origin, destination, departure, '
                        'arrival — operated_by is used '
                        'when present, because benefits '
                        'follow the operating carrier. '
                        'Times may be 15:05 or '
                        '09.10.2026 15:05.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _departuresCsv,
                        maxLines: 4,
                        minLines: 2,
                        decoration: const InputDecoration(
                          labelText:
                              'Departures from FRA (CSV)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _arrivalsCsv,
                        maxLines: 4,
                        minLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Arrivals into FRA (CSV)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ExpansionTile(
                        title: Text('CSV template',
                            style: theme.textTheme.bodySmall),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                16, 0, 16, 12),
                            child: SelectableText(
                              csvTemplate,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(
                                      fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _benefitsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Airlines with benefits',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                // The legacy's re-read: the Dart side
                // holds no cache, so a re-read is a
                // fresh fetch of the same query.
                if (!_loadingBenefits)
                  IconButton(
                    icon: const Icon(Icons.refresh_outlined, size: 20),
                    tooltip: 'Re-read the benefits database',
                    onPressed: _loadBenefits,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (_loadingBenefits)
              const Text('Reading the benefits database…')
            else
              Text(
                benefitSummary(
                    _benefits.flags, _benefits.records, _benefits.sourceLabel,
                    _benefits.problems),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget _report(WeekendSearch search) {
    final report = search.report;
    final theme = Theme.of(context);
    final unmatched = _unmatchedCarriers(report, search.benefits.flags);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Weekend ${report.weekend.describe()} · ${report.outboundTotal} '
          'outbound, ${report.returnTotal} return flights read',
          style: theme.textTheme.bodySmall,
        ),
        for (final note in report.notes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_outlined,
                    size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(child: Text(note, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
        if (describeRule(report.outboundRejectedAirlines).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(describeRule(report.outboundRejectedAirlines),
                style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        if (report.cityCount == 0)
          _emptyState(report)
        else
          _cityList(report),
        if (report.oneWayOnly.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('One leg only (${report.oneWayOnly.length})',
                      style: theme.textTheme.titleSmall),
                  Text(
                    'A qualifying outbound or return, but not both. Useful '
                    'if you would travel another way for one of the legs.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (final city in report.oneWayOnly)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${city.label} (${city.airports.toList()..sort()})',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (unmatched.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Airlines in the data with no benefit flag',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(unmatched.join(', '),
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        SwitchListTile(
          title: const Text('Catalogue destinations first'),
          value: _catalogueFirst,
          onChanged: (value) => setState(() => _catalogueFirst = value),
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget _emptyState(MatchReport report) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          report.notes.isEmpty
              ? 'No city has both a qualifying outbound and a qualifying '
                  'return in this weekend with your windows.'
              : 'No city has both a qualifying outbound and a qualifying '
                  'return in this weekend with your windows — see the notes '
                  'above for what failed.',
        ),
      ),
    );
  }

  Widget _cityList(MatchReport report) {
    final theme = Theme.of(context);
    final index = CatalogueIndex(_catalogue);
    final cities = [...report.cities];
    if (_catalogueFirst) {
      cities.sort((a, b) {
        final aIn = index.match(a.city, a.country) != null;
        final bIn = index.match(b.city, b.country) != null;
        if (aIn != bIn) return aIn ? -1 : 1;
        return a.city.compareTo(b.city);
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('${report.cityCount} destinations',
                  style: theme.textTheme.titleMedium),
            ),
            if (cities.isNotEmpty)
              TextButton(
                onPressed: () => setState(() {
                  if (_allExpanded) {
                    _expandedCities.clear();
                  } else {
                    _expandedCities.addAll(
                        cities.map((city) => '${city.city}|${city.country}'));
                  }
                  _allExpanded = !_allExpanded;
                }),
                child: Text(_allExpanded ? 'Collapse all' : 'Expand all'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Tap a destination to see its flights.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        for (final city in cities)
          _cityRow(city, index.match(city.city, city.country)),
      ],
    );
  }

  /// One result: the summary line (city, options, earliest
  /// out, nights, airlines) that expands in place into the
  /// flight detail. The summary used to be a table *above*
  /// the detail cards, so finding a city's flights meant
  /// scanning the list twice.
  Widget _cityRow(CityResult city, String? catalogueName) {
    final theme = Theme.of(context);
    final key = '${city.city}|${city.country}';
    final expanded = _expandedCities.contains(key);
    final first = city.options.first;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() {
              if (expanded) {
                _expandedCities.remove(key);
              } else {
                _expandedCities.add(key);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(city.label,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          '${city.count} option${city.count == 1 ? '' : 's'} · '
                          'earliest out ${_stamp(first.outFlight.departure)} · '
                          '${first.nights} night${first.nights == 1 ? '' : 's'}',
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _airlineList(city.options),
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (catalogueName != null)
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      tooltip: 'Open $catalogueName',
                      onPressed: () => _openDestination(catalogueName),
                    ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  if (catalogueName != null)
                    Text('in your catalogue as $catalogueName',
                        style: theme.textTheme.bodySmall),
                  Text(
                    '${city.airports.toList()..sort()}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (city.unmappedAirports.isNotEmpty)
                    Text(
                      '${city.unmappedAirports.toList()..sort()} could not be '
                      'mapped to a city — the label is the raw airport code.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  const SizedBox(height: 8),
                  for (final option in city.options) _optionTile(option),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The distinct operating carriers across a city's
  /// options, both legs, sorted — the summary line's
  /// "Airlines" part.
  static String _airlineList(List<TripOption> options) {
    final airlines = <String>{
      for (final option in options) ...[
        option.outFlight.operatorAirline,
        option.backFlight.operatorAirline,
      ],
    }.toList()
      ..sort();
    return airlines.join(', ');
  }

  /// Opens a result city's destination page. The results
  /// live in this widget's state and the page is pushed as
  /// a route, so popping back returns to the intact list —
  /// the search never has to run again.
  void _openDestination(String catalogueName) {
    Destination? match;
    for (final destination in _catalogue) {
      if (destination.name == catalogueName) {
        match = destination;
        break;
      }
    }
    if (match == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DestinationPage(
        repository: widget.destinations,
        destination: match!,
      ),
    ));
  }

  Widget _optionTile(TripOption option) {
    final out = option.outFlight;
    final back = option.backFlight;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Out', style: theme.textTheme.labelSmall),
                Text('${out.flightNo} · ${out.operatorAirline}',
                    style: theme.textTheme.bodyMedium),
                if (out.marketingAirline.isNotEmpty &&
                    out.marketingAirline != out.operatorAirline)
                  Text('marketed as ${out.marketingAirline}',
                      style: theme.textTheme.bodySmall),
                Text(
                    '${_stamp(out.departure)} → ${_stamp(out.arrival)}'
                    '${out.terminal.isEmpty ? '' : ' · T${out.terminal}'}',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Back', style: theme.textTheme.labelSmall),
                Text('${back.flightNo} · ${back.operatorAirline}',
                    style: theme.textTheme.bodyMedium),
                Text('${_stamp(back.departure)} → ${_stamp(back.arrival)}',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Chip(
            label: Text('${option.nights}n'),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  List<String> _unmatchedCarriers(MatchReport report, Map<String, bool> flags) {
    final names = <String>[];
    for (final city in [...report.cities, ...report.oneWayOnly]) {
      for (final flight in [...city.outOnly, ...city.backOnly]) {
        final name = flight.operatorAirline;
        if (name.isNotEmpty && !names.contains(name)) names.add(name);
      }
    }
    return unmatchedAirlines(names, flags);
  }

  static String _hm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  static String _stamp(DateTime moment) =>
      '${_weekdayName(moment.weekday)} ${moment.hour.toString().padLeft(2, '0')}:'
      '${moment.minute.toString().padLeft(2, '0')}';

  static String _weekdayName(int weekday) => const [
        'Mon',
        'Tue',
        'Wed',
        'Thu',
        'Fri',
        'Sat',
        'Sun',
      ][weekday - 1];

  static String _isoShort(DateTime day) =>
      '${day.day.toString().padLeft(2, '0')}.'
      '${day.month.toString().padLeft(2, '0')}.';
}
