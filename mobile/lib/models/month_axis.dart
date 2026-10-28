/// Where a tap lands on a monthly chart's axis.
///
/// Both monthly charts (climate and air quality) plot twelve
/// equal columns between a left axis strip and a small right
/// margin, and both must agree on what a tap means: the
/// column under the finger. The arithmetic lived in both
/// painters' callers, with different paddings, and neither
/// answered "the tap was outside the plot" -- so a tap on the
/// axis labels or past the last column was silently swallowed
/// (2026-10-28, with the reader unsure the feature existed at
/// all).
library;

/// The number of columns a monthly chart draws.
const monthAxisColumns = 12;

/// The column index (0 = January) a tap at [dx] selects, or
/// null when the tap is outside the plot.
///
/// [leftPadding] is the axis strip the plot starts after,
/// [rightPadding] the margin after the last column. A tap
/// exactly on the right edge belongs to the last column (the
/// finger is on the edge of December's slot, not past it);
/// a tap on the axis labels is not a month at all.
int? monthColumnAt({
  required double dx,
  required double width,
  required double leftPadding,
  double rightPadding = 4,
  int columns = monthAxisColumns,
}) {
  if (columns <= 0) return null;
  final plotWidth = width - leftPadding - rightPadding;
  if (plotWidth <= 0) return null;
  if (dx < leftPadding || dx > leftPadding + plotWidth) return null;
  final index = ((dx - leftPadding) / plotWidth * columns).floor();
  if (index < 0) return null;
  return index >= columns ? columns - 1 : index;
}

/// The horizontal span of one column, in the same
/// coordinates as [monthColumnAt]'s `dx`.
///
/// The charts draw their highlight band from this, so the
/// band and the tap test cannot drift apart: a band that
/// misses its own column would make the highlight a lie.
({double left, double right}) monthColumnSpan(
  int index, {
  required double width,
  required double leftPadding,
  double rightPadding = 4,
  int columns = monthAxisColumns,
}) {
  final plotWidth = width - leftPadding - rightPadding;
  final columnWidth = plotWidth / columns;
  return (
    left: leftPadding + columnWidth * index,
    right: leftPadding + columnWidth * (index + 1),
  );
}
