/// Trip models, mirroring `itinerary/models.py` and
/// the `trips` / `variants` / `stops` / `legs` tables
/// `storage_turso.py` keeps.
///
/// `legs` is positional: `legs[i]` sits between
/// `stops[i]` and `stops[i+1]`.
library;

import 'dart:convert';

class StopRef {
  final String kind;
  final String name;
  final String? country;
  final double? lat;
  final double? lon;

  const StopRef({
    required this.kind,
    required this.name,
    this.country,
    this.lat,
    this.lon,
  });

  factory StopRef.fromRow(Map<String, dynamic> row) => StopRef(
        kind: (row['kind'] as String?) ?? 'custom',
        name: (row['name'] as String?) ?? 'Unnamed stop',
        country: row['country'] as String?,
        lat: (row['lat'] as num?)?.toDouble(),
        lon: (row['lon'] as num?)?.toDouble(),
      );

  /// The storage shape (`itinerary.models.make_ref`).
  Map<String, Object?> toJson() => {
        'kind': kind,
        'name': name,
        'country': country,
        'lat': lat,
        'lon': lon,
      };
}

class Stop {
  final String id;
  final StopRef ref;
  final String? arrivalDate;
  final String? departureDate;
  final String? arrivalTime;
  final String? departureTime;
  final int? nights;
  final String role;
  final String notes;

  const Stop({
    required this.id,
    required this.ref,
    this.arrivalDate,
    this.departureDate,
    this.arrivalTime,
    this.departureTime,
    this.nights,
    this.role = 'stop',
    this.notes = '',
  });

  factory Stop.fromRow(Map<String, dynamic> row) => Stop(
        id: (row['id'] as String?) ?? '',
        ref: StopRef.fromRow(row),
        arrivalDate: row['arrival_date'] as String?,
        departureDate: row['departure_date'] as String?,
        arrivalTime: row['arrival_time'] as String?,
        departureTime: row['departure_time'] as String?,
        nights: _asInt(row['nights']),
        role: (row['role'] as String?) ?? 'stop',
        notes: (row['notes'] as String?) ?? '',
      );

  /// The storage shape (`itinerary.models.make_stop`):
  /// the ref nested under `ref`, the dates and times
  /// as plain strings.
  Map<String, Object?> toJson() => {
        'id': id,
        'ref': ref.toJson(),
        'arrival_date': arrivalDate,
        'departure_date': departureDate,
        'arrival_time': arrivalTime,
        'departure_time': departureTime,
        'nights': nights,
        'role': role,
        'notes': notes,
      };
}

class Leg {
  final String mode;
  final String note;

  const Leg({required this.mode, this.note = ''});

  factory Leg.fromRow(Map<String, dynamic> row) => Leg(
        mode: (row['mode'] as String?) ?? 'flight',
        note: (row['note'] as String?) ?? '',
      );

  /// The storage shape (`itinerary.models.make_leg`).
  Map<String, Object?> toJson() => {'mode': mode, 'note': note};
}

class Variant {
  final String id;
  final String name;
  final String notes;
  final int? rating;
  final List<String> months;
  final String comment;
  final List<Stop> stops;
  final List<Leg> legs;

  const Variant({
    required this.id,
    required this.name,
    this.notes = '',
    this.rating,
    this.months = const [],
    this.comment = '',
    this.stops = const [],
    this.legs = const [],
  });

  factory Variant.fromRow(
    Map<String, dynamic> row, {
    required List<Stop> stops,
    required List<Leg> legs,
  }) {
    final months = <String>[];
    final raw = row['months'];
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecodeMayBeList(raw);
      months.addAll(decoded.whereType<String>());
    }
    return Variant(
      id: (row['id'] as String?) ?? '',
      name: (row['name'] as String?) ?? 'Variant',
      notes: (row['notes'] as String?) ?? '',
      rating: _asInt(row['rating']),
      months: months,
      comment: (row['comment'] as String?) ?? '',
      stops: stops,
      legs: legs,
    );
  }

  static List<dynamic> jsonDecodeMayBeList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : [];
    } catch (_) {
      return [];
    }
  }

  /// The storage shape (`itinerary.models.make_variant`):
  /// the months as the JSON list the `variants` table
  /// keeps, the stops and legs in their stored order.
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'notes': notes,
        'rating': rating,
        'months': months,
        'comment': comment,
        'stops': [for (final stop in stops) stop.toJson()],
        'legs': [for (final leg in legs) leg.toJson()],
      };
}

class Trip {
  final String id;
  final String name;
  final String? created;
  final String? activeVariantId;

  /// The `updated_at` the `trips` table stamped
  /// on the row this copy was loaded from -- the
  /// optimistic-concurrency signature (E10). Not
  /// part of the export shape: it is storage
  /// metadata, like the legacy's file signature.
  final String? updatedAt;
  final List<Variant> variants;

  const Trip({
    required this.id,
    required this.name,
    this.created,
    this.activeVariantId,
    this.updatedAt,
    this.variants = const [],
  });

  Variant? get activeVariant {
    for (final variant in variants) {
      if (variant.id == activeVariantId) return variant;
    }
    return variants.isEmpty ? null : variants.first;
  }

  /// The storage shape (`itinerary.models.make_trip`).
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'created': created,
        'active_variant_id': activeVariantId,
        'variants': [for (final variant in variants) variant.toJson()],
      };
}

/// A stored cell can hold a REAL or TEXT value
/// (SQLite's dynamic typing); an unchecked
/// `as int?` cast would throw and take the whole
/// trips list with it.
int? _asInt(Object? value) =>
    value is int ? value : value is num ? value.toInt() : null;
