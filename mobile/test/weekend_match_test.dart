/// The pure matcher: the weekend rules, the pairing, the
/// ranking, and the "why did it drop that" reporting. All
/// fixtures are naive wall-clocks, the same convention the
/// board parser keeps.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/timetable.dart' show fetchWindow;
import 'package:travel_planner/models/weekend_match.dart';

/// Friday 2026-10-16 (a real Friday in the fixtures' week).
final friday = DateTime(2026, 10, 16);
final saturday = DateTime(2026, 10, 17);
final sunday = DateTime(2026, 10, 18);
final monday = DateTime(2026, 10, 19);

final weekend = Weekend(friday);

Flight out({
  String flightNo = 'LH1000',
  String airline = 'LH',
  String destination = 'LHR',
  DateTime? departure,
}) {
  return Flight(
    flightNo: flightNo,
    airline: airline,
    origin: 'FRA',
    destination: destination,
    departure: departure ?? friday.add(const Duration(hours: 15)),
    arrival: (departure ?? friday.add(const Duration(hours: 15)))
        .add(const Duration(hours: 2)),
  );
}

Flight back({
  String flightNo = 'LH2000',
  String airline = 'LH',
  String origin = 'LHR',
  DateTime? departure,
}) {
  final dep = departure ?? saturday.add(const Duration(hours: 18));
  return Flight(
    flightNo: flightNo,
    airline: airline,
    origin: origin,
    destination: 'FRA',
    departure: dep,
    arrival: dep.add(const Duration(hours: 2)),
  );
}

void main() {
  group('holiday bridge days', () {
    final thursday = DateTime(2026, 10, 15);
    final tuesday = DateTime(2026, 10, 20);

    test('Thursday out is off by default and off the matcher', () {
      const windows = Windows();
      expect(windows.thursdayFrom, isNull);
      expect(
        isOutboundCandidate(
            out(departure: thursday.add(const Duration(hours: 15))),
            weekend,
            windows),
        isFalse,
      );
    });

    test('switching Thursday on accepts a Thursday departure', () {
      const windows = Windows(thursdayFrom: 14 * 60);
      expect(
        isOutboundCandidate(
            out(departure: thursday.add(const Duration(hours: 13, minutes: 59))),
            weekend,
            windows),
        isFalse,
      );
      expect(
        isOutboundCandidate(
            out(departure: thursday.add(const Duration(hours: 14))),
            weekend,
            windows),
        isTrue,
      );
    });

    test('Tuesday back is off by default and on when set', () {
      const off = Windows();
      expect(
        isReturnCandidate(
            back(departure: tuesday.add(const Duration(hours: 6))),
            weekend,
            off),
        isFalse,
      );

      const on = Windows(tuesdayReturnBefore: 9 * 60);
      // back() lands two hours after departure: 06:30 lands
      // 08:30 (before 09:00), 08:00 lands 10:00 (after).
      expect(
        isReturnCandidate(
            back(departure: tuesday.add(const Duration(hours: 6, minutes: 30))),
            weekend,
            on),
        isTrue,
      );
      expect(
        isReturnCandidate(
            back(departure: tuesday.add(const Duration(hours: 8))),
            weekend,
            on),
        isFalse,
      );
    });

    test('a day switched off fetches no board window', () {
      const windows = Windows(
        thursdayFrom: 14 * 60,
        tuesdayReturnBefore: 9 * 60,
      );
      final (since, until) =
          fetchWindow(weekend, windows, thursday, 'departures');
      expect(since, thursday.add(const Duration(hours: 14)));
      expect(until, weekend.friday);

      final (tueSince, tueUntil) =
          fetchWindow(weekend, windows, tuesday, 'arrivals');
      expect(tueSince, tuesday);
      expect(tueUntil, tuesday.add(const Duration(hours: 9)));

      // Saturday-out disabled: no window at all.
      const satOff = Windows(saturdayBefore: null);
      expect(
        fetchWindow(weekend, satOff, saturday, 'departures'),
        (null, null),
      );
    });

    test('Sunday can be switched off entirely', () {
      const windows = Windows(sundayEnabled: false);
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 18))),
            weekend,
            windows),
        isFalse,
      );
      expect(
        fetchWindow(weekend, windows, sunday, 'arrivals'),
        (null, null),
      );
    });

    test('a disabled day is not described as an option', () {
      const windows = Windows(thursdayFrom: null, tuesdayReturnBefore: null);
      expect(windows.describe(), startsWith('out:'));
      expect(windows.describe(), isNot(contains('Thu')));
      expect(windows.describe(), isNot(contains('Tue')));
      // The enabled legacy days are still spelled out.
      expect(windows.describe(), contains('Fri from 14:00'));
      expect(windows.describe(), contains('Mon before 09:00'));
    });
  });

  group('weekendContaining', () {
    test('a Monday plans the coming weekend', () {
      final result = weekendContaining(DateTime(2026, 10, 12)); // Monday
      expect(result.friday, friday);
    });

    test('a Saturday and Sunday belong to the Friday that started them', () {
      expect(weekendContaining(saturday).friday, friday);
      expect(weekendContaining(sunday).friday, friday);
    });

    test('a Friday is its own weekend', () {
      expect(weekendContaining(friday).friday, friday);
    });

    test('Tue-Thu reach forward to the next Friday', () {
      expect(weekendContaining(DateTime(2026, 10, 13)).friday, friday);
      expect(weekendContaining(DateTime(2026, 10, 14)).friday, friday);
      expect(weekendContaining(DateTime(2026, 10, 15)).friday, friday);
    });
  });

  test('nextFriday honours the lead time', () {
    final today = DateTime(2026, 10, 11); // Sunday
    expect(nextFriday(today), friday);
    // Less than a week of lead time is pushed to the Friday after.
    expect(nextFriday(today, minimumDaysAhead: 7), DateTime(2026, 10, 23));
    expect(nextFriday(today, minimumDaysAhead: 8), DateTime(2026, 10, 23));
  });

  group('candidate windows', () {
    final windows = const Windows();

    test('outbound Friday needs 14:00 or later', () {
      expect(
        isOutboundCandidate(out(departure: friday.add(const Duration(hours: 13, minutes: 59))), weekend, windows),
        isFalse,
      );
      expect(
        isOutboundCandidate(out(departure: friday.add(const Duration(hours: 14))), weekend, windows),
        isTrue,
      );
    });

    test('outbound Saturday stops before noon', () {
      expect(
        isOutboundCandidate(
            out(departure: saturday.add(const Duration(hours: 11, minutes: 59))),
            weekend,
            windows),
        isTrue,
      );
      expect(
        isOutboundCandidate(out(departure: saturday.add(const Duration(hours: 12))), weekend, windows),
        isFalse,
      );
    });

    test('a Sunday outbound is never a candidate', () {
      expect(
        isOutboundCandidate(out(departure: sunday.add(const Duration(hours: 10))), weekend, windows),
        isFalse,
      );
    });

    test('return Saturday lands after noon, Sunday always, Monday before 09:00', () {
      // The rule is on the *arrival* (which flight lands
      // when), the same leg the legacy page checks.
      expect(
        isReturnCandidate(
            back(departure: saturday.add(const Duration(hours: 9))),
            weekend,
            windows),
        isFalse,
      );
      expect(
        isReturnCandidate(
            back(departure: saturday.add(const Duration(hours: 12))),
            weekend,
            windows),
        isTrue,
      );
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 23))),
            weekend,
            windows),
        isTrue,
      );
      expect(
        isReturnCandidate(
            back(departure: monday.subtract(const Duration(hours: 2))),
            weekend,
            windows),
        isTrue,
      );
      expect(
        isReturnCandidate(back(departure: monday.add(const Duration(hours: 7))),
            weekend,
            windows),
        isFalse,
      );
    });

    test('a flight that is not direct to or from FRA is no candidate', () {
      expect(
        isOutboundCandidate(
          out(departure: friday.add(const Duration(hours: 16)))
              .copyWithForTest(origin: 'MUC'),
          weekend,
          windows,
        ),
        isFalse,
      );
    });

    test('the Sunday bound applies only when it is set', () {
      // Off (the default): any Sunday return counts.
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 23))),
            weekend,
            windows),
        isTrue,
      );
      // On: the return must land by the bound. The
      // `back()` fixture lands two hours after it
      // departs, so the departure times below land at
      // 19:00 and 21:00.
      final limited =
          const Windows(sundayReturnUntil: 20 * 60);
      expect(limited.describe(), contains('Sun before 20:00'));
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 17))),
            weekend,
            limited),
        isTrue,
      );
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 19))),
            weekend,
            limited),
        isFalse,
      );
    });
  });

  group('nights', () {
    test('land Friday, leave Sunday is two nights', () {
      final option = nightsAway(
        out(departure: friday.add(const Duration(hours: 16))),
        back(departure: sunday.add(const Duration(hours: 18))),
      );
      expect(option, 2);
    });

    test('an overnight return that lands the morning it left is zero, not negative', () {
      final late = Flight(
        flightNo: 'LH1',
        airline: 'LH',
        origin: 'FRA',
        destination: 'LHR',
        departure: sunday.add(const Duration(hours: 23)),
        arrival: monday.add(const Duration(hours: 1)),
      );
      final early = Flight(
        flightNo: 'LH2',
        airline: 'LH',
        origin: 'LHR',
        destination: 'FRA',
        departure: monday.add(const Duration(hours: 0)),
        arrival: monday.add(const Duration(hours: 2)),
      );
      expect(nightsAway(late, early), 0);
    });
  });

  group('findWeekends', () {
    bool benefitAll(String airline) => true;
    (String, String)? lookupAll(String airport) => const ('Somewhere', 'XX');

    test('a city needs both legs and is ranked and labelled', () {
      final report = findWeekends(
        outbound: [out()],
        returns: [back()],
        weekend: weekend,
        windows: const Windows(),
        benefitCheck: benefitAll,
        cityLookup: lookupAll,
      );
      expect(report.cityCount, 1);
      expect(report.cities.single.city, 'Somewhere');
      expect(report.optionCount, 1);
      expect(report.oneWayOnly, isEmpty);
    });

    test('one leg only is reported separately, not dropped', () {
      final report = findWeekends(
        outbound: [out()],
        returns: const [],
        weekend: weekend,
        windows: const Windows(),
        benefitCheck: benefitAll,
        cityLookup: lookupAll,
      );
      expect(report.cities, isEmpty);
      expect(report.oneWayOnly.single.city, 'Somewhere');
    });

    test('an airline without benefits is counted and explained', () {
      final report = findWeekends(
        outbound: [out(), out(flightNo: 'BA1', airline: 'BA')],
        returns: [back()],
        weekend: weekend,
        windows: const Windows(),
        benefitCheck: (airline) => airline == 'LH',
        cityLookup: lookupAll,
      );
      expect(report.outboundRejectedAirlines, {'BA': 1});
      expect(describeRule(report.outboundRejectedAirlines),
          contains('BA (1)'));
      expect(report.cities.single.count, 1);
    });

    test('an unmapped airport keeps its code as the label and is flagged', () {
      final report = findWeekends(
        outbound: [out()],
        returns: [back()],
        weekend: weekend,
        windows: const Windows(),
        benefitCheck: benefitAll,
        cityLookup: (_) => null,
      );
      expect(report.cities.single.city, '?LHR');
      expect(report.cities.single.unmappedAirports, {'LHR'});
    });

    test('a return before the outbound lands is not pairable', () {
      final report = findWeekends(
        outbound: [out(departure: saturday.add(const Duration(hours: 11)))],
        returns: [back(departure: saturday.add(const Duration(hours: 12)))],
        weekend: weekend,
        windows: const Windows(),
        benefitCheck: benefitAll,
        cityLookup: lookupAll,
      );
      // Out departs Sat 11:00, lands Sat 13:00; the return
      // departs Sat 12:00 -- before the arrival, so no pair.
      expect(report.cities, isEmpty);
    });

    test('the best options prefer fewer nights and a Sunday return', () {
      final report = findWeekends(
        outbound: [
          out(departure: friday.add(const Duration(hours: 16))),
        ],
        returns: [
          back(flightNo: 'LH9', departure: monday.add(const Duration(hours: 6))),
          back(flightNo: 'LH8', departure: sunday.add(const Duration(hours: 19))),
          back(flightNo: 'LH7', departure: sunday.add(const Duration(hours: 12))),
        ],
        weekend: weekend,
        windows: const Windows(),
        benefitCheck: benefitAll,
        cityLookup: lookupAll,
      );
      final options = report.cities.single.options;
      expect(options.first.backFlight.flightNo, 'LH7'); // earliest Sunday
      // At most two ways home per outbound flight.
      expect(options.length, 2);
    });
  });
}

/// A tiny seam so the origin can be changed in one test
/// without widening `Flight`'s constructor.
extension _CopyWithForTest on Flight {
  Flight copyWithForTest({String? origin}) => Flight(
        flightNo: flightNo,
        airline: airline,
        origin: origin ?? this.origin,
        destination: destination,
        departure: departure,
        arrival: arrival,
        terminal: terminal,
      );
}
