/// The AI populate: a generated profile -> one destination
/// row, written back through the repository.
///
/// The Dart port of
/// `deepseek_populator.populate_existing_destination_
/// with_profile` plus `_apply_profile_to_row`, mapped onto
/// the app's data layer: there is no workbook here, so
/// "find the row and set ~40 columns" becomes "build the
/// updated destination and save it once" -- the same
/// read-modify-write the flag editors use, with the typed
/// core and the lossless tail updated together.
///
/// The field map is the legacy one, including its
/// deliberate gaps:
///
/// * "Reachable via" is **not** populated (the column was
///   removed from the workbook);
/// * only `Avg AQI` gets a yearly average -- the other
///   yearly-average columns do not exist;
/// * the review section never blocks the profile: a
///   malformed review block is skipped, the rest written.
///
/// A blank or missing value is skipped rather than
/// overwritten, exactly like `_set`.
library;

import '../models/destination.dart';
import '../models/destination_profile.dart';
import '../models/review_score.dart';

/// What one populate run wrote, for the UI's summary line.
typedef PopulateReport = ({
  bool ok,
  String message,
  double? reviewScore,
  int fieldsWritten,
});

class AiPopulator {
  final Destination destination;

  const AiPopulator(this.destination);

  /// Apply the profile to the destination and return the
  /// updated row. Pure: the caller saves it.
  Destination apply(Map<String, dynamic> profile) {
    final prof = _map(profile['profile']);
    var updated = destination;

    void setCore(String field, Object? value) {
      if (_blank(value)) return;
      updated = updated.withField(field, value);
    }

    void setTail(String column, Object? value) {
      if (_blank(value)) return;
      updated = updated.withTail(column, value);
    }

    // ── identity: the profile's own spelling, else the
    // row's ──
    setCore('country', _text(profile['country']) ?? destination.country);
    setCore('continent',
        _text(profile['continent']) ?? destination.continent);

    // ── written profile fields ──
    setTail('Why to Go There', prof['why_to_go']);
    setTail('What to Expect', prof['what_to_expect']);
    setTail('Ideal Time to Go', prof['ideal_time_to_go']);
    setTail('Avoid Going There', prof['avoid_going']);
    setTail('Recommended Stay', prof['recommended_stay']);
    setCore('avg_cost_day', _number(prof['avg_cost_per_day_eur']));
    setTail('Rent a Car?', prof['rent_a_car']);
    setTail('Highlights', prof['highlights']);
    setTail('Population (Metro Area)', _number(prof['population_metro']));
    setTail('Visa?', prof['visa_requirement']);
    setTail('Visa Requirement', prof['visa_requirement']);
    setCore('flight_time_fra', _number(prof['flight_time_hours']));
    setCore('safety_rating', _number(prof['safety_rating_10']));
    setTail('Introduction Sentence', prof['introduction_sentence']);

    final inEu = prof['in_eu'];
    if (inEu is bool) setTail('Yes?', inEu);

    // ── month ratings ──
    final ratings = _map(prof['month_ratings']);
    for (final month in fullMonths) {
      final value = _text(ratings[month])?.toLowerCase();
      if (value == 'ideal' || value == 'ok' || value == 'bad') {
        setTail(month, value);
      }
    }

    // ── reviews — a malformed section never blocks the rest ──
    // The legacy flow calls .get() on whatever arrived and lets a
    // wrong type raise into its except: a reviews block that is
    // not an object skips the section entirely rather than
    // inventing a neutral score from nothing.
    final reviews = profile['reviews'];
    final praise = reviews is Map ? _text(reviews['praise']) ?? '' : '';
    final dislikes = reviews is Map ? _text(reviews['dislikes']) ?? '' : '';
    if (reviews is Map) {
      try {
        final data = DestinationReviewData(
          destinationName: destination.name,
          country: destination.country ?? '',
          aspectCounts: _aspectCounts(reviews['aspects']),
          platformRatings: _platformRatings(reviews['platform_ratings']),
          totalReviewsAnalyzed:
              _number(reviews['total_reviews_analyzed'])?.toInt() ?? 100,
          dateRange:
              _text(reviews['date_range']) ?? 'Feb 2024 - Feb 2026',
        );
        final scores = data.calculateFinalScores();
        final reviewScore = scores['Review Score (0-10)'] as double?;
        setTail('Reviews', reviewScore);
        setTail('Tourist Reviews',
            '$praise Recurring criticisms mention $dislikes');
        setTail('What do the reviews praise?', praise);
        setTail('What do they dislike?', dislikes);
      } catch (_) {
        // A raise anywhere in the scoring (a rating that is
        // not a number, a count that is a string) skips the
        // section: the written profile and the climate data
        // are still valuable.
      }
    }

    // ── monthly climate ──
    final climate = _map(profile['climate']);
    const series = {
      'High (C)': 'high_c',
      'Low (C)': 'low_c',
      'Rainy Days': 'rainy_days',
      'Rain (mm)': 'rain_mm',
      'AQI': 'aqi',
    };
    for (final entry in series.entries) {
      final values = climate[entry.value];
      if (values is! List || values.length < 12) continue;
      for (var i = 0; i < 12; i++) {
        setTail('${monthAbbreviations[i]} ${entry.key}', _number(values[i]));
      }
    }
    setTail('Avg AQI', _average(climate['aqi']));

    // The placeholder status clears, so the "incomplete"
    // warning disappears — the legacy flow's `.value = None`
    // trick, which openpyxl needs and the database does
    // not: a NULL is a NULL.
    updated = updated.withField('data_status', null);
    return updated;
  }

  static double? _average(Object? values) {
    if (values is! List) return null;
    final numbers = [
      for (final value in values)
        if (_number(value) != null) _number(value)!,
    ];
    if (numbers.isEmpty) return null;
    final mean = numbers.reduce((a, b) => a + b) / numbers.length;
    return double.parse(mean.toStringAsFixed(1));
  }

  static Map<String, AspectSentiment> _aspectCounts(Object? raw) {
    final aspectsRaw = _map(raw);
    final out = <String, AspectSentiment>{};
    for (final aspect in aspects) {
      final counts = _map(aspectsRaw[aspect]);
      out[aspect] = AspectSentiment(
        pos: _number(counts['pos'])?.toInt() ?? 0,
        neutral: _number(counts['neutral'])?.toInt() ?? 0,
        neg: _number(counts['neg'])?.toInt() ?? 0,
      );
    }
    return out;
  }

  static List<PlatformRating> _platformRatings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          PlatformRating(
            sourceName: _text(entry['source_name']) ?? 'Unknown',
            avgRating: _number(entry['avg_rating']) ?? 0.0,
            reviewCount: _number(entry['review_count'])?.toInt() ?? 0,
          ),
    ];
  }
}

bool _blank(Object? value) =>
    value == null ||
    (value is String && value.trim().isEmpty) ||
    isBlank(value);

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

String? _text(Object? value) => value == null ? null : '$value'.trim();

/// `deepseek_populator._num`: a float or nothing, never a
/// crash on "45" or "n/a".
double? _number(Object? value) {
  if (value == null || value is bool) return null;
  if (value is num) return value.toDouble();
  return coerceNumber('$value');
}
