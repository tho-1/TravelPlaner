/// One destination: the typed core the app filters and
/// sorts on, plus the lossless column tail.
///
/// The workbook has 145 columns including duplicate
/// names and object-typed cells, so a flat typed model
/// would be brittle and would drop data; the tail
/// preserves every column exactly, the same contract
/// `storage_turso.py` keeps on the Python side.
library;

import 'dart:convert';

class Destination {
  final String name;
  final String? continent;
  final String? country;
  final bool visited;
  final bool favourite;
  final bool toBeResearched;
  final int? prio;
  final double? safetyRating;
  final double? avgCostDay;
  final double? flightTimeFra;
  final String? comment;

  /// Every workbook column as an ordered
  /// `(column, value)` list -- lossless.
  final List<(String, dynamic)> columns;

  const Destination({
    required this.name,
    this.continent,
    this.country,
    this.visited = false,
    this.favourite = false,
    this.toBeResearched = false,
    this.prio,
    this.safetyRating,
    this.avgCostDay,
    this.flightTimeFra,
    this.comment,
    this.columns = const [],
  });

  /// A `destinations` table row (typed core + `data`
  /// JSON tail), the shape `storage_turso.load_destinations`
  /// returns.
  factory Destination.fromRow(Map<String, dynamic> row) {
    final columns = <(String, dynamic)>[];
    final raw = row['data'];
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final pair in decoded) {
          if (pair is List && pair.length >= 2) {
            columns.add((pair[0].toString(), pair[1]));
          }
        }
      }
    }
    return Destination(
      name: (row['destination'] as String?) ?? '',
      continent: row['continent'] as String?,
      country: row['country'] as String?,
      visited: _truthy(row['visited']),
      favourite: _truthy(row['favourite']),
      toBeResearched: _truthy(row['to_be_researched']),
      prio: _toInt(row['prio']),
      safetyRating: _toDouble(row['safety_rating']),
      avgCostDay: _toDouble(row['avg_cost_day']),
      flightTimeFra: _toDouble(row['flight_time_fra']),
      comment: row['comment'] as String?,
      columns: columns,
    );
  }

  /// The value of one tail column (null when the
  /// destination has no such column).
  dynamic column(String name) {
    for (final (column, value) in columns) {
      if (column == name) return value;
    }
    return null;
  }

  /// A copy with one typed field and its tail entry
  /// replaced -- the read-modify-write the flag
  /// editors use, so the typed core and the tail
  /// never diverge.
  Destination withField(String field, dynamic value) {
    final columns = [
      for (final (column, old) in columns)
        (column, column == _coreColumn(field) ? value : old),
    ];
    return switch (field) {
      'favourite' => Destination(
          name: name, continent: continent, country: country,
          visited: visited, favourite: value as bool,
          toBeResearched: toBeResearched, prio: prio,
          safetyRating: safetyRating, avgCostDay: avgCostDay,
          flightTimeFra: flightTimeFra, comment: comment,
          columns: columns),
      'visited' => Destination(
          name: name, continent: continent, country: country,
          visited: value as bool, favourite: favourite,
          toBeResearched: toBeResearched, prio: prio,
          safetyRating: safetyRating, avgCostDay: avgCostDay,
          flightTimeFra: flightTimeFra, comment: comment,
          columns: columns),
      'to_be_researched' => Destination(
          name: name, continent: continent, country: country,
          visited: visited, favourite: favourite,
          toBeResearched: value as bool, prio: prio,
          safetyRating: safetyRating, avgCostDay: avgCostDay,
          flightTimeFra: flightTimeFra, comment: comment,
          columns: columns),
      'prio' => Destination(
          name: name, continent: continent, country: country,
          visited: visited, favourite: favourite,
          toBeResearched: toBeResearched, prio: value as int?,
          safetyRating: safetyRating, avgCostDay: avgCostDay,
          flightTimeFra: flightTimeFra, comment: comment,
          columns: columns),
      'comment' => Destination(
          name: name, continent: continent, country: country,
          visited: visited, favourite: favourite,
          toBeResearched: toBeResearched, prio: prio,
          safetyRating: safetyRating, avgCostDay: avgCostDay,
          flightTimeFra: flightTimeFra, comment: value as String?,
          columns: columns),
      _ => this,
    };
  }

  /// The typed-core field -> workbook column map,
  /// the same map `storage_turso.CORE_COLUMNS`
  /// keeps on the Python side.
  static const coreColumns = {
    'destination': 'Destination',
    'continent': 'Continent',
    'country': 'Country',
    'visited': 'Visited?',
    'favourite': 'In näherer Auswahl 2025?',
    'prio': 'Prio Thorsten',
    'safety_rating': 'Safety Rating (10 = safest)',
    'avg_cost_day': 'Avg. Cost/Day (3* Hotel & Food)',
    'flight_time_fra': 'Flight Time to Frankfurt (hours)',
    'to_be_researched': 'To be researched',
    'malaria_risk': 'Malaria risk?',
    'data_status': 'Data Status',
    'comment': 'Comment',
  };

  static String _coreColumn(String field) =>
      coreColumns[field] ?? field;

  /// The app's truthiness convention (True / "x" /
  /// "yes" / ...), stored as 0/1 in the database.
  static bool _truthy(dynamic value) {
    if (value is bool) return value;
    if (value is int) return value == 1;
    if (value is double) return value == 1;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'x' ||
        text == 'yes' ||
        text == 'y' ||
        text == 'ja' ||
        text == 'j' ||
        text == 'true' ||
        text == '1' ||
        text.contains('x');
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static double? _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value == null) return null;
    final text = value.toString().trim().replaceAll(',', '.');
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }
}
