/// The monthly charts' tap feedback.
///
/// The report (2026-10-28): tapping a month on a phone
/// darkened one small grey line under the chart and nothing
/// else, so the reader concluded the feature was broken. The
/// answer is now a filled readout card with the month as its
/// title, a hint before the first tap, and a highlighted
/// column inside the chart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/destination_profile.dart';
import 'package:travel_planner/ui/aqi_chart.dart';
import 'package:travel_planner/ui/climate_chart.dart';
import 'package:travel_planner/ui/month_readout.dart';

ClimateData _climate() => const ClimateData(
      highs: [
        18, 19, 21, 24, 27, 30, 32, 32, 29, 25, 21, 18, //
      ],
      lows: [
        10, 11, 13, 16, 19, 22, 24, 24, 21, 17, 13, 10, //
      ],
      rainyDays: [
        8, 7, 7, 6, 5, 3, 2, 2, 4, 6, 8, 9, //
      ],
      rainMm: [
        70, 60, 55, 40, 25, 12, 5, 8, 30, 60, 85, 90, //
      ],
      aqi: [
        42, 40, 38, 35, 33, 30, 28, 29, 32, 36, 40, 44, //
      ],
      groundAqi: [
        38, 36, 34, 31, 29, 27, 25, 26, 29, 32, 36, 40, //
      ],
      typical: [
        45, 43, 41, 38, 35, 32, 30, 31, 34, 38, 42, 47, //
      ],
      groundTypical: [
        40, 38, 36, 33, 31, 29, 27, 28, 31, 34, 38, 42, //
      ],
    );

/// Taps the centre of the plot's [month] column (0 = Jan).
Future<void> tapMonth(WidgetTester tester, Finder chart, int month) async {
  final box = tester.renderObject<RenderBox>(chart);
  final width = box.size.width;
  // The climate chart's axis strip is 30px, the AQI one 34;
  // both put month i's centre at the same fraction of the
  // plot. 30 is inside both strips' plot area for the
  // purposes of the centre, which is what the test needs.
  final left = width > 0 ? 32.0 : 0.0;
  final dx = box.localToGlobal(Offset.zero).dx +
      left +
      (width - left - 4) * (month + 0.5) / 12;
  await tester.tapAt(Offset(dx, box.localToGlobal(Offset.zero).dy + 100));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  Future<void> pumpClimate(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: ClimateChart(data: _climate()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pumpAqi(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: AqiChart(data: _climate()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder climatePlot() => find.byType(CustomPaint).last;
  Finder aqiPlot() => find.byType(CustomPaint).last;

  group('the climate chart', () {
    testWidgets('it says how to get the values before the first tap',
        (tester) async {
      await pumpClimate(tester);
      expect(find.text(monthTapHint), findsOneWidget,
          reason: 'the reader has to know the chart is tappable');
      expect(find.byType(MonthReadout), findsNothing);
    });

    testWidgets('a tap answers with a readout card, not a grey line',
        (tester) async {
      await pumpClimate(tester);
      await tapMonth(tester, climatePlot(), 5);

      // The card is a filled surface with the month as a
      // title, and the hint is gone.
      expect(find.byType(MonthReadout), findsOneWidget);
      expect(find.text(monthTapHint), findsNothing);
      expect(find.text('June'), findsOneWidget);
      // The values are the June row, each with its unit.
      expect(find.text('30°C'), findsWidgets, reason: 'June high');
      expect(find.text('22°C'), findsWidgets, reason: 'June low');
      expect(find.text('12 mm'), findsOneWidget, reason: 'June rain');
      expect(find.text('3'), findsWidgets, reason: 'June rainy days');

      // The card is visually distinct: a filled container
      // with a border, not bare text.
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(MonthReadout),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, isNotNull,
          reason: 'the readout has a filled background');
    });

    testWidgets('tapping another month moves the readout', (tester) async {
      await pumpClimate(tester);
      await tapMonth(tester, climatePlot(), 5);
      expect(find.text('June'), findsOneWidget);

      await tapMonth(tester, climatePlot(), 0);
      expect(find.text('June'), findsNothing);
      expect(find.text('January'), findsOneWidget);
      expect(find.text('18°C'), findsWidgets);
    });

    testWidgets('a tap on the axis strip changes nothing', (tester) async {
      await pumpClimate(tester);
      final box = tester.renderObject<RenderBox>(climatePlot());
      await tester.tapAt(box.localToGlobal(Offset.zero) + const Offset(4, 100));
      await tester.pump();
      expect(find.byType(MonthReadout), findsNothing,
          reason: 'the axis labels are not a month');
      expect(find.text(monthTapHint), findsOneWidget);
    });

    testWidgets('a missing month reads as a dash, never a zero',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: ClimateChart(
              data: const ClimateData(
                highs: [20, null, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31],
                lows: [null, null, null, null, null, null, null, null, null,
                    null, null, null],
                rainyDays: [],
                rainMm: [],
                aqi: [],
                groundAqi: [],
                typical: [],
                groundTypical: [],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tapMonth(tester, climatePlot(), 1);
      expect(find.text('February'), findsOneWidget);
      expect(find.text('—'), findsWidgets,
          reason: 'a month with no value says so');
      expect(find.text('0°C'), findsNothing);
    });
  });

  group('the air quality chart', () {
    testWidgets('it says how to get the values before the first tap',
        (tester) async {
      await pumpAqi(tester);
      expect(find.text(monthTapHint), findsOneWidget);
      expect(find.byType(MonthReadout), findsNothing);
    });

    testWidgets('a tap answers with the month and its four series',
        (tester) async {
      await pumpAqi(tester);
      await tapMonth(tester, aqiPlot(), 0);

      expect(find.byType(MonthReadout), findsOneWidget);
      expect(find.text('January'), findsOneWidget);
      expect(find.text('42'), findsOneWidget, reason: 'January AQI');
      expect(find.text('38'), findsOneWidget, reason: 'January ground AQI');
      expect(find.text('45'), findsOneWidget, reason: 'January typical');
      expect(find.text('40'), findsOneWidget,
          reason: 'January ground typical');
    });

    testWidgets('every month can be reached', (tester) async {
      await pumpAqi(tester);
      for (var month = 0; month < 12; month++) {
        await tapMonth(tester, aqiPlot(), month);
        expect(find.byType(MonthReadout), findsOneWidget,
            reason: 'month $month is tappable');
        expect(find.text(fullMonths[month]), findsWidgets,
            reason: 'month $month names itself');
      }
    });
  });
}
