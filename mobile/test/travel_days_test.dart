/// The travel-day model: the free day selection (report b).
///
/// The rules that must not drift: "after" is inclusive and
/// "before" strict (the legacy's Friday/Saturday bounds),
/// the fetch window follows the bound, and the candidate
/// days are the period plus the day before and after.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/travel_days.dart';

void main() {
  final friday = DateTime(2026, 10, 16);

  group('TravelDay.accepts', () {
    test('"any" takes the whole day', () {
      final day = TravelDay(friday);
      expect(day.accepts(0), isTrue);
      expect(day.accepts(23 * 60 + 59), isTrue);
    });

    test('"after" is inclusive (the legacy Friday rule)', () {
      final day = TravelDay(friday, bound: DayBound.after, minutes: 14 * 60);
      expect(day.accepts(13 * 60 + 59), isFalse);
      expect(day.accepts(14 * 60), isTrue);
      expect(day.accepts(23 * 60), isTrue);
    });

    test('"before" is strict (the legacy Saturday rule)', () {
      final day = TravelDay(friday, bound: DayBound.before, minutes: 12 * 60);
      expect(day.accepts(11 * 60 + 59), isTrue);
      expect(day.accepts(12 * 60), isFalse);
    });
  });

  group('fetchWindow', () {
    test('any covers the day, after from the bound, before until it', () {
      final any = TravelDay(friday).fetchWindow();
      expect(any.$1, DateTime(2026, 10, 16));
      expect(any.$2, DateTime(2026, 10, 17));

      final after =
          TravelDay(friday, bound: DayBound.after, minutes: 14 * 60)
              .fetchWindow();
      expect(after.$1, DateTime(2026, 10, 16, 14));
      expect(after.$2, DateTime(2026, 10, 17));

      final before =
          TravelDay(friday, bound: DayBound.before, minutes: 12 * 60)
              .fetchWindow();
      expect(before.$1, DateTime(2026, 10, 16));
      expect(before.$2, DateTime(2026, 10, 16, 12));
    });
  });

  group('describe', () {
    test('names the clock the bound applies to', () {
      expect(TravelDay(friday).describe(outbound: true), 'any time');
      expect(
        TravelDay(friday, bound: DayBound.after, minutes: 14 * 60)
            .describe(outbound: true),
        'departs after 14:00',
      );
      expect(
        TravelDay(friday, bound: DayBound.before, minutes: 9 * 60)
            .describe(outbound: false),
        'lands before 09:00',
      );
    });
  });

  group('the period and its candidate days', () {
    final period = TravelPeriod(DateTime(2026, 12, 10), DateTime(2026, 12, 15));

    test('the candidates are the period plus one day either side', () {
      final days = candidateDays(period);
      expect(days.first, DateTime(2026, 12, 9));
      expect(days.last, DateTime(2026, 12, 16));
      expect(days.length, 8);
    });

    test('the neighbours are the flex days', () {
      expect(isFlexDay(period, DateTime(2026, 12, 9)), isTrue);
      expect(isFlexDay(period, DateTime(2026, 12, 10)), isFalse);
      expect(isFlexDay(period, DateTime(2026, 12, 15)), isFalse);
      expect(isFlexDay(period, DateTime(2026, 12, 16)), isTrue);
    });

    test('the custom default is first day out, last day back', () {
      final plan = periodPlan(period);
      expect(plan.outDays.single.day, DateTime(2026, 12, 10));
      expect(plan.outDays.single.bound, DayBound.any);
      expect(plan.backDays.single.day, DateTime(2026, 12, 15));
    });
  });

  group('the weekend helpers', () {
    test('a Monday plans the coming weekend', () {
      expect(fridayOf(DateTime(2026, 10, 12)), friday);
    });

    test('a Saturday and Sunday belong to the Friday that started them', () {
      expect(fridayOf(DateTime(2026, 10, 17)), friday);
      expect(fridayOf(DateTime(2026, 10, 18)), friday);
    });

    test('a Friday is its own weekend', () {
      expect(fridayOf(friday), friday);
    });

    test('Tue-Thu reach forward to the next Friday', () {
      expect(fridayOf(DateTime(2026, 10, 13)), friday);
      expect(fridayOf(DateTime(2026, 10, 14)), friday);
      expect(fridayOf(DateTime(2026, 10, 15)), friday);
    });

    test('nextFriday honours the lead time', () {
      expect(nextFriday(DateTime(2026, 10, 11)), friday);
      // Less than a week of lead time is pushed to the
      // Friday after.
      expect(nextFriday(DateTime(2026, 10, 11), minimumDaysAhead: 7),
          DateTime(2026, 10, 23));
    });

    test('the legacy preset keeps the five classic rules', () {
      final plan = legacyWeekendPlan(friday);
      expect(plan.outDays.length, 2);
      expect(plan.backDays.length, 3);
      expect(plan.describe(), contains('departs after 14:00'));
      expect(plan.describe(), contains('departs before 12:00'));
      expect(plan.describe(), contains('lands after 12:00'));
      expect(plan.describe(), contains('lands before 09:00'));
    });
  });
}
