/// The weekend finder's orchestration: five board queries,
/// one matcher run, one explainable report.
///
/// The Dart port of `timetable.search_weekend`. A provider
/// that cannot answer for one window is not fatal: the legs
/// that did arrive are still collected and the report
/// explains the gap in `notes` instead of pretending there
/// were no flights.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/airline_benefits.dart';
import '../models/timetable.dart';
import '../models/travel_days.dart';
import '../models/weekend_match.dart';
import 'benefits_repository.dart';
import 'catalogue_match.dart';
import 'error_log.dart';

/// IATA code -> "City|Country" records from the generated
/// `assets/airports.json` (built from the Python
/// `airport_city` module, which is the single source of
/// truth). Loaded once and cached, like the Python module's
/// `lru_cache`.
class AirportLookup {
  static final Map<String, (String, String)> _table = {};
  static var _loaded = false;

  /// Railway stations on Fraport's board: Lufthansa AIRail
  /// trains carry LH flight numbers into main-station codes,
  /// which are *DB station codes, not IATA* -- the airport
  /// table cannot know them. Without this table they render
  /// under their code ("?QKL", report f, 2026-10-16). The
  /// nine the legacy `airport_city.RAIL_STATIONS` knew plus
  /// QKL/ZWS, which the board serves since. Names are ASCII,
  /// matching the rest of the tables.
  static const railStations = <String, (String, String)>{
    'DHC': ('Bremen', 'DE'),
    'DTZ': ('Dortmund', 'DE'),
    'QDU': ('Dusseldorf', 'DE'),
    'QKL': ('Cologne', 'DE'),
    'XHJ': ('Aachen', 'DE'),
    'XIR': ('Dresden', 'DE'),
    'ZBA': ('Basel', 'CH'),
    'ZEU': ('Goettingen', 'DE'),
    'ZMB': ('Hamburg', 'DE'),
    'ZMU': ('Munich', 'DE'),
    'ZWS': ('Stuttgart', 'DE'),
  };

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _table.addAll(railStations);
    try {
      final text = await rootBundle.loadString('assets/airports.json');
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final pair = entry.value;
        if (pair is List && pair.length >= 2) {
          final city = '${pair[0]}'.trim();
          final country = '${pair[1]}'.trim();
          if (city.isNotEmpty) {
            _table[entry.key] = (city, country);
          }
        }
      }
    } catch (_) {
      // A missing or malformed asset leaves the
      // table empty: airports then key under
      // their own code, which the matcher handles
      // (unknown is not a failure), instead of
      // throwing into the finder's search.
    }
    _loaded = true;
  }

  /// The city and country an airport serves, or `null` when
  /// the table does not know the code -- the same contract
  /// `airport_city.city_for_airport` has (unknown is not a
  /// failure).
  static (String, String)? cityForAirport(String code) {
    final key = code.trim().toUpperCase();
    if (key.isEmpty) return null;
    return _table[key];
  }

  /// Test seam: install a table without loading the asset.
  static void installForTesting(Map<String, (String, String)> table) {
    _table
      ..clear()
      ..addAll(railStations)
      ..addAll(table);
    _loaded = true;
  }
}

/// The finder's outcome: the report plus the benefit source
/// that produced it, so the UI can show both from one run.
typedef WeekendSearch = ({
  MatchReport report,
  BenefitSource benefits,
});

/// The flight filters the finder card exposes: which
/// airlines count (the dropdown, report d) and the longest
/// leg the user is willing to sit through. `null` disables
/// the cap. `minNights` is the stay-length floor — a
/// *visible* finder control (report e, clarified 2026-10-16:
/// default "at least 1 night", the user may change it).
class WeekendSearchOptions {
  final AirlineScope airlineScope;
  final Duration? maxLegDuration;
  final int minNights;

  const WeekendSearchOptions({
    this.airlineScope = AirlineScope.lufthansaGroup,
    this.maxLegDuration,
    this.minNights = 1,
  });
}

class WeekendRepository {
  final FlightBoardProvider provider;

  /// The optional second source (report j): asked only
  /// about windows that failed or look incomplete, never
  /// about healthy ones.
  final FlightBoardProvider? fallback;

  WeekendRepository(this.provider, {this.fallback});

  /// Run one board query per selected day and match them.
  Future<WeekendSearch> search(
    TravelPlan plan,
    BenefitSource benefits, {
    WeekendSearchOptions options = const WeekendSearchOptions(),
  }) async {
    await AirportLookup.ensureLoaded();
    await CountryNames.ensureLoaded();
    final outbound = <Flight>[];
    final returns = <Flight>[];
    final notes = <String>[];

    // One board query per selected out/back day.
    final queries = <(TravelDay, String, List<Flight>)>[
      for (final day in plan.outDays) (day, 'departures', outbound),
      for (final day in plan.backDays) (day, 'arrivals', returns),
    ];
    final windowsByKey = <String, (TravelDay, String, List<Flight>)>{
      for (final query in queries) '${_isoDate(query.$1.day)} ${query.$2}': query,
    };
    final windowCounts = <String, int>{};
    final failedWindows = <String>[];
    for (final (rule, kind, sink) in queries) {
      final (since, until) = rule.fetchWindow();
      final windowLabel = '${_isoDate(rule.day)} $kind';
      try {
        final result = await provider.fetch(rule.day, kind,
            since: since, until: until);
        if (result.warning.isNotEmpty) {
          notes.add('$windowLabel: ${result.warning}');
        }
        sink.addAll(result.flights);
        windowCounts[windowLabel] = result.flights.length;
      } on ProviderUnavailable catch (error) {
        // One dead window must not end the search (the old
        // `break` lost every later day because one query
        // failed): the other days still answer, and the
        // failure is a visible note *and* a log line, never
        // silence.
        notes.add('$windowLabel: ${error.message}');
        ErrorLog.instance.record('weekend-finder', error.message,
            details: {'window': windowLabel});
        failedWindows.add(windowLabel);
      } catch (error) {
        notes.add('$windowLabel: the query failed ($error)');
        ErrorLog.instance
            .record('weekend-finder', '$error', details: {'window': windowLabel});
        failedWindows.add(windowLabel);
      }
    }

    // An empty or implausible window is never silently "no
    // flights": the Fraport feed carried exactly one arrival
    // on 2026-10-25 where sibling windows carried hundreds
    // (report f, 2026-10-16). Compare the windows against
    // each other and say what looks wrong.
    final busiest =
        windowCounts.values.fold<int>(0, (a, b) => a > b ? a : b);
    final suspicious = <String>{...failedWindows};
    for (final entry in windowCounts.entries) {
      final warning = _windowWarning(entry.key, entry.value, busiest);
      if (warning == null) continue;
      suspicious.add(entry.key);
      notes.add(warning);
      ErrorLog.instance.record('weekend-finder', warning, details: {
        'window': entry.key,
        'flights': entry.value,
        'busiest': busiest,
      });
    }

    // The fallback pass (report j): every suspicious window
    // is asked again from the second source, and what it
    // returns is merged in -- deduplicated by flight number
    // and departure, so two sources never double-count.
    for (final label in suspicious) {
      final query = windowsByKey[label];
      if (query == null) continue;
      await _fillFromFallback(
        rule: query.$1,
        kind: query.$2,
        sink: query.$3,
        primaryCount: windowCounts[label] ?? 0,
        windowLabel: label,
        notes: notes,
      );
    }

    // The leg-duration cap: how many flights each list lost
    // goes into the notes, so an empty result can never be
    // mistaken for "nothing flies".
    final cap = options.maxLegDuration;
    if (cap != null) {
      final droppedOut = _dropOverlong(outbound, cap);
      final droppedBack = _dropOverlong(returns, cap);
      if (droppedOut + droppedBack > 0) {
        notes.add(
            'Dropped ${droppedOut + droppedBack} flight(s) longer than '
            '${cap.inMinutes / 60} h per leg.');
      }
    }

    final report = findWeekends(
      outbound: outbound,
      returns: returns,
      plan: plan,
      airlineCheck: (code, name) => airlineInScope(
          code, name, options.airlineScope, benefits.flags),
      cityLookup: AirportLookup.cityForAirport,
      countryNameFor: CountryNames.nameFor,
      minNights: options.minNights,
    );
    if (report.shortStaysDropped > 0) {
      // Report e: a filter that can empty a list says what
      // it dropped and why. The floor is the user's choice
      // ("Min. nights"), so the note names it.
      notes.add('${report.shortStaysDropped} option(s) in '
          '${report.shortStayCities} cit(y/ies) dropped for staying '
          'fewer than ${options.minNights} '
          'night(s).');
    }

    // Unknown airport/station codes become log lines with
    // the board's own name for them, so the city table can
    // be grown from the log instead of from screenshots.
    for (final city in [...report.cities, ...report.oneWayOnly]) {
      for (final code in city.unmappedAirports) {
        ErrorLog.instance.record(
            'weekend-finder',
            'airport code $code is not on the city table',
            details: {
              'shown as': city.city,
              'airports': city.airports.toList()..sort(),
            });
      }
    }
    return (report: withNotes(report, notes), benefits: benefits);
  }

  /// The "this data looks wrong" note for one window, or
  /// null when it looks healthy. A window that answered
  /// nothing at all, or that answered a fraction of what
  /// sibling windows answered, is a board-side gap -- the
  /// reader must not mistake it for "nowhere to fly".
  static String? _windowWarning(String window, int flights, int busiest) {
    if (flights == 0) {
      return '$window: the board returned no flights at all — nothing '
          'is scheduled or the board has no data for this window yet; '
          'the results below may be incomplete.';
    }
    if (busiest >= 30 && flights < busiest * 0.02) {
      return '$window: only $flights flight(s) where other windows '
          'returned up to $busiest — the board\'s data for this window '
          'looks incomplete; the results below may be incomplete.';
    }
    return null;
  }

  /// Ask the fallback about one suspicious window and merge
  /// what it returns (report j). The primary's flights stay
  /// authoritative -- the fallback only adds what is
  /// missing, keyed by flight number and departure.
  Future<void> _fillFromFallback({
    required TravelDay rule,
    required String kind,
    required List<Flight> sink,
    required int primaryCount,
    required String windowLabel,
    required List<String> notes,
  }) async {
    final source = fallback;
    if (source == null) return;
    final (since, until) = rule.fetchWindow();
    try {
      final result = await source.fetch(rule.day, kind,
          since: since, until: until);
      final seen = {
        for (final flight in sink)
          '${flight.flightNo}|${flight.departure.toIso8601String()}',
      };
      var added = 0;
      for (final flight in result.flights) {
        final key =
            '${flight.flightNo}|${flight.departure.toIso8601String()}';
        if (seen.add(key)) {
          sink.add(flight);
          added++;
        }
      }
      if (added > 0) {
        final note = '$windowLabel: the primary source looked incomplete '
            '($primaryCount flight(s)) — filled in $added flight(s) '
            'from ${result.source}.';
        notes.add(note);
        ErrorLog.instance.record('weekend-finder', note, details: {
          'window': windowLabel,
          'primary': primaryCount,
          'fallback flights': result.flights.length,
          'added': added,
        });
      }
    } on ProviderUnavailable catch (error) {
      final note =
          '$windowLabel: the fallback source could not help either '
          '(${error.message}).';
      notes.add(note);
      ErrorLog.instance.record('weekend-finder', error.message,
          details: {'window': windowLabel, 'source': 'fallback'});
    } catch (error) {
      final note =
          '$windowLabel: the fallback source failed ($error).';
      notes.add(note);
      ErrorLog.instance.record('weekend-finder', '$error',
          details: {'window': windowLabel, 'source': 'fallback'});
    }
  }

  /// Retain only flights within the cap; returns the number
  /// dropped. A flight whose arrival precedes its departure
  /// (a board glitch) stays: the matcher reports it, not
  /// this filter.
  static int _dropOverlong(List<Flight> flights, Duration cap) {
    final before = flights.length;
    flights.retainWhere(
        (flight) => flight.arrival.difference(flight.departure) <= cap);
    return before - flights.length;
  }

  /// A copy of the report with its notes attached; the pure
  /// matcher stays free of fetch failures.
  static MatchReport withNotes(MatchReport report, List<String> notes) {
    return MatchReport(
      plan: report.plan,
      cities: report.cities,
      oneWayOnly: report.oneWayOnly,
      outboundTotal: report.outboundTotal,
      returnTotal: report.returnTotal,
      outboundRejectedAirlines: report.outboundRejectedAirlines,
      shortStaysDropped: report.shortStaysDropped,
      shortStayCities: report.shortStayCities,
      notes: notes,
    );
  }

  static String _isoDate(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
