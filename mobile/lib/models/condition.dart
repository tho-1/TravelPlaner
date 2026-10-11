/// Travel conditions: the month ratings' meaning, and the
/// country-level rollup that the legacy map's choropleth uses.
///
/// Ported from `pages/world_map.py` — `_normalize_condition`
/// and the "Ideal > Ok > Bad > Unknown" rule — plus the
/// colour palette the legacy page uses, so the app's map
/// reads the same way the PC map does.
library;

import 'destination_profile.dart';

/// The four buckets, in the legacy palette's own terms.
enum Condition {
  /// The palette colour, stored as a plain ARGB value so this
  /// model stays Flutter-free (the tests run without a
  /// binding).
  ideal('Ideal', 0xFF2ECC71),
  ok('Ok', 0xFFF1C40F),
  bad('Bad', 0xFFE74C3C),
  unknown('Unknown', 0xFF95A5A6);

  final String label;
  final int colorValue;

  const Condition(this.label, this.colorValue);
}

/// The raw cell -> Condition, exactly the legacy mapping
/// (including its synonyms).
Condition normalizeCondition(Object? value) {
  if (value == null) return Condition.unknown;
  final text = value.toString().trim().toLowerCase();
  if (text.isEmpty) return Condition.unknown;
  if ({'ideal', 'good', 'great', 'best', 'green'}.contains(text)) {
    return Condition.ideal;
  }
  if ({'ok', 'okay', 'medium', 'yellow'}.contains(text)) return Condition.ok;
  if ({'bad', 'poor', 'red', 'worst'}.contains(text)) return Condition.bad;
  return Condition.unknown;
}

/// The month rating as the profile parses it, as a
/// [Condition] — the same bucket, by the same rule.
Condition conditionOfMonth(MonthRating rating) {
  switch (rating.bucket) {
    case MonthLevel.ideal:
      return Condition.ideal;
    case MonthLevel.ok:
      return Condition.ok;
    case MonthLevel.bad:
      return Condition.bad;
    case MonthLevel.unknown:
      return Condition.unknown;
  }
}

/// A country's condition for one month: the **best**
/// condition among its destinations, the same order the
/// legacy page uses (Ideal > Ok > Bad > Unknown).
Condition countryCondition(Iterable<Condition> conditions) {
  var best = Condition.unknown;
  for (final condition in conditions) {
    // Declaration order is the legacy's order: Ideal > Ok >
    // Bad > Unknown, so the smallest index wins.
    if (condition.conditionIndex < best.conditionIndex) {
      best = condition;
    }
  }
  return best;
}

/// The palette order, as a number the rollup can compare.
extension on Condition {
  int get conditionIndex => Condition.values.indexOf(this);
}
