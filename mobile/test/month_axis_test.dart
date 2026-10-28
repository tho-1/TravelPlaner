/// The monthly charts' tap geometry.
///
/// The two charts (climate, air quality) plot twelve equal
/// columns and must agree on what a tap means. Before
/// 2026-10-28 each drew its own arithmetic, with a different
/// left padding, and neither answered "the tap was outside
/// the plot" -- so a tap on the axis labels was swallowed and
/// the reader could not tell the feature existed.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_planner/models/month_axis.dart';

void main() {
  // A phone-sized plot: a 30px axis strip, a 4px right
  // margin, so 366px of plot over twelve columns.
  const width = 400.0;
  const left = 30.0;
  double centreOf(int month) =>
      left + (width - left - 4) * (month + 0.5) / 12;

  test('every column centre maps to its own month', () {
    for (var month = 0; month < 12; month++) {
      expect(
        monthColumnAt(dx: centreOf(month), width: width, leftPadding: left),
        month,
        reason: 'the centre of column $month',
      );
    }
  });

  test('the first and last columns include their edges', () {
    expect(monthColumnAt(dx: left, width: width, leftPadding: left), 0,
        reason: 'the plot starts in January');
    expect(
      monthColumnAt(dx: width - 4, width: width, leftPadding: left),
      11,
      reason: 'the right edge is still December, not past it',
    );
    // A hair inside each edge.
    expect(monthColumnAt(dx: left + 0.5, width: width, leftPadding: left), 0);
    expect(
        monthColumnAt(dx: width - 4.5, width: width, leftPadding: left), 11);
  });

  test('a tap on the axis strip is not a month', () {
    expect(monthColumnAt(dx: 0, width: width, leftPadding: left), isNull);
    expect(monthColumnAt(dx: left - 1, width: width, leftPadding: left), isNull);
  });

  test('a tap past the last column is not a month', () {
    expect(
        monthColumnAt(dx: width - 3, width: width, leftPadding: left), isNull);
    expect(monthColumnAt(dx: width + 20, width: width, leftPadding: left),
        isNull);
  });

  test('a plot with no width maps nothing', () {
    expect(monthColumnAt(dx: 10, width: left, leftPadding: left), isNull);
    expect(monthColumnAt(dx: 10, width: 0, leftPadding: left), isNull);
    expect(monthColumnAt(dx: -5, width: 0, leftPadding: left), isNull);
  });

  test('a column boundary belongs to the column it starts', () {
    final boundary = left + (width - left - 4) / 12;
    expect(monthColumnAt(dx: boundary - 0.01, width: width, leftPadding: left),
        0);
    expect(monthColumnAt(dx: boundary, width: width, leftPadding: left), 1);
  });

  test('the span of a column is where a tap selects it', () {
    for (var month = 0; month < 12; month++) {
      final span =
          monthColumnSpan(month, width: width, leftPadding: left);
      expect(span.right - span.left, closeTo((width - left - 4) / 12, 1e-9),
          reason: 'column $month is one twelfth wide');
      // Inside the span, the tap test agrees.
      expect(
        monthColumnAt(
            dx: (span.left + span.right) / 2, width: width, leftPadding: left),
        month,
      );
    }
  });

  test('the spans tile the plot without gaps', () {
    for (var month = 0; month < 11; month++) {
      final here = monthColumnSpan(month, width: width, leftPadding: left);
      final next = monthColumnSpan(month + 1, width: width, leftPadding: left);
      expect(next.left, closeTo(here.right, 1e-9));
    }
    final first = monthColumnSpan(0, width: width, leftPadding: left);
    final last = monthColumnSpan(11, width: width, leftPadding: left);
    expect(first.left, left);
    expect(last.right, closeTo(width - 4, 1e-9));
  });

  test('a chart with its own padding still works', () {
    // The air-quality chart starts its plot 34px in.
    const aqiLeft = 34.0;
    final centre = aqiLeft + (width - aqiLeft - 4) * (6 + 0.5) / 12;
    expect(
      monthColumnAt(dx: centre, width: width, leftPadding: aqiLeft),
      6,
      reason: 'July, at the air-quality chart\'s padding',
    );
  });
}
