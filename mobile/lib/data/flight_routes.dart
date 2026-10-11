/// The transport routes: the models, the cache
/// key, the duration parser, and the table logic
/// (sort, filter, search) — all pure.
///
/// The Dart port of `flight_routes.py`'s pure
/// halves: the cache key (`_normalize_key`), the
/// duration parser (`_parse_duration_minutes`),
/// the China determination, and the row
/// processing (the `processed_rows` the tables
/// are built from). The Streamlit rendering is
/// ported separately; nothing here touches the
/// network or the file system.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/destination.dart';
import 'text_norm.dart' show stripDiacritics;

/// Normalize a destination or airline name for
/// caching and matching.
///
/// The province/state qualifier is KEPT: 24
/// workbook rows use the "Name (Province)" form,
/// and dropping it gave "Suzhou (Jiangsu)" and
/// "Suzhou (Anhui)" one shared cache file and one
/// shared planner lookup, so one of them showed
/// the other's airport, Prio and rating. Airline
/// names have no parentheses, so their keys are
/// unaffected.
String normalizeKey(Object? value) {
  if (value == null) return '';
  final folded = stripDiacritics(value.toString());
  return folded.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Convert a duration string (e.g. '1h 45m', '2h',
/// '45m', '1h 20m - 1h 40m') into minutes for
/// sorting. The first lower-bound segment is taken;
/// a bare number is minutes when it is plausibly
/// minutes (<= 18) and hours otherwise.
double parseDurationMinutes(Object? text) {
  if (text == null) return double.infinity;
  final raw = text.toString().trim().toLowerCase();
  if (raw.isEmpty ||
      raw == '—' ||
      raw == '-' ||
      raw == 'n/a' ||
      raw == 'none' ||
      raw == 'null') {
    return double.infinity;
  }

  // Take the first lower-bound time segment.
  final firstPart =
      raw.split('-').first.split('–').first.split('to').first.trim();

  final hMatch = RegExp(r'(\d+(?:\.\d+)?)\s*h').firstMatch(firstPart);
  final mMatch = RegExp(r'(\d+(?:\.\d+)?)\s*m').firstMatch(firstPart);
  var hours = 0.0;
  var minutes = 0.0;
  if (hMatch != null) hours = double.parse(hMatch.group(1)!);
  if (mMatch != null) minutes = double.parse(mMatch.group(1)!);

  if (hMatch == null && mMatch == null) {
    final numMatch = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(firstPart);
    if (numMatch != null) {
      final val = double.parse(numMatch.group(1)!);
      return val <= 18 ? val * 60 : val;
    }
    return double.infinity;
  }

  return hours * 60 + minutes;
}

/// Whether the destination is a Chinese city (or
/// in China), which adds the high-speed rail
/// research and the trains tab.
bool isChinaDestination(String destination, String country) {
  final c = country.trim().toLowerCase();
  final d = destination.trim().toLowerCase();
  return ['china', 'peoples republic of china', 'prc', 'cn']
          .any((x) => c.contains(x)) ||
      const {
        'nanchang', 'beijing', 'shanghai', 'guangzhou', 'shenzhen',
        'chengdu', 'chongqing', 'hangzhou', 'xian', "xi'an", 'wuhan',
        'nanjing', 'tianjin', 'suzhou', 'changsha', 'zhengzhou',
        'qingdao', 'dalian', 'kunming', 'xiamen', 'fuzhou', 'harbin',
        'guilin', 'sanya', 'haikou', 'urumqi', 'lhasa', 'guiyang',
        'nanning', 'hefei', 'jinan',
      }.contains(d);
}

/// The cached transport research for one
/// destination: the airport, the direct flight
/// routes and, for Chinese cities, the
/// high-speed rail connections.
class FlightRoutes {
  final String airportName;
  final String iataCode;
  final String city;
  final String country;
  final String lastUpdated;
  final List<FlightRoute> routes;
  final List<HsrRoute> hsrRoutes;
  final List<String> trainStations;

  const FlightRoutes({
    this.airportName = '',
    this.iataCode = '',
    this.city = '',
    this.country = '',
    this.lastUpdated = '',
    this.routes = const [],
    this.hsrRoutes = const [],
    this.trainStations = const [],
  });

  factory FlightRoutes.fromJson(Map<String, dynamic> json) {
    return FlightRoutes(
      airportName: (json['airport_name'] ?? '').toString(),
      iataCode: (json['iata_code'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      country: (json['country'] ?? '').toString(),
      lastUpdated: (json['last_updated'] ?? '').toString(),
      routes: _routes(json['routes']),
      hsrRoutes: _hsrRoutes(json['hsr_routes']),
      trainStations: [
        for (final s in (json['train_stations'] as List? ?? const []))
          s.toString(),
      ],
    );
  }

  static List<FlightRoute> _routes(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final r in raw)
        if (r is Map) FlightRoute.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  static List<HsrRoute> _hsrRoutes(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final r in raw)
        if (r is Map) HsrRoute.fromJson(Map<String, dynamic>.from(r)),
    ];
  }
}

/// One direct flight route: a destination city,
/// the airlines that fly it and the flight time.
class FlightRoute {
  final String destinationCity;
  final String destinationCountry;
  final String destinationIata;
  final List<String> airlines;
  final String flightTime;
  final String routeType;
  final String frequencyNotes;

  const FlightRoute({
    this.destinationCity = '',
    this.destinationCountry = '',
    this.destinationIata = '',
    this.airlines = const [],
    this.flightTime = '',
    this.routeType = '',
    this.frequencyNotes = '',
  });

  factory FlightRoute.fromJson(Map<String, dynamic> json) {
    return FlightRoute(
      destinationCity: (json['destination_city'] ?? '').toString().trim(),
      destinationCountry:
          (json['destination_country'] ?? '').toString().trim(),
      destinationIata: (json['destination_iata'] ?? '').toString().trim(),
      airlines: _airlines(json['airlines']),
      flightTime: (json['flight_time'] ?? '').toString().trim(),
      routeType: (json['route_type'] ?? '').toString().trim(),
      frequencyNotes: (json['frequency_notes'] ?? '').toString().trim(),
    );
  }

  /// The airlines: a list, or a comma-separated
  /// string — the two shapes the model sends.
  static List<String> _airlines(Object? raw) {
    if (raw is List) {
      return [
        for (final a in raw)
          if (a.toString().trim().isNotEmpty) a.toString().trim(),
      ];
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return [
        for (final a in raw.split(','))
          if (a.trim().isNotEmpty) a.trim(),
      ];
    }
    return const [];
  }
}

/// One high-speed rail connection: a destination
/// city, the arrival station and the travel time.
class HsrRoute {
  final String destinationCity;
  final String destinationStation;
  final String originStation;
  final String duration;
  final String trainTypes;
  final String frequencyNotes;

  const HsrRoute({
    this.destinationCity = '',
    this.destinationStation = '',
    this.originStation = '',
    this.duration = '',
    this.trainTypes = '',
    this.frequencyNotes = '',
  });

  factory HsrRoute.fromJson(Map<String, dynamic> json) {
    return HsrRoute(
      destinationCity: (json['destination_city'] ?? '').toString().trim(),
      destinationStation:
          (json['destination_station'] ?? '').toString().trim(),
      originStation: (json['origin_station'] ?? '').toString().trim(),
      duration: (json['duration'] ?? '').toString().trim(),
      trainTypes: (json['train_types'] ?? '').toString().trim(),
      frequencyNotes: (json['frequency_notes'] ?? '').toString().trim(),
    );
  }
}

/// The catalogue indexed by cache key, so a route
/// can be matched to the destination it belongs
/// to (for the Wishlist link, the Prio and the
/// Review score). Two rows normalizing to the
/// same key keep the first, exactly like the
/// legacy's `planner_lookup`.
Map<String, Destination> buildPlannerLookup(List<Destination> catalogue) {
  final lookup = <String, Destination>{};
  for (final dest in catalogue) {
    final key = normalizeKey(dest.name);
    if (key.isEmpty) continue;
    lookup.putIfAbsent(key, () => dest);
  }
  return lookup;
}

/// One row of the flights table: the route, its
/// duration in minutes and the matching catalogue
/// entry (null when the city is not in the planner).
class FlightRow {
  final FlightRoute route;
  final double durationMinutes;
  final Destination? planner;

  const FlightRow({
    required this.route,
    required this.durationMinutes,
    this.planner,
  });

  String get city => route.destinationCity;
  String get country => route.destinationCountry;
  String get airport => route.destinationIata;
  String get flightTime => route.flightTime;
  List<String> get airlines => route.airlines;
  String get frequency => route.frequencyNotes;
  bool get inPlanner => planner != null;
}

/// The flights table, sorted by duration and
/// narrowed by the filter and the search — the
/// `processed_rows` -> `sort_values` -> filter
/// pipeline the legacy runs on the DataFrame.
List<FlightRow> queryFlightRows({
  required List<FlightRoute> routes,
  required Map<String, Destination> plannerLookup,
  bool inPlannerOnly = false,
  String query = '',
}) {
  final rows = [
    for (final route in routes)
      FlightRow(
        route: route,
        durationMinutes: parseDurationMinutes(route.flightTime),
        planner: plannerLookup[normalizeKey(route.destinationCity)],
      ),
    ];
  rows.sort((a, b) => a.durationMinutes.compareTo(b.durationMinutes));
  var result = rows;
  if (inPlannerOnly) {
    result = result.where((row) => row.inPlanner).toList();
  }
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    result = result.where((row) {
      final airlines = row.airlines.join(', ').toLowerCase();
      return row.city.toLowerCase().contains(q) ||
          row.country.toLowerCase().contains(q) ||
          row.airport.toLowerCase().contains(q) ||
          row.flightTime.toLowerCase().contains(q) ||
          airlines.contains(q);
    }).toList();
  }
  return result;
}

/// One row of the trains table: the connection,
/// its travel time in minutes and the matching
/// catalogue entry.
class TrainRow {
  final HsrRoute route;
  final double durationMinutes;
  final Destination? planner;

  const TrainRow({
    required this.route,
    required this.durationMinutes,
    this.planner,
  });

  String get city => route.destinationCity;
  String get arrivalStation => route.destinationStation;
  String get travelTime => route.duration;
  String get trainType => route.trainTypes;
  String get frequency => route.frequencyNotes;
  bool get inPlanner => planner != null;
}

/// The trains table, sorted by travel time and
/// narrowed by the filter and the search.
List<TrainRow> queryTrainRows({
  required List<HsrRoute> routes,
  required Map<String, Destination> plannerLookup,
  bool inPlannerOnly = false,
  String query = '',
}) {
  final rows = [
    for (final route in routes)
      TrainRow(
        route: route,
        durationMinutes: parseDurationMinutes(route.duration),
        planner: plannerLookup[normalizeKey(route.destinationCity)],
      ),
    ];
  rows.sort((a, b) => a.durationMinutes.compareTo(b.durationMinutes));
  var result = rows;
  if (inPlannerOnly) {
    result = result.where((row) => row.inPlanner).toList();
  }
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    result = result.where((row) {
      return row.city.toLowerCase().contains(q) ||
          row.arrivalStation.toLowerCase().contains(q) ||
          row.travelTime.toLowerCase().contains(q) ||
          row.trainType.toLowerCase().contains(q);
    }).toList();
  }
  return result;
}

/// The airline colors from the Airlines sheet:
/// normalized name -> color. The bundled
/// `assets/airline_colors.json` is the source
/// (generated from the workbook's Airlines sheet
/// by `tools/generate_assets.py`), so the colors
/// are a snapshot that a regeneration refreshes.
class AirlineColors {
  final Map<String, String> _colors;

  const AirlineColors(this._colors);

  /// The color palette the legacy maps the named
  /// colors to; an unknown value is used as-is
  /// (a hex code).
  static const _palette = {
    'red': '#dc2626',
    'blue': '#2563eb',
    'green': '#16a34a',
    'yellow': '#d97706',
    'orange': '#ea580c',
    'purple': '#9333ea',
    'pink': '#db2777',
    'black': '#0f172a',
    'gray': '#64748b',
    'grey': '#64748b',
  };

  /// Load the bundled colors. A missing file
  /// leaves every airline uncolored, never a
  /// crash — the same per-device pattern as the
  /// other bundled assets.
  static Future<AirlineColors> load() async {
    try {
      final text =
          await rootBundle.loadString('assets/airline_colors.json');
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final colors = <String, String>{};
      for (final entry in decoded.entries) {
        final color = entry.value?.toString().trim().toLowerCase() ?? '';
        if (color.isNotEmpty) colors[entry.key] = color;
      }
      return AirlineColors(colors);
    } catch (_) {
      return const AirlineColors({});
    }
  }

  /// The display color for an airline, or null
  /// when the Airlines sheet has no color for it.
  String? colorFor(String airline) {
    final color = _colors[normalizeKey(airline)];
    if (color == null || color.isEmpty) return null;
    return _palette[color] ?? color;
  }

  /// Green and blue are bold in the legacy table.
  bool isBold(String airline) {
    final color = _colors[normalizeKey(airline)];
    return color == 'green' || color == 'blue';
  }
}
