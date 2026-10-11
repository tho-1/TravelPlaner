/// The weekend finder: Fri→Mon possibilities from FRA.
///
/// The Flutter port of `pages/weekend_finder.py`'s live
/// path (the CSV upload override has no mobile equivalent
/// -- the app always reads the live board). The rules and
/// the data flow are the legacy ones: the six time bounds
/// narrow five board queries, the matcher requires both
/// legs, and the report explains what it dropped and why
/// -- an empty answer is never ambiguous.
library;

import 'package:flutter/material.dart';

import '../data/benefits_repository.dart';
import '../data/catalogue_match.dart';
import '../data/destination_repository.dart';
import '../data/weekend_repository.dart';
import '../models/airline_benefits.dart';
import '../models/destination.dart';
import '../models/timetable.dart';
import '../models/weekend_match.dart';

class WeekendFinderPage extends StatefulWidget {
  final BenefitsRepository benefits;
  final DestinationRepository destinations;

  const WeekendFinderPage({
    super.key,
    required this.benefits,
    required this.destinations,
  });

  @override
  State<WeekendFinderPage> createState() => _WeekendFinderPageState();
}

class _WeekendFinderPageState extends State<WeekendFinderPage> {
  late final WeekendRepository _repository;
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

  WeekendSearch? _result;
  List<Destination> _catalogue = const <Destination>[];
  var _searching = false;
  @override
  void initState() {
    super.initState();
    _repository = WeekendRepository(
        FraportBoardProvider(throttleSeconds: 1.5));
    _weekend = weekendContaining(DateTime.now());
    _loadBenefits();
    _loadCatalogue();
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

  Future<void> _find() async {
    setState(() {
      _searching = true;
      _result = null;
    });
    final search = await _repository.search(_weekend, _windows, _benefits);
    if (!mounted) return;
    setState(() {
      _result = search;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Weekend Finder')),
      body: _searching
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Querying the flight board…'),
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
                  label: const Text('This weekend'),
                  selected: _isSameWeekend(weekendContaining(DateTime.now())),
                  onSelected: (_) => setState(
                      () => _weekend = weekendContaining(DateTime.now())),
                ),
                ChoiceChip(
                  label: const Text('Next weekend'),
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
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _boundChip('Out Fri from', _windows.fridayFrom, (value) {
                  setState(() => _windows = _copyWindows(fridayFrom: value));
                }),
                _boundChip('Out Sat before', _windows.saturdayBefore, (value) {
                  setState(() => _windows = _copyWindows(saturdayBefore: value));
                }),
                _boundChip('Back Sat after', _windows.saturdayReturnAfter,
                    (value) {
                  setState(() =>
                      _windows = _copyWindows(saturdayReturnAfter: value));
                }),
                _boundChip('Back Mon before', _windows.mondayReturnBefore,
                    (value) {
                  setState(() =>
                      _windows = _copyWindows(mondayReturnBefore: value));
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Windows _copyWindows({
    int? fridayFrom,
    int? saturdayBefore,
    int? saturdayReturnAfter,
    int? mondayReturnBefore,
  }) =>
      Windows(
        fridayFrom: fridayFrom ?? _windows.fridayFrom,
        saturdayBefore: saturdayBefore ?? _windows.saturdayBefore,
        saturdayReturnAfter:
            saturdayReturnAfter ?? _windows.saturdayReturnAfter,
        mondayReturnBefore: mondayReturnBefore ?? _windows.mondayReturnBefore,
      );

  Widget _boundChip(String label, int value, ValueChanged<int> onChanged) {
    final hhmm = TimeOfDay(hour: value ~/ 60, minute: value % 60);
    return ActionChip(
      avatar: const Icon(Icons.schedule_outlined, size: 18),
      label: Text('$label ${_hm(value)}'),
      onPressed: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: hhmm,
          helpText: label,
        );
        if (picked == null) return;
        onChanged(picked.hour * 60 + picked.minute);
      },
    );
  }

  Widget _benefitsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Airlines with benefits',
                style: Theme.of(context).textTheme.titleSmall),
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
      children: [
        Text('${report.cityCount} destinations',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final city in cities) _cityCard(city, index.match(city.city, city.country)),
      ],
    );
  }

  Widget _cityCard(CityResult city, String? catalogueName) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(city.label, style: theme.textTheme.titleSmall),
            if (catalogueName != null)
              Text('in your catalogue as $catalogueName',
                  style: theme.textTheme.bodySmall),
            Text(
              '${city.airports.toList()..sort()} · ${city.count} '
              'option${city.count == 1 ? '' : 's'}',
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
    );
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
