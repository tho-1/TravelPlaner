/// The destination profile parser: the numeric coercion
/// rules, the month-rating buckets, the avoid-text reasons,
/// and the climate KPIs. Fixtures mirror the workbook's real
/// shapes (floats, "n/a", "22 °C").
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/destination.dart';
import 'package:travel_planner/models/destination_profile.dart';

Destination _destination(Map<String, Object?> columns) => Destination(
      core: {'destination': 'Alexandria', 'country': 'Egypt'},
      columns: [
        for (final entry in columns.entries) (entry.key, entry.value),
      ],
    );

DestinationProfile _profile(Map<String, Object?> columns) =>
    DestinationProfile.from(_destination(columns));

void main() {
  group('coerceNumber', () {
    test('plain numbers and comma decimals', () {
      expect(coerceNumber(45), 45);
      expect(coerceNumber(4.5), 4.5);
      expect(coerceNumber('8,5'), 8.5);
      expect(coerceNumber(' 7 '), 7);
    });

    test('a unit or a rating suffix does not hide the number', () {
      expect(coerceNumber('22 °C'), 22);
      expect(coerceNumber('8/10'), 8);
    });

    test('blank tokens and junk are null, never zero', () {
      expect(coerceNumber(null), isNull);
      expect(coerceNumber(''), isNull);
      expect(coerceNumber('n/a'), isNull);
      expect(coerceNumber('—'), isNull);
      expect(coerceNumber('unknown'), isNull);
      expect(coerceNumber('tbd?'), isNull);
      expect(coerceNumber('no idea'), isNull);
    });
  });

  group('month ratings', () {
    test('the three buckets map the legacy spellings', () {
      final profile = _profile({
        'March': 'ideal',
        'April': 'good',
        'July': 'ok',
        'August': 'yellow',
        'June': 'bad',
        'December': 'worst',
        'January': '',
      });
      expect(profile.months[2].bucket, MonthLevel.ideal);
      expect(profile.months[3].bucket, MonthLevel.ideal);
      expect(profile.months[6].bucket, MonthLevel.ok);
      expect(profile.months[7].bucket, MonthLevel.ok);
      expect(profile.months[5].bucket, MonthLevel.bad);
      expect(profile.months[11].bucket, MonthLevel.bad);
      expect(profile.months[0].bucket, MonthLevel.unknown);
    });
  });

  group('parseAvoidAnnotations', () {
    test('a range in parens covers its months', () {
      final reasons = parseAvoidAnnotations(
          'Summer (June-August) (very hot and humid)');
      expect(reasons['June'], 'very hot and humid');
      expect(reasons['July'], 'very hot and humid');
      expect(reasons['August'], 'very hot and humid');
      expect(reasons.containsKey('May'), isFalse);
    });

    test('a range that wraps the year continues into January', () {
      final reasons = parseAvoidAnnotations('Winter (December-February) (cold)');
      expect(reasons['December'], 'cold');
      expect(reasons['February'], 'cold');
      expect(reasons.containsKey('June'), isFalse);
    });

    test('"and" inside parentheses does not split the segment', () {
      final reasons =
          parseAvoidAnnotations('Rainy season (May-October) (wet and grey)');
      expect(reasons['May'], 'wet and grey');
      expect(reasons['October'], 'wet and grey');
      expect(reasons.containsKey('November'), isFalse);
    });

    test('a "Month to Month" range inside parens names no months, like the legacy',
        () {
      // The legacy parser only understands ranges with a
      // hyphen, so "May to October" in parens contributes no
      // months -- both sides behave the same way.
      final reasons =
          parseAvoidAnnotations('Rainy season (May to October) (wet and grey)');
      expect(reasons, isEmpty);
    });

    test('a descriptive segment without months adds no reasons', () {
      final reasons = parseAvoidAnnotations('It is complicated (very)');
      expect(reasons, isEmpty);
    });

    test('repeated months keep both reasons', () {
      final reasons =
          parseAvoidAnnotations('Summer (June-August) (hot) and Winter (June) (wet)');
      expect(reasons['June'], contains('hot'));
      expect(reasons['June'], contains('wet'));
    });
  });

  group('climate KPIs', () {
    final profile = _profile({
      'Jan High (C)': 17.7,
      'Jul High (C)': 31,
      'Aug High (C)': 31.5,
      'Jan Low (C)': 11,
      'Jan Rain (mm)': 44.4,
      'Dec Rain (mm)': 35.8,
      'Jul Rain (mm)': 0.2,
      'Jan AQI': 76,
      'Feb AQI': 80,
      'Mar AQI': 59,
      'Reviews': 7,
    });

    test('the peak high names the month', () {
      final peak = profile.peakHigh;
      expect(peak!.$1, 31.5);
      expect(peak.$2, 'Aug');
    });

    test('the wettest month names the month', () {
      final wettest = profile.wettestMonth;
      expect(wettest!.$1, 44.4);
      expect(wettest.$2, 'Jan');
    });

    test('the average AQI averages the months that exist', () {
      expect(profile.averageAqi, closeTo((76 + 80 + 59) / 3, 0.001));
      expect(DestinationProfile.aqiBand(profile.averageAqi!), 'Moderate');
    });

    test('a destination with no climate data says so', () {
      final empty = _profile({'Reviews': 1});
      expect(empty.climate.hasData, isFalse);
      expect(empty.peakHigh, isNull);
      expect(empty.averageAqi, isNull);
      expect(empty.bestMonths, isEmpty);
    });
  });

  group('best months', () {
    test('the ideal months come first', () {
      final profile = _profile({
        'March': 'ideal',
        'April': 'ideal',
        'May': 'ideal',
        'June': 'bad',
        'July': 'bad',
        'Aug': 'bad',
        'Oct Rain (mm)': 1,
      });
      expect(profile.bestMonths, ['Mar', 'Apr', 'May']);
    });

    test('without ideal months the driest ones with acceptable air win', () {
      final profile = _profile({
        'Jan Rain (mm)': 44,
        'Jun Rain (mm)': 0.1,
        'Jul Rain (mm)': 0.2,
        'Aug Rain (mm)': 0.3,
        'Sep Rain (mm)': 0.4,
        'Jun AQI': 40,
        'Jul AQI': 200,
        'Aug AQI': 60,
      });
      // Jun and Aug have acceptable air; Jul does not and is
      // dropped even though it is drier than Aug.
      expect(profile.bestMonths, ['Jun', 'Aug']);
    });
  });

  group('profile text fields', () {
    test('the overview fields come from the tail', () {
      final profile = _profile({
        'Introduction Sentence': 'A Mediterranean jewel.',
        'Why to Go There': 'History',
        'What to Expect': 'Bustling',
        'Tourist Reviews': 'Travellers praise',
        'What do the reviews praise?': 'the history',
        'What do they dislike?': 'the touts',
        'Highlights': 'Bibliotheca Alexandrina',
        'Visa Requirement': 'Apply beforehand',
        'Malaria risk?': 'no',
        'Avg. Cost/Day (3* Hotel & Food)': '45',
        'Recommended Stay': '2-3 days',
        'Population (Metro Area)': 5200000,
        'Food - Spicyness': 'mild',
        'IQAir Rank': '12',
        'Reviews': '7',
      });
      expect(profile.introduction, 'A Mediterranean jewel.');
      expect(profile.whyToGo, 'History');
      expect(profile.dislikes, 'the touts');
      expect(profile.highlights, 'Bibliotheca Alexandrina');
      expect(profile.visaRequirement, 'Apply beforehand');
      expect(profile.costPerDay, 45);
      expect(profile.population, 5200000);
      expect(profile.reviewsCount, 7);
      expect(profile.iqairRank, 12);
      expect(profile.hasOverviewText, isTrue);
      expect(profile.hasFood, isTrue);
    });

    test('an overview cell shows what it holds, quirks included', () {
      // The legacy page only blanks on pandas-NA, so an
      // "n/a" in an overview column *is* displayed. Numeric
      // cells are stricter (coerceNumber) -- overview text
      // is not.
      final profile = _profile({'Why to Go There': 'n/a'});
      expect(profile.whyToGo, 'n/a');
      final empty = _profile(<String, Object?>{});
      expect(empty.hasOverviewText, isFalse);
    });
  });

  group('food', () {
    test('the dishes split on commas, semicolons and newlines', () {
      final profile = _profile({
        'Food - Main Dishes': 'Koshari, Molokhia; Fatta\nTaameya',
      });
      expect(profile.foodDishList,
          ['Koshari', 'Molokhia', 'Fatta', 'Taameya']);
    });

    test('blank dishes are an empty list', () {
      expect(_profile({}).foodDishList, isEmpty);
      expect(
          _profile({'Food - Main Dishes': '  '}).foodDishList,
          isEmpty);
    });

    test('the spiciness shows as a fraction of ten', () {
      expect(
          _profile({'Food - Spicyness': '6'}).foodSpicinessText,
          '6/10');
      expect(
          _profile({'Food - Spicyness': '6.5'}).foodSpicinessText,
          '6.5/10');
      expect(
          _profile({'Food - Spicyness': 'n/a'}).foodSpicinessText,
          '—');
      expect(_profile({}).foodSpicinessText, '—');
    });
  });
}
