/// Airline benefits: which carriers qualify, and how a flag
/// map is read out of the Turso benefits table.
///
/// The Dart port of the pure parts of `airline_benefits.py`
/// and `benefits_turso.py`, rule for rule:
///
/// * only an explicit yes counts -- `unknown` is not a yes;
/// * a flag map is keyed by IATA code **and** canonical
///   name, so a board's `LH` and an export's `Lufthansa`
///   both resolve;
/// * lookup order: IATA code, canonical key, an
///   unambiguous substring match, and finally the built-in
///   seed list when no source could be read at all;
/// * an **empty read is a failure**, not "nobody
///   qualifies" -- an empty map removes every destination
///   from the finder with no visible cause.
///
/// No network here: the fetching lives in
/// `data/benefits_repository.dart`, exactly like the
/// Python split between the pure module and
/// `benefits_turso.fetch_*`.
library;

/// One airline row read from a benefits source.
typedef AirlineRecord = ({
  String code,
  String name,
  bool benefits,
  List<String> which,
});

const codeColumns = <String>['iata', 'iata_code', 'code', 'airline_code'];
const nameColumns = <String>['name', 'airline', 'airline_name', 'carrier'];
const benefitColumns = <String>[
  'discount_eligible',
  'business_class',
  'confirmed_booking',
];

const yesValues = {'yes', 'y', 'true', '1', 'ja', 'x'};

/// Only an explicit yes counts. `unknown` is not a yes.
/// The legacy's set exactly (`_is_yes`): "ja" is a yes,
/// and a numeric 1.0 is not -- `toString` makes it
/// "1.0", which the set rejects.
bool isYes(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  return yesValues.contains(value.toString().trim().toLowerCase());
}

/// Map canonical column name -> column index, tolerating
/// naming drift the same way `benefits_turso.pick_columns`
/// does. Key order follows the canonical tuples, not the
/// file's column order, so the result is deterministic.
Map<String, int> pickColumns(List<String>? fieldNames) {
  final normalised = <String, int>{};
  for (var index = 0; index < (fieldNames?.length ?? 0); index++) {
    normalised[_normaliseHeader(fieldNames![index])] = index;
  }
  final mapping = <String, int>{};
  for (final canonical in [...codeColumns, ...nameColumns, ...benefitColumns]) {
    final index = normalised[_normaliseHeader(canonical)];
    if (index != null) {
      mapping.putIfAbsent(canonical, () => index);
    }
  }
  return mapping;
}

String _normaliseHeader(Object? name) =>
    (name ?? '').toString().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '');

/// Rows -> one record per airline, plus any problems.
///
/// Returns `([], [problem])` when the columns are not
/// recognisable, so a schema change is reported rather than
/// silently read as "no benefits" -- the contract
/// `benefits_turso.rows_to_records` keeps.
(List<AirlineRecord>, List<String>) rowsToRecords(
    List<List<Object?>> rows, List<String> fieldNames) {
  final mapping = pickColumns(fieldNames);
  final codeAt = _firstPresent(mapping, codeColumns);
  final benefitAt = [
    for (final column in benefitColumns)
      if (mapping[column] != null) (column, mapping[column]!),
  ];
  if (codeAt == null || benefitAt.isEmpty) {
    final found = fieldNames.isEmpty ? 'nothing' : fieldNames.join(', ');
    return (
      <AirlineRecord>[],
      [
        'expected a code column (${codeColumns.join('/')}) and at least one '
            'benefit column (${benefitColumns.join('/')}); found: $found',
      ],
    );
  }
  final nameAt = _firstPresent(mapping, nameColumns);
  final out = <AirlineRecord>[];
  final seen = <String>{};
  for (final values in rows) {
    if (values.isEmpty || codeAt >= values.length) continue;
    final code = (values[codeAt] ?? '').toString().trim().toUpperCase();
    if (code.isEmpty || seen.contains(code)) continue;
    seen.add(code);
    final name = nameAt != null && nameAt < values.length
        ? (values[nameAt] ?? '').toString().trim()
        : '';
    final which = [
      for (final (column, index) in benefitAt)
        if (index < values.length && isYes(values[index])) column,
    ];
    out.add((code: code, name: name.isEmpty ? code : name, benefits: which.isNotEmpty, which: which));
  }
  return (out, const <String>[]);
}

int? _firstPresent(Map<String, int> mapping, List<String> columns) {
  for (final column in columns) {
    final index = mapping[column];
    if (index != null) return index;
  }
  return null;
}

/// ``{key: has benefits}`` keyed by IATA code *and* canonical
/// name. Boards say ``LH``, exports say ``Lufthansa``;
/// registering both means the lookup works whichever
/// spelling arrives.
Map<String, bool> recordsToFlags(List<AirlineRecord> records) {
  final flags = <String, bool>{};
  for (final row in records) {
    flags[row.code] = row.benefits;
    if (row.name.isNotEmpty) {
      flags[canonicalAirlineKey(row.name)] = row.benefits;
    }
  }
  return flags;
}

/// Words that never identify a carrier: legal forms and
/// filler. "Air" is deliberately NOT dropped -- it is part
/// of real names ("Air France", "Air Canada").
const legalSuffixes = <String>{
  'airlines', 'airline', 'airways', 'lines', 'airlinegroup', 'airport',
  'transport', 'ag', 'kg', 'mbh', 'sa', 'nv', 'bv', 'sarl', 'aps',
  'group', 'inc', 'incorporated', 'ltd', 'limited', 'plc', 'llc', 'llp',
  'corporation', 'corp', 'company', 'co', 'holdings', 'holding',
  'worldwide', 'global', 'international', 'intl', 'national',
};

/// Normalised keys that name a carrier the table does not
/// spell identically. Both sides are already normalised, so
/// these entries are literal -- the explicit table the
/// project prefers over heuristics.
const nameEquivalents = <String, String>{
  'deutschelufthansa': 'lufthansa',
  'lufthansacityline': 'lufthansa',
  'lufthansaregional': 'lufthansa',
  'lufthansagroup': 'lufthansa',
  'cityline': 'lufthansa',
  'eurowingseurope': 'eurowings',
  'brussels': 'brussels',
  'klmroyaldutch': 'klm',
  'allnippon': 'ana',
  'vivaaerobus': 'viva',
  'wizzair': 'wizz',
  'tapairportugal': 'tap',
  'tapportugal': 'tap',
  'taiportugal': 'tap',
  'sasscandinavian': 'sas',
  'lotpolish': 'lot',
  'aegean': 'aegean',
  'turkish': 'turkish',
  'qatarairways': 'qatar',
  'austrian': 'austrian',
  'swissair': 'swiss',
  'swissairlines': 'swiss',
  'aireuropa': 'aireuropa',
};

/// Latin-1 accents the airline names actually use. Dart has
/// no Unicode normalisation table, and a wrong guess here
/// only affects the *name* lookup path (the IATA path is
/// ASCII), so an explicit table beats a heuristic.
const transliterations = <String, String>{
  'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'á': 'a', 'à': 'a', 'â': 'a', 'å': 'a',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u',
  'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ø': 'o', 'æ': 'ae',
};

/// Lowercase alphanumeric key used to match airline names
/// across sources: punctuation and legal-form words go, a
/// repeated word collapses ("SWISS Swiss" -> "swiss").
String normalizeAirline(Object? value) {
  if (value == null) return '';
  var text = value.toString().toLowerCase();
  for (final entry in transliterations.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  // Dotted legal forms first, as whole units: "S.A."
  // would otherwise split into "s" and "a" and then
  // look like two real words (the legacy's regex,
  // airline_benefits.py).
  text = text.replaceAll(
    RegExp(
      r'\b(?:s\.?a\.?|n\.?v\.?|b\.?v\.?|a\.?g\.?|g\.?b\.?r\.?|'
      r'a\.?s\.?|s\.?a\.?r\.?l\.?|k\.?g\.?|l\.?t\.?d\.?|'
      r'p\.?l\.?c\.?|l\.?l\.?c\.?)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  text = text.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  final words = text.split(' ').where((w) => w.isNotEmpty).toList();
  final kept = <String>[];
  for (final word in words) {
    if (legalSuffixes.contains(word) || kept.contains(word)) continue;
    kept.add(word);
  }
  return kept.isNotEmpty ? kept.join() : words.join();
}

/// Normalised key, folded through the equivalence table.
String canonicalAirlineKey(Object? value) {
  final raw = normalizeAirline(value);
  if (raw.isEmpty) return '';
  return nameEquivalents[raw] ?? raw;
}

/// Extract a 2-3 character IATA airline code from a name or
/// flight number. Flight numbers are the other common shape
/// a board gives us ("LH 1000").
String iataCode(Object? value) {
  if (value == null) return '';
  final text = value.toString().trim().toUpperCase();
  if (text.isEmpty) return '';
  if (RegExp(r'^[A-Z0-9]{2}$').hasMatch(text)) return text;
  final match = RegExp(r'^([A-Z0-9]{2})\s*[\s-]?\d').firstMatch(text);
  if (match != null) return match.group(1)!;
  return '';
}

/// The documented default set, as canonical keys -- the last
/// resort when no source could be read at all.
const seedBenefitAirlines = <String>[
  'Lufthansa',
  'Eurowings',
  'SWISS',
  'Austrian',
  'Brussels Airlines',
  'Air France',
  'KLM',
  'ITA Airways',
  'SAS',
  'TAP Air Portugal',
  'Iberia',
  'British Airways',
  'Aer Lingus',
  'United Airlines',
  'Air Canada',
  'ANA',
  'Singapore Airlines',
  'Qatar Airways',
  'Emirates',
  'Turkish Airlines',
  'LOT Polish Airlines',
  'Aegean Airlines',
  'Air Europa',
  'Finnair',
];

Map<String, bool> seedFlags() => {
      for (final name in seedBenefitAirlines) canonicalAirlineKey(name): true,
    };

/// Whether one airline qualifies.
///
/// Tries, in order: the exact IATA code, the canonical name
/// key, an unambiguous substring match, and finally the seed
/// list when no source at all could be read.
///
/// When a source *was* read, an unlisted airline does **not**
/// qualify -- the safer direction: a too-narrow list is
/// visible and fixable, a too-wide one silently invents
/// destinations.
bool hasBenefits(String airline, Map<String, bool>? flags) {
  final map = flags ?? seedFlags();
  final code = iataCode(airline);
  if (code.isNotEmpty && map.containsKey(code)) {
    return map[code]!;
  }
  final key = canonicalAirlineKey(airline);
  if (key.isEmpty) return false;
  if (map.isNotEmpty) {
    if (map.containsKey(key)) return map[key]!;
    // A carrier may be listed under a spelling we could not
    // fold ("Singapore Airlines Limited" -> "singapore").
    // Substring containment only, and only while the answer
    // does not depend on which one matched.
    final matches = <bool>{
      for (final entry in map.entries)
        if (entry.key.isNotEmpty &&
            (entry.key.contains(key) || key.contains(entry.key)))
          entry.value,
    };
    if (matches.length == 1) return matches.first;
    // 0 matches, or a yes and a no at once: either way we
    // cannot claim it qualifies.
    return false;
  }
  return seedFlags().containsKey(key);
}

/// Distinct carriers in the data that no source mentions,
/// so a missing flag is visible rather than silent.
List<String> unmatchedAirlines(Iterable<String> airlines,
    Map<String, bool>? flags) {
  final map = flags ?? const <String, bool>{};
  final known = map.isNotEmpty ? map : seedFlags();
  final out = <String>[];
  for (final airline in airlines) {
    final name = airline.trim();
    if (name.isEmpty) continue;
    final code = iataCode(name);
    final key = canonicalAirlineKey(name);
    final knownKey = code.isNotEmpty && known.containsKey(code) ||
        known.containsKey(key) ||
        known.keys.any((k) =>
            k.isNotEmpty && (k.contains(key) || key.contains(k)));
    if (knownKey) continue;
    if (!out.contains(name)) out.add(name);
  }
  out.sort();
  return out;
}

/// The airline filter the finder's dropdown exposes (report
/// d, 2026-10-16). The two Lufthansa options are **identity**
/// scopes -- membership, not benefit flags; the user's own
/// definition for [AirlineScope.lufthansa] is "all airlines
/// with Lufthansa in their name".
enum AirlineScope {
  /// Lufthansa Group carriers (the explicit table below).
  lufthansaGroup,

  /// Everything with "Lufthansa" in its name.
  lufthansa,

  /// The benefits database's yes-only flags -- the finder's
  /// original behaviour.
  allWithBenefits,

  /// No filter at all.
  all,
}

/// The dropdown's labels, in the enum's order.
const airlineScopeLabels = <AirlineScope, String>{
  AirlineScope.lufthansaGroup: 'Only Lufthansa Group',
  AirlineScope.lufthansa: 'Only Lufthansa',
  AirlineScope.allWithBenefits: 'All with benefits',
  AirlineScope.all: 'All',
};

/// The Lufthansa Group's passenger carriers, in the order the
/// finder's caption lists them: the IATA code and the name a
/// reader knows it by.
///
/// **One table, three readers**: the membership test below, the
/// caption in the finder, and the test that keeps them in step.
/// The list grew a carrier at a time and the caption lagged
/// behind it (the user's report, 2026-10-21) — a caption that
/// names a different set than the code filters on is a lie the
/// reader cannot see.
const lufthansaGroupCarriers = <(String, String)>[
  ('LH', 'Lufthansa'),
  ('LX', 'SWISS'),
  ('OS', 'Austrian Airlines'),
  ('SN', 'Brussels Airlines'),
  ('AZ', 'ITA Airways'),
  ('EW', 'Eurowings'),
  ('4Y', 'Discover Airlines'),
  ('WK', 'Edelweiss'),
  ('EN', 'Air Dolomiti'),
  ('VL', 'Lufthansa City Airlines'),
  ('CL', 'Lufthansa CityLine'),
];

/// The membership test's codes. Kept as a literal set (a
/// const set cannot call `canonicalAirlineKey`), with a test
/// that pins it to [lufthansaGroupCarriers].
const lufthansaGroupCodes = <String>{
  'LH', // Lufthansa (incl. CityLine-operated flights)
  'CL', // Lufthansa City / CityLine
  'EW', // Eurowings
  '4Y', // Eurowings Discover
  'LX', // SWISS
  'WK', // Edelweiss
  'OS', // Austrian
  'SN', // Brussels Airlines
  'EN', // Air Dolomiti
  'AZ', // ITA Airways
  'VL', // Lufthansa City Airlines
};

const lufthansaGroupNames = <String>{
  'lufthansa',
  'lufthansacity',
  'lufthansacityline',
  'lufthansaregional',
  'eurowings',
  'eurowingsdiscover',
  'swiss',
  'edelweiss',
  'austrian',
  'brussels',
  'airdolomiti',
  'ita',
  'itaairways',
  'lufthansacityairlines',
  'discover',
  'discoverairlines',
  'austrianairlines',
  'brusselsairlines',
  'edelweissair',
  'swissinternational',
  'lufthansaairlines',
};

/// The caption the finder shows for the Lufthansa Group scope:
/// the carriers, in the table's order. One source, so the
/// caption cannot drift from the membership test.
String lufthansaGroupCaption() =>
    lufthansaGroupCarriers.map((carrier) => carrier.$2).join(', ');

/// Whether one flight's carrier passes the scope.
///
/// `airline` is the board's operator code (`al`), `name`
/// its carrier name (`alname`) when the record carries one.
bool airlineInScope(String airline, String name, AirlineScope scope,
    Map<String, bool>? benefitFlags) {
  switch (scope) {
    case AirlineScope.all:
      return true;
    case AirlineScope.allWithBenefits:
      return hasBenefits(airline, benefitFlags);
    case AirlineScope.lufthansa:
      // The user's definition: every airline with
      // "Lufthansa" in its name (Lufthansa, Lufthansa City,
      // ...). The code fallback covers board rows that carry
      // only `al`.
      final spelling = name.trim().isNotEmpty ? name : airline;
      return spelling.toLowerCase().contains('lufthansa') ||
          const {'LH', 'CL'}.contains(spelling.trim().toUpperCase());
    case AirlineScope.lufthansaGroup:
      final code = airline.trim().toUpperCase();
      if (lufthansaGroupCodes.contains(code)) return true;
      final key = canonicalAirlineKey(name.trim().isNotEmpty ? name : airline);
      return lufthansaGroupNames.contains(key);
  }
}

/// One line for the results header, so "nothing matched" is
/// explainable: with a real source it names the qualifying
/// carriers instead of counting a 597-entry table. With the
/// seed list it says so.
String benefitSummary(Map<String, bool> flags, List<AirlineRecord> records,
    String sourceLabel, List<String> problems) {
  if (records.isNotEmpty) {
    final qualified =
        (records.where((r) => r.benefits).map((r) => r.code).toList()..sort())
            .join(', ');
    return '${records.where((r) => r.benefits).length} of ${records.length} '
        'airlines have benefits (from $sourceLabel: '
        '${qualified.isEmpty ? 'none yet' : qualified}); '
        "'Unknown' counts as no.";
  }
  if (!flags.isNotEmpty) {
    return 'No benefits database reachable'
        '${problems.isNotEmpty ? ' (${problems.first})' : ''} - using the '
        'built-in default list of ${seedBenefitAirlines.length} airlines.';
  }
  final flagged = flags.values.where((v) => v).length;
  return '$flagged of ${flags.length} listed airlines have benefits '
      '($sourceLabel)';
}
