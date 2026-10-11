/// The IQAir ranking matcher: the pure half of
/// `iqair_ranking.py`.
///
/// The legacy page renders an "IQAir Annual PM2.5"
/// history table by matching the workbook destination
/// against a cached snapshot of the IQAir world
/// ranking (`iqair_cache/world_cities.json`,
/// `{cities: [{rank, city, country, pm25: {2025:
/// 112.5, ...}}]}`). This module is the Dart port of
/// that matching — the normalisation, the country
/// filter, the alias and capital fallbacks, and the
/// resolution chain — so the app shows the same
/// city, the same rank and the same per-year
/// values the legacy table does.
///
/// No Flutter, no I/O: a list of cities in, a
/// result out. The snapshot is read by the caller
/// (the desktop app reads the local cache file;
/// Android has no such file and the table stays
/// hidden, like the banner).
library;

import 'text_norm.dart';

/// One city in the IQAir snapshot.
class IqairCity {
  final int rank;
  final String city;
  final String country;

  /// Year ("2025") -> PM2.5 (µg/m³).
  final Map<String, double> pm25;

  const IqairCity({
    required this.rank,
    required this.city,
    required this.country,
    required this.pm25,
  });

  factory IqairCity.fromJson(Map<String, dynamic> json) {
    final pm25 = <String, double>{};
    final raw = json['pm25'];
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is num) {
          pm25[key.toString()] = value.toDouble();
        }
      });
    }
    return IqairCity(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      city: (json['city'] as String?) ?? '',
      country: (json['country'] as String?) ?? '',
      pm25: pm25,
    );
  }

  /// The mean of the up-to-five most recent year
  /// values (the user's "average of up to 5 years"
  /// decision), or null when the city has none.
  double? get pm25Avg {
    const years = ['2025', '2024', '2023', '2022', '2021'];
    final values = [
      for (final year in years)
        if (pm25.containsKey(year)) pm25[year]!,
    ];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }
}

/// The outcome of resolving one destination name.
class IqairResult {
  /// "city", "capital", "wrong-country",
  /// "ambiguous" or "unmatched".
  final String status;
  final int? rank;
  final double? pm25Avg;
  final IqairCity? entry;

  /// The capital the region row resolved to
  /// ("capital" results only).
  final String? via;

  /// True when several same-country hits were
  /// resolved by best rank — a guess, not a match.
  final bool guessed;

  /// The near-miss candidates ("wrong-country" and
  /// "ambiguous" results).
  final List<IqairCity> candidates;

  const IqairResult._({
    required this.status,
    this.rank,
    this.pm25Avg,
    this.entry,
    this.via,
    this.guessed = false,
    this.candidates = const [],
  });

  const IqairResult.city({
    required int rank,
    required double? pm25Avg,
    required IqairCity entry,
    required bool guessed,
  }) : this._(
          status: 'city',
          rank: rank,
          pm25Avg: pm25Avg,
          entry: entry,
          guessed: guessed,
        );

  const IqairResult.capital({
    required int rank,
    required double? pm25Avg,
    required IqairCity entry,
    required String via,
    required bool guessed,
  }) : this._(
          status: 'capital',
          rank: rank,
          pm25Avg: pm25Avg,
          entry: entry,
          via: via,
          guessed: guessed,
        );

  const IqairResult.miss({
    required String status,
    required List<IqairCity> candidates,
  }) : this._(status: status, candidates: candidates);

  bool get matched => status == 'city' || status == 'capital';
}

/// Workbook country spellings that differ from
/// IQAir's.
const _countryAliases = <String, String>{
  'uae': 'united arab emirates',
  'united states': 'usa',
  'u s a': 'usa',
  'u k': 'united kingdom',
};

const _countryConnectors = <String>{'and', 'the', 'of', '&'};

/// Region rows -> the capital city that IS ranked.
const _capitalFallback = <String, String>{
  'sri lanka': 'Colombo',
  'kerala': 'Thiruvananthapuram',
  'brunei': 'Bandar Seri Begawan',
};

/// Workbook name -> the name IQAir actually uses
/// (verified against the 2026-09 snapshot).
const _aliases = <String, String>{
  'saigon': 'Ho Chi Minh City',
  'bangalore': 'Bengaluru',
  'seville': 'Sevilla',
  'mallorca': 'Palma',
  'bilbao': 'Bilbo',
  'samarkand': 'Samarqand',
  'pattaya': 'Pattaya City',
  'phu quoc': 'Phu Quoc City',
};

/// The matcher: an index of the snapshot's cities
/// by their normalised name.
class IqairIndex {
  final Map<String, List<IqairCity>> _byName;

  IqairIndex._(this._byName);

  factory IqairIndex.build(Iterable<IqairCity> cities) {
    final index = <String, List<IqairCity>>{};
    for (final city in cities) {
      index.putIfAbsent(norm(city.city), () => []).add(city);
    }
    return IqairIndex._(index);
  }

  List<IqairCity> hits(String normalisedName) =>
      _byName[normalisedName] ?? const [];

  /// Every indexed name, for the prefix fallback.
  Iterable<String> get names => _byName.keys;

  List<IqairCity> citiesFor(String normalisedName) =>
      _byName[normalisedName] ?? const [];
}

/// Resolve one workbook destination name against the
/// index, the port of `iqair_ranking.lookup`.
///
/// The chain, in order: the candidate names (full,
/// base, parenthetical — "KK (Kota Kinabalu)" —
/// then their aliases), each country-filtered; then
/// the region->capital fallback; then the renamed-
/// city prefix match ("Santa Cruz" -> "Santa Cruz
/// de la Sierra", needs two tokens so "Salvador"
/// never matches "San Salvador"); then the
/// best-rank guess among several same-country hits.
IqairResult lookup(
  String name,
  IqairIndex index, {
  String? country,
}) {
  final raw = name.trim();
  final parenMatch = RegExp(r'^(.*?)\s*\((.*?)\)\s*$').firstMatch(raw);
  final base = parenMatch?.group(1) ?? raw;
  final paren = parenMatch?.group(2);
  final nb = norm(base);
  final np = paren == null ? null : norm(paren);

  // Candidate names, in try order: full, base,
  // parenthetical, then their aliases.
  final candidates = <String>[];
  for (final candidate in [raw, base, paren]) {
    if (candidate != null && candidate.isNotEmpty &&
        !candidates.contains(candidate)) {
      candidates.add(candidate);
    }
  }
  for (final candidate in [...candidates]) {
    final aliased = _aliases[norm(candidate)];
    if (aliased != null && !candidates.contains(aliased)) {
      candidates.add(aliased);
    }
  }

  var wrongCountry = <IqairCity>[];
  List<IqairCity>? multiHits;
  for (final candidate in candidates) {
    final hits = index.hits(norm(candidate));
    if (hits.isEmpty) continue;
    final filtered = _countryFilter(hits, country);
    if (filtered.isEmpty) {
      if (wrongCountry.isEmpty) {
        wrongCountry = [...hits]
          ..sort((a, b) => a.rank.compareTo(b.rank));
        wrongCountry = wrongCountry.take(5).toList();
      }
      continue;
    }
    if (filtered.length == 1) {
      final picked = _pick(filtered);
      return IqairResult.city(
        rank: picked.rank,
        pm25Avg: picked.pm25Avg,
        entry: picked,
        guessed: filtered.length > 1,
      );
    }
    multiHits ??= filtered;
  }

  // The region row -> capital city, country-filtered.
  final cap = _capitalFallback[nb] ?? (np == null ? null : _capitalFallback[np]);
  if (cap != null) {
    final hits = _countryFilter(index.hits(norm(cap)), country);
    if (hits.isNotEmpty) {
      final picked = _pick(hits);
      return IqairResult.capital(
        rank: picked.rank,
        pm25Avg: picked.pm25Avg,
        entry: picked,
        via: cap,
        guessed: hits.length > 1,
      );
    }
  }

  // Renamed city rows: the query is a PREFIX of the
  // IQAir name. Needs >= 2 tokens to avoid "Salvador"
  // matching "San Salvador".
  if (nb.split(' ').length >= 2) {
    for (final entryNorm in index.names) {
      if (entryNorm.startsWith('$nb ')) {
        final filtered =
            _countryFilter(index.citiesFor(entryNorm), country);
        if (filtered.length == 1) {
          final picked = _pick(filtered);
          return IqairResult.city(
            rank: picked.rank,
            pm25Avg: picked.pm25Avg,
            entry: picked,
            guessed: filtered.length > 1,
          );
        }
      }
    }
  }

  // Several same-country hits (e.g. Suzhou Jiangsu vs
  // Anhui): best rank wins, flagged as a guess.
  if (multiHits != null) {
    final picked = _pick(multiHits);
    return IqairResult.city(
      rank: picked.rank,
      pm25Avg: picked.pm25Avg,
      entry: picked,
      guessed: true,
    );
  }

  if (wrongCountry.isNotEmpty) {
    return IqairResult.miss(
        status: 'wrong-country', candidates: wrongCountry);
  }
  for (final candidate in [base, raw]) {
    final hits = index.hits(norm(candidate));
    if (hits.isNotEmpty) {
      final sorted = [...hits]
        ..sort((a, b) => a.rank.compareTo(b.rank));
      return IqairResult.miss(
          status: 'ambiguous',
          candidates: sorted.take(5).toList());
    }
  }
  return const IqairResult.miss(status: 'unmatched', candidates: []);
}

/// Keep hits whose IQAir country matches the workbook's
/// Country cell.
///
/// Connector words and abbreviations are ignored
/// ('Bosnia and Herzegovina' == 'Bosnia Herzegovina',
/// 'UAE' == 'United Arab Emirates'), but the remaining
/// token sets must be **equal**: subset matching
/// paired 'Guinea' with 'Equatorial Guinea' and
/// 'Sudan' with 'South Sudan', and the wrong
/// country's PM2.5 was written into the workbook.
/// An empty result means a candidate exists but in
/// OTHER countries — a miss, not a guess source.
List<IqairCity> _countryFilter(
    List<IqairCity> hits, String? country) {
  if (country == null || country.isEmpty) return hits;
  final ct = _countryTokens(country);
  if (ct.isEmpty) return hits;
  return [
    for (final hit in hits)
      if (_countryTokens(hit.country).length == ct.length &&
          _countryTokens(hit.country).containsAll(ct))
        hit,
  ];
}

Set<String> _countryTokens(String country) {
  final normalised = norm(country);
  final aliased = _countryAliases[normalised] ?? normalised;
  return aliased
      .split(' ')
      .where((token) => token.isNotEmpty &&
          !_countryConnectors.contains(token))
      .toSet();
}

/// Single hit -> itself; several -> the best (lowest)
/// rank.
IqairCity _pick(List<IqairCity> hits) {
  return hits.reduce((a, b) => a.rank <= b.rank ? a : b);
}

/// The normalisation both sides go through: NFKD
/// decompose, drop the combining marks, drop the
/// apostrophes (Xi'an == Xian), fold to lower case,
/// and collapse every non-alphanumeric run to a
/// single space.
String norm(String value) {
  final decomposed = stripDiacritics(value);
  final noApostrophes =
      decomposed.replaceAll("'", '').replaceAll('\u2019', '');
  final lower = noApostrophes.toLowerCase();
  final collapsed =
      lower.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  return collapsed.replaceAll(RegExp(r'\s+'), ' ').trim();
}
