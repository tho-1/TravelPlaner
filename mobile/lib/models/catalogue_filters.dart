/// The catalogue and world-map filter panel: one shared,
/// pure filter model ported rule-for-rule from `filters.py`.
///
/// The legacy app filters the Overview and the World Map
/// with the same helpers, and both pages must stay
/// identical — so this is *one* model both pages embed,
/// with the two rules that used to be re-implemented (and
/// broken) per page:
///
/// 1. **A filter may only remove a row when the field it
///    filters on is populated.** A destination with no
///    safety rating must not disappear because the safety
///    slider sits at 3.5 — that silently hid Mumbai, Delhi
///    and every freshly added placeholder. Blank cells are
///    always kept.
/// 2. **"Good month" is defined once** (the legacy's
///    `WEATHER_AT_LEAST_OK` synonym set), so the Overview,
///    the map and the trip planner can never disagree.
///
/// Pure Dart: no Flutter, no Turso — `Destination` in,
/// filtered rows out, with the blank counts the UI's
/// invariant caption needs.
library;

import 'destination.dart';
import 'destination_profile.dart';

/// "Weather at least ok in" — the shared vocabulary, the
/// legacy `filters.WEATHER_AT_LEAST_OK` set verbatim.
const weatherAtLeastOk = <String>{
  'ideal', 'good', 'great', 'best', 'green', //
  'ok', 'okay', 'medium', 'yellow',
};

/// The legacy's Yes/No vocabularies (research) — 'x' is
/// the workbook's own tick mark.
const _boolPositives = <String>{
  'true', 'yes', 'ja', 'j', 'y', 'x', '1', '1.0',
};

/// `filters.apply_unvisited`'s positives — 'x' is the
/// workbook's own tick mark.
const _visitedPositives = <String>{'true', 'yes', 'y', '1', '1.0', 'ja', 'j', 'x'};

const _boolNegatives = <String>{'false', 'no', 'nein', 'n', '0', '0.0'};

/// The legacy `filters.EU_POSITIVE` / `EU_NEGATIVE`.
const _euPositives = <String>{
  'true', 'yes', 'ja', 'y', '1', '1.0', 'eu', 'european union',
};
const _euNegatives = <String>{'false', 'no', 'nein', 'n', '0', '0.0', 'non-eu'};

/// One filter state, shared by the catalogue and the map.
///
/// Null means "All" for the selects, the numeric minima
/// default to the column minimum (no filtering), and
/// [onlyUnvisited] is **on** by default on both legacy
/// pages.
class CatalogueFilters {
  final String? continent;

  /// Dependent: the pages scope the country options by the
  /// chosen continent, exactly like the legacy.
  final String? country;

  /// The workbook's `Yes?` column: true = EU, false = not,
  /// null = All.
  final bool? eu;

  /// A full month name ("July"): keep the rows whose rating
  /// for that month is at least ok — or blank.
  final String? weatherMonth;

  final double minSafety;
  final double minReviews;
  final bool onlyUnvisited;

  /// null = All, true = only to-be-researched, false = hide
  /// them.
  final bool? requiresResearch;

  const CatalogueFilters({
    this.continent,
    this.country,
    this.eu,
    this.weatherMonth,
    this.minSafety = 0,
    this.minReviews = 0,
    this.onlyUnvisited = false,
    this.requiresResearch,
  });

  /// The legacy pages' default state.
  factory CatalogueFilters.initial() =>
      const CatalogueFilters(onlyUnvisited: true);

  CatalogueFilters copyWith({
    String? continent,
    String? country,
    bool? eu,
    String? weatherMonth,
    double? minSafety,
    double? minReviews,
    bool? onlyUnvisited,
    bool? requiresResearch,
    bool clearContinent = false,
    bool clearCountry = false,
    bool clearEu = false,
    bool clearWeatherMonth = false,
    bool clearRequiresResearch = false,
  }) {
    return CatalogueFilters(
      continent: clearContinent ? null : (continent ?? this.continent),
      country: clearCountry ? null : (country ?? this.country),
      eu: clearEu ? null : (eu ?? this.eu),
      weatherMonth:
          clearWeatherMonth ? null : (weatherMonth ?? this.weatherMonth),
      minSafety: minSafety ?? this.minSafety,
      minReviews: minReviews ?? this.minReviews,
      onlyUnvisited: onlyUnvisited ?? this.onlyUnvisited,
      requiresResearch: clearRequiresResearch
          ? null
          : (requiresResearch ?? this.requiresResearch),
    );
  }

  /// Whether any control narrows the set at all — the sheet
  /// shows "Clear filters" only when something is on.
  bool get isActive =>
      continent != null ||
      country != null ||
      eu != null ||
      weatherMonth != null ||
      minSafety > 0 ||
      minReviews > 0 ||
      onlyUnvisited ||
      requiresResearch != null;
}

/// The result of applying the filters, with the counts the
/// invariant caption needs.
class FilterOutcome {
  final List<Destination> kept;

  /// Field -> how many rows have no value for it. The
  /// catalogues show this so "why is Mumbai not here?" is
  /// answerable.
  final Map<String, int> missing;

  const FilterOutcome(this.kept, this.missing);

  bool get isEmpty => kept.isEmpty;

  /// How many rows the filters removed.
  int removed(int total) => total - kept.length;

  /// The legacy caption: "Rows without a value are never
  /// hidden by a filter — currently missing: safety (3),
  /// reviews (12)."
  String get missingCaption {
    if (missing.isEmpty) return '';
    final parts = [
      for (final entry in missing.entries) '${entry.key} (${entry.value})',
    ];
    return 'Rows without a value are never hidden by a filter — '
        'currently missing: ${parts.join(', ')}.';
  }
}

/// Slider bounds for a column, tolerant of blanks and junk
/// ("8/10" must not crash the panel) — the legacy
/// `filters.numeric_bounds`.
(double, double) numericBounds(
  Iterable<Object?> values, {
  (double, double) fallback = (0.0, 10.0),
  double top = 10.0,
}) {
  final numbers = [
    for (final value in values)
      if (coerceNumber(value) != null) coerceNumber(value)!,
  ];
  var low = fallback.$1;
  var high = fallback.$2;
  if (numbers.isNotEmpty) {
    low = numbers.reduce((a, b) => a < b ? a : b);
    high = numbers.reduce((a, b) => a > b ? a : b);
  }
  // Keep both bounds inside the scale, then guarantee a
  // usable (min < max) range — a slider with equal bounds
  // throws.
  low = low.clamp(0.0, top);
  high = high.clamp(low, top);
  if (high <= low) {
    high = (low + 1.0).clamp(low, top);
    if (high <= low) {
      low = (top - 1.0).clamp(0.0, top);
    }
  }
  return (low, high);
}

/// The legacy classify: true, false, or "not a boolean
/// value" — which never filters either way.
bool? _classify(Object? value, Set<String> positives, Set<String> negatives) {
  if (isBlank(value)) return null;
  final text = value.toString().trim().toLowerCase();
  if (positives.contains(text)) return true;
  if (negatives.contains(text)) return false;
  return null;
}

/// The filter set, applied. Every predicate keeps blanks:
/// see the library doc.
FilterOutcome applyCatalogueFilters(
  List<Destination> destinations,
  CatalogueFilters filters,
  DestinationProfile Function(Destination) profileOf,
) {
  var kept = destinations;
  final missing = <String, int>{};

  var safetyMissing = 0;
  var reviewsMissing = 0;
  for (final destination in destinations) {
    if (destination.safetyRating == null) safetyMissing++;
    if (profileOf(destination).reviewsCount == null) reviewsMissing++;
  }
  if (safetyMissing > 0) missing['safety'] = safetyMissing;
  if (reviewsMissing > 0) missing['reviews'] = reviewsMissing;

  final continent = filters.continent;
  if (continent != null) {
    final wanted = continent.trim().toLowerCase();
    kept = [
      for (final destination in kept)
        if ((destination.continent ?? '').trim().toLowerCase() == wanted)
          destination,
    ];
  }

  final country = filters.country;
  if (country != null) {
    final wanted = country.trim().toLowerCase();
    kept = [
      for (final destination in kept)
        if ((destination.country ?? '').trim().toLowerCase() == wanted)
          destination,
    ];
  }

  final eu = filters.eu;
  if (eu != null) {
    final result = <Destination>[];
    for (final destination in kept) {
      // The workbook's `Yes?` column; a value that is not a
      // boolean never filters (blank included).
      final flag =
          _classify(destination.column('Yes?'), _euPositives, _euNegatives);
      if (flag == null || flag == eu) result.add(destination);
    }
    kept = result;
  }

  final weatherMonth = filters.weatherMonth;
  if (weatherMonth != null) {
    kept = [
      for (final destination in kept)
        // The shared vocabulary, checked on the raw cell:
        // a month that was never filled in is not evidence
        // of bad weather.
        if (_weatherOk(destination.column(weatherMonth)))
          destination,
    ];
  }

  if (filters.minSafety > 0) {
    final minimum = filters.minSafety;
    kept = [
      for (final destination in kept)
        if (destination.safetyRating == null ||
            destination.safetyRating! >= minimum)
          destination,
    ];
  }

  if (filters.minReviews > 0) {
    final minimum = filters.minReviews;
    kept = [
      for (final destination in kept)
        if (profileOf(destination).reviewsCount == null ||
            profileOf(destination).reviewsCount! >= minimum)
          destination,
    ];
  }

  if (filters.onlyUnvisited) {
    final result = <Destination>[];
    for (final destination in kept) {
      // A blank cell counts as *not* visited, so nothing is
      // hidden by accident.
      final visited =
          _classify(destination.core['visited'], _visitedPositives, const {});
      if (visited != true) result.add(destination);
    }
    kept = result;
  }

  final research = filters.requiresResearch;
  if (research != null) {
    final result = <Destination>[];
    for (final destination in kept) {
      final flag = _classify(
          destination.core['to_be_researched'], _boolPositives, _boolNegatives);
      if (flag == null || flag == research) result.add(destination);
    }
    kept = result;
  }

  return FilterOutcome(kept, missing);
}

/// The raw month cell is blank, or its text is in the
/// shared "at least ok" vocabulary.
bool _weatherOk(Object? value) =>
    isBlank(value) || weatherAtLeastOk.contains(value.toString().trim().toLowerCase());

/// The distinct, sorted option lists the filter sheet needs.
/// The country list is scoped by the chosen continent, the
/// legacy's dependent selectbox.
List<String> continentOptions(List<Destination> destinations) => [
      for (final value in {
        for (final destination in destinations)
          if (destination.continent != null && destination.continent!.isNotEmpty)
            destination.continent!,
      })
        value,
    ]..sort();

List<String> countryOptions(
        List<Destination> destinations, String? continent) =>
    [
      for (final value in {
        for (final destination in destinations)
          if (destination.country != null &&
              destination.country!.isNotEmpty &&
              (continent == null ||
                  (destination.continent ?? '').trim().toLowerCase() ==
                      continent.trim().toLowerCase()))
            destination.country!,
      })
        value,
    ]..sort();
