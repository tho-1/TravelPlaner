/// The monthly air-quality profile, drawn with a
/// [CustomPainter].
///
/// The legacy dashboard uses a plotly chart with up to
/// four always-on series read straight from the workbook
/// columns (works on Streamlit Cloud — the aqi_cache/ is
/// not deployed):
///
/// * dotted  = trailing 12 complete months (12M);
/// * solid   = multi-year typical — the mean of the
///   yearly monthly means (climate-normal convention);
/// * amber/brown = Open-Meteo CAMS model, teal = OpenAQ
///   ground stations.
///
/// The X axis is numeric (0..11 = Jan..Dec) so the
/// seasonal Dec→Jan wrap fits in the half-month slots at
/// the edges: when a series has BOTH endpoint months, a
/// short stub continues December to x=11.5 (holding
/// January's value) and a stub enters January from
/// x=-0.5 (holding December's value). The axis range is
/// clamped to [-0.5, 11.5], so every month slot is
/// exactly one unit wide — the edge months do not look
/// stretched. Without the wrap, a month whose neighbours
/// are empty (e.g. a lone December dot between two
/// missing months) floats unconnected.
///
/// Behind the series, the AQI severity bands (Good /
/// Moderate / Unhealthy / Very Unhealthy) are drawn as
/// horizontal strips, the same colour coding the legacy
/// chart annotates.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/destination_profile.dart';
import '../models/month_axis.dart';
import 'month_readout.dart';

class AqiChart extends StatefulWidget {
  final ClimateData data;

  const AqiChart({super.key, required this.data});

  @override
  State<AqiChart> createState() => _AqiChartState();
}

class _AqiChartState extends State<AqiChart> {
  int? _selected;

  /// The axis strip the plot starts after; the tap test and
  /// the painter share it, so they cannot disagree.
  static const _leftPadding = 34.0;

  void _select(int? index) {
    if (index == null || index == _selected) return;
    HapticFeedback.selectionClick();
    setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final data = widget.data;
    final selected = _selected;
    final legend = <_LegendEntry>[
      if (data.groundAqi.any((v) => v != null))
        _LegendEntry(
          color: const Color(0xFF22D3EE),
          label: 'OpenAQ ground (12M)',
          dotted: true,
        ),
      _LegendEntry(
        color: const Color(0xFFA16207),
        label: 'Open-Meteo (12M)',
        dotted: true,
      ),
      if (data.groundTypical.any((v) => v != null))
        _LegendEntry(
          color: const Color(0xFF0E7490),
          label: 'OpenAQ ground (multi-year)',
        ),
      if (data.typical.any((v) => v != null))
        _LegendEntry(
          color: const Color(0xFF78350F),
          label: 'Open-Meteo (multi-year)',
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          children: [
            for (final entry in legend)
              _Legend(color: entry.color, label: entry.label,
                  dotted: entry.dotted),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            return GestureDetector(
              onTapDown: (details) => _select(monthColumnAt(
                dx: details.localPosition.dx,
                width: constraints.maxWidth,
                leftPadding: _leftPadding,
              )),
              child: SizedBox(
                height: 240,
                child: CustomPaint(
                  painter: _AqiChartPainter(
                    aqi: data.aqi,
                    groundAqi: data.groundAqi,
                    typical: data.typical,
                    groundTypical: data.groundTypical,
                    labelColor: scheme.onSurfaceVariant,
                    selectedMonth: selected,
                    highlightColor: scheme.primary.withValues(alpha: 0.12),
                    selectedLabelColor: scheme.primary,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        if (selected == null)
          Text(
            monthTapHint,
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          MonthReadout(
            month: fullMonths[selected],
            facts: [
              MonthFact(
                label: 'Open-Meteo (12M)',
                value: _fmt(data.aqi, selected),
                color: const Color(0xFFA16207),
              ),
              MonthFact(
                label: 'OpenAQ ground (12M)',
                value: _fmt(data.groundAqi, selected),
                color: const Color(0xFF22D3EE),
              ),
              MonthFact(
                label: 'Open-Meteo (multi-year)',
                value: _fmt(data.typical, selected),
                color: const Color(0xFF78350F),
              ),
              MonthFact(
                label: 'OpenAQ ground (multi-year)',
                value: _fmt(data.groundTypical, selected),
                color: const Color(0xFF0E7490),
              ),
            ],
          ),
      ],
    );
  }

  String _fmt(List<double?> series, int i) {
    if (i >= series.length || series[i] == null) return '—';
    return series[i]!.round().toString();
  }
}

class _LegendEntry {
  final Color color;
  final String label;
  final bool dotted;

  const _LegendEntry({
    required this.color,
    required this.label,
    this.dotted = false,
  });
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final bool dotted;

  const _Legend({
    required this.color,
    required this.label,
    this.dotted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(16, 12),
          painter: _LineSwatch(color: color, dotted: dotted),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _LineSwatch extends CustomPainter {
  final Color color;
  final bool dotted;

  const _LineSwatch({required this.color, required this.dotted});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final from = Offset(0, size.height / 2);
    final to = Offset(size.width, size.height / 2);
    if (!dotted) {
      canvas.drawLine(from, to, paint);
      return;
    }
    // A dotted swatch: short dashes with round caps.
    const dash = 1.5;
    const gap = 3.0;
    var travelled = 0.0;
    while (travelled < size.width) {
      final end = (travelled + dash).clamp(0.0, size.width);
      canvas.drawLine(
        Offset(travelled, size.height / 2),
        Offset(end, size.height / 2),
        paint,
      );
      travelled = end + gap;
    }
  }

  @override
  bool shouldRepaint(_LineSwatch old) =>
      old.color != color || old.dotted != dotted;
}

class _AqiChartPainter extends CustomPainter {
  final List<double?> aqi;
  final List<double?> groundAqi;
  final List<double?> typical;
  final List<double?> groundTypical;
  final Color labelColor;

  /// The month the reader tapped, or null for none. Drawn as
  /// a band under the severity strips, with the month's label
  /// emphasised (2026-10-28).
  final int? selectedMonth;
  final Color highlightColor;
  final Color selectedLabelColor;

  const _AqiChartPainter({
    required this.aqi,
    required this.groundAqi,
    required this.typical,
    required this.groundTypical,
    required this.labelColor,
    this.selectedMonth,
    required this.highlightColor,
    required this.selectedLabelColor,
  });

  // The band colours, the legacy chart's coding.
  static const _good = Color(0xFF22C55E);
  static const _moderate = Color(0xFFEAB308);
  static const _unhealthy = Color(0xFFF97316);
  static const _veryUnhealthy = Color(0xFFEF4444);

  @override
  void paint(Canvas canvas, Size size) {
    const leftPadding = 34.0;
    const bottomPadding = 18.0;
    const topPadding = 8.0;
    final plotWidth = size.width - leftPadding - 4;
    final plotHeight = size.height - bottomPadding - topPadding;

    final all = [
      ...aqi,
      ...groundAqi,
      ...typical,
      ...groundTypical,
    ].whereType<double>().toList();
    if (all.isEmpty) {
      _paintNoData(canvas, size);
      return;
    }
    final topAqi = all.reduce((a, b) => a > b ? a : b);
    final yMax = (130.0 > topAqi * 1.25) ? 130.0 : (topAqi * 1.25);

    double y(double value) =>
        topPadding + plotHeight * (1 - value / yMax);
    // The X axis spans [-0.5, 11.5] so every month slot
    // is one unit wide and the wrap stubs fit the edges.
    double x(double month) =>
        leftPadding + plotWidth * (month + 0.5) / 12;

    // The severity bands, below the series.
    _band(canvas, size, y, 0, 50, _good, 'Good');
    _band(canvas, size, y, 50, 100, _moderate, 'Moderate');
    _band(canvas, size, y, 100, yMax < 150 ? yMax : 150, _unhealthy,
        'Unhealthy');
    if (yMax > 150) {
      _band(canvas, size, y, 150, yMax, _veryUnhealthy, 'Very unhealthy');
    }

    // The selected column over the bands, under the series:
    // a tint that darkens the severity strip it crosses
    // rather than hiding it.
    if (selectedMonth != null) {
      final span = monthColumnSpan(
        selectedMonth!,
        width: size.width,
        leftPadding: leftPadding,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(span.left, topPadding, span.right,
              topPadding + plotHeight),
          const Radius.circular(4),
        ),
        Paint()..color = highlightColor,
      );
    }

    // The 12M (dotted) series first, so the solid
    // multi-year lines draw on top of them.
    if (groundAqi.any((v) => v != null)) {
      _drawSeries(
        canvas,
        groundAqi,
        x,
        y,
        const Color(0xFF22D3EE),
        stroke: 2.2,
        dotted: true,
      );
    }
    _drawSeries(
      canvas,
      aqi,
      x,
      y,
      const Color(0xFFA16207),
      stroke: 2.2,
      dotted: true,
    );
    if (groundTypical.any((v) => v != null)) {
      _drawTypicalSeries(
        canvas,
        groundTypical,
        x,
        y,
        lineColor: const Color(0xFF0E7490),
        markerColor: const Color(0xFF0E7490),
        diamond: true,
      );
    }
    if (typical.any((v) => v != null)) {
      _drawTypicalSeries(
        canvas,
        typical,
        x,
        y,
        lineColor: const Color(0xFF78350F),
        markerColor: const Color(0xFF451A03),
        diamond: false,
      );
    }

    // Axis: a baseline, the month labels and the AQI
    // scale on the left.
    final axisPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(leftPadding, topPadding + plotHeight),
      Offset(size.width - 4, topPadding + plotHeight),
      axisPaint,
    );
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < 12; i++) {
      final selected = i == selectedMonth;
      textPainter.text = TextSpan(
        text: monthAbbreviations[i],
        style: TextStyle(
          color: selected ? selectedLabelColor : labelColor,
          fontSize: selected ? 10 : 9,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(x(i.toDouble()) - textPainter.width / 2,
            topPadding + plotHeight + 4),
      );
    }
    void scaleLabel(String text, double value) {
      textPainter.text = TextSpan(
        text: text,
        style: TextStyle(color: labelColor, fontSize: 9),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(0, y(value) - textPainter.height / 2),
      );
    }

    scaleLabel(yMax.round().toString(), yMax);
    scaleLabel('100', 100);
    scaleLabel('50', 50);
    scaleLabel('0', 0);
  }

  /// One severity strip with its name on the right.
  void _band(
    Canvas canvas,
    Size size,
    double Function(double) y,
    double from,
    double to,
    Color color,
    String name,
  ) {
    final top = y(to);
    final bottom = y(from);
    canvas.drawRect(
      Rect.fromLTWH(34, top, size.width - 34 - 4, bottom - top),
      Paint()..color = color.withValues(alpha: 0.22),
    );
    final painter = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(color: color, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(size.width - painter.width - 6, top + 2),
    );
  }

  /// A lines-only series (the 12M traces), with the
  /// Dec→Jan wrap stubs appended when both endpoints
  /// exist.
  void _drawSeries(
    Canvas canvas,
    List<double?> values,
    double Function(double) x,
    double Function(double) y,
    Color color, {
    required double stroke,
    required bool dotted,
  }) {
    final points = <Offset>[];
    if (_closesCycle(values)) {
      // The wrap: December's value continues at x=-0.5
      // and January's at x=11.5.
      points.add(Offset(x(-0.5), y(values[11]!)));
    }
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        // A gap breaks the line; draw what we have.
        _stroke(canvas, points, color, stroke, dotted);
        points.clear();
        continue;
      }
      points.add(Offset(x(i.toDouble()), y(value)));
    }
    if (_closesCycle(values)) {
      points.add(Offset(x(11.5), y(values[0]!)));
    }
    _stroke(canvas, points, color, stroke, dotted);
  }

  /// A lines+markers series (the multi-year typical
  /// traces): markers stay on the real months, and the
  /// Dec→Jan wrap is drawn as two short segments that
  /// never carry a marker.
  void _drawTypicalSeries(
    Canvas canvas,
    List<double?> values,
    double Function(double) x,
    double Function(double) y, {
    required Color lineColor,
    required Color markerColor,
    required bool diamond,
  }) {
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        _stroke(canvas, points, lineColor, 2.8, false);
        points.clear();
        continue;
      }
      points.add(Offset(x(i.toDouble()), y(value)));
    }
    _stroke(canvas, points, lineColor, 2.8, false);

    // The markers, on top of the line.
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) continue;
      final center = Offset(x(i.toDouble()), y(value));
      if (diamond) {
        _drawDiamond(canvas, center, markerColor);
      } else {
        canvas.drawCircle(center, 3, Paint()..color = markerColor);
      }
    }

    // The wrap stubs: December's value at x=-0.5 to
    // January's at x=0, and January's at x=11 to
    // December's at x=11.5.
    if (_closesCycle(values)) {
      _stroke(
        canvas,
        [Offset(x(-0.5), y(values[11]!)), Offset(x(0), y(values[0]!))],
        lineColor,
        2.8,
        false,
      );
      _stroke(
        canvas,
        [Offset(x(11), y(values[11]!)), Offset(x(11.5), y(values[0]!))],
        lineColor,
        2.8,
        false,
      );
    }
  }

  bool _closesCycle(List<double?> values) =>
      values.length == 12 &&
      values[0] != null &&
      values[11] != null;

  /// A polyline through the points, dashed when [dotted].
  /// An empty or single-point list draws nothing.
  void _stroke(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double stroke,
    bool dotted,
  ) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < points.length - 1; i++) {
      _drawLine(canvas, points[i], points[i + 1], paint, dotted: dotted);
    }
  }

  void _drawLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    required bool dotted,
  }) {
    if (!dotted) {
      canvas.drawLine(from, to, paint);
      return;
    }
    // A dotted line: short dashes with round caps, the
    // plotly "dot" dash.
    const dash = 1.5;
    const gap = 3.0;
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return;
    final ux = dx / length;
    final uy = dy / length;
    var travelled = 0.0;
    while (travelled < length) {
      final end = (travelled + dash).clamp(0.0, length);
      canvas.drawLine(
        Offset(from.dx + ux * travelled, from.dy + uy * travelled),
        Offset(from.dx + ux * end, from.dy + uy * end),
        paint,
      );
      travelled = end + gap;
    }
  }

  void _drawDiamond(Canvas canvas, Offset center, Color color) {
    final path = Path()
      ..moveTo(center.dx, center.dy - 4)
      ..lineTo(center.dx + 4, center.dy)
      ..lineTo(center.dx, center.dy + 4)
      ..lineTo(center.dx - 4, center.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _paintNoData(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'No air-quality data yet',
        style: TextStyle(color: labelColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset((size.width - painter.width) / 2,
          (size.height - painter.height) / 2),
    );
  }

  @override
  bool shouldRepaint(_AqiChartPainter old) =>
      !_sameSeries(old.aqi, aqi) ||
      !_sameSeries(old.groundAqi, groundAqi) ||
      !_sameSeries(old.typical, typical) ||
      !_sameSeries(old.groundTypical, groundTypical) ||
      old.labelColor != labelColor ||
      old.selectedMonth != selectedMonth ||
      old.highlightColor != highlightColor ||
      old.selectedLabelColor != selectedLabelColor;
}

bool _sameSeries(List<double?> a, List<double?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
