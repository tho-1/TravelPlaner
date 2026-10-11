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
  final decomposed = _stripDiacritics(value);
  final noApostrophes =
      decomposed.replaceAll("'", '').replaceAll('’', '');
  final lower = noApostrophes.toLowerCase();
  final collapsed =
      lower.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  return collapsed.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Decompose the accented Latin characters the
/// destination names carry (Cancún, Montréal, Zürich,
/// Kraków, Đà Nẵng) to their ASCII base — the NFKD
/// step the legacy normaliser performs. Characters
/// outside the maps are left for the non-alphanumeric
/// collapse to replace with a space, which is the
/// same miss the legacy records.
String _stripDiacritics(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    buffer.write(
        _diacritics[char] ?? _vietnamese[char] ?? char);
  }
  return buffer.toString();
}

/// The Vietnamese letters (Latin Extended-B and the
/// Latin Extended Additional block): the catalogue's
/// Southeast-Asian names carry them, and the ranking
/// spells those cities ASCII ("Da Nang").
const _vietnamese = <String, String>{
  'Đ': 'D', 'đ': 'd',
  'Ă': 'A', 'ă': 'a',
  'Ơ': 'O', 'ơ': 'o',
  'Ư': 'U', 'ư': 'u',
  'Ạ': 'A', 'ạ': 'a', 'Ả': 'A', 'ả': 'a',
  'Ấ': 'A', 'ấ': 'a', 'Ầ': 'A', 'ầ': 'a',
  'Ẩ': 'A', 'ẩ': 'a', 'Ẫ': 'A', 'ẫ': 'a',
  'Ậ': 'A', 'ậ': 'a',
  'Ắ': 'A', 'ắ': 'a', 'Ằ': 'A', 'ằ': 'a',
  'Ẳ': 'A', 'ẳ': 'a', 'Ẵ': 'A', 'ẵ': 'a',
  'Ặ': 'A', 'ặ': 'a',
  'Ẹ': 'E', 'ẹ': 'e', 'Ẻ': 'E', 'ẻ': 'e',
  'Ẽ': 'E', 'ẽ': 'e',
  'Ế': 'E', 'ế': 'e', 'Ề': 'E', 'ề': 'e',
  'Ể': 'E', 'ể': 'e', 'Ễ': 'E', 'ễ': 'e',
  'Ệ': 'E', 'ệ': 'e',
  'Ỉ': 'I', 'ỉ': 'i', 'Ị': 'I', 'ị': 'i',
  'Ọ': 'O', 'ọ': 'o', 'Ỏ': 'O', 'ỏ': 'o',
  'Ố': 'O', 'ố': 'o', 'Ồ': 'O', 'ồ': 'o',
  'Ổ': 'O', 'ổ': 'o', 'Ỗ': 'O', 'ỗ': 'o',
  'Ộ': 'O', 'ộ': 'o',
  'Ớ': 'O', 'ớ': 'o', 'Ờ': 'O', 'ờ': 'o',
  'Ở': 'O', 'ở': 'o', 'Ỡ': 'O', 'ỡ': 'o',
  'Ợ': 'O', 'ợ': 'o',
  'Ụ': 'U', 'ụ': 'u', 'Ủ': 'U', 'ủ': 'u',
  'Ứ': 'U', 'ứ': 'u', 'Ừ': 'U', 'ừ': 'u',
  'Ử': 'U', 'ử': 'u', 'Ữ': 'U', 'ữ': 'u',
  'Ự': 'U', 'ự': 'u',
  'Ỳ': 'Y', 'ỳ': 'y', 'Ỵ': 'Y', 'ỵ': 'y',
  'Ỷ': 'Y', 'ỷ': 'y', 'Ỹ': 'Y', 'ỹ': 'y',
};

/// Accented character -> ASCII base. Covers the
/// Latin-1 Supplement and Latin Extended-A blocks,
/// which is what the workbook's city and country
/// names use.
const _diacritics = <String, String>{
  'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A',
  'Æ': 'AE', 'Ç': 'C',
  'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E',
  'Ì': 'I', 'Í': 'I', 'Î': 'I', 'Ï': 'I',
  'Ð': 'D', 'Ñ': 'N',
  'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', 'Ø': 'O',
  'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U',
  'Ý': 'Y', 'Þ': 'Th', 'ß': 'ss',
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'æ': 'ae', 'ç': 'c',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ð': 'd', 'ñ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ý': 'y', 'þ': 'th', 'ÿ': 'y',
  // Latin Extended-A
  'Ā': 'A', 'ā': 'a', 'Ă': 'A', 'ă': 'a', 'Ą': 'A', 'ą': 'a',
  'Ć': 'C', 'ć': 'c', 'Ĉ': 'C', 'ĉ': 'C', 'Ċ': 'C', 'ċ': 'c',
  'Č': 'C', 'č': 'c', 'Ď': 'D', 'ď': 'd', 'Đ': 'D', 'đ': 'd',
  'Ē': 'E', 'ē': 'e', 'Ĕ': 'E', 'ĕ': 'e', 'Ė': 'E', 'ė': 'e',
  'Ę': 'E', 'ę': 'e', 'Ě': 'E', 'ě': 'e',
  'Ĝ': 'G', 'ĝ': 'g', 'Ğ': 'G', 'ğ': 'g', 'Ġ': 'G', 'ġ': 'g',
  'Ģ': 'G', 'ģ': 'g', 'Ĥ': 'H', 'ĥ': 'h', 'Ħ': 'H', 'ħ': 'h',
  'Ĩ': 'I', 'ĩ': 'i', 'Ī': 'I', 'ī': 'i', 'Ĭ': 'I', 'ĭ': 'i',
  'Į': 'I', 'į': 'i', 'İ': 'I', 'ı': 'i', 'Ĳ': 'IJ', 'ĳ': 'ij',
  'Ĵ': 'J', 'ĵ': 'j', 'Ķ': 'K', 'ķ': 'k', 'ĸ': 'k',
  'Ĺ': 'L', 'ĺ': 'l', 'Ļ': 'L', 'ļ': 'l', 'Ľ': 'L', 'ľ': 'l',
  'Ŀ': 'L', 'ŀ': 'l', 'Ł': 'L', 'ł': 'l',
  'Ń': 'N', 'ń': 'n', 'Ņ': 'N', 'ņ': 'n', 'Ň': 'N', 'ň': 'n',
  'Ŋ': 'N', 'ŋ': 'n',
  'Ō': 'O', 'ō': 'o', 'Ŏ': 'O', 'ŏ': 'o', 'Ő': 'O', 'ő': 'o',
  'Œ': 'OE', 'œ': 'oe',
  'Ŕ': 'R', 'ŕ': 'r', 'Ŗ': 'R', 'ŗ': 'r', 'Ř': 'R', 'ř': 'r',
  'Ś': 'S', 'ś': 's', 'Ŝ': 'S', 'ŝ': 's', 'Ş': 'S', 'ş': 's',
  'Š': 'S', 'š': 's',
  'Ţ': 'T', 'ţ': 't', 'Ť': 'T', 'ť': 't', 'Ŧ': 'T', 'ŧ': 't',
  'Ũ': 'U', 'ũ': 'u', 'Ū': 'U', 'ū': 'u', 'Ŭ': 'U', 'ŭ': 'u',
  'Ů': 'U', 'ů': 'u', 'Ű': 'U', 'ű': 'u', 'Ų': 'U', 'ų': 'u',
  'Ŵ': 'W', 'ŵ': 'w', 'Ŷ': 'Y', 'ŷ': 'y', 'Ÿ': 'Y',
  'Ź': 'Z', 'ź': 'z', 'Ż': 'Z', 'ż': 'z', 'Ž': 'Z', 'ž': 'z',
};
