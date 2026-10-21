/// The weekend finder page: the search, the result summary
/// and the notes.
///
/// The finder's contract is the app's oldest one: a board
/// that failed must never look like a weekend with no
/// flights. The page is where that contract becomes visible
/// -- the notes under the result, the warning icon, and the
/// empty state that points at the notes instead of claiming
/// there is nothing to fly.
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

/// A board that always fails, the way a provider outage
/// looks.
class _DeadBoard implements FlightBoardProvider {
  @override
  bool get answersWholeDay => false;

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    throw const ProviderUnavailable('fraport: HTTP 503');
  }
}

/// A board with one weekend's worth of flights: out of FRA on
/// Friday afternoon (and Saturday morning), home on Sunday
/// evening or Monday morning. The times follow the legacy
/// rules the page's preset selects (out from Friday 14:00 or
/// before Saturday 12:00; back on Sunday any time or Monday
/// before 09:00), so the pairs match and the page shows a
/// result.
class _WeekendBoard implements FlightBoardProvider {
  @override
  bool get answersWholeDay => false;

  @override
  Future<FetchResult> fetch(
    DateTime day,
    String direction, {
    DateTime? since,
    DateTime? until,
  }) async {
    if (direction == 'departures') {
      // Friday from 14:00, Saturday before 12:00.
      final hour = day.weekday == DateTime.saturday ? 9 : 15;
      final departure = DateTime(day.year, day.month, day.day, hour);
      return FetchResult(
        flights: [
          Flight(
            flightNo: 'LH1000',
            airline: 'LH',
            origin: 'FRA',
            destination: 'LHR',
            airportName: 'London Heathrow',
            departure: departure,
            arrival: departure.add(const Duration(hours: 2)),
          ),
        ],
        source: 'fixture',
        fetchedAt: DateTime.now().toIso8601String(),
      );
    }
    // Sunday any time, Monday before 09:00. Saturday has no
    // return in the fixture, so the weekend is the classic one.
    if (day.weekday == DateTime.saturday) {
      return FetchResult(
        flights: const [],
        source: 'fixture',
        fetchedAt: DateTime.now().toIso8601String(),
      );
    }
    final hour = day.weekday == DateTime.monday ? 8 : 19;
    final arrival = DateTime(day.year, day.month, day.day, hour);
    return FetchResult(
      flights: [
        Flight(
          flightNo: day.weekday == DateTime.monday ? 'LH2001' : 'LH2000',
          airline: 'LH',
          origin: 'LHR',
          destination: 'FRA',
          airportName: 'Frankfurt',
          departure: arrival.subtract(const Duration(hours: 2)),
          arrival: arrival,
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
        httpClient: FakeTurso((_) => okRows(['iata', 'name', 'benefits'], const []))
            .client(),
      );

  DestinationRepository destinations() => DestinationRepository(
        TursoClient(
          _config,
          httpClient: FakeTurso((_) => okRows(const [], const [])).client(),
        ),
      );

  Future<void> pumpFinder(WidgetTester tester) async {
    // The search loads the airport and country tables from
    // the asset bundle. That is real I/O, which the widget
    // test's fake clock cannot drive -- so the tables are
    // primed here (outside the fake clock) and the search's
    // own call finds them cached.
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await AirportLookup.ensureLoaded();
      await CountryNames.ensureLoaded();
    });
    await tester.pumpWidget(MaterialApp(
      home: WeekendFinderPage(
        benefits: benefits(),
        destinations: destinations(),
        board: _DeadBoard(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The input cards fill the screen; the search button is
  /// below them.
  Future<void> tapFind(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Find weekends'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Find weekends'));
    // The search overlay is a spinner, which schedules
    // frames forever -- so the test cannot wait for "quiet",
    // it waits for the answer.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('outbound').evaluate().isNotEmpty) break;
    }
  }

  testWidgets('a dead board becomes a note, not an empty result',
      (tester) async {
    await pumpFinder(tester);

    await tapFind(tester);

    // The failure is on screen...
    expect(find.byIcon(Icons.warning_amber_outlined), findsWidgets);
    expect(find.textContaining('fraport'), findsWidgets);
    // ...and the result line says how much was read, so a
    // reader can tell "nothing found" from "nothing read".
    expect(find.textContaining('outbound'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the empty state points at the notes when there are any',
      (tester) async {
    await pumpFinder(tester);

    await tapFind(tester);

    expect(
      find.textContaining('see the notes above for what failed'),
      findsOneWidget,
    );
  });

  testWidgets('on a phone the result facts are readable, not truncated',
      (tester) async {
    // The phone screenshot (2026-10-20) showed the facts line
    // ellipsised into "earliest out Sat 09:20 · 1 n…" -- the
    // line said nothing. The facts are now one per line, and
    // they wrap instead of being cut.
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => binding.setSurfaceSize(null));
    // The board's airports have to map to a city.
    AirportLookup.installForTesting({
      'LHR': ('London', 'GB'),
    });
    await tester.runAsync(() async {
      await AirportLookup.ensureLoaded();
      await CountryNames.ensureLoaded();
    });
    await tester.pumpWidget(MaterialApp(
      home: WeekendFinderPage(
        benefits: benefits(),
        destinations: destinations(),
        board: _WeekendBoard(),
      ),
    ));
    await tester.pumpAndSettle();

    // The preset fills the days, then the search runs.
    await tester.tap(find.textContaining('This weekend'));
    await tester.pumpAndSettle();
    await tapFind(tester);

    // The result is there...
    expect(find.textContaining('London'), findsWidgets);
    // ...the departure fact is whole...
    final departure = tester.widget<Text>(find.textContaining('earliest out'));
    expect(departure.overflow, isNot(TextOverflow.ellipsis),
        reason: 'the facts must wrap, not be cut');
    expect(departure.maxLines, isNull);
    // ...and so is the return fact.
    final returns = tester.widget<Text>(find.textContaining('latest return'));
    expect(returns.overflow, isNot(TextOverflow.ellipsis));
    expect(returns.maxLines, isNull);
    // Nothing overflowed the card.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the card carries the airline filter, the benefits and '
      'nothing else', (tester) async {
    await pumpFinder(tester);

    // The airline filter and the benefits answer are one
    // question, so they live in one card (the report,
    // 2026-10-21).
    expect(find.text('Airlines'), findsOneWidget);
    expect(find.text('Airlines with benefits'), findsOneWidget);

    // The texts that repeated what the screen already said
    // are gone.
    expect(find.textContaining('Tap a day to select'), findsNothing);
    expect(find.textContaining('Flights longer than the cap'), findsNothing);
    expect(find.textContaining('out: '), findsNothing,
        reason: 'the plan line repeated the day chips below it');
  });

  testWidgets('the group carriers hide behind a question mark',
      (tester) async {
    await pumpFinder(tester);

    // The list is long; the card stays short and the reader
    // asks for the list.
    expect(find.text('Which carriers?'), findsOneWidget);
    expect(find.textContaining('Lufthansa Group carriers:'), findsNothing);
    final hint = find.byIcon(Icons.help_outline);
    expect(hint, findsOneWidget);
    // The tooltip carries the whole list.
    final tooltip = tester.widget<Tooltip>(
      find.byWidgetPredicate((widget) =>
          widget is Tooltip &&
          (widget.message ?? '').contains('Lufthansa')),
    );
    expect(tooltip.message, contains('Lufthansa City Airlines'));
    expect(tooltip.message, contains('Edelweiss'));
    // The list is long: an unbounded box runs past the
    // screen edge and both ends are cut (the phone,
    // 2026-10-21), so the box is bounded by the view.
    expect(tooltip.constraints, isNotNull);
    expect(tooltip.constraints!.maxWidth, lessThanOrEqualTo(752),
        reason: 'the surface is 800 wide: the box must wrap inside it');

    // And the "?" actually shows them when asked (tap on a
    // phone; hover on the desktop) -- a hint that never
    // opens is not a hint.
    expect(find.textContaining('Edelweiss'), findsNothing,
        reason: 'the list is not on screen until it is asked for');
    await tester.tap(hint);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Lufthansa City Airlines'), findsWidgets,
        reason: 'the tapped hint shows the carriers');
  });
}
