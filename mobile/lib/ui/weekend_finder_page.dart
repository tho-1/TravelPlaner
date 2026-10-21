/// The weekend finder: free-form travel days from FRA.
///
/// The Flutter port of `pages/weekend_finder.py`, with the
/// day model the user asked for (report b, 2026-10-16): a
/// travel *period* on the calendar populates candidate days
/// (the period plus the day before and after), each side
/// ("out on"/"back on") selects its days freely, and every
/// selected day carries its own any/after/before time bound.
/// The rules and the data flow stay the legacy ones: the
/// bounds narrow the board queries, the matcher requires
/// both legs, and the report explains what it dropped and
/// why -- an empty answer is never ambiguous. The Fraport
/// board is the only flight source (the CSV override is
/// gone, report c).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter;

import '../data/benefits_repository.dart';
import '../data/catalogue_match.dart';
import '../data/destination_repository.dart';
import '../data/flight_board_cache.dart';
import '../data/error_log.dart';
import '../data/flight_routes_schedule_repository.dart';
import '../data/flight_routes_schedule_writer.dart';
import '../data/weekend_repository.dart';
import '../models/airline_benefits.dart';
import '../models/destination.dart';
import '../models/timetable.dart';
import '../models/travel_days.dart';
import '../models/weekend_match.dart';
import 'destination_page.dart';

class WeekendFinderPage extends StatefulWidget {
  final BenefitsRepository benefits;
  final DestinationRepository destinations;

  /// The flight board the finder queries. The app passes
  /// nothing (the live Fraport board); tests inject a fake
  /// so a search runs without network.
  final FlightBoardProvider? board;

  /// The optional fallback source (report j), consulted
  /// only about board windows that failed or look
  /// incomplete. Null when no key is configured.
  final FlightBoardProvider? fallback;

  /// Where the per-device board cache lives. Empty means no
  /// cache: the credentialed fallback is then asked every
  /// time (which is why the app wires a real directory here).
  final String cacheDir;

  /// The clock the presets and the period picker work from.
  /// A test seam: the DST weekend is the case where the day
  /// arithmetic has to be right, and it cannot be reached
  /// by waiting for the calendar.
  final DateTime Function()? now;

  /// Called when a result opens a destination page, so the
  /// shell records the open-destination tab. Null when the
  /// feature is off.
  final void Function(String name)? onOpenDestination;
  final bool Function(String name)? isInOpenTabs;
  final void Function(String name)? onAddToOpenTabs;

  const WeekendFinderPage({
    super.key,
    required this.benefits,
    required this.destinations,
    this.board,
    this.fallback,
    this.cacheDir = '',
    this.now,
    this.onOpenDestination,
    this.isInOpenTabs,
    this.onAddToOpenTabs,
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

  /// The travel period and the days selected per side. A
  /// day is selected exactly when it has a rule entry; the
  /// entry also carries its any/after/before bound.
  late TravelPeriod _period = weekendPeriod(fridayOf(_now()));
  final Map<DateTime, TravelDay> _outRules = {};
  final Map<DateTime, TravelDay> _backRules = {};

  /// The last rule each day carried, so a day that is
  /// deselected and selected again comes back with its bound
  /// instead of "any time" (the user's rule is not silently
  /// reset -- the report, 2026-10-21).
  final Map<DateTime, TravelDay> _rememberedRules = {};

  /// The clock the presets work from.
  late final DateTime Function() _now = widget.now ?? DateTime.now;

  /// Which preset (or "custom") produced the current
  /// selection -- the chips show it as selected.
  String _preset = 'this';

  /// The airline filter (report d) and the stay-length
  /// floor (report e, clarified 2026-10-16: a *visible*
  /// control, default "at least 1 night").
  AirlineScope _airlineScope = AirlineScope.lufthansaGroup;
  var _minNights = 1;

  /// Whether catalogue destinations are grouped first in
  /// the result list.
  var _catalogueFirst = true;

  final TextEditingController _maxLegHours =
      TextEditingController(text: '6');

  WeekendSearch? _result;
  List<Destination> _catalogue = const <Destination>[];
  var _searching = false;

  /// Which result rows are expanded (keyed city|country),
  /// and the expand-all flag behind the header button.
  final _expandedCities = <String>{};
  var _allExpanded = false;

  /// Attached to the results block: after a search
  /// completes, the page scrolls itself to the results —
  /// the input cards above stay up, but the answer should
  /// come to you.
  final _resultsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _applyPreset('this');
    _loadBenefits();
    _loadCatalogue();
  }

  @override
  void dispose() {
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

  /// The plan the search runs with, built from the selected
  /// days.
  TravelPlan _plan() => TravelPlan(
        outDays: _outRules.values.toList()
          ..sort((a, b) => a.compareTo(b)),
        backDays: _backRules.values.toList()
          ..sort((a, b) => a.compareTo(b)),
        label: _period.describe(),
      );

  /// The day selection changed: the results on screen belong to
  /// the *old* selection, and a reader who deselects a day
  /// must not still see it in the results (the report,
  /// 2026-10-21). So the search runs again.
  ///
  /// Fraport is free and unlimited, so a repeated search
  /// costs nothing there; the credentialed fallbacks are
  /// asked only about windows we do not already have (the
  /// local and Turso caches), so a repeated search does not
  /// burn their budget either.
  void _selectionChanged() {
    if (_result == null) return; // nothing on screen to be stale
    if (_outRules.isEmpty || _backRules.isEmpty) return; // not searchable
    _find();
  }

  Future<void> _find() async {
    if (_outRules.isEmpty || _backRules.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Select at least one out day and one back day.'),
      ));
      return;
    }
    setState(() {
      _searching = true;
      _result = null;
    });
    final sharedSchedules = widget.board == null
        ? await FlightRoutesScheduleRepository.fromAssets()
        : null;
    final repository = WeekendRepository(
      _liveBoard,
      fallback: widget.fallback,
      // The credentialed fallback's answers are cached on the
      // device, so a repeated search (the user changed a day)
      // does not spend its quota again (2026-10-21).
      fallbackCache:
          FlightBoardCache(widget.cacheDir.isEmpty ? '' : widget.cacheDir),
      sharedSchedules: sharedSchedules,
      // The write side shares the reader's client: one
      // configured endpoint, one token, both directions.
      sharedBoardWriter: sharedSchedules == null
          ? null
          : FlightRoutesScheduleWriter(sharedSchedules.client),
    );
    final hours = double.tryParse(_maxLegHours.text.trim());
    try {
      final search = await repository.search(
        _plan(),
        _benefits,
        options: WeekendSearchOptions(
          airlineScope: _airlineScope,
          maxLegDuration:
              hours == null ? null : Duration(minutes: (hours * 60).round()),
          minNights: _minNights,
        ),
      );
      if (!mounted) return;
      setState(() {
        _result = search;
        _searching = false;
      });
      // Bring the results into view: the input cards above
      // stay mounted, so without this the answer sits below
      // the fold.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _resultsKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 450),
            alignment: 0.02,
          );
        }
      });
    } catch (error) {
      // The provider errors surface as notes inside the
      // result; this is for anything else, so a failure
      // never leaves the spinner up forever. It is logged
      // too -- that is what the error log is for (report f).
      if (!mounted) return;
      setState(() => _searching = false);
      ErrorLog.instance
          .record('weekend-finder', 'search failed: $error');
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
      // The list stays mounted during a search: swapping it
      // for a spinner used to reset the scroll position, so
      // after every search you landed back at the top and
      // had to scroll past all the input cards again.
      body: Stack(
        children: [
          ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _periodCard(),
                const SizedBox(height: 12),
                _daysCard(),
                const SizedBox(height: 12),
                _sourceCard(),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.travel_explore_outlined),
                  label: const Text('Find weekends'),
                  onPressed: (_loadingBenefits ||
                          _outRules.isEmpty ||
                          _backRules.isEmpty)
                      ? null
                      : _find,
                ),
                if (result != null) ...[
                  const SizedBox(height: 16),
                  KeyedSubtree(key: _resultsKey, child: _report(result)),
                ],
              ],
            ),
          if (_searching)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.72),
                child: AbsorbPointer(
                  absorbing: true,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        const Text('Querying the flight board…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The travel period: two presets and the calendar
  /// range picker (report b). The period decides which
  /// days the two pickers below offer.
  Widget _periodCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Travel period', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(_period.describe(), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text('This weekend '
                      '(${_isoShort(weekendPeriod(fridayOf(_now())).start)})'),
                  selected: _preset == 'this',
                  onSelected: (_) => setState(() => _applyPreset('this')),
                ),
                ChoiceChip(
                  label: Text('Next weekend '
                      '(${_isoShort(weekendPeriod(addCalendarDays(fridayOf(_now()), 7)).start)})'),
                  selected: _preset == 'next',
                  onSelected: (_) => setState(() => _applyPreset('next')),
                ),
                ActionChip(
                  avatar: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text(_period.describe()),
                  onPressed: _pickPeriod,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The pickers below offer every day of the period, plus the '
              'day before and the day after (the flex days).',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// "This"/"next weekend" preselect the legacy rules (out
  /// Fri from 14:00 or Sat before 12:00, back Sun any time
  /// or Mon before 09:00): the finder answers the classic
  /// question exactly as it always did until the days are
  /// touched.
  void _applyPreset(String which) {
    final friday = which == 'this'
        ? fridayOf(_now())
        : addCalendarDays(fridayOf(_now()), 7);
    final period = weekendPeriod(friday);
    final plan = legacyWeekendPlan(friday, label: period.describe());
    setState(() {
      _preset = which;
      _period = period;
      _setRules(_outRules, plan.outDays);
      _setRules(_backRules, plan.backDays);
    });
  }

  Future<void> _pickPeriod() async {
    final today = _now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: addCalendarDays(today, -30),
      lastDate: addCalendarDays(today, 300),
      initialDateRange: DateTimeRange(start: _period.start, end: _period.end),
      helpText: 'When do you consider travel?',
    );
    if (picked == null) return;
    setState(() {
      _preset = 'custom';
      _period = TravelPeriod(picked.start, picked.end);
      // A custom period starts with its first day out and
      // its last day back, both "any time" -- the days are
      // then selected and bounded freely.
      final plan = periodPlan(_period);
      _setRules(_outRules, plan.outDays);
      _setRules(_backRules, plan.backDays);
    });
  }

  void _setRules(Map<DateTime, TravelDay> target, List<TravelDay> days) {
    target
      ..clear()
      ..addEntries(days.map((day) => MapEntry(day.day, day)));
  }

  /// The free day selection: which candidate days count as
  /// "out on" and "back on", and what time bound each
  /// selected day carries (report b).
  Widget _daysCard() {
    final theme = Theme.of(context);
    final candidates = candidateDays(_period);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Out on / Back on', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            ..._daySide(
              title: 'Out on',
              rules: _outRules,
              candidates: candidates,
              outbound: true,
            ),
            const SizedBox(height: 10),
            ..._daySide(
              title: 'Back on',
              rules: _backRules,
              candidates: candidates,
              outbound: false,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _daySide({
    required String title,
    required Map<DateTime, TravelDay> rules,
    required List<DateTime> candidates,
    required bool outbound,
  }) {
    final theme = Theme.of(context);
    final selected = rules.values.toList()
      ..sort((a, b) => a.compareTo(b));
    return [
      Text(title, style: theme.textTheme.labelLarge),
      const SizedBox(height: 4),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final day in candidates)
            FilterChip(
              label: Text(_dayLabel(day)),
              selected: rules.containsKey(day),
              onSelected: (on) {
                setState(() {
                  if (on) {
                    // A day that comes back keeps the rule it
                    // had: selecting it afresh used to reset it
                    // to "any time" and silently throw the
                    // user's bound away. The rule is remembered
                    // here because removing the day's entry
                    // from the map takes the bound with it.
                    rules[day] = _rememberedRules[day] ?? TravelDay(day);
                  } else {
                    final rule = rules.remove(day);
                    if (rule != null) _rememberedRules[day] = rule;
                  }
                });
                _selectionChanged();
              },
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      if (selected.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (final rule in selected)
          _ruleRow(rule, outbound: outbound, rules: rules),
      ],
    ];
  }

  /// One selected day's rule row: the bound direction and
  /// the time it applies to ("departs after 14:00" /
  /// "lands before 09:00" / "any time").
  Widget _ruleRow(TravelDay rule,
      {required bool outbound, required Map<DateTime, TravelDay> rules}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 110,
            child: Text(_dayLabel(rule.day),
                style: theme.textTheme.bodyMedium),
          ),
          DropdownButton<DayBound>(
            value: rule.bound,
            isDense: true,
            items: const [
              DropdownMenuItem(value: DayBound.any, child: Text('any time')),
              DropdownMenuItem(value: DayBound.after, child: Text('after')),
              DropdownMenuItem(value: DayBound.before, child: Text('before')),
            ],
            onChanged: (bound) {
              if (bound == null) return;
              setState(() {
                rules[rule.day] = rule.withBound(
                  bound,
                  bound == DayBound.any
                      ? null
                      // Sensible starting bounds: leave
                      // after work, be home before the
                      // night.
                      : (rule.minutes ??
                          (bound == DayBound.after ? 14 * 60 : 9 * 60)),
                );
              });
            },
          ),
          if (rule.bound == DayBound.any)
            Text('any time', style: theme.textTheme.labelSmall)
          else
            ActionChip(
              label: Text(
                '${(rule.minutes! ~/ 60).toString().padLeft(2, '0')}:'
                '${(rule.minutes! % 60).toString().padLeft(2, '0')}',
                style: theme.textTheme.labelSmall),
              onPressed: () =>
                  _pickRuleTime(rule, outbound: outbound, rules: rules),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Future<void> _pickRuleTime(TravelDay rule,
      {required bool outbound, required Map<DateTime, TravelDay> rules}) async {
    final current = rule.minutes ?? 0;
    final picked = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: outbound
          ? (rule.bound == DayBound.before ? 'Depart before:' : 'Depart after:')
          : (rule.bound == DayBound.before ? 'Land before:' : 'Land after:'),
    );
    if (picked == null) return;
    setState(() {
      rules[rule.day] =
          rule.withBound(rule.bound, picked.hour * 60 + picked.minute);
    });
  }

  /// "Thu 10.12." -- with a flex marker outside the period.
  String _dayLabel(DateTime day) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final name = weekdays[day.weekday - 1];
    final date = '${day.day}.${day.month}.';
    return '$name $date';
  }

  /// The flight source and the flight filters: the live
  /// Fraport board is the only source (the CSV override is
  /// gone, report c), the dropdown decides which airlines
  /// count (report d) and the stay floor is the visible
  /// "Min. nights" control (report e).
  Widget _sourceCard() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Flight data source', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Source: the live Fraport departures/arrivals board.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Text('Airlines', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            DropdownButtonFormField<AirlineScope>(
              initialValue: _airlineScope,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              isExpanded: true,
              items: [
                for (final scope in AirlineScope.values)
                  DropdownMenuItem(
                    value: scope,
                    child: Text(airlineScopeLabels[scope]!,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (scope) {
                if (scope == null) return;
                setState(() => _airlineScope = scope);
              },
            ),
            const SizedBox(height: 4),
            Text(_scopeCaption(), style: theme.textTheme.bodySmall),
            // The group is eleven carriers now: the list
            // goes behind a question mark (hover on the
            // desktop, a tap on the phone) so the card stays
            // short.
            if (_airlineScope == AirlineScope.lufthansaGroup)
              Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  triggerMode: TooltipTriggerMode.tap,
                  message: lufthansaGroupCaption(),
                  // Without a width the box is laid out
                  // unbounded and both ends of the list are
                  // cut off the screen edge (the phone,
                  // 2026-10-21). It wraps to the card's
                  // width instead.
                  constraints: BoxConstraints(
                      maxWidth:
                          MediaQuery.of(context).size.width - 48),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.help_outline,
                          size: 15, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text('Which carriers?',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            // The benefits answer belongs with the airline
            // filter -- it is the other half of the same
            // question -- so it lives here rather than in a
            // box of its own.
            Row(
              children: [
                Expanded(
                  child: Text('Airlines with benefits',
                      style: theme.textTheme.labelLarge),
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
            const SizedBox(height: 2),
            if (_loadingBenefits)
              const Text('Reading the benefits database…')
            else
              Text(
                benefitSummary(
                    _benefits.flags, _benefits.records, _benefits.sourceLabel,
                    _benefits.problems),
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 150,
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
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<int>(
                    initialValue: _minNights,
                    decoration: const InputDecoration(
                      labelText: 'Min. nights',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    isExpanded: true,
                    items: [
                      for (final nights in [0, 1, 2, 3, 4])
                        DropdownMenuItem(
                          value: nights,
                          child: Text(
                            nights == 0
                                ? 'Any'
                                : '$nights night${nights == 1 ? '' : 's'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _minNights = value);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// What the airline scope means, in one line.
  String _scopeCaption() {
    switch (_airlineScope) {
      case AirlineScope.lufthansaGroup:
        return 'Only the Lufthansa Group carriers.';
      case AirlineScope.lufthansa:
        return 'Every airline with "Lufthansa" in its name.';
      case AirlineScope.allWithBenefits:
        return 'Only airlines flagged as having benefits in the benefits '
            'database.';
      case AirlineScope.all:
        return 'Every airline on the board.';
    }
  }


  Widget _report(WeekendSearch search) {
    final report = search.report;
    final theme = Theme.of(context);
    final unmatched = _unmatchedCarriers(report, search.benefits.flags);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Travel ${report.plan.label.isEmpty ? '' : '${report.plan.label} · '}'
          '${report.outboundTotal} '
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
         const SizedBox(height: 12),
         if (report.cityCount == 0)
           _emptyState(report)
         else
           _cityList(report),
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
              child:               Text('${report.cityCount} destinations fit this weekend',
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
         ..._groupedCityRows(cities, index),
       ],
     );
  }

  /// Groups result cities into "on your list" vs "not on your list"
  /// with subheadings (report f, 2026-10-17).
  List<Widget> _groupedCityRows(List<CityResult> cities, CatalogueIndex index) {
    final theme = Theme.of(context);
    final known = <CityResult>[];
    final unknown = <CityResult>[];
    for (final city in cities) {
      if (index.match(city.city, city.country) != null) {
        known.add(city);
      } else {
        unknown.add(city);
      }
    }
    final out = <Widget>[];
    if (known.isNotEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Text('Destination on your list:',
            style: theme.textTheme.labelLarge),
      ));
      for (final city in known) {
        out.add(_cityRow(city, index.match(city.city, city.country)));
      }
    }
    if (unknown.isNotEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text('Destinations not on your list:',
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
      ));
      for (final city in unknown) {
        out.add(_cityRow(city, index.match(city.city, city.country)));
      }
    }
    return out;
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
                         Text('${CountryNames.flagFor(city.country)} ${city.label}',
                             style: theme.textTheme.titleSmall,
                             overflow: TextOverflow.ellipsis),
                         // The facts, one per line and *not*
                         // ellipsised: a phone has no room for
                         // them side by side, and a truncated
                         // "earliest out Sat 09:20 · 1 n…" says
                         // nothing (the phone screenshot,
                         // 2026-10-20).
                         Text(
                           '${city.count} option${city.count == 1 ? '' : 's'} · '
                           '${cityDepartureSummary(city)}',
                           style: theme.textTheme.bodySmall,
                         ),
                         if (cityReturnSummary(city).isNotEmpty)
                           Text(
                             cityReturnSummary(city),
                             style: theme.textTheme.bodySmall?.copyWith(
                                 color: theme.colorScheme.primary),
                           ),
                         if (catalogueName != null)
                           Text(
                             _finderFigures(catalogueName),
                             style: theme.textTheme.labelSmall?.copyWith(
                                 color: theme.colorScheme.onSurfaceVariant),
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
                  if (catalogueName != null &&
                      catalogueName.trim().toLowerCase() !=
                          city.city.trim().toLowerCase())
                    Text(
                      'Catalogue name: $catalogueName',
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

  String _finderFigures(String catalogueName) {
    Destination? match;
    for (final d in _catalogue) {
      if (d.name == catalogueName) {
        match = d;
        break;
      }
    }
    if (match == null) return '';
    final dest = match;
    final reviews = dest.column('Reviews');
    final prio = dest.prio;
    final pop = dest.column('Population (Metro Area)');
    final stay = dest.column('Recommended Stay');
    final parts = <String>[];
    if (reviews != null) parts.add('⭐$reviews');
    if (prio != null && '$prio'.trim().isNotEmpty) parts.add('🎯$prio');
    if (pop != null) {
      final n = (pop is num) ? pop.toDouble() : double.tryParse('$pop');
      if (n != null) {
        parts.add('👥${(n / 1e6).toStringAsFixed(1)}m'.replaceAll('.0m', 'm'));
      }
    }
    if (stay != null && '$stay'.trim().isNotEmpty) parts.add('🛏$stay');
    return parts.join(' · ');
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
      settings: RouteSettings(name: 'destination/${match.name}'),
      builder: (_) => DestinationPage(
        repository: widget.destinations,
        destination: match!,
        onOpenDestination: widget.onOpenDestination,
        initiallyInOpenTabs: widget.isInOpenTabs?.call(match.name) ?? false,
        onAddToOpenTabs: widget.onAddToOpenTabs,
      ),
    ));
  }

  Widget _optionTile(TripOption option) {
    final theme = Theme.of(context);
    final stay = option.nights == 1 ? '1 night' : '${option.nights} nights';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                stay,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 4),
            _flightLeg('Outbound', option.outFlight, Icons.flight_takeoff),
            const Divider(height: 16),
            _flightLeg('Return', option.backFlight, Icons.flight_land),
          ],
        ),
      ),
    );
  }

  Widget _flightLeg(String label, Flight flight, IconData icon) {
    final theme = Theme.of(context);
    final terminal = flight.terminal.isEmpty ? '' : ' · T${flight.terminal}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text('${flight.flightNo} · ${_carrierLabel(flight)}',
                  style: theme.textTheme.bodyMedium),
              Text(
                '${_stamp(flight.departure)} → ${_stamp(flight.arrival)}$terminal',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
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

  /// The carrier as a reader says it: the board's name when
  /// the record carried one, else the code.
  static String _carrierLabel(Flight flight) {
    final name = flight.airlineName.trim();
    return name.isNotEmpty ? name : flight.operatorAirline;
  }

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
