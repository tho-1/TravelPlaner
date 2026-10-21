/// The day selection: "Out on" and "Back on".
///
/// The report (2026-10-21) was that "Out on" did not work
/// reliably: a day was deselected, the rule row under the
/// buttons stayed, and the results still included the day.
/// The rule rows and the chips come from the same map, so a
/// deselect that leaves a row behind means the map still
/// holds the day -- and the plan (which the search runs on)
/// is built from that same map, so the results follow it.
///
/// The cause was the **DST weekend** (2026-10-25): the
/// "next weekend" preset added seven *absolute* days to
/// Friday the 23rd, which lands on Thursday the 29th at
/// 23:00 local. The rule was then keyed by a time the day
/// chips did not have, so the chip looked unselected, the
/// rule row stayed, and the day could not be deselected.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/data/benefits_repository.dart';
import 'package:travel_planner/data/catalogue_match.dart';
import 'package:travel_planner/data/destination_repository.dart';
import 'package:travel_planner/data/weekend_repository.dart';
import 'package:travel_planner/models/timetable.dart';
import 'package:travel_planner/models/weekend_match.dart';
import 'package:travel_planner/turso/config.dart';
import 'package:travel_planner/turso/pipeline_client.dart';
import 'package:travel_planner/ui/weekend_finder_page.dart';

import 'fake_turso.dart';

const _config = TursoConfig(
  url: 'https://db.example.turso.io',
  token: 'token',
);

/// A board with one London flight in every window, and a call
/// log -- so a test can prove a window was or was not asked
/// for, and can tell one search's answer from the next.
class _CountingBoard implements FlightBoardProvider {
  @override
  bool get answersWholeDay => false;

  final List<String> calls = [];

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    calls.add('$day $direction');
    // Inside the legacy preset's windows: out of FRA on
    // Friday afternoon or Saturday morning, home on Sunday
    // evening or Monday morning.
    final int hour;
    if (direction == 'departures') {
      hour = day.weekday == DateTime.saturday ? 9 : 15;
    } else {
      hour = day.weekday == DateTime.monday ? 8 : 19;
    }
    final departure = DateTime(day.year, day.month, day.day, hour);
    // A different number per day: the matcher keeps at most
    // two ways home per *outbound number*, so one number for
    // Friday and Saturday would hide one of the days.
    final number = direction == 'departures'
        ? (day.weekday == DateTime.saturday ? 'LH1100' : 'LH1000')
        : (day.weekday == DateTime.monday ? 'LH2001' : 'LH2000');
    return FetchResult(
      flights: [
        Flight(
          flightNo: number,
          airline: 'LH',
          origin: direction == 'departures' ? 'FRA' : 'LHR',
          destination: direction == 'departures' ? 'LHR' : 'FRA',
          airportName: 'London Heathrow',
          departure: departure,
          arrival: departure.add(const Duration(hours: 2)),
        ),
      ],
      source: 'fixture',
      fetchedAt: DateTime.now().toIso8601String(),
    );
  }
}

void main() {
  BenefitsRepository benefits() => BenefitsRepository(
        _config,
        httpClient:
            FakeTurso((_) => okRows(['iata', 'name', 'benefits'], const []))
                .client(),
      );

  DestinationRepository destinations() => DestinationRepository(
        TursoClient(
          _config,
          httpClient: FakeTurso((_) => okRows(const [], const [])).client(),
        ),
      );

  Future<void> pumpFinder(WidgetTester tester,
      {DateTime? now, FlightBoardProvider? board}) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(500, 1600));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await AirportLookup.ensureLoaded();
      await CountryNames.ensureLoaded();
    });
    await tester.pumpWidget(MaterialApp(
      home: WeekendFinderPage(
        benefits: benefits(),
        destinations: destinations(),
        board: board,
        now: now == null ? null : () => now,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Press the search button -- it sits below the input
  /// cards -- and wait for the answer, which the search
  /// overlay's spinner never lets `pumpAndSettle` reach.
  Future<void> tapFind(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Find weekends'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Find weekends'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('earliest out').evaluate().isNotEmpty) break;
    }
  }

  /// The chip for [label] under [side] ('Out on' / 'Back on').
  ///
  /// Both sides render the same day chips, so the side is
  /// found by position: the "Out on" chips come first.
  Finder chipUnder(String side, String label) {
    final chips = find.widgetWithText(FilterChip, label);
    if (side == 'Out on') return chips.first;
    return chips.last;
  }

  /// How many rule rows the day has.
  ///
  /// The day label is on screen once per side (the chip) and
  /// once per rule row, so the two chips are the baseline.
  int ruleRowsFor(WidgetTester tester, String label) =>
      find.text(label).evaluate().length - 2;

  testWidgets('deselecting a day removes its rule row', (tester) async {
    await pumpFinder(tester);

    // The preset fills the days: out Friday from 14:00, back
    // Saturday/Sunday/Monday.
    await tester.tap(find.textContaining('This weekend'));
    await tester.pumpAndSettle();
    expect(ruleRowsFor(tester, 'Fri 23.10.'), 1,
        reason: 'the Friday rule row is there to start with');

    // Deselect Friday under "Out on".
    await tester.tap(chipUnder('Out on', 'Fri 23.10.'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<FilterChip>(chipUnder('Out on', 'Fri 23.10.')).selected,
      isFalse,
    );
    expect(ruleRowsFor(tester, 'Fri 23.10.'), 0,
        reason: 'the rule row goes with the day');
  });

  testWidgets('deselecting a day on one side leaves the other side alone',
      (tester) async {
    await pumpFinder(tester);
    await tester.tap(find.textContaining('This weekend'));
    await tester.pumpAndSettle();

    // Saturday is both an out day and a back day in the
    // legacy plan. Deselecting it under "Out on" must not
    // touch the "Back on" rule.
    final saturday = chipUnder('Out on', 'Sat 24.10.');
    expect(tester.widget<FilterChip>(saturday).selected, isTrue);
    expect(ruleRowsFor(tester, 'Sat 24.10.'), 2,
        reason: 'Saturday has a rule on each side');

    await tester.tap(saturday);
    await tester.pumpAndSettle();

    expect(tester.widget<FilterChip>(saturday).selected, isFalse);
    expect(ruleRowsFor(tester, 'Sat 24.10.'), 1,
        reason: 'the back side keeps its rule');
  });

  testWidgets('re-selecting a day restores its rule, not a blank one',
      (tester) async {
    await pumpFinder(tester);
    await tester.tap(find.textContaining('This weekend'));
    await tester.pumpAndSettle();

    final friday = chipUnder('Out on', 'Fri 23.10.');
    await tester.tap(friday);
    await tester.pumpAndSettle();
    expect(ruleRowsFor(tester, 'Fri 23.10.'), 0);

    // Selecting it again brings the day back -- with the
    // bound it had, so the user's rule is not silently reset
    // to "any time". The bound shows as the time chip; a
    // reset would show "any time" instead.
    await tester.tap(friday);
    await tester.pumpAndSettle();
    expect(ruleRowsFor(tester, 'Fri 23.10.'), 1);
    expect(find.text('14:00'), findsOneWidget,
        reason: 'the rule kept its 14:00 bound');
  });

  testWidgets('the results follow the selection', (tester) async {
    // The report (2026-10-21) had two halves: the day would
    // not deselect, and the results still contained it. The
    // first half is the DST bug above; this is the second --
    // an answer drawn for the *old* selection must be
    // replaced, not left standing under new chips.
    final board = _CountingBoard();
    await pumpFinder(tester, board: board);
    await tester.tap(find.textContaining('This weekend'));
    await tester.pumpAndSettle();
    await tapFind(tester);


    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The preset's earliest out is the Friday flight.
    expect(find.textContaining('earliest out Fri 15:00'), findsOneWidget);

    // Deselect Friday under "Out on": the search runs again,
    // and the answer now names the Saturday flight. The
    // results sit below the input cards, which the search
    // scrolled past -- so the chips are found by scrolling
    // back up.
    final friday = chipUnder('Out on', 'Fri 23.10.');
    await tester.scrollUntilVisible(
      friday,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(friday);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('earliest out Sat 09:00')
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    expect(find.textContaining('earliest out Fri 15:00'), findsNothing,
        reason: 'a deselected day cannot stay in the results');
    expect(find.textContaining('earliest out Sat 09:00'), findsOneWidget);
  });

  testWidgets('the next weekend works in the DST week', (tester) async {
    // The weekend of 23 October 2026 is the DST weekend: on
    // Saturday the 24th the clock goes back an hour at 03:00.
    // Adding seven *absolute* days to Friday the 23rd (which
    // is what the preset used to do) lands on Thursday the
    // 29th at 23:00 -- a day the chips do not have, so the
    // rule row stayed while the chip looked unselected and
    // the day could not be deselected (the report, 2026-10-21).
    await pumpFinder(tester, now: DateTime(2026, 10, 24, 12));

    await tester.tap(find.textContaining('Next weekend'));
    await tester.pumpAndSettle();

    // The next weekend is the one of Friday 30 October, and
    // its out day is *selected* -- the chip and the rule row
    // agree.
    final friday = chipUnder('Out on', 'Fri 30.10.');
    expect(
      tester.widget<FilterChip>(friday).selected,
      isTrue,
      reason: 'the preset selected a day the chip can see',
    );
    expect(ruleRowsFor(tester, 'Fri 30.10.'), 1);

    // And it can be deselected.
    await tester.tap(friday);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(friday).selected, isFalse);
    expect(ruleRowsFor(tester, 'Fri 30.10.'), 0);
  });
}
