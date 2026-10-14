/// The four navigation icons: small flat colour
/// illustrations drawn with CustomPaint, one visual
/// family with the app icon (globe, suitcase,
/// compass, folded map).
///
/// Colour is meaning, not decoration: the selected
/// tab paints its shapes in full colour while the
/// unselected ones render the same geometry in
/// muted blue-greys, so the coloured icon *is* the
/// "where am I" signal. Pure geometry — no image
/// assets, no package dependency, crisp at any
/// scale.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which tab an icon stands for.
enum NavTabIcon { globe, suitcase, compass, map }

class NavIcon extends StatelessWidget {
  final NavTabIcon kind;

  /// Side length in logical pixels; 26 is the nav size.
  /// Larger sizes turn the icon into a small illustration
  /// (empty states).
  final double size;

  const NavIcon(this.kind, {super.key, this.size = 26});

  @override
  Widget build(BuildContext context) {
    // Always in full colour: the tab colours are part of the
    // app's identity, and selection is signalled by the rail
    // pill / bottom-bar indicator, not by draining the icon.
    return CustomPaint(
      size: Size.square(size),
      painter: _NavIconPainter(kind, selected: true),
    );
  }
}

class _NavIconPainter extends CustomPainter {
  final NavTabIcon kind;
  final bool selected;

  _NavIconPainter(this.kind, {required this.selected});

  // The two palettes. Selected: the tab's real colours.
  // Unselected: the same shapes in blue-greys, so the
  // silhouettes still read but clearly "off".
  static const _globe = (
    ocean: Color(0xFF4FA3D1),
    land: Color(0xFF7CBF6B),
    line: Color(0xFFE8F4F8),
    rim: Color(0xFF2C6E8A),
  );
  static const _globeOff = (
    ocean: Color(0xFFAEBDC7),
    land: Color(0xFF97A8B3),
    line: Color(0xFFE3E9ED),
    rim: Color(0xFF78909C),
  );

  static const _case = (
    body: Color(0xFFE3A857),
    lid: Color(0xFFC98B3D),
    strap: Color(0xFF9C6A2F),
    handle: Color(0xFF6D4A22),
  );
  static const _caseOff = (
    body: Color(0xFFAEBDC7),
    lid: Color(0xFF93A5B1),
    strap: Color(0xFF78909C),
    handle: Color(0xFF607D8B),
  );

  static const _compass = (
    face: Color(0xFFF7F5EF),
    ring: Color(0xFF37474F),
    north: Color(0xFFE53935),
    south: Color(0xFF546E7A),
  );
  static const _compassOff = (
    face: Color(0xFFDDE4E9),
    ring: Color(0xFF78909C),
    north: Color(0xFF93A5B1),
    south: Color(0xFF607D8B),
  );

  static const _map = (
    panelA: Color(0xFFC8E6C9),
    panelB: Color(0xFFA5D6A7),
    water: Color(0xFFB3D9F2),
    fold: Color(0xFF8FBF94),
    route: Color(0xFFE53935),
  );
  static const _mapOff = (
    panelA: Color(0xFFC3CDD5),
    panelB: Color(0xFFAEBDC7),
    water: Color(0xFFB8C6D0),
    fold: Color(0xFF93A5B1),
    route: Color(0xFF78909C),
  );

  @override
  void paint(Canvas canvas, Size size) {
    // All geometry below is drawn in a 26x26 box; scale it
    // to whatever size the widget was given (the empty
    // states draw it at 56-64).
    canvas.scale(size.width / 26, size.height / 26);
    switch (kind) {
      case NavTabIcon.globe:
        _paintGlobe(canvas);
      case NavTabIcon.suitcase:
        _paintSuitcase(canvas);
      case NavTabIcon.compass:
        _paintCompass(canvas);
      case NavTabIcon.map:
        _paintMap(canvas);
    }
  }

  void _paintGlobe(Canvas canvas) {
    final c = selected ? _globe : _globeOff;
    final centre = const Offset(13, 13);
    final radius = 10.0;

    // Ocean, with the land masses and the graticule
    // clipped to the disc so nothing bleeds past the rim.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: centre, radius: radius)));
    canvas.drawOval(
      Rect.fromCircle(center: centre, radius: radius),
      Paint()..color = c.ocean,
    );
    final land = Paint()..color = c.land;
    canvas.drawOval(const Rect.fromLTWH(4, 6, 9, 6), land);
    canvas.drawOval(const Rect.fromLTWH(13, 12, 7, 8), land);
    canvas.drawOval(const Rect.fromLTWH(15, 4, 5, 4), land);
    canvas.drawOval(const Rect.fromLTWH(5, 16, 5, 4), land);
    // Graticule: two meridians and the equator.
    final line = Paint()
      ..color = c.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    canvas.drawOval(
      Rect.fromCircle(center: centre, radius: radius),
      line..strokeWidth = 1.1,
    );
    canvas.drawOval(
      Rect.fromLTWH(centre.dx - 4.5, centre.dy - radius, 9, radius * 2),
      line,
    );
    canvas.drawLine(
      Offset(centre.dx - radius, centre.dy),
      Offset(centre.dx + radius, centre.dy),
      line,
    );
    canvas.drawLine(
      Offset(centre.dx - radius * 0.92, centre.dy - 5),
      Offset(centre.dx + radius * 0.92, centre.dy - 5),
      line,
    );
    canvas.drawLine(
      Offset(centre.dx - radius * 0.92, centre.dy + 5),
      Offset(centre.dx + radius * 0.92, centre.dy + 5),
      line,
    );
    canvas.restore();
    // The rim stays outside the clip so it is always crisp.
    canvas.drawOval(
      Rect.fromCircle(center: centre, radius: radius),
      Paint()
        ..color = c.rim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  void _paintSuitcase(Canvas canvas) {
    final c = selected ? _case : _caseOff;
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4, 9, 18, 13),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(body, Paint()..color = c.body);
    // The lid band across the top of the case.
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        const Rect.fromLTWH(4, 9, 18, 4.5),
        topLeft: const Radius.circular(2.5),
        topRight: const Radius.circular(2.5),
      ),
      Paint()..color = c.lid,
    );
    // Two vertical straps.
    final strap = Paint()..color = c.strap;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(8, 9, 2.4, 13),
        const Radius.circular(1),
      ),
      strap,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(15.6, 9, 2.4, 13),
        const Radius.circular(1),
      ),
      strap,
    );
    // The handle: a stroked arc over the lid.
    final handle = Paint()
      ..color = c.handle
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      const Rect.fromLTWH(8.5, 4.5, 9, 8),
      math.pi,
      math.pi,
      false,
      handle,
    );
  }

  void _paintCompass(Canvas canvas) {
    final c = selected ? _compass : _compassOff;
    final centre = const Offset(13, 13);
    canvas.drawOval(
      Rect.fromCircle(center: centre, radius: 10),
      Paint()..color = c.face,
    );
    canvas.drawOval(
      Rect.fromCircle(center: centre, radius: 10),
      Paint()
        ..color = c.ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    // The dial: the four cardinal ticks.
    final tick = Paint()
      ..color = c.ring
      ..strokeWidth = 1.2;
    for (final angle in const [0.0, math.pi / 2, math.pi, 3 * math.pi / 2]) {
      final direction = Offset(math.sin(angle), -math.cos(angle));
      canvas.drawLine(
        centre + direction * 7.0,
        centre + direction * 9.0,
        tick,
      );
    }
    // The needle: red to the north-east, grey to the
    // south-west, sharing the centre.
    final needlePath = Path()
      ..moveTo(centre.dx + 6.6, centre.dy - 6.6)
      ..lineTo(centre.dx - 1.6, centre.dy - 1.2)
      ..lineTo(centre.dx + 1.2, centre.dy + 1.6)
      ..close();
    canvas.drawPath(needlePath, Paint()..color = c.north);
    final tailPath = Path()
      ..moveTo(centre.dx - 6.6, centre.dy + 6.6)
      ..lineTo(centre.dx + 1.2, centre.dy + 1.6)
      ..lineTo(centre.dx - 1.6, centre.dy - 1.2)
      ..close();
    canvas.drawPath(tailPath, Paint()..color = c.south);
    canvas.drawOval(
      Rect.fromCircle(center: centre, radius: 1.4),
      Paint()..color = c.ring,
    );
  }

  void _paintMap(Canvas canvas) {
    final c = selected ? _map : _mapOff;
    // The classic accordion fold: left and right panels
    // lean one way, the middle panel the other.
    final left = Path()
      ..moveTo(3, 7)
      ..lineTo(9.5, 4.5)
      ..lineTo(9.5, 20.5)
      ..lineTo(3, 23)
      ..close();
    final middle = Path()
      ..moveTo(9.5, 4.5)
      ..lineTo(16.5, 7)
      ..lineTo(16.5, 23)
      ..lineTo(9.5, 20.5)
      ..close();
    final right = Path()
      ..moveTo(16.5, 7)
      ..lineTo(23, 4.5)
      ..lineTo(23, 23)
      ..lineTo(16.5, 23)
      ..close();
    canvas.drawPath(left, Paint()..color = c.water);
    canvas.drawPath(middle, Paint()..color = c.panelA);
    canvas.drawPath(right, Paint()..color = c.panelB);
    // Fold edges.
    final fold = Paint()
      ..color = c.fold
      ..strokeWidth = 1;
    canvas.drawLine(const Offset(9.5, 4.5), const Offset(9.5, 20.5), fold);
    canvas.drawLine(const Offset(16.5, 7), const Offset(16.5, 23), fold);
    // The route across the panels, ending in the pin.
    final route = Paint()
      ..color = c.route
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final dash = Paint()
      ..color = c.route
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(5.5, 17), const Offset(9.5, 14), route);
    _dashedLine(
      canvas,
      const Offset(9.5, 14),
      const Offset(14, 10),
      dash,
    );
    _dashedLine(
      canvas,
      const Offset(14, 10),
      const Offset(19, 7.5),
      dash,
    );
    canvas.drawOval(
      Rect.fromCircle(center: const Offset(19.5, 6.5), radius: 2),
      Paint()..color = c.route,
    );
    canvas.drawOval(
      Rect.fromCircle(center: const Offset(19.5, 6.5), radius: 0.8),
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }

  void _dashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dashLength = 2.4;
    final delta = to - from;
    final length = delta.distance;
    final unit = delta / length;
    var travelled = 0.0;
    while (travelled < length) {
      final end = math.min(travelled + dashLength, length);
      canvas.drawLine(from + unit * travelled, from + unit * end, paint);
      travelled = end + 2.0;
    }
  }

  @override
  bool shouldRepaint(_NavIconPainter old) =>
      old.kind != kind || old.selected != selected;
}
