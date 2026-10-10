/// One destination: the raw typed core the app filters
/// and sorts on, plus the lossless column tail.
///
/// The workbook has 145 columns including duplicate
/// names and object-typed cells, so a flat typed model
/// would be brittle and would drop data; the raw core
/// map keeps every typed field exactly as the row
/// carries it -- `Prio Thorsten` really holds ints, a
/// float and strings like "n/a" -- and the tail
/// preserves every column. Typed getters parse only
/// for display. This is the same lossless contract
/// `storage_turso.py` keeps on the Python side.
library;

import 'dart:convert';

class Destination {
  /// Raw typed-core values keyed by the CORE_COLUMNS
  /// field names ('destination', 'continent', ...),
  /// exactly as the row carries them.
  final Map<String, Object?> core;

  /// Every workbook column as an ordered
  /// `(column, value)` list -- lossless.
  final List<(String, Object?)> columns;

  const Destination({required this.core, this.columns = const []});

  /// A `destinations` table row (typed core + `data`
  /// JSON tail), the shape `storage_turso.load_destinations`
  /// returns.
  factory Destination.fromRow(Map<String, Object?> row) {
    final core = <String, Object?>{
      for (final field in coreColumns.keys) field: row[field],
    };
    final columns = <(String, Object?)>[];
    final raw = row['data'];
    if (raw is String && raw.isNotEmpty) {
      final decoded = _decodeMayFail(raw);
      if (decoded is List) {
        for (final pair in decoded) {
          if (pair is List && pair.length >= 2) {
            columns.add((pair[0].toString(), pair[1]));
          }
        }
      }
    }
    return Destination(core: core, columns: columns);
  }

  static Object? _decodeMayFail(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  String get name => text(core['destination']) ?? '';
  String? get continent => text(core['continent']);
  String? get country => text(core['country']);
  bool get visited => truthy(core['visited']);
  bool get favourite => truthy(core['favourite']);
  bool get toBeResearched => truthy(core['to_be_researched']);

  /// The raw prio. Never normalise it into the field:
  /// a read-modify-write that parses "n/a" to null
  /// would write NULL over the real value.
  Object? get prio => core['prio'];

  /// Prio as a number, for display and sorting only.
  int? get prioInt => toInt(core['prio']);
  double? get safetyRating => toDouble(core['safety_rating']);
  double? get avgCostDay => toDouble(core['avg_cost_day']);
  double? get flightTimeFra => toDouble(core['flight_time_fra']);
  bool get malariaRisk => truthy(core['malaria_risk']);
  String? get dataStatus => text(core['data_status']);
  String? get comment => text(core['comment']);

  /// The value of one tail column (null when the
  /// destination has no such column).
  Object? column(String name) {
    for (final (entry, value) in columns) {
      if (entry == name) return value;
    }
    return null;
  }

  /// A copy with one typed-core field and its tail
  /// entry replaced -- the read-modify-write the flag
  /// editors use, so the typed core and the tail
  /// never diverge. A missing tail entry is appended,
  /// exactly what `repository._set_field` does. Unknown
  /// fields are ignored -- the same strictness
  /// `storage_turso.CORE_COLUMNS` has.
  Destination withField(String field, Object? value) {
    final column = coreColumns[field];
    if (column == null) return this;
    final core = {...this.core, field: value};
    final columns = [...this.columns];
    final index = columns.indexWhere((entry) => entry.$1 == column);
    if (index >= 0) {
      columns[index] = (column, value);
    } else {
      columns.add((column, value));
    }
    return Destination(core: core, columns: columns);
  }

  /// The typed-core field -> workbook column map,
  /// the same map `storage_turso.CORE_COLUMNS`
  /// keeps on the Python side.
  static const Map<String, String> coreColumns = {
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

  /// The app's truthiness convention (True / "x" /
  /// "yes" / ...), stored as 0/1 in the database.
  static bool truthy(Object? value) {
    if (value is bool) return value;
    if (value is num) return value == 1;
    final raw = value?.toString().trim().toLowerCase() ?? '';
    return raw == 'x' ||
        raw == 'yes' ||
        raw == 'y' ||
        raw == 'ja' ||
        raw == 'j' ||
        raw == 'true' ||
        raw == '1' ||
        raw.contains('x');
  }

  /// The text convention: null when blank, otherwise
  /// the value as text (numbers occur in text columns).
  static String? text(Object? value) {
    if (value == null) return null;
    final raw = value.toString();
    return raw.isEmpty ? null : raw;
  }

  static int? toInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static double? toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value == null) return null;
    final raw = value.toString().trim().replaceAll(',', '.');
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }
}
