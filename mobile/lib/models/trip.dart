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
        nights: (row['nights'] as int?),
        role: (row['role'] as String?) ?? 'stop',
        notes: (row['notes'] as String?) ?? '',
      );
}

class Leg {
  final String mode;
  final String note;

  const Leg({required this.mode, this.note = ''});

  factory Leg.fromRow(Map<String, dynamic> row) => Leg(
        mode: (row['mode'] as String?) ?? 'flight',
        note: (row['note'] as String?) ?? '',
      );
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
      rating: (row['rating'] as int?),
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
}

class Trip {
  final String id;
  final String name;
  final String? created;
  final String? activeVariantId;
  final List<Variant> variants;

  const Trip({
    required this.id,
    required this.name,
    this.created,
    this.activeVariantId,
    this.variants = const [],
  });

  Variant? get activeVariant {
    for (final variant in variants) {
      if (variant.id == activeVariantId) return variant;
    }
    return variants.isEmpty ? null : variants.first;
  }
}
