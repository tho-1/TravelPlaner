/// The pure matcher: the free day rules, the pairing, the
/// ranking, and the "why did it drop that" reporting. All
/// fixtures are naive wall-clocks, the same convention the
/// board parser keeps.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/travel_days.dart';
import 'package:travel_planner/models/weekend_match.dart';

/// Friday 2026-10-16 (a real Friday in the fixtures' week).
final friday = DateTime(2026, 10, 16);
final saturday = DateTime(2026, 10, 17);
final sunday = DateTime(2026, 10, 18);
final monday = DateTime(2026, 10, 19);

/// The legacy weekend rules, expressed in the free day
/// model: out Fri from 14:00 or Sat before 12:00, back Sat
/// after 12:00, Sun any time or Mon before 09:00.
final plan = legacyWeekendPlan(friday);

Flight out({
  String flightNo = 'LH1000',
  String airline = 'LH',
  String destination = 'LHR',
  DateTime? departure,
  String airportName = '',
}) {
  return Flight(
    flightNo: flightNo,
    airline: airline,
    origin: 'FRA',
    destination: destination,
    airportName: airportName,
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
  String airportName = '',
}) {
  final dep = departure ?? saturday.add(const Duration(hours: 18));
  return Flight(
    flightNo: flightNo,
    airline: airline,
    origin: origin,
    destination: 'FRA',
    airportName: airportName,
    departure: dep,
    arrival: dep.add(const Duration(hours: 2)),
  );
}

void main() {
  group('the free day rules', () {
    test('a deselected day is not a candidate at all', () {
      // The legacy plan has no Thursday out.
      expect(
        isOutboundCandidate(
            out(departure: DateTime(2026, 10, 15, 15)), plan),
        isFalse,
      );
    });

    test('a day can be added and bounded freely (the holiday bridge)', () {
      final thursday = DateTime(2026, 10, 15);
      final bridge = TravelPlan(
        outDays: [
          TravelDay(thursday, bound: DayBound.after, minutes: 14 * 60),
          ...plan.outDays,
        ],
        backDays: plan.backDays,
      );
      expect(
        isOutboundCandidate(
            out(departure: thursday.add(const Duration(hours: 13, minutes: 59))),
            bridge),
        isFalse,
      );
      expect(
        isOutboundCandidate(
            out(departure: thursday.add(const Duration(hours: 14))),
            bridge),
        isTrue,
      );
    });

    test('every selected day owns its fetch window', () {
      final windows = [
        for (final day in plan.outDays) day.fetchWindow(),
        for (final day in plan.backDays) day.fetchWindow(),
      ];
      expect(windows.length, 5);
      expect(windows.first.$1, friday.add(const Duration(hours: 14)));
    });

    test('the plan describes only the days it has', () {
      expect(plan.describe(), startsWith('out:'));
      expect(plan.describe(), contains('departs after 14:00'));
      expect(plan.describe(), contains('lands before 09:00'));
    });
  });

  group('candidate days', () {
    test('outbound Friday needs 14:00 or later', () {
      expect(
        isOutboundCandidate(
            out(departure: friday.add(const Duration(hours: 13, minutes: 59))),
            plan),
        isFalse,
      );
      expect(
        isOutboundCandidate(
            out(departure: friday.add(const Duration(hours: 14))), plan),
        isTrue,
      );
    });

    test('outbound Saturday stops before noon', () {
      expect(
        isOutboundCandidate(
            out(departure: saturday.add(const Duration(hours: 11, minutes: 59))),
            plan),
        isTrue,
      );
      expect(
        isOutboundCandidate(
            out(departure: saturday.add(const Duration(hours: 12))), plan),
        isFalse,
      );
    });

    test('a day the plan does not select is never a candidate', () {
      expect(
        isOutboundCandidate(
            out(departure: sunday.add(const Duration(hours: 10))), plan),
        isFalse,
      );
    });

    test('the return rules apply to the landing', () {
      expect(
        isReturnCandidate(
            back(departure: saturday.add(const Duration(hours: 9))), plan),
        isFalse, // lands 11:00 -- before the Saturday bound
      );
      // Saturday: lands 12:00 or later (the bound is
      // inclusive).
      expect(
        isReturnCandidate(
            back(departure: saturday.add(const Duration(hours: 12))), plan),
        isTrue,
      );
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 10))), plan),
        isTrue,
      );
      // Monday: lands before 09:00 (the fixture lands two
      // hours after departure).
      expect(
        isReturnCandidate(
            back(departure: monday.subtract(const Duration(hours: 2))), plan),
        isTrue,
      );
      expect(
        isReturnCandidate(back(departure: monday.add(const Duration(hours: 7))),
            plan),
        isFalse,
      );
    });

    test('a flight that is not direct to or from FRA is no candidate', () {
      expect(
        isOutboundCandidate(
          out(departure: friday.add(const Duration(hours: 16)))
              .copyWithForTest(origin: 'MUC'),
          plan,
        ),
        isFalse,
      );
    });

    test('any time is a first-class state (Sunday, no bound)', () {
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 1))), plan),
        isTrue,
      );
      expect(
        isReturnCandidate(
            back(departure: sunday.add(const Duration(hours: 22))), plan),
        isTrue,
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

    test('an overnight return that lands the morning it left is zero, not negative',
        () {
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
    bool allowAll(String code, String name) => true;
    (String, String)? lookupAll(String airport) => const ('Somewhere', 'XX');

    test('a city needs both legs and is ranked and labelled', () {
      final report = findWeekends(
        outbound: [out()],
        returns: [back()],
        plan: plan,
        airlineCheck: allowAll,
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
        plan: plan,
        airlineCheck: allowAll,
        cityLookup: lookupAll,
      );
      expect(report.cities, isEmpty);
      expect(report.oneWayOnly.single.city, 'Somewhere');
    });

    test('an airline the filter drops is counted and explained', () {
      final report = findWeekends(
        outbound: [out(), out(flightNo: 'BA1', airline: 'BA')],
        returns: [back()],
        plan: plan,
        airlineCheck: (code, name) => code == 'LH',
        cityLookup: lookupAll,
      );
      expect(report.outboundRejectedAirlines, {'BA': 1});
      expect(
          describeRule(report.outboundRejectedAirlines), contains('BA (1)'));
      expect(report.cities.single.count, 1);
    });

    test('an unmapped airport keeps its code as the label and is flagged', () {
      final report = findWeekends(
        outbound: [out()],
        returns: [back()],
        plan: plan,
        airlineCheck: allowAll,
        cityLookup: (_) => null,
      );
      // No board name, no city table entry: the code is the
      // label (report f: never a mystery placeholder).
      expect(report.cities.single.city, 'LHR');
      expect(report.cities.single.unmappedAirports, {'LHR'});
    });

    test('an unmapped airport falls back to the board name', () {
      final report = findWeekends(
        outbound: [out(airportName: 'Cologne Main Station')],
        returns: [back()],
        plan: plan,
        airlineCheck: allowAll,
        cityLookup: (_) => null,
      );
      expect(report.cities.single.city, 'Cologne Main Station');
      expect(report.cities.single.unmappedAirports, {'LHR'});
    });

    test('a return before the outbound lands is not pairable', () {
      final report = findWeekends(
        outbound: [out(departure: saturday.add(const Duration(hours: 11)))],
        returns: [back(departure: saturday.add(const Duration(hours: 12)))],
        plan: plan,
        airlineCheck: allowAll,
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
        plan: plan,
        airlineCheck: allowAll,
        cityLookup: lookupAll,
      );
      final options = report.cities.single.options;
      expect(options.first.backFlight.flightNo, 'LH7'); // earliest Sunday
      // At most two ways home per outbound flight.
      expect(options.length, 2);
    });

    test('the minimum-stay filter drops short stays and says so', () {
      final report = findWeekends(
        outbound: [out(departure: friday.add(const Duration(hours: 16)))],
        returns: [
          back(flightNo: 'LH7', departure: saturday.add(const Duration(hours: 18))),
        ],
        plan: plan,
        airlineCheck: allowAll,
        cityLookup: lookupAll,
        minNights: 2,
      );
      expect(report.shortStaysDropped, 1);
      expect(report.shortStayCities, 1);
      expect(report.cities, isEmpty);
      // The city must not sneak back in as a "one leg only"
      // near miss: both legs qualified, the stay was short.
      expect(report.oneWayOnly, isEmpty);
    });

    test('the default floor is one night: same-day trips drop', () {
      final report = findWeekends(
        outbound: [out(departure: sunday.add(const Duration(hours: 8)))],
        returns: [
          back(
              flightNo: 'LH7',
              departure: sunday.add(const Duration(hours: 20))),
        ],
        plan: TravelPlan(
          outDays: [TravelDay(sunday)],
          backDays: [TravelDay(sunday)],
        ),
        airlineCheck: allowAll,
        cityLookup: lookupAll,
      );
      expect(report.shortStaysDropped, 1);
      expect(report.cities, isEmpty);
    });
  });

  group('the result summary line', () {
    CityResult cityWith(List<TripOption> options) => CityResult(
          city: 'Rome',
          country: 'IT',
          options: options,
        );

    TripOption option({
      required DateTime outDeparture,
      required DateTime backDeparture,
      required DateTime backArrival,
      int nights = 2,
    }) =>
        TripOption(
          city: 'Rome',
          country: 'IT',
          outFlight: Flight(
            flightNo: 'LH1000',
            airline: 'LH',
            origin: 'FRA',
            destination: 'FCO',
            departure: outDeparture,
            arrival: outDeparture.add(const Duration(hours: 2)),
          ),
          backFlight: Flight(
            flightNo: 'LH2000',
            airline: 'LH',
            origin: 'FCO',
            destination: 'FRA',
            departure: backDeparture,
            arrival: backArrival,
          ),
          nights: nights,
        );

    test('it names the earliest departure and the latest Sunday return',
        () {
      // "Earliest out Fr, 13:30. Latest return Sunday, 19:00 (takeoff)."
      final summary = citySummary(cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 18, 19),
          backArrival: DateTime(2026, 10, 18, 21),
        ),
      ]));
      expect(summary, contains('earliest out Fri 13:30'));
      expect(summary, contains('latest return Sunday 19:00 (takeoff)'));
      expect(summary, contains('2🛏'));
      expect(summary, isNot(contains('Monday')),
          reason: 'no Monday return, so no Monday line');
    });

    test('it adds the earliest Monday landing when there is one', () {
      final summary = citySummary(cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 18, 19),
          backArrival: DateTime(2026, 10, 18, 21),
        ),
        option(
          outDeparture: DateTime(2026, 10, 16, 15),
          backDeparture: DateTime(2026, 10, 19, 6),
          backArrival: DateTime(2026, 10, 19, 8),
        ),
      ]));
      expect(summary, contains('latest return Sunday 19:00 (takeoff)'));
      expect(summary, contains('Monday 08:00 (landing)'));
      expect(summary, contains(' or '),
          reason: 'the two return options are alternatives');
    });

    test('the latest Sunday takeoff wins over an earlier one', () {
      final summary = citySummary(cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 18, 15),
          backArrival: DateTime(2026, 10, 18, 17),
        ),
        option(
          outDeparture: DateTime(2026, 10, 16, 15),
          backDeparture: DateTime(2026, 10, 18, 19),
          backArrival: DateTime(2026, 10, 18, 21),
        ),
      ]));
      expect(summary, contains('Sunday 19:00 (takeoff)'));
      expect(summary, isNot(contains('Sunday 15:00')));
    });

    test('the earliest departure wins over a later one', () {
      final summary = citySummary(cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 15),
          backDeparture: DateTime(2026, 10, 18, 19),
          backArrival: DateTime(2026, 10, 18, 21),
        ),
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 18, 19),
          backArrival: DateTime(2026, 10, 18, 21),
        ),
      ]));
      expect(summary, contains('earliest out Fri 13:30'));
    });

    test('a Saturday return is not a Sunday one', () {
      // The return line is about the *Sunday* return; a
      // Saturday return says nothing about it. It is still
      // named, though -- just under its own day.
      final summary = citySummary(cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 17, 19),
          backArrival: DateTime(2026, 10, 17, 21),
        ),
      ]));
      expect(summary, contains('earliest out Fri 13:30'));
      expect(summary, isNot(contains('Sunday')));
      expect(summary, contains('Sat 19:00 (takeoff)'));
    });

    test('a city without options has no summary', () {
      expect(citySummary(const CityResult(city: 'Rome', country: 'IT')), '');
    });

    test('the summary is two facts, and each is readable on its own', () {
      // A phone ellipsises one long line into uselessness, so
      // the page shows the two facts on two lines.
      final city = cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 18, 19),
          backArrival: DateTime(2026, 10, 18, 21),
        ),
      ]);
      expect(cityDepartureSummary(city), 'earliest out Fri 13:30 · 2🛏');
      expect(cityReturnSummary(city),
          'latest return Sunday 19:00 (takeoff)');
      expect(citySummary(city),
          'earliest out Fri 13:30 · 2🛏 · latest return Sunday 19:00 (takeoff)');
    });

    test('the return fact is empty when there is no return', () {
      final city = cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 17, 19),
          backArrival: DateTime(2026, 10, 17, 21),
        ),
      ]);
      expect(cityReturnSummary(city), 'latest return Sat 19:00 (takeoff)');
    });

    test('a return on another day is named rather than left out', () {
      // A reader told nothing about the way home is worse off
      // than one told "Saturday 19:00" -- so the line always
      // says when they are back.
      final city = cityWith([
        option(
          outDeparture: DateTime(2026, 10, 16, 13, 30),
          backDeparture: DateTime(2026, 10, 17, 19),
          backArrival: DateTime(2026, 10, 17, 21),
        ),
      ]);
      expect(cityReturnSummary(city), contains('Sat 19:00'));
      expect(cityReturnSummary(city), startsWith('latest return'));
    });
  });
}

/// A tiny seam so the origin can be changed in one test
/// without widening Flight's constructor.
extension _CopyWithForTest on Flight {
  Flight copyWithForTest({String? origin}) => Flight(
        flightNo: flightNo,
        airline: airline,
        airlineName: airlineName,
        origin: origin ?? this.origin,
        destination: destination,
        airportName: airportName,
        departure: departure,
        arrival: arrival,
        terminal: terminal,
      );
}
