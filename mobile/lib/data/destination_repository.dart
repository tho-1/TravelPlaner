/// Destinations on Turso -- the Dart mirror of
/// `storage_turso.py` plus `repository.py`'s write helpers.
///
/// The contract that must not drift:
///
/// * A failed read returns an empty list *with* problems;
///   an empty list without problems means the database is
///   genuinely empty. Never let a "no results" answer be
///   ambiguous.
/// * A failed write returns `false` -- surface it, never
///   report it as success.
/// * Every field edit is a **read-modify-write** that
///   updates the typed core *and* the lossless `data`
///   tail (`repository._set_field` on the Python side).
///   A targeted UPDATE that only touches the typed
///   column would leave the tail stale, and every other
///   reader -- the API, the HTML frontend, the workbook
///   export -- sees the old value.
library;

import 'dart:convert';

import '../models/destination.dart';
import '../turso/pipeline_client.dart';

class DestinationRepository {
  final TursoClient client;

  DestinationRepository(this.client);

  /// All destinations, ordered by name.
  Future<(List<Destination>, List<String>)> loadDestinations() async {
    final (results, problems) = await client
        .runPipeline(['SELECT * FROM destinations ORDER BY destination']);
    if (problems.isNotEmpty) return (<Destination>[], problems);
    if (results.isEmpty) return (<Destination>[], const <String>['no result']);
    return (
      [for (final row in results.first.asMaps) Destination.fromRow(row)],
      const <String>[],
    );
  }

  /// One destination by exact name. `(null, [])` means
  /// "no such destination", `(null, problems)` means the
  /// read failed -- never conflate the two.
  Future<(Destination?, List<String>)> getDestination(String name) async {
    final (List<Map<String, dynamic>> rows, List<String> problems) =
        await client.query(
      'SELECT * FROM destinations WHERE destination = '
      "'${_escape(name)}'",
    );
    if (problems.isNotEmpty) return (null, problems);
    if (rows.isEmpty) return (null, const <String>[]);
    return (Destination.fromRow(rows.first), const <String>[]);
  }

  /// Read-modify-write one field of one destination
  /// (`repository._modify_destination`). `false` means
  /// nothing was written: the destination is unknown or
  /// the write failed.
  Future<bool> updateField(String name, String field, Object? value) async {
    final (dest, problems) = await getDestination(name);
    if (problems.isNotEmpty || dest == null) return false;
    return saveDestination(dest.withField(field, value));
  }

  /// Upsert one destination (`storage_turso.save_destination`):
  /// the typed core, the JSON tail and `updated_at` in one
  /// statement, so a save round-trips losslessly.
  Future<bool> saveDestination(Destination dest) async {
    final problems = await client.execute(_upsertSql(dest));
    return problems.isEmpty;
  }

  String _upsertSql(Destination dest) {
    // Render each field like storage_turso._destination_to_params:
    // booleans as 0/1, the numeric fields coerced to a number,
    // prio and the text fields as (possibly empty) text.
    String t(String field) => _sqlValue(Destination.text(dest.core[field]));
    String b(String field) =>
        Destination.truthy(dest.core[field]) ? '1' : '0';
    String n(String field) => _sqlValue(_number(dest.core[field]));
    return 'INSERT INTO destinations ('
        'destination, continent, country, visited, favourite, prio, '
        'safety_rating, avg_cost_day, flight_time_fra, '
        'to_be_researched, malaria_risk, data_status, comment, '
        'data, updated_at) VALUES ('
        "${_sqlValue(dest.name.isEmpty ? '' : dest.name)}, "
        "${t('continent')}, ${t('country')}, "
        "${b('visited')}, ${b('favourite')}, ${t('prio')}, "
        "${n('safety_rating')}, ${n('avg_cost_day')}, "
        "${n('flight_time_fra')}, "
        "${b('to_be_researched')}, ${b('malaria_risk')}, "
        "${t('data_status')}, ${t('comment')}, "
        '${_sqlValue(_tailJson(dest))}, ${_sqlValue(utcNow())} '
        ') ON CONFLICT(destination) DO UPDATE SET '
        'continent = excluded.continent, country = excluded.country, '
        'visited = excluded.visited, favourite = excluded.favourite, '
        'prio = excluded.prio, safety_rating = excluded.safety_rating, '
        'avg_cost_day = excluded.avg_cost_day, '
        'flight_time_fra = excluded.flight_time_fra, '
        'to_be_researched = excluded.to_be_researched, '
        'malaria_risk = excluded.malaria_risk, '
        'data_status = excluded.data_status, comment = excluded.comment, '
        'data = excluded.data, updated_at = excluded.updated_at';
  }

  /// The tail as the ordered `[name, value]` JSON array
  /// `storage_turso` keeps. Built from the destination's
  /// columns, which `withField` already kept in sync.
  String _tailJson(Destination dest) => jsonEncode([
        for (final (name, value) in dest.columns) [name, value],
      ]);
}

String _escape(String value) => value.replaceAll("'", "''");

/// A SQL literal, NULL-safe (`storage_turso._sql_value`).
String _sqlValue(Object? value) {
  if (value == null) return 'NULL';
  if (value is bool) return value ? '1' : '0';
  if (value is num) return value.toString();
  return "'${_escape(value.toString())}'";
}

/// Coerce a cell to a number or null (`storage_turso._number`).
Object? _number(Object? value) {
  if (value == null) return null;
  if (value is bool) return null;
  if (value is num) return value;
  final raw = value.toString().trim().replaceAll(',', '.');
  if (raw.isEmpty) return null;
  return int.tryParse(raw) ?? double.tryParse(raw);
}

/// UTC ISO with second precision, the `updated_at` shape
/// every Python writer uses.
String utcNow() {
  final now = DateTime.now().toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-'
      '${two(now.month)}-${two(now.day)}T'
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}+00:00';
}
