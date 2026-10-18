/// Write-side of the shared FlightRoutes schedule cache.
///
/// Travel Planner feeds the full-day boards its finder pulls
/// (Fraport departures) back into the sibling project's
/// Turso database, in the sibling's own format and with the
/// sibling's own upsert statements: their desktop and phone
/// apps pull the whole `schedule_boards` table on the next
/// sync, so rows written here are adopted transparently.
///
/// The two statements mirror `utils/sync.py` byte for byte,
/// with one deliberate difference: both keep the conditional
/// form (`WHERE excluded.updated_at >`). The sibling strips
/// it when pushing because a pull has just shown their row is
/// older; Travel Planner races their apps on live rows and
/// cannot know that, so a stale write must lose, not win.
/// Last-write-wins with `updated_at` as the tiebreaker is the
/// contract both sides already share.
library;

import 'dart:convert';

import '../turso/pipeline_client.dart';

class FlightRoutesScheduleWriter {
  final TursoClient client;

  /// Injectable clock -- `updated_at` is the sync
  /// tiebreaker, so tests must be able to freeze it.
  final DateTime Function() now;

  const FlightRoutesScheduleWriter(this.client, {DateTime Function()? now})
      : now = now ?? DateTime.now;

  static const _boardUpsert = 'INSERT INTO schedule_boards '
      '(iata, day, payload, updated_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(iata, day) DO UPDATE SET '
      'payload = excluded.payload, updated_at = excluded.updated_at '
      'WHERE excluded.updated_at > schedule_boards.updated_at';

  static const _provUpsert = 'INSERT INTO schedule_provenance '
      '(key, source, obtained_at, n_flights, updated_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET '
      'source = excluded.source, obtained_at = excluded.obtained_at, '
      'n_flights = excluded.n_flights, '
      'updated_at = excluded.updated_at '
      'WHERE excluded.updated_at > schedule_provenance.updated_at';

  /// Write one complete airport-day board plus its
  /// provenance row: first a stamp read, then both upserts.
  ///
  /// Guards before anything travels: the payload must *be* a
  /// full v2 board -- v2 schema, no `coverage`, and a
  /// non-empty flight list whose length matches
  /// `n_flights`. A partial or malformed payload is never
  /// dressed up as a complete board (the one thing that could
  /// poison the readers on both sides).
  ///
  /// The live pipeline does not report `rows_affected` for
  /// DML (verified 2026-10-18), so "the remote is newer"
  /// cannot be inferred from the upsert result. The write
  /// decision follows their own sync protocol instead: read
  /// the remote board's stamp first, and only write when this
  /// stamp is at least as new. The conditional upserts stay
  /// for the race the read cannot close.
  ///
  /// Returns the problems (empty = the request ran), plus
  /// `wrote`: false when the remote kept its newer row or the
  /// write failed.
  Future<(bool wrote, List<String> problems)> writeBoard({
    required String airport,
    required String day,
    required Map<String, Object?> payload,
  }) async {
    final problems = <String>[];
    final meta = payload['meta'];
    if (meta is! Map) {
      problems.add('the payload has no meta object');
      return (false, problems);
    }
    final flights = payload['flights'];
    if (flights is! List || flights.isEmpty) {
      problems.add('the payload has no flights -- an empty, zero-flight '
          'board is never written');
      return (false, problems);
    }
    final nFlights = flights.length;
    if (meta['schema_version'] != 2) {
      problems.add('only schema-v2 boards are written '
          '(schema_version: ${meta['schema_version']})');
      return (false, problems);
    }
    if (meta['coverage'] != null) {
      problems.add('a board with a coverage window is partial and is '
          'never written as a full day');
      return (false, problems);
    }
    if (meta['airport'] != airport.toUpperCase() ||
        meta['date'] != day ||
        (meta['n_flights'] is int ? meta['n_flights'] : -1) != nFlights) {
      problems.add('the payload meta does not match the written key '
          '(meta airport ${meta['airport']} / date ${meta['date']} / '
          'n_flights ${meta['n_flights']} vs $nFlights)');
      return (false, problems);
    }
    // The stamp read interpolates the key into its WHERE, so
    // the key shape is part of the contract, like the
    // reader's own loadBoards validation.
    if (!RegExp(r'^[A-Z0-9]{3,4}$').hasMatch(airport.toUpperCase()) ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
      problems.add('the board key must be an IATA code and an ISO date');
      return (false, problems);
    }

    final stamp = _utcSecondsStamp();
    final remote = await _remoteStamp(airport, day);
    if (remote.problems.isNotEmpty) {
      return (false, remote.problems);
    }
    if (remote.boardStamp != null && !_newerStamp(remote.boardStamp!, stamp)) {
      // Last-write-wins keeping the better copy: their apps
      // wrote that row more recently, so this fetch is
      // already outdated. That is not a failure -- the share
      // simply says so.
      return (false, const <String>[]);
    }

    final obtainedAt = '${meta['obtained_at'] ?? ''}';
    final key = '${airport.toUpperCase()}|$day';
    final (results, requestProblems) = await client.runPipeline(
      [_boardUpsert, _provUpsert],
      args: [
        [airport.toUpperCase(), day, jsonEncode(payload), stamp],
        // key, source, obtained_at, n_flights, updated_at --
        // n_flights travels string-encoded (the protocol's
        // exactness rule for i64).
        [key, meta['source'].toString(), obtainedAt, nFlights, stamp],
      ],
    );
    if (requestProblems.isNotEmpty) {
      return (false, requestProblems);
    }
    // No rows_affected from the live pipeline (see above) --
    // the stamp read was the decision; the upserts' ok-ness
    // carries the outcome.
    return (results.isNotEmpty, const <String>[]);
  }

  /// The remote board row's `updated_at` for this (iata,
  /// day), or null when the row does not exist. The
  /// provenance stamp is not fetched: it is written from the
  /// same payload and the flight-data freshness is decided
  /// per the board.
  Future<({String? boardStamp, List<String> problems})> _remoteStamp(
    String airport,
    String day,
  ) async {
    final (results, problems) = await client.query(
      'SELECT updated_at FROM schedule_boards '
      "WHERE iata = '${airport.toUpperCase()}' AND day = '$day'",
    );
    if (problems.isNotEmpty) {
      return (boardStamp: null, problems: problems);
    }
    final stamp =
        results.isEmpty || results.first['updated_at'] == null
            ? null
            : results.first['updated_at'].toString();
    return (boardStamp: stamp, problems: const <String>[]);
  }

  /// Their sync's LWW comparison at Dart precision: an
  /// unparseable stamp falls back to the string comparison
  /// SQLite's own `WHERE` performs on the same two texts.
  /// True when `local` is strictly newer than `remote`.
  bool _newerStamp(String remote, String local) {
    final parsed = DateTime.tryParse(remote);
    final fresh = DateTime.tryParse(local);
    if (parsed != null && fresh != null) {
      return fresh.isAfter(parsed);
    }
    return local.compareTo(remote) > 0;
  }

  /// The `updated_at` stamp the sibling's `db.now_iso()`
  /// produces: UTC to second precision with an explicit
  /// '+00:00' offset. Stamp comparisons in their sync parse
  /// stamps, but the format itself is the contract.
  String _utcSecondsStamp() =>
      '${now().toUtc().toIso8601String().substring(0, 19)}+00:00';
}
