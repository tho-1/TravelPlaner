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
import 'offline_cache.dart';

class DestinationRepository {
  final TursoClient client;

  /// The offline-first snapshot store (Phase 5, Option A);
  /// null keeps the online-only contract (and the tests).
  final OfflineCache? offline;

  DestinationRepository(this.client, {this.offline});

  /// All destinations, ordered by name. On a live-read
  /// failure the last successful snapshot is served, with
  /// its offline note -- never "no results" unexplained.
  Future<(List<Destination>, List<String>)> loadDestinations() async {
    final (results, problems) = await client
        .runPipeline(['SELECT * FROM destinations ORDER BY destination']);
    if (problems.isNotEmpty) return _offlineOrFailure(problems);
    if (results.isEmpty) return (<Destination>[], const <String>['no result']);
    final rows = results.first.asMaps;
    // Only a full read may write the snapshot (a one-row
    // read would overwrite the dataset with a fragment).
    offline?.save('destinations', [rows]);
    return (
      [for (final row in rows) Destination.fromRow(row)],
      const <String>[],
    );
  }

  (List<Destination>, List<String>) _offlineOrFailure(
    List<String> problems,
  ) {
    final snapshot = offline?.load('destinations');
    if (snapshot == null) return (<Destination>[], problems);
    return (
      [
        for (final row in snapshot.tables.single) Destination.fromRow(row),
      ],
      offlineNote('destination catalogue', problems.first, snapshot.savedAt),
    );
  }

  /// One destination by exact name. `(null, [])` means
  /// "no such destination", `(null, problems)` means the
  /// read failed -- never conflate the two. Offline, the
  /// snapshot answers what it holds and clearly labels
  /// everything else as "unknown offline", never as "does
  /// not exist".
  Future<(Destination?, List<String>)> getDestination(String name) async {
    final (List<Map<String, dynamic>> rows, List<String> problems) =
        await client.query(
      'SELECT * FROM destinations WHERE destination = '
      "'${_escape(name)}'",
    );
    if (problems.isNotEmpty) return _offlineOne(name, problems);
    if (rows.isEmpty) return (null, const <String>[]);
    return (Destination.fromRow(rows.first), const <String>[]);
  }

  Future<(Destination?, List<String>)> _offlineOne(
    String name,
    List<String> problems,
  ) async {
    final snapshot = offline?.load('destinations');
    if (snapshot == null) return (null, problems);
    final rows = [
      for (final row in snapshot.tables.single)
        if (row['destination'] == name) row,
    ];
    final note = offlineNote('destination catalogue', problems.first,
        snapshot.savedAt);
    return rows.isEmpty
        // "Unknown offline" -- distinguishable from the live
        // "(null, [])" that genuinely means "does not exist".
        ? (null, [...note, '$name is not in the offline snapshot'])
        : (Destination.fromRow(rows.first), note);
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

  /// Append a new placeholder destination
  /// (`repository.add_new_destination`'s Turso branch):
  /// the same core fields, the same "PLACEHOLDER - UPDATE
  /// REQUIRED" status and the same tail. A duplicate name
  /// is refused, not overwritten.
  Future<bool> addDestination({
    required String name,
    String country = 'Unknown',
    String continent = 'Unknown',
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final (existing, problems) = await getDestination(trimmed);
    if (problems.isNotEmpty || existing != null) return false;
    final destination = Destination(
      core: {
        'destination': trimmed,
        'continent': continent,
        'country': country,
        'visited': false,
        'favourite': false,
        'prio': null,
        'safety_rating': null,
        'avg_cost_day': null,
        'flight_time_fra': null,
        'to_be_researched': true,
        'malaria_risk': false,
        'data_status': 'PLACEHOLDER - UPDATE REQUIRED',
        'comment': null,
      },
      columns: [
        ('Destination', trimmed),
        ('Continent', continent),
        ('Country', country),
        ('Data Status', 'PLACEHOLDER - UPDATE REQUIRED'),
        ('To be researched', true),
      ],
    );
    return saveDestination(destination);
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
