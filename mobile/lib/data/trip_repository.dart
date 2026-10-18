/// Trips on Turso -- the Dart mirror of
/// `storage_turso.py`'s trip functions.
///
/// The contract that must not drift:
///
/// * `loadTrips` reads the four tables in **one pipeline
///   request** and groups them in Dart (trips -> variants
///   -> stops/legs); a failed read returns an empty list
///   *with* problems, never an ambiguous empty list.
/// * `saveTrip` writes the whole trip in **one pipeline
///   request**. A mid-batch failure is surfaced as `failed`
///   and may leave a partially replaced variant list, stops
///   or legs. That is a known limit, not an oversight --
///   verified against the live endpoint 2026-10-18:
///   `BEGIN`/`COMMIT` do run, but the server keeps going
///   after an error (`ok, error, ok`), so a trailing `COMMIT`
///   would make the partial write *durable*; the conditional
///   `batch` steps are rejected (400, "missing field `stmt`")
///   and `on_error: rollback` is accepted but ignored (the
///   `COMMIT` still executes). A test pins that this method
///   never sends a transaction -- re-probe before adding one.
///   a variant's stops and legs are deleted and re-inserted
///   so the stored order always matches the in-memory order
///   (`legs[i]` sits between `stops[i]` and `stops[i+1]`).
/// * `false` means nothing was written -- surface it.
library;

import 'dart:convert';
import 'dart:math';

import '../models/pending_write.dart';
import '../models/trip.dart';
import '../turso/pipeline_client.dart';

// storage_turso.py keeps one _utcnow for both the trip and
// the destination writers; the Dart mirror does the same.
import 'destination_repository.dart' show utcNow;
import 'offline_cache.dart';
import 'write_journal.dart';

/// The outcome of one trip save.
///
/// `conflict` is the Turso-world
/// `TripsFileChanged`: another session saved the
/// trip after this copy was loaded, so the write
/// was refused instead of silently discarding the
/// other edit (AGENTS.md rule 3 -- a failed
/// write is never reported as success).
///
/// `queued` is offline-first Phase 5: nothing reached
/// the database and the write is in the journal,
/// waiting. It is *not* `saved` -- the caller must not
/// say the trip was saved, only that it will be.
enum TripSaveStatus { saved, failed, conflict, queued }

class TripRepository {
  final TursoClient client;

  /// The offline-first snapshot store (Phase 5, Option A);
  /// null keeps the online-only contract (and the tests).
  final OfflineCache? offline;

  /// The offline write queue (Phase 5, commit 2); null keeps
  /// the online-only contract (and the tests).
  final WriteJournal? journal;

  final Random _random = Random();

  TripRepository(this.client, {this.offline, this.journal});


  /// All trips with their variants, stops and legs. On a
  /// live-read failure the last successful snapshot is
  /// served, labelled, never silently.
  Future<(List<Trip>, List<String>)> loadTrips() async {
    final (List<StatementResult> results, List<String> problems) =
        await client.runPipeline([
      'SELECT * FROM trips ORDER BY created',
      'SELECT * FROM variants ORDER BY trip_id, rowid',
      'SELECT * FROM stops ORDER BY variant_id, position',
      'SELECT * FROM legs ORDER BY variant_id, position',
    ]);
    if (problems.isNotEmpty) return _offlineOrFailure(problems);
    if (results.length < 4) {
      return (<Trip>[], const <String>['incomplete pipeline result']);
    }
    // Only a full read may write the snapshot.
    offline?.save('trips', [
      results[0].asMaps,
      results[1].asMaps,
      results[2].asMaps,
      results[3].asMaps,
    ]);
    return (
      tripsFromTables([
        results[0].asMaps,
        results[1].asMaps,
        results[2].asMaps,
        results[3].asMaps,
      ]),
      const <String>[],
    );
  }

  (List<Trip>, List<String>) _offlineOrFailure(
    List<String> problems,
  ) {
    final snapshot = offline?.load('trips');
    if (snapshot == null || snapshot.tables.length < 4) {
      return (<Trip>[], problems);
    }
    return (
      tripsFromTables(snapshot.tables.take(4).toList()),
      offlineNote('trips', problems.first, snapshot.savedAt),
    );
  }

  /// The read's second half, shared by the live path and
  /// the snapshot path so both can never drift apart: four
  /// row lists (trips, variants, stops, legs) in one model.
  static List<Trip> tripsFromTables(
    List<List<Map<String, Object?>>> tables,
  ) {
    final variantsByTrip = _groupBy(tables[1], 'trip_id');
    final stopsByVariant = _groupBy(tables[2], 'variant_id');
    final legsByVariant = _groupBy(tables[3], 'variant_id');

    final trips = <Trip>[];
    for (final row in tables[0]) {
      final tripId = row['id'] as String? ?? '';
      final variants = <Variant>[];
      for (final variantRow in variantsByTrip[tripId] ?? const []) {
        final variantId = variantRow['id'] as String? ?? '';
        final stops = [
          for (final stop in stopsByVariant[variantId] ?? const [])
            Stop.fromRow(stop),
        ];
        final legs = [
          for (final leg in legsByVariant[variantId] ?? const [])
            Leg.fromRow(leg),
        ];
        variants.add(Variant.fromRow(variantRow, stops: stops, legs: legs));
      }
      trips.add(Trip(
        id: tripId,
        name: row['name'] as String? ?? 'Untitled trip',
        created: row['created'] as String?,
        activeVariantId: row['active_variant_id'] as String?,
        updatedAt: row['updated_at'] as String?,
        variants: variants,
      ));
    }
    return trips;
  }

  static Map<String, List<Map<String, Object?>>> _groupBy(
    List<Map<String, Object?>> rows,
    String key,
  ) {
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      grouped.putIfAbsent(
        row[key] as String? ?? '',
        () => [],
      ).add(row);
    }
    return grouped;
  }

  /// Upsert one trip and all its variants, stops and legs
  /// (`storage_turso.save_trip`). Stops without an id get
  /// one, in the `stop-<10 hex>` shape `itinerary.models`
  /// generates -- the stops table's primary key needs it.
  ///
  /// The optimistic-concurrency guard (E10): the trip's
  /// `updated_at` is compared with the live row, exactly
  /// like the legacy compares the trips.json signature at
  /// save time (`storage._assert_not_stale`). A trip
  /// another session saved since this copy was loaded is
  /// never overwritten silently -- the caller offers
  /// "Reload latest data" instead.
  ///
  /// The comparison and the write are one statement: the
  /// upsert's `WHERE trips.updated_at = ...` turns the
  /// update into a no-op (zero affected rows) when another
  /// device saved in between, which a separate check and
  /// write cannot guarantee -- a save could land between
  /// the two requests. The variant statements run only
  /// after the trip row is confirmed written, so a
  /// conflict never deletes and re-inserts the variants.
  Future<TripSaveStatus> saveTrip(Trip trip) async {
    final tripId = trip.id;
    if (tripId.isEmpty) return TripSaveStatus.failed;
    final now = utcNow();
    // `= NULL` never matches in SQL: a copy that saw no
    // stamp (a row saved before the column existed) must
    // compare with IS, or its every save would be a
    // false conflict.
    final expectedStamp = trip.updatedAt == null
        ? 'WHERE trips.updated_at IS NULL'
        : 'WHERE trips.updated_at = ${_sqlValue(trip.updatedAt)}';
    final upsert = 'INSERT INTO trips (id, name, created, active_variant_id, '
        'updated_at) VALUES ('
        '${_sqlValue(tripId)}, ${_sqlValue(trip.name)}, '
        '${_sqlValue(trip.created)}, '
        '${_sqlValue(trip.activeVariantId)}, ${_sqlValue(now)}) '
        'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
        'active_variant_id = excluded.active_variant_id, '
        'updated_at = excluded.updated_at '
        // The creation date is never rewritten: a copy
        // without one (an older export) must not NULL
        // the stored date.
        '$expectedStamp';
    final statements = _variantStatements(trip, tripId, now);
    final (upserts, upsertProblems) = await client.runPipeline([upsert]);
    if (upsertProblems.isNotEmpty) {
      // Offline: nothing reached the database, so the whole
      // write -- guard and all -- can be replayed later.
      if (_queue(upsert, statements, trip, upsertProblems)) {
        return TripSaveStatus.queued;
      }
      return TripSaveStatus.failed;
    }
    // Zero affected rows: the trip changed since this copy
    // was loaded (or the stored updated_at is unknown to
    // this copy) -- another device's write wins and the
    // caller offers a reload.
    if (upserts.first.rowsAffected == 0) {
      return TripSaveStatus.conflict;
    }
    if (statements.isEmpty) return TripSaveStatus.saved;
    final (_, problems) = await client.runPipeline(statements);
    // Not queued: the trip row already landed, so replaying
    // would either fight its own new stamp (a false conflict)
    // or duplicate half a variant list. A failure here is
    // surfaced so the caller reloads before retrying.
    return problems.isNotEmpty ? TripSaveStatus.failed : TripSaveStatus.saved;
  }

  /// Queue the whole trip write when the upsert failed for
  /// transport reasons only. Returns whether it is queued;
  /// false means the caller must report the failure.
  bool _queue(
    String upsert,
    List<String> statements,
    Trip trip,
    List<String> problems,
  ) {
    final journal = this.journal;
    if (journal == null || !problems.every(offlineProblem)) return false;
    return journal.enqueue(PendingWrite(
      key: 'trip:${trip.id}',
      label: 'trip “${trip.name}”',
      statements: [upsert, ...statements],
      guardFirst: true,
      at: utcNow(),
    ));
  }

  /// The variant, stop and leg statements of one trip save.
  List<String> _variantStatements(Trip trip, String tripId, String now) {
    final statements = <String>[];
    for (final variant in trip.variants) {
      final variantId = variant.id;
      if (variantId.isEmpty) continue;
      statements.add(
        'INSERT INTO variants (id, trip_id, name, notes, rating, '
        'months, comment, updated_at) VALUES ('
        '${_sqlValue(variantId)}, ${_sqlValue(tripId)}, '
        '${_sqlValue(variant.name)}, ${_sqlValue(variant.notes)}, '
        '${_sqlValue(variant.rating)}, '
        '${_sqlValue(jsonEncodeList(variant.months))}, '
        '${_sqlValue(variant.comment)}, ${_sqlValue(now)}) '
        'ON CONFLICT(id) DO UPDATE SET trip_id = excluded.trip_id, '
        'name = excluded.name, notes = excluded.notes, '
        'rating = excluded.rating, months = excluded.months, '
        'comment = excluded.comment, updated_at = excluded.updated_at',
      );
      // Replace this variant's stops and legs so the stored
      // order always matches the in-memory order.
      statements.add(
        'DELETE FROM stops WHERE variant_id = ${_sqlValue(variantId)}',
      );
      statements.add(
        'DELETE FROM legs WHERE variant_id = ${_sqlValue(variantId)}',
      );
      var position = 0;
      for (final stop in variant.stops) {
        statements.add(
          'INSERT INTO stops (id, variant_id, position, kind, name, '
          'country, lat, lon, role, arrival_date, departure_date, '
          'arrival_time, departure_time, nights, notes, updated_at) '
          'VALUES ('
          '${_sqlValue(stop.id.isEmpty ? _newId('stop') : stop.id)}, '
          '${_sqlValue(variantId)}, $position, '
          '${_sqlValue(stop.ref.kind)}, ${_sqlValue(stop.ref.name)}, '
          '${_sqlValue(stop.ref.country)}, ${_sqlValue(stop.ref.lat)}, '
          '${_sqlValue(stop.ref.lon)}, ${_sqlValue(stop.role)}, '
          '${_sqlValue(stop.arrivalDate)}, ${_sqlValue(stop.departureDate)}, '
          '${_sqlValue(stop.arrivalTime)}, ${_sqlValue(stop.departureTime)}, '
          '${_sqlValue(stop.nights)}, ${_sqlValue(stop.notes)}, '
          '${_sqlValue(now)})',
        );
        position++;
      }
      position = 0;
      for (final leg in variant.legs) {
        statements.add(
          'INSERT INTO legs (variant_id, position, mode, note, '
          'updated_at) VALUES ('
          '${_sqlValue(variantId)}, $position, ${_sqlValue(leg.mode)}, '
          '${_sqlValue(leg.note)}, ${_sqlValue(now)})',
        );
        position++;
      }
    }
    return statements;
  }

  /// Delete a trip and its variants, stops and legs
  /// (`storage_turso.delete_trip`).
  Future<bool> deleteTrip(String tripId) async {
    final safe = _sqlValue(tripId);
    final (_, problems) = await client.runPipeline([
      'DELETE FROM legs WHERE variant_id IN '
          '(SELECT id FROM variants WHERE trip_id = $safe)',
      'DELETE FROM stops WHERE variant_id IN '
          '(SELECT id FROM variants WHERE trip_id = $safe)',
      'DELETE FROM variants WHERE trip_id = $safe',
      'DELETE FROM trips WHERE id = $safe',
    ]);
    return problems.isEmpty;
  }

  /// `itinerary.models.new_id`'s shape: `<prefix>-<10 hex>`.
  String _newId(String prefix) => '$prefix-${[
    for (var i = 0; i < 5; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join()}';
}

String _sqlValue(Object? value) {
  if (value == null) return 'NULL';
  if (value is bool) return value ? '1' : '0';
  if (value is num) return value.toString();
  final text = value.toString().replaceAll("'", "''");
  return "'$text'";
}

/// The months list as the JSON array the `variants` table
/// keeps (Python's `json.dumps(variant.get('months') or [])`).
String jsonEncodeList(List<String> values) => jsonEncode(values);
