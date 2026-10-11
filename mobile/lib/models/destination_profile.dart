/// The destination profile: the parsed view of the lossless
/// tail that the legacy detail page reads while rendering.
///
/// The legacy page parses these columns inline (in
/// `render_destination`, `render_climate_dashboard` and the
/// avoid-annotation helper); this module is the Dart port of
/// that parsing so the app shows the same overview, the same
/// best-months chips and the same climate KPIs — including
/// the quirks that are deliberate:
///
/// * a hand-typed "22 °C" or "n/a" must never blank the
///   page: every numeric cell goes through [coerceNumber],
///   which returns null for "no data" and never throws;
/// * "unknown" is not a yes anywhere;
/// * the month ratings have three buckets (ideal / ok /
///   bad) and the reason hints come from the "Avoid Going
///   There" text, parsed with the same segment/range rules
///   the legacy page uses.
///
/// No Flutter, no Turso: `Destination` in, profile out.
library;

import 'destination.dart';

/// The twelve full month names, in board order.
const fullMonths = <String>[
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

/// The twelve abbreviations, same order.
const monthAbbreviations = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov',
  'Dec',
];

/// Values that mean "the cell is empty / not filled in yet".
const blankTokens = <String>{
  '', '-', '--', '—', 'n/a', 'na', 'nan', 'none', 'null', '?', 'unknown', 'tbd',
  'tbd?',
};

/// True when a cell carries no usable value.
bool isBlank(Object? value) {
  if (value == null) return true;
  return blankTokens.contains(value.toString().trim().toLowerCase());
}

final RegExp _numberPattern = RegExp(r'[-+]?\d[\d.,]*');

/// Parse a numeric cell, tolerating "8", "8.0", "8,5",
/// " 7 ", "22 °C", "8/10".
///
/// Returns null for blanks and for anything that holds no
/// number at all, so callers can distinguish "no data" from
/// zero. Only the *first* number in a string is read, so
/// "8/10" is 8 (a rating out of ten) and never 810.
double? coerceNumber(Object? value) {
  if (isBlank(value)) return null;
  if (value is bool) return value ? 1 : 0;
  if (value is num) return value.toDouble();
  final match = _numberPattern.firstMatch(value.toString());
  if (match == null) return null;
  var token = match.group(0)!;
  if (token.contains(',') && token.contains('.')) {
    // 1,234.56 -> thousands separator is a comma
    token = token.replaceAll(',', '');
  } else if (token.contains(',')) {
    // 1,234 -> thousands; 8,5 -> decimal comma
    final parts = token.split(',');
    final head = parts[0];
    final tail = parts.length > 1 ? parts[1] : '';
    final headIsInt = RegExp(r'^[+-]?\d+$').hasMatch(head);
    token = (tail.length == 3 && headIsInt)
        ? token.replaceAll(',', '')
        : token.replaceAll(',', '.');
  }
  return double.tryParse(token);
}

/// The text convention the profile uses: null when blank,
/// otherwise the trimmed text (numbers occur in text
/// columns).
String? profileText(Object? value) {
  if (value == null) return null;
  final raw = value.toString().trim();
  return raw.isEmpty ? null : raw;
}

/// A month's travel rating, with the reason hint when the
/// avoid text explains one.
class MonthRating {
  final String month;
  final String abbreviation;
  final String? level;
  final String? reason;

  const MonthRating({
    required this.month,
    required this.abbreviation,
    this.level,
    this.reason,
  });

  /// Which of the three chips this month renders as.
  MonthLevel get bucket {
    switch (level) {
      case 'ideal':
      case 'good':
      case 'great':
      case 'best':
      case 'green':
        return MonthLevel.ideal;
      case 'ok':
      case 'okay':
      case 'medium':
      case 'yellow':
        return MonthLevel.ok;
      case 'bad':
      case 'poor':
      case 'red':
      case 'worst':
        return MonthLevel.bad;
      default:
        return MonthLevel.unknown;
    }
  }

  /// The legacy page shows the reason only for the ok and
  /// bad months — an ideal month needs no apology.
  bool get showReason =>
      (bucket == MonthLevel.ok || bucket == MonthLevel.bad) &&
      reason != null &&
      reason!.isNotEmpty;
}

enum MonthLevel { ideal, ok, bad, unknown }

/// One destination's climate and air-quality series.
class ClimateData {
  final List<double?> highs;
  final List<double?> lows;
  final List<double?> rainyDays;
  final List<double?> rainMm;
  final List<double?> aqi;
  final List<double?> groundAqi;
  final List<double?> typical;
  final List<double?> groundTypical;

  const ClimateData({
    required this.highs,
    required this.lows,
    required this.rainyDays,
    required this.rainMm,
    required this.aqi,
    required this.groundAqi,
    required this.typical,
    required this.groundTypical,
  });

  /// The legacy page decides "has data" over every series;
  /// an all-null destination gets the "being populated"
  /// note instead of an empty chart.
  bool get hasData => [
        ...highs,
        ...lows,
        ...rainMm,
        ...aqi,
        ...groundAqi,
        ...typical,
        ...groundTypical,
      ].any((value) => value != null);
}

/// The parsed profile.
class DestinationProfile {
  final Destination destination;

  final String? introduction;
  final String? whyToGo;
  final String? whatToExpect;
  final String? touristReviews;
  final String? praises;
  final String? dislikes;
  final String? highlights;

  final String? visaRequirement;
  final String? malariaRisk;
  final double? costPerDay;
  final String? rentACar;
  final String? recommendedStay;
  final String? idealTime;
  final String? avoidTime;
  final double? population;

  final String? foodSpiciness;
  final String? foodDescription;
  final String? foodDishes;

  final int? reviewsCount;
  final String? dataStatus;

  final List<MonthRating> months;
  final ClimateData climate;

  final int? iqairRank;
  final double? iqairPm25;

  final String? aqiSource;

  const DestinationProfile({
    required this.destination,
    this.introduction,
    this.whyToGo,
    this.whatToExpect,
    this.touristReviews,
    this.praises,
    this.dislikes,
    this.highlights,
    this.visaRequirement,
    this.malariaRisk,
    this.costPerDay,
    this.rentACar,
    this.recommendedStay,
    this.idealTime,
    this.avoidTime,
    this.population,
    this.foodSpiciness,
    this.foodDescription,
    this.foodDishes,
    this.reviewsCount,
    this.dataStatus,
    this.months = const [],
    this.climate = const ClimateData(
      highs: [], lows: [], rainyDays: [], rainMm: [], aqi: [], groundAqi: [],
      typical: [], groundTypical: [],
    ),
    this.iqairRank,
    this.iqairPm25,
    this.aqiSource,
  });

  factory DestinationProfile.from(Destination destination) {
    String? text(String column) => profileText(destination.column(column));
    double? number(String column) => coerceNumber(destination.column(column));

    final avoidRaw = text('Avoid Going There');
    final reasons =
        avoidRaw == null ? const <String, String>{} : parseAvoidAnnotations(avoidRaw);

    final months = <MonthRating>[
      for (var i = 0; i < 12; i++)
        MonthRating(
          month: fullMonths[i],
          abbreviation: monthAbbreviations[i],
          level: text(fullMonths[i])?.toLowerCase(),
          reason: reasons[fullMonths[i]],
        ),
    ];

    final climate = ClimateData(
      highs: [for (final m in monthAbbreviations) number('$m High (C)')],
      lows: [for (final m in monthAbbreviations) number('$m Low (C)')],
      rainyDays: [for (final m in monthAbbreviations) number('$m Rainy Days')],
      rainMm: [for (final m in monthAbbreviations) number('$m Rain (mm)')],
      aqi: [for (final m in monthAbbreviations) number('$m AQI')],
      groundAqi: [for (final m in monthAbbreviations) number('$m AQI (Ground)')],
      typical: [for (final m in monthAbbreviations) number('$m AQI (Typical)')],
      groundTypical: [
        for (final m in monthAbbreviations) number('$m AQI (Ground Typical)')
      ],
    );

    final reviews = destination.column('Reviews');
    final rank = number('IQAir Rank');
    final pm25 = number('IQAir PM2.5');
    return DestinationProfile(
      destination: destination,
      introduction: text('Introduction Sentence'),
      whyToGo: text('Why to Go There'),
      whatToExpect: text('What to Expect'),
      touristReviews: text('Tourist Reviews'),
      praises: text('What do the reviews praise?'),
      dislikes: text('What do they dislike?'),
      highlights: text('Highlights'),
      visaRequirement: text('Visa Requirement') ?? text('Visa?'),
      malariaRisk: text('Malaria risk?'),
      costPerDay: number('Avg. Cost/Day (3* Hotel & Food)'),
      rentACar: text('Rent a Car?'),
      recommendedStay: text('Recommended Stay'),
      idealTime: text('Ideal Time to Go'),
      avoidTime: text('Avoid Going There'),
      population: number('Population (Metro Area)'),
      foodSpiciness: text('Food - Spicyness'),
      foodDescription: text('Food - Description'),
      foodDishes: text('Food - Main Dishes'),
      reviewsCount: reviews == null ? null : coerceNumber(reviews)?.round(),
      dataStatus: text('Data Status'),
      months: months,
      climate: climate,
      iqairRank: rank?.round(),
      iqairPm25: pm25,
      aqiSource: text('AQI Source'),
    );
  }

  String get name => destination.name;

  bool get hasOverviewText => [
        introduction, whyToGo, whatToExpect, touristReviews, praises, dislikes,
      ].any((value) => value != null && value.isNotEmpty);

  bool get hasHighlights => highlights != null && highlights!.isNotEmpty;

  bool get hasFood => [foodSpiciness, foodDescription, foodDishes]
      .any((value) => value != null && value.isNotEmpty);

  /// The main dishes, split the way the legacy
  /// page splits them: on commas, semicolons
  /// and newlines.
  List<String> get foodDishList {
    final raw = foodDishes;
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    return [
      for (final part in raw.split(RegExp(r'[,;\n]+')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// "6/10" — the legacy's `{num:g}/10`
  /// spiciness display, or "—" when the cell
  /// holds no number.
  String get foodSpicinessText {
    final value =
        foodSpiciness == null ? null : coerceNumber(foodSpiciness);
    if (value == null) return '—';
    final asInt = value.roundToDouble();
    final text = (value == asInt)
        ? asInt.round().toString()
        : value.toString();
    return '$text/10';
  }

  // ── climate KPIs ─────────────────────────────────────────────────────────

  /// "35 °C (Jul)" — the hottest month's high.
  (double, String)? get peakHigh {
    var best = (double.negativeInfinity, '');
    var found = false;
    for (var i = 0; i < climate.highs.length; i++) {
      final value = climate.highs[i];
      if (value == null) continue;
      if (!found || value > best.$1) {
        best = (value, monthAbbreviations[i]);
        found = true;
      }
    }
    return found ? best : null;
  }

  /// "78 mm (Nov)" — the wettest month.
  (double, String)? get wettestMonth {
    var best = (double.negativeInfinity, '');
    var found = false;
    for (var i = 0; i < climate.rainMm.length; i++) {
      final value = climate.rainMm[i];
      if (value == null) continue;
      if (!found || value > best.$1) {
        best = (value, monthAbbreviations[i]);
        found = true;
      }
    }
    return found ? best : null;
  }

  /// The mean of the months that have a value.
  double? get averageAqi {
    final values = climate.aqi.where((v) => v != null).cast<double>().toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  /// The AQI band the legacy page's badge uses.
  static String aqiBand(double average) {
    if (average <= 50) return 'Good';
    if (average <= 100) return 'Moderate';
    if (average <= 150) return 'Unhealthy for Sensitive';
    return 'Unhealthy';
  }

  /// The best months, as the legacy KPI card computes them:
  /// the ideal-rated months first, and — only when no month
  /// is rated ideal — the three driest months that still
  /// have acceptable air (the fallback that used to ignore
  /// AQI and recommend smog).
  List<String> get bestMonths {
    final ideal = <String>[];
    for (final month in months) {
      if (month.bucket == MonthLevel.ideal) ideal.add(month.abbreviation);
    }
    if (ideal.isNotEmpty || climate.rainMm.isEmpty) {
      return ideal.take(4).toList();
    }
    final ranked = <(String, double, double?)>[];
    for (var i = 0; i < climate.rainMm.length; i++) {
      final rain = climate.rainMm[i];
      if (rain == null) continue;
      ranked.add((monthAbbreviations[i], rain, climate.aqi[i]));
    }
    ranked.sort((a, b) {
      final byRain = a.$2.compareTo(b.$2);
      if (byRain != 0) return byRain;
      final aAqi = a.$3 ?? 9999;
      final bAqi = b.$3 ?? 9999;
      return aAqi.compareTo(bAqi);
    });
    return [
      for (final (month, _, aqi) in ranked.take(3))
        if (aqi == null || aqi <= 100) month,
    ];
  }
}

// ── the avoid-text parser ─────────────────────────────────────────────────

/// Parse the "Avoid Going There" text into
/// month -> reason hints.
///
/// The legacy page supports what the user actually wrote:
/// "Summer (June-August) (very hot and humid)" gives every
/// month from June to August the "very hot and humid"
/// reason; "Winter (December-February)" wraps around the
/// year boundary. A segment that names no month contributes
/// no reasons rather than a wrong one.
Map<String, String> parseAvoidAnnotations(String raw) {
  if (raw.trim().isEmpty) return const {};
  final result = <String, String>{};
  for (final segment in _splitSegments(raw)) {
    final parens = RegExp(r'\(([^)]+)\)').allMatches(segment);
    final months = <String>[];
    final reasons = <String>[];
    for (final match in parens) {
      final content = match.group(1)!.trim();
      final range = RegExp(r'([A-Za-z]+)[\-–]([A-Za-z]+)$').firstMatch(content);
      if (range != null) {
        final monthsInRange = _monthsInRange(range.group(1)!, range.group(2)!);
        months.addAll(monthsInRange);
        continue;
      }
      final candidates = content.split(RegExp(r'[,\s]+'))
          .where((part) => part.isNotEmpty)
          .toList();
      if (candidates.isNotEmpty &&
          candidates.every((part) => _normaliseMonth(part) != null)) {
        for (final candidate in candidates) {
          final month = _normaliseMonth(candidate);
          if (month != null) months.add(month);
        }
        continue;
      }
      reasons.add(content);
    }

    // A plain-text month range outside the parens:
    // "June to September" or a short "Jun-Aug".
    final plain = segment.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
    final plainRange = RegExp(r'\b([A-Za-z]+)\s+(?:to|-)\s+([A-Za-z]+)\b',
            caseSensitive: false)
        .firstMatch(plain);
    if (plainRange != null) {
      months.addAll(
          _monthsInRange(plainRange.group(1)!, plainRange.group(2)!));
    }
    if (months.isEmpty) {
      final shortRange =
          RegExp(r'\b([A-Za-z]{3})-([A-Za-z]{3})\b').firstMatch(plain);
      if (shortRange != null) {
        months.addAll(
            _monthsInRange(shortRange.group(1)!, shortRange.group(2)!));
      }
    }

    final reason = reasons.join('; ');
    for (final month in months) {
      final existing = result[month];
      if (existing == null || existing.isEmpty) {
        result[month] = reason;
      } else if (reason.isNotEmpty && !existing.contains(reason)) {
        result[month] = '$existing; $reason';
      }
    }
  }
  return result;
}

/// Split on ' and ' only when not inside parentheses, so a
/// reason like "(humid and grey)" stays one segment.
List<String> _splitSegments(String text) {
  final segments = <String>[];
  final current = StringBuffer();
  var depth = 0;
  var i = 0;
  while (i < text.length) {
    final char = text[i];
    if (char == '(') {
      depth++;
      current.write(char);
      i++;
    } else if (char == ')') {
      depth = depth > 0 ? depth - 1 : 0;
      current.write(char);
      i++;
    } else if (depth == 0 &&
        text.substring(i).toLowerCase().startsWith(' and ')) {
      segments.add(current.toString().trim());
      current.clear();
      i += 5;
    } else {
      current.write(char);
      i++;
    }
  }
  final tail = current.toString().trim();
  if (tail.isNotEmpty) segments.add(tail);
  return segments.where((segment) => segment.isNotEmpty).toList();
}

String? _normaliseMonth(String value) {
  final lower = value.trim().toLowerCase();
  final byFull = fullMonths.firstWhere(
    (month) => month.toLowerCase() == lower,
    orElse: () => '',
  );
  if (byFull.isNotEmpty) return byFull;
  if (lower.length >= 3) {
    final byAbbreviation = fullMonths.firstWhere(
      (month) => month.toLowerCase().startsWith(lower.substring(0, 3)),
      orElse: () => '',
    );
    if (byAbbreviation.isNotEmpty) return byAbbreviation;
  }
  return null;
}

List<String> _monthsInRange(String start, String end) {
  final from = _normaliseMonth(start);
  final to = _normaliseMonth(end);
  if (from == null || to == null) return const [];
  final startIndex = fullMonths.indexOf(from);
  final endIndex = fullMonths.indexOf(to);
  if (startIndex <= endIndex) {
    return fullMonths.sublist(startIndex, endIndex + 1);
  }
  return [...fullMonths.sublist(startIndex), ...fullMonths.sublist(0, endIndex + 1)];
}
