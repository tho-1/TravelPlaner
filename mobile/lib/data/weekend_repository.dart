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
import '../models/weekend_match.dart';
import 'benefits_repository.dart';
import 'catalogue_match.dart';

/// IATA code -> "City|Country" records from the generated
/// `assets/airports.json` (built from the Python
/// `airport_city` module, which is the single source of
/// truth). Loaded once and cached, like the Python module's
/// `lru_cache`.
class AirportLookup {
  static final Map<String, (String, String)> _table = {};
  static var _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
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

/// The flight filters the finder card exposes: whether the
/// match honours the benefit-airline flags, and the longest
/// leg the user is willing to sit through. `null` disables
/// the cap.
class WeekendSearchOptions {
  final bool benefitsOnly;
  final Duration? maxLegDuration;

  const WeekendSearchOptions({
    this.benefitsOnly = true,
    this.maxLegDuration,
  });
}

class WeekendRepository {
  final FlightBoardProvider provider;

  WeekendRepository(this.provider);

  /// Run the five board queries for one weekend and match
  /// them.
  Future<WeekendSearch> search(
    Weekend weekend,
    Windows windows,
    BenefitSource benefits, {
    WeekendSearchOptions options = const WeekendSearchOptions(),
  }) async {
    await AirportLookup.ensureLoaded();
    await CountryNames.ensureLoaded();
    final outbound = <Flight>[];
    final returns = <Flight>[];
    final notes = <String>[];

    // One board query per enabled out/back day — the
    // holiday-bridge days (Thursday out, Tuesday back)
    // query only when their picker switched them on.
    final queries = <(DateTime, String, List<Flight>)>[
      if (windows.thursdayFrom != null)
        (weekend.thursday, 'departures', outbound),
      if (windows.fridayFrom != null)
        (weekend.friday, 'departures', outbound),
      if (windows.saturdayBefore != null)
        (weekend.saturday, 'departures', outbound),
      if (windows.saturdayReturnAfter != null)
        (weekend.saturday, 'arrivals', returns),
      if (windows.sundayEnabled) (weekend.sunday, 'arrivals', returns),
      if (windows.mondayReturnBefore != null)
        (weekend.monday, 'arrivals', returns),
      if (windows.tuesdayReturnBefore != null)
        (weekend.tuesday, 'arrivals', returns),
    ];
    for (final (day, kind, sink) in queries) {
      final (since, until) = fetchWindow(weekend, windows, day, kind);
      if (since == null || until == null) continue;
      try {
        final result = await provider.fetch(day, kind, since: since, until: until);
        if (result.warning.isNotEmpty) {
          notes.add('${_isoDate(day)} $kind: ${result.warning}');
        }
        sink.addAll(result.flights);
      } on ProviderUnavailable catch (error) {
        notes.add(error.message);
        break;
      }
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
      weekend: weekend,
      windows: windows,
      benefitCheck: options.benefitsOnly
          ? (airline) => hasBenefits(airline, benefits.flags)
          : (_) => true,
      cityLookup: AirportLookup.cityForAirport,
      countryNameFor: CountryNames.nameFor,
    );
    return (report: withNotes(report, notes), benefits: benefits);
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
      weekend: report.weekend,
      windows: report.windows,
      cities: report.cities,
      oneWayOnly: report.oneWayOnly,
      outboundTotal: report.outboundTotal,
      returnTotal: report.returnTotal,
      outboundRejectedAirlines: report.outboundRejectedAirlines,
      notes: notes,
    );
  }

  static String _isoDate(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
