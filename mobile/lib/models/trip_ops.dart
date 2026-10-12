/// Pure trip / variant / stop operations -- the Dart
/// port of `itinerary/itinerary.py` and the builders
/// of `itinerary/models.py`.
///
/// The legacy mutates plain dicts in place; the Dart
/// models are immutable, so every operation returns a
/// new object and the caller keeps the list (or the
/// trip) it was given. The leg invariants are the
/// legacy's: `legs[i]` sits between `stops[i]` and
/// `stops[i+1]`, `removeStop` deletes the leg that
/// pointed INTO the removed stop, and `moveStop` only
/// swaps adjacent stops -- the gap between them keeps
/// its transport, so legs stay valid.
///
/// Streamlit-free and I/O-free, so it is unit-tested
/// headlessly (`trip_ops_test.dart`).
library;

import 'dart:convert';
import 'dart:math';

import 'destination.dart';
import 'trip.dart';
import '../data/text_norm.dart';

/// `itinerary.models.TRANSPORT_MODES` -- the modes
/// `setLegMode` accepts; anything else becomes "other".
const transportModes = ['flight', 'train', 'bus', 'car', 'boat', 'other'];

/// The workbook "best time" vocabulary that counts as
/// a good month (`itinerary.itinerary.GOOD_MONTH_VALUES`).
const goodMonthValues = ['ideal', 'good', 'great', 'best', 'green'];

/// The month columns the catalogue carries, in order.
const months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

final Random _random = Random.secure();

/// A date-only ISO string ("YYYY-MM-DD") -- the
/// shape `date.fromisoformat` accepts. A datetime
/// string is deliberately not a match.
final RegExp _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// `itinerary.models.new_id`: `<prefix>-<10 hex>`.
String newId(String prefix) => '$prefix-${[
      for (var i = 0; i < 5; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join()}';

/// `datetime.now().isoformat(timespec="seconds")` --
/// local time without a timezone suffix, the shape
/// the legacy stamps onto a new trip.
String _nowIso() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-'
      '${two(now.month)}-${two(now.day)}T'
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}

// ── builders (itinerary.models) ────────────────────────────────────

StopRef makeRef(String kind, String name,
        [String? country, double? lat, double? lon]) =>
    StopRef(kind: kind, name: name, country: country, lat: lat, lon: lon);

Stop makeStop(StopRef ref,
        {String role = 'stop',
        String? arrivalDate,
        String? departureDate,
        String? arrivalTime,
        String? departureTime,
        int? nights,
        String notes = ''}) =>
    Stop(
      id: newId('stop'),
      ref: ref,
      arrivalDate: arrivalDate,
      departureDate: departureDate,
      arrivalTime: arrivalTime,
      departureTime: departureTime,
      nights: nights,
      role: role,
      notes: notes,
    );

Leg makeLeg([String mode = 'flight', String note = '']) => Leg(
      mode: transportModes.contains(mode) ? mode : 'other',
      note: note,
    );

Variant makeVariant(String name,
        {List<Stop> stops = const [],
        List<Leg> legs = const [],
        String notes = '',
        int? rating,
        List<String> months = const [],
        String comment = ''}) =>
    Variant(
      id: newId('variant'),
      name: name,
      notes: notes,
      rating: rating,
      months: months,
      comment: comment,
      stops: stops,
      legs: legs,
    );

Trip makeTrip(String name, {List<Variant>? variants}) {
  final list = variants ?? [makeVariant('Variant 1')];
  return Trip(
    id: newId('trip'),
    name: name,
    created: _nowIso(),
    activeVariantId: list.first.id,
    variants: list,
  );
}

// ── trip / variant management (itinerary.itinerary) ────────────────

Trip createTrip(String name) => makeTrip(name);

/// The deep copy `duplicate_trip` builds: fresh ids
/// everywhere, the "(copy)" suffix, and the clone
/// pointing at the cloned active variant.
Trip duplicateTrip(Trip trip) {
  final variants = [for (final variant in trip.variants) _copyVariant(variant)];
  final oldActive = trip.activeVariantId;
  final index = trip.variants.indexWhere((variant) => variant.id == oldActive);
  return Trip(
    id: newId('trip'),
    name: '${trip.name} (copy)',
    created: _nowIso(),
    activeVariantId: variants[index < 0 ? 0 : index].id,
    variants: variants,
  );
}

List<Trip> deleteTrip(List<Trip> trips, String tripId) =>
    [for (final trip in trips) if (trip.id != tripId) trip];

/// A blank name keeps the current one, the legacy's
/// `rename_trip` rule.
Trip renameTrip(Trip trip, String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return trip;
  return Trip(
    id: trip.id,
    name: trimmed,
    created: trip.created,
    activeVariantId: trip.activeVariantId,
    variants: trip.variants,
  );
}

/// A new variant that copies the active variant's
/// stops and legs -- with **fresh stop ids**: the
/// legacy's `copy.deepcopy` keeps them, which is
/// harmless in its JSON storage but would collide
/// on the stops table's primary key.
Trip createVariant(Trip trip, String name) {
  final active = trip.activeVariant;
  final label = name.isEmpty ? 'Variant' : name;
  final variant = active == null || active.stops.isEmpty
      ? makeVariant(label)
      : Variant(
          id: newId('variant'),
          name: label,
          stops: [for (final stop in active.stops) _copyStop(stop)],
          legs: [
            for (final leg in active.legs)
              Leg(mode: leg.mode, note: leg.note),
          ],
        );
  return Trip(
    id: trip.id,
    name: trip.name,
    created: trip.created,
    activeVariantId: trip.activeVariantId,
    variants: [...trip.variants, variant],
  );
}

/// The clone `duplicate_variant` builds, or null when
/// the variant is not part of the trip.
Trip? duplicateVariant(Trip trip, String variantId) {
  final index = trip.variants.indexWhere((v) => v.id == variantId);
  if (index < 0) return null;
  final src = trip.variants[index];
  final clone = Variant(
    id: newId('variant'),
    name: '${src.name} (copy)',
    notes: src.notes,
    rating: src.rating,
    months: src.months,
    comment: src.comment,
    stops: [for (final stop in src.stops) _copyStop(stop)],
    legs: [
      for (final leg in src.legs) Leg(mode: leg.mode, note: leg.note),
    ],
  );
  return Trip(
    id: trip.id,
    name: trip.name,
    created: trip.created,
    activeVariantId: trip.activeVariantId,
    variants: [...trip.variants, clone],
  );
}

/// A trip always keeps at least one variant; deleting
/// the active one activates the first survivor.
Trip deleteVariant(Trip trip, String variantId) {
  if (trip.variants.length <= 1) return trip;
  final survivors =
      [for (final variant in trip.variants) if (variant.id != variantId) variant];
  return Trip(
    id: trip.id,
    name: trip.name,
    created: trip.created,
    activeVariantId: trip.activeVariantId == variantId
        ? survivors.first.id
        : trip.activeVariantId,
    variants: survivors,
  );
}

Trip setActiveVariant(Trip trip, String variantId) {
  if (trip.variants.indexWhere((v) => v.id == variantId) < 0) {
    return trip;
  }
  return Trip(
    id: trip.id,
    name: trip.name,
    created: trip.created,
    activeVariantId: variantId,
    variants: trip.variants,
  );
}

Variant renameVariant(Variant variant, String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return variant;
  return _withStopsLegs(variant, variant.stops, variant.legs, name: trimmed);
}

// ── stop operations (legs stay positional & consistent) ────────────

/// Append or insert a stop; a matching leg placeholder
/// is inserted too (`add_stop`).
Variant addStop(Variant variant, StopRef ref,
        {String role = 'stop',
        int? at,
        String? arrivalDate,
        String? departureDate,
        String? arrivalTime,
        String? departureTime,
        int? nights,
        String notes = ''}) {
  final stop = makeStop(ref,
      role: role,
      arrivalDate: arrivalDate,
      departureDate: departureDate,
      arrivalTime: arrivalTime,
      departureTime: departureTime,
      nights: nights,
      notes: notes);
  final stops = [...variant.stops];
  final legs = [...variant.legs];
  if (at == null || at >= stops.length) {
    stops.add(stop);
    if (stops.length > 1) {
      legs.add(makeLeg());
    }
  } else {
    final position = at < 0 ? 0 : at;
    stops.insert(position, stop);
    legs.insert(position - 1 < 0 ? 0 : position - 1, makeLeg());
  }
  return _withStopsLegs(variant, stops, legs);
}

/// Remove stop `index` and the leg that pointed into it.
/// Out of range leaves the variant unchanged.
Variant removeStop(Variant variant, int index) {
  if (index < 0 || index >= variant.stops.length) return variant;
  final stops = [...variant.stops]..removeAt(index);
  final legs = [...variant.legs];
  if (legs.isNotEmpty) {
    legs.removeAt(index - 1 < 0 ? 0 : index - 1);
  }
  return _withStopsLegs(variant, stops, legs);
}

/// Swap stop `index` with its neighbour. Legs are
/// positional gaps and are left UNTOUCHED: the
/// transport of gap i stays attached to positions
/// (i, i+1) regardless of which stop sits there.
/// Swapping FRA-flight-A-train-B to FRA-B-A therefore
/// means "fly FRA→B, train B→A" -- the A↔B train
/// stays on the A-B gap, which is what a traveler
/// reordering visits expects.
Variant moveStop(Variant variant, int index, int direction) {
  final target = index + (direction > 0 ? 1 : -1);
  final stops = [...variant.stops];
  if (index < 0 ||
      index >= stops.length ||
      target < 0 ||
      target >= stops.length) {
    return variant;
  }
  final moved = stops[index];
  stops[index] = stops[target];
  stops[target] = moved;
  return _withStopsLegs(variant, stops, variant.legs);
}

/// The stop editor's Save: replace stop `index` with
/// the edited one. Out of range leaves the variant
/// unchanged.
Variant updateStop(Variant variant, int index, Stop updated) {
  if (index < 0 || index >= variant.stops.length) return variant;
  final stops = [...variant.stops]..[index] = updated;
  return _withStopsLegs(variant, stops, variant.legs);
}

/// The transport mode of leg `index`; an unknown mode
/// becomes "other". The leg's note is kept.
Variant setLegMode(Variant variant, int index, String mode) {
  if (index < 0 || index >= variant.legs.length) return variant;
  final legs = [...variant.legs];
  legs[index] = Leg(
    mode: transportModes.contains(mode) ? mode : 'other',
    note: legs[index].note,
  );
  return _withStopsLegs(variant, variant.stops, legs);
}

/// The variant meta editor's Save (E5): notes, rating,
/// the months multiselect, the comment.
Variant updateMeta(
  Variant variant, {
  required String notes,
  required int? rating,
  required List<String> months,
  required String comment,
}) =>
    _withStopsLegs(
      variant,
      variant.stops,
      variant.legs,
      notes: notes,
      rating: rating,
      months: months,
      comment: comment,
    );

Variant _withStopsLegs(
  Variant variant,
  List<Stop> stops,
  List<Leg> legs, {
  String? name,
  String? notes,
  int? rating,
  List<String>? months,
  String? comment,
}) =>
    Variant(
      id: variant.id,
      name: name ?? variant.name,
      notes: notes ?? variant.notes,
      rating: rating ?? variant.rating,
      months: months ?? variant.months,
      comment: comment ?? variant.comment,
      stops: stops,
      legs: legs,
    );

Variant _copyVariant(Variant variant) => Variant(
      id: newId('variant'),
      name: variant.name,
      notes: variant.notes,
      rating: variant.rating,
      months: variant.months,
      comment: variant.comment,
      stops: [for (final stop in variant.stops) _copyStop(stop)],
      legs: [
        for (final leg in variant.legs) Leg(mode: leg.mode, note: leg.note),
      ],
    );

Stop _copyStop(Stop stop) => Stop(
      id: newId('stop'),
      ref: StopRef(
        kind: stop.ref.kind,
        name: stop.ref.name,
        country: stop.ref.country,
        lat: stop.ref.lat,
        lon: stop.ref.lon,
      ),
      arrivalDate: stop.arrivalDate,
      departureDate: stop.departureDate,
      arrivalTime: stop.arrivalTime,
      departureTime: stop.departureTime,
      nights: stop.nights,
      role: stop.role,
      notes: stop.notes,
    );

// ── totals / summary ─────────────────────────────────────────────────

/// The variant's totals: the stop count, the nights
/// (explicit, or from date spans where nights is
/// unset), the transport counts and the first and
/// last date. `nightsKnown` says whether any night
/// count is known at all.
TripTotals totals(Variant variant) {
  var nights = 0;
  var nightsKnown = false;
  for (final stop in variant.stops) {
    if (stop.nights != null) {
      nights += stop.nights!;
      nightsKnown = true;
    }
  }
  // Nights from date spans where nights is unset.
  // Date-only strings, exactly like the legacy's
  // `date.fromisoformat` (a datetime string is not a
  // date and is skipped).
  for (final stop in variant.stops) {
    if (stop.nights != null ||
        stop.arrivalDate == null ||
        stop.departureDate == null) {
      continue;
    }
    final arrival = _parseDateOnly(stop.arrivalDate);
    final departure = _parseDateOnly(stop.departureDate);
    if (arrival != null && departure != null && departure.isAfter(arrival)) {
      nights += departure.difference(arrival).inDays;
      nightsKnown = true;
    }
  }
  var flights = 0;
  var trains = 0;
  var other = 0;
  for (final leg in variant.legs) {
    if (leg.mode == 'flight') {
      flights++;
    } else if (leg.mode == 'train') {
      trains++;
    } else {
      other++;
    }
  }
  final dates = <String>[
    for (final stop in variant.stops) ...[
      if (stop.arrivalDate != null) stop.arrivalDate!,
      if (stop.departureDate != null) stop.departureDate!,
    ],
  ]..sort();
  return TripTotals(
    stops: variant.stops.length,
    nights: nights,
    flights: flights,
    trains: trains,
    other: other,
    start: dates.isEmpty ? null : dates.first,
    end: dates.isEmpty ? null : dates.last,
    nightsKnown: nightsKnown,
  );
}

/// `date.fromisoformat`: a date-only ISO string, or null.
/// A datetime string is not a date and is skipped --
/// exactly the legacy's `ValueError` path.
DateTime? _parseDateOnly(String? value) {
  if (value == null || value.isEmpty) return null;
  if (!_dateOnly.hasMatch(value)) return null;
  return DateTime.tryParse(value);
}

/// The "⚠️ Check results" panel (`ops.warnings_for`):
/// every way the route can be inconsistent -- missing
/// coordinates, impossible dates, negative nights, a
/// leg that arrives before the previous departure.
/// Empty means "all good -- route is consistent".
List<String> warningsFor(Variant variant) {
  final out = <String>[];
  final stops = variant.stops;
  if (stops.isEmpty) {
    return ['No stops yet — add your first destination.'];
  }
  if (stops.length == 1) {
    out.add('Single stop — add more destinations to build a route.');
  }
  for (final stop in stops) {
    final name = stop.ref.name;
    if (stop.ref.lat == null || stop.ref.lon == null) {
      out.add("'$name' has no coordinates — "
          'it will not appear on the map.');
    }
    final arrival = stop.arrivalDate;
    final departure = stop.departureDate;
    if (arrival != null && arrival.isNotEmpty &&
        departure != null && departure.isNotEmpty) {
      final a = _parseDateOnly(arrival);
      final d = _parseDateOnly(departure);
      if (a == null || d == null) {
        out.add("'$name': invalid date format.");
      } else if (d.isBefore(a)) {
        out.add("'$name': departure before arrival.");
      }
    } else if (departure != null &&
        departure.isNotEmpty &&
        arrival == null &&
        stop.role != 'origin') {
      // origin stops legitimately have only a departure date
      out.add("'$name': departure date without arrival.");
    }
    if (stop.nights != null && stop.nights! < 0) {
      out.add("'$name': negative nights.");
    }
  }
  out.addAll(_legWarnings(stops));
  if (variant.months.length > 12) {
    out.add('More than 12 months selected?!');
  }
  return out;
}

/// Legs that cannot happen: arriving before the
/// previous departure. The per-stop checks cannot
/// see this -- an 11-hour flight with a large time
/// offset arrives on the *next* day, so identical
/// dates on two consecutive stops mean the route
/// is impossible.
List<String> _legWarnings(List<Stop> stops) {
  final out = <String>[];
  for (var i = 0; i < stops.length - 1; i++) {
    final here = stops[i];
    final next = stops[i + 1];
    final dep = here.departureDate;
    final arr = next.arrivalDate;
    if (dep == null || dep.isEmpty || arr == null || arr.isEmpty) {
      continue;
    }
    final depDate = _parseDateOnly(dep);
    final arrDate = _parseDateOnly(arr);
    if (depDate == null || arrDate == null) continue;
    if (arrDate.isBefore(depDate)) {
      out.add('${next.ref.name} arrives $arr — before leaving '
          '${here.ref.name} on $dep.');
    }
  }
  return out;
}

/// The route summary line: "3 stops · 5 nights ·
/// 2 flights · 2026-05-01 → 2026-05-06".
String routeSummary(Variant variant) {
  final t = totals(variant);
  final bits = <String>['${t.stops} stops'];
  if (t.nights > 0) {
    bits.add('${t.nights} nights');
  }
  if (t.flights > 0) {
    bits.add('${t.flights} flights');
  }
  if (t.trains > 0) {
    bits.add('${t.trains} trains');
  }
  if (t.other > 0) {
    bits.add('${t.other} other');
  }
  if (t.start != null) {
    bits.add('${t.start} → ${t.end}');
  }
  return bits.join(' · ');
}

/// For each 'destination'-kind stop: the months where
/// the workbook says the destination's climate is
/// good (`suggested_months`). A stop matches its
/// catalogue row by exact name first, then by the
/// normalised key -- workbook rows often carry
/// province suffixes ("Xi'an (Shaanxi)"), so an
/// exact match is tried first, then a normalised one.
Map<String, List<String>> suggestedMonths(
    Variant variant, List<Destination> catalogue) {
  final byName = <String, Destination>{};
  final byNorm = <String, Destination>{};
  for (final dest in catalogue) {
    byName[dest.name.toLowerCase()] = dest;
    byNorm.putIfAbsent(_normDestKey(dest.name), () => dest);
  }
  final out = <String, List<String>>{};
  for (final stop in variant.stops) {
    if (stop.ref.kind != 'destination') continue;
    final name = stop.ref.name;
    var row = byName[name.toLowerCase()];
    row ??= byNorm[_normDestKey(name)];
    if (row == null) continue;
    final good = <String>[];
    for (final month in months) {
      final value = (row.column(month) ?? '').toString().trim().toLowerCase();
      if (value.isNotEmpty &&
          goodMonthValues.any((good) => value.contains(good))) {
        good.add(month);
      }
    }
    if (good.isNotEmpty) {
      out[name] = good;
    }
  }
  return out;
}

/// The tolerant lookup key: "Xi'an (Shaanxi)" and
/// "Xian" both become "xian" -- the legacy's
/// `_norm_dest_key` (NFKD-folded, province suffix
/// dropped, non-alphanumerics collapsed).
String _normDestKey(String name) {
  var folded = stripDiacritics(name);
  folded = folded.replaceAll(RegExp(r'\s*\([^)]*\)'), '');
  return folded
      .replaceAll(RegExp(r'[^a-z0-9]+'), '')
      .toLowerCase();
}

/// Months the workbook rates good for EVERY stop of
/// the variant (`_trip_wide_suggestion`): the
/// intersection of the per-stop suggestions, in
/// calendar order. The variant meta editor
/// pre-selects these until the user picks their
/// own.
List<String> tripWideSuggestion(
    Map<String, List<String>> suggestions) {
  Set<String>? common;
  for (final monthList in suggestions.values) {
    common = common == null
        ? monthList.toSet()
        : common.intersection(monthList.toSet());
  }
  if (common == null || common.isEmpty) return [];
  return [
    for (final month in months)
      if (common.contains(month)) month,
  ];
}

// ── export (E9) ────────────────────────────────────────────────────

/// One trip (all variants/stops/legs) as pretty JSON
/// for download (`storage.export_trip`). The models
/// are normalized by construction -- every `fromRow`
/// applies the legacy's defaults -- so the export is
/// the serialized trip, the same shape the legacy's
/// `normalize_trip` produces.
String exportTrip(Trip trip) =>
    const JsonEncoder.withIndent('  ').convert(trip.toJson());

/// The whole trips store as pretty JSON -- the
/// `trips.json` snapshot the legacy sidebar
/// downloads as a backup (`storage.normalize_all`:
/// `{"schema_version": 1, "trips": [...]}`).
/// No restore side (user, 2026-10-12): importing
/// a snapshot back is a bulk write to the live
/// database, and the export-only backup covers
/// the need -- the legacy synced `trips.json`
/// rather than restoring snapshots.
String exportTrips(List<Trip> trips) =>
    const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'trips': [for (final trip in trips) trip.toJson()],
    });

/// The totals of one variant.
class TripTotals {
  final int stops;
  final int nights;
  final int flights;
  final int trains;
  final int other;
  final String? start;
  final String? end;
  final bool nightsKnown;

  const TripTotals({
    required this.stops,
    required this.nights,
    required this.flights,
    required this.trains,
    required this.other,
    required this.start,
    required this.end,
    required this.nightsKnown,
  });
}
