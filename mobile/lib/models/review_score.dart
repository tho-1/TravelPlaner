/// The review score: the sentiment arithmetic behind the
/// "Reviews" column.
///
/// The Dart port of `review_analyzer.py`, formula for
/// formula:
///
/// * each aspect scores `(pos - neg) / total`, 0 when the
///   aspect is not mentioned at all;
/// * the platform score is a **Bayesian** average of the
///   platform ratings -- a 5.0 from 12 reviews must not
///   outrank a 4.6 from 900 -- mapped from [1, 5] to
///   [-1, 1];
/// * the final score is `50 + 50 * (0.6 * S_aspect + 0.4
///   * S_platform)`, clamped to 0..100 and reported on a
///   0-10 scale with one decimal.
library;

const aspects = <String>[
  'Scenery & atmosphere',
  'Things to do',
  'Food & drink',
  'Value for money',
  'Crowds & overtourism',
  'Safety & cleanliness',
  'Getting around / accessibility',
];

class AspectSentiment {
  final int pos;
  final int neutral;
  final int neg;

  const AspectSentiment({this.pos = 0, this.neutral = 0, this.neg = 0});

  int get total => pos + neutral + neg;

  /// [-1, 1]; an aspect nobody mentioned is 0, not absent.
  double get score => total == 0 ? 0.0 : (pos - neg) / total;
}

class PlatformRating {
  final String sourceName;
  final double avgRating;
  final int reviewCount;

  const PlatformRating({
    required this.sourceName,
    required this.avgRating,
    required this.reviewCount,
  });
}

/// One destination's review inputs.
class DestinationReviewData {
  final String destinationName;
  final String country;
  final Map<String, AspectSentiment> aspectCounts;
  final List<PlatformRating> platformRatings;
  final int totalReviewsAnalyzed;
  final String dateRange;

  const DestinationReviewData({
    required this.destinationName,
    required this.country,
    this.aspectCounts = const {},
    this.platformRatings = const [],
    this.totalReviewsAnalyzed = 100,
    this.dateRange = 'Feb 2024 - Feb 2026',
  });

  /// The average of the seven aspect scores; a missing
  /// aspect counts as 0.
  double calculateAspectScore() {
    if (aspects.isEmpty) return 0.0;
    var sum = 0.0;
    for (final aspect in aspects) {
      sum += (aspectCounts[aspect] ?? const AspectSentiment()).score;
    }
    return sum / aspects.length;
  }

  /// The Bayesian platform score, mapped to [-1, 1].
  ///
  /// `cPrior` is the prior mean (3.5 on a 1-5 scale) and
  /// `mWeight` how many reviews the prior is worth (200):
  /// a 5.0 from a handful of reviews is pulled towards the
  /// prior, a 4.6 from 900 is not.
  double calculatePlatformScore({
    double cPrior = 3.5,
    double mWeight = 200.0,
  }) {
    if (platformRatings.isEmpty) return 0.0;
    final bayesian = <double>[];
    for (final rating in platformRatings) {
      final v = rating.reviewCount.toDouble();
      final r = rating.avgRating;
      bayesian.add((v * r + mWeight * cPrior) / (v + mWeight));
    }
    final average = bayesian.reduce((a, b) => a + b) / bayesian.length;
    final score = (average - 3.0) / 2.0;
    return score.clamp(-1.0, 1.0);
  }

  Map<String, Object?> calculateFinalScores() {
    final aspect = calculateAspectScore();
    final platform = calculatePlatformScore();
    var score100 = (50 + 50 * (0.6 * aspect + 0.4 * platform)).round();
    score100 = score100.clamp(0, 100);
    final score10 = double.parse((score100 / 10.0).toStringAsFixed(1));
    return {
      'Destination': destinationName,
      'Country': country,
      'Final Score (0-100)': score100,
      'Review Score (0-10)': score10,
      'S_aspect': double.parse(aspect.toStringAsFixed(3)),
      'S_platform': double.parse(platform.toStringAsFixed(3)),
      'Total Reviews Analyzed': totalReviewsAnalyzed,
      'Confidence':
          totalReviewsAnalyzed >= 25 ? 'High' : 'Low Confidence',
      'Date Range': dateRange,
      'Aspect Scores': {
        for (final aspect in aspects)
          aspect: double.parse(
              ((aspectCounts[aspect] ?? const AspectSentiment()).score)
                  .toStringAsFixed(3)),
      },
    };
  }
}
