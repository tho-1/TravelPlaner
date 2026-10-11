/// The monthly temperature & rainfall chart, drawn with a
/// [CustomPainter].
///
/// The legacy dashboard uses a plotly dual-axis chart; this
/// is its phone-sized equivalent, built without a chart
/// dependency: per month a band from the low to the high,
/// the highs and lows connected, and the rainfall as bars
/// along the bottom on their own scale. Gaps (months with
/// no data) stay gaps — the chart never invents a value to
/// keep a line continuous.
library;

import 'package:flutter/material.dart';

import '../models/destination_profile.dart';

class ClimateChart extends StatelessWidget {
  final ClimateData data;

  const ClimateChart({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          children: [
            _Legend(color: scheme.error, label: 'High'),
            _Legend(color: scheme.primary, label: 'Low'),
            _Legend(color: Colors.lightBlue, label: 'Rain (mm)'),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 220,
          child: CustomPaint(
            painter: _ClimateChartPainter(
              highs: data.highs,
              lows: data.lows,
              rain: data.rainMm,
              highColor: scheme.error,
              lowColor: scheme.primary,
              rainColor: Colors.lightBlue.withValues(alpha: 0.55),
              axisColor: scheme.outlineVariant,
              labelColor: scheme.onSurfaceVariant,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;

  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ClimateChartPainter extends CustomPainter {
  final List<double?> highs;
  final List<double?> lows;
  final List<double?> rain;
  final Color highColor;
  final Color lowColor;
  final Color rainColor;
  final Color axisColor;
  final Color labelColor;

  const _ClimateChartPainter({
    required this.highs,
    required this.lows,
    required this.rain,
    required this.highColor,
    required this.lowColor,
    required this.rainColor,
    required this.axisColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftPadding = 30.0;
    const bottomPadding = 18.0;
    const topPadding = 8.0;
    final plotWidth = size.width - leftPadding - 4;
    final plotHeight = size.height - bottomPadding - topPadding;

    // The temperature scale spans the data, padded by one
    // degree, and never inverts when only one month exists.
    final temps = [...highs, ...lows].whereType<double>().toList();
    final rains = rain.whereType<double>().toList();
    if (temps.isEmpty && rains.isEmpty) {
      _paintNoData(canvas, size);
      return;
    }
    var minTemp = temps.isEmpty ? 0.0 : temps.reduce((a, b) => a < b ? a : b);
    var maxTemp = temps.isEmpty ? 10.0 : temps.reduce((a, b) => a > b ? a : b);
    if (maxTemp - minTemp < 4) {
      final mid = (maxTemp + minTemp) / 2;
      minTemp = mid - 2;
      maxTemp = mid + 2;
    } else {
      minTemp -= 2;
      maxTemp += 2;
    }
    final maxRain = rains.isEmpty ? 1.0 : rains.reduce((a, b) => a > b ? a : b);

    double tempY(double value) =>
        topPadding + plotHeight * (maxTemp - value) / (maxTemp - minTemp);
    double rainY(double value) =>
        topPadding + plotHeight * (1 - value / maxRain);
    double columnX(int index) =>
        leftPadding + plotWidth * (index + 0.5) / 12;

    // Rain bars first, so the temperature lines sit on top.
    final rainPaint = Paint()..color = rainColor;
    for (var i = 0; i < rain.length; i++) {
      final value = rain[i];
      if (value == null || value <= 0) continue;
      final barWidth = plotWidth / 12 * 0.5;
      final x = columnX(i) - barWidth / 2;
      final y = rainY(value);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, topPadding + plotHeight - y),
          const Radius.circular(3),
        ),
        rainPaint,
      );
    }

    // The low-high band per month, then the connecting lines.
    final bandPaint = Paint()
      ..color = highColor.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    for (var i = 0; i < highs.length; i++) {
      final high = highs[i];
      final low = i < lows.length ? lows[i] : null;
      if (high == null || low == null) continue;
      final x = columnX(i);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x - 5, tempY(high), x + 5, tempY(low)),
          const Radius.circular(3),
        ),
        bandPaint,
      );
    }
    _connect(canvas, highs, tempY, columnX, lowColor, stroke: 1.6, dots: false);
    _connect(canvas, lows, tempY, columnX, highColor, stroke: 1.6, dots: false);

    // The dots: high warm, low cool, drawn above the lines.
    for (var i = 0; i < highs.length; i++) {
      final high = highs[i];
      if (high != null) {
        canvas.drawCircle(Offset(columnX(i), tempY(high)), 3,
            Paint()..color = highColor);
      }
      final low = i < lows.length ? lows[i] : null;
      if (low != null) {
        canvas.drawCircle(Offset(columnX(i), tempY(low)), 3,
            Paint()..color = lowColor);
      }
    }

    // Axis: a baseline, the month labels, the temperature
    // extremes on the left and the wettest month on the right.
    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(leftPadding, topPadding + plotHeight),
      Offset(size.width - 4, topPadding + plotHeight),
      axisPaint,
    );
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < 12; i++) {
      textPainter.text = TextSpan(
        text: monthAbbreviations[i],
        style: TextStyle(color: labelColor, fontSize: 9),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(columnX(i) - textPainter.width / 2,
            topPadding + plotHeight + 4),
      );
    }
    void scaleLabel(String text, double y) {
      textPainter.text = TextSpan(
        text: text,
        style: TextStyle(color: labelColor, fontSize: 9),
      );
      textPainter.layout();
      textPainter.paint(
          canvas, Offset(0, y - textPainter.height / 2));
    }

    scaleLabel('${maxTemp.round()}°', topPadding + 2);
    scaleLabel('${minTemp.round()}°', topPadding + plotHeight - 6);
    if (rains.isNotEmpty) {
      scaleLabel('${maxRain.round()}mm',
          rainY(rains.reduce((a, b) => a > b ? a : b)) - 6);
    }
  }

  /// A line through the months that have a value; a missing
  /// month breaks the line instead of interpolating.
  void _connect(
    Canvas canvas,
    List<double?> values,
    double Function(double) y,
    double Function(int) x,
    Color color, {
    required double stroke,
    required bool dots,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    Offset? previous;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        previous = null; // the gap breaks the line
        continue;
      }
      final point = Offset(x(i), y(value));
      if (previous != null) {
        canvas.drawLine(previous, point, paint);
      }
      if (dots) {
        canvas.drawCircle(point, 2.5, Paint()..color = color);
      }
      previous = point;
    }
  }

  void _paintNoData(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'No monthly data yet',
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
  bool shouldRepaint(_ClimateChartPainter old) =>
      !_sameSeries(old.highs, highs) ||
      !_sameSeries(old.lows, lows) ||
      !_sameSeries(old.rain, rain) ||
      old.highColor != highColor ||
      old.lowColor != lowColor ||
      old.rainColor != rainColor;
}

bool _sameSeries(List<double?> a, List<double?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
