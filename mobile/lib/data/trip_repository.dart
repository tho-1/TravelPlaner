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
///   request** (atomic); a variant's stops and legs are
///   deleted and re-inserted so the stored order always
///   matches the in-memory order (`legs[i]` sits between
///   `stops[i]` and `stops[i+1]`).
/// * `false` means nothing was written -- surface it.
library;

import 'dart:convert';
import 'dart:math';

import '../models/trip.dart';
import '../turso/pipeline_client.dart';

// storage_turso.py keeps one _utcnow for both the trip and
// the destination writers; the Dart mirror does the same.
import 'destination_repository.dart' show utcNow;

class TripRepository {
  final TursoClient client;

  final Random _random = Random();

  TripRepository(this.client);

  /// All trips with their variants, stops and legs.
  Future<(List<Trip>, List<String>)> loadTrips() async {
    final (results, List<String> problems) = await client.runPipeline([
      'SELECT * FROM trips ORDER BY created',
      'SELECT * FROM variants ORDER BY trip_id, rowid',
      'SELECT * FROM stops ORDER BY variant_id, position',
      'SELECT * FROM legs ORDER BY variant_id, position',
    ]);
    if (problems.isNotEmpty) return (<Trip>[], problems);
    if (results.length < 4) {
      return (<Trip>[], const <String>['incomplete pipeline result']);
    }
    final variantsByTrip = _groupBy(results[1].asMaps, 'trip_id');
    final stopsByVariant = _groupBy(results[2].asMaps, 'variant_id');
    final legsByVariant = _groupBy(results[3].asMaps, 'variant_id');

    final trips = <Trip>[];
    for (final row in results[0].asMaps) {
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
        variants: variants,
      ));
    }
    return (trips, const <String>[]);
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
  Future<bool> saveTrip(Trip trip) async {
    final tripId = trip.id;
    if (tripId.isEmpty) return false;
    final now = utcNow();
    final statements = <String>[
      'INSERT INTO trips (id, name, created, active_variant_id, '
          'updated_at) VALUES ('
          '${_sqlValue(tripId)}, ${_sqlValue(trip.name)}, '
          '${_sqlValue(trip.created)}, '
          '${_sqlValue(trip.activeVariantId)}, ${_sqlValue(now)}) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          'created = excluded.created, '
          'active_variant_id = excluded.active_variant_id, '
          'updated_at = excluded.updated_at',
    ];
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
    final (_, problems) = await client.runPipeline(statements);
    return problems.isEmpty;
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
