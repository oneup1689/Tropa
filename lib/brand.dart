import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'modes.dart';

/// Poster fonts (bundled, SIL OFL): Unbounded for headings and numbers, Rubik for text.
const String headingFont = 'Unbounded';
const String bodyFont = 'Rubik';

TextStyle headingStyle(double size, {double weight = 700, Color color = const Color(0xFFFFFFFF)}) => TextStyle(
      fontFamily: headingFont,
      fontSize: size,
      color: color,
      height: 1.1,
      fontVariations: [FontVariation('wght', weight)],
    );

TextStyle bodyStyle(double size, {double weight = 400, Color color = const Color(0xFFFFFFFF)}) => TextStyle(
      fontFamily: bodyFont,
      fontSize: size,
      color: color,
      height: 1.2,
      fontVariations: [FontVariation('wght', weight)],
    );

/// Colours of the ways of travelling on a poster (bright: they sit on dark backgrounds and maps).
Color posterModeColor(TravelMode m) => switch (m) {
      TravelMode.walk => const Color(0xFF69F0AE),
      TravelMode.bike => const Color(0xFF40C4FF),
      TravelMode.car => const Color(0xFFFF7043),
      TravelMode.water => const Color(0xFF18FFFF),
      TravelMode.mixed => const Color(0xFFFFD54F),
    };

const Color brandGreen = Color(0xFF2E7D32);
const Color brandDeep = Color(0xFF0B3D2E);
const Color brandAccent = Color(0xFFFF7043);

/// The Tropa logo: a green round badge with a peak, a zigzag trail up its face and an orange flag on the summit.
/// Drawn in code (no image files), so it is sharp at any size. [size] is the diameter of the badge; with
/// [badge] false only the peak, the trail and the flag are drawn (for use on a coloured background).
void drawTropaLogo(Canvas c, Offset topLeft, double size, {bool badge = true, Color? mono}) {
  final s = size;
  c.save();
  c.translate(topLeft.dx, topLeft.dy);
  if (badge) {
    c.drawCircle(
      Offset(s / 2, s / 2),
      s / 2,
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(s, s), const [Color(0xFF3B8E5A), Color(0xFF0B3D2E)]),
    );
  }
  if (mono != null) {
    // One-colour version (status bar icons): a solid peak with the trail cut out of it, and the flag.
    c.saveLayer(Rect.fromLTWH(0, 0, s, s), Paint());
    final solid = Path()
      ..moveTo(s * 0.10, s * 0.82)
      ..lineTo(s * 0.46, s * 0.26)
      ..lineTo(s * 0.62, s * 0.50)
      ..lineTo(s * 0.72, s * 0.38)
      ..lineTo(s * 0.92, s * 0.82)
      ..close();
    c.drawPath(solid, Paint()..color = mono);
    final cut = Path()
      ..moveTo(s * 0.30, s * 0.80)
      ..lineTo(s * 0.50, s * 0.66)
      ..lineTo(s * 0.34, s * 0.56)
      ..lineTo(s * 0.50, s * 0.46)
      ..lineTo(s * 0.43, s * 0.36)
      ..lineTo(s * 0.46, s * 0.27);
    c.drawPath(
      cut,
      Paint()
        ..blendMode = BlendMode.clear
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.07
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    c.drawLine(
      Offset(s * 0.46, s * 0.27),
      Offset(s * 0.46, s * 0.10),
      Paint()
        ..color = mono
        ..strokeWidth = s * 0.05
        ..strokeCap = StrokeCap.round,
    );
    c.drawPath(
      Path()
        ..moveTo(s * 0.46, s * 0.10)
        ..lineTo(s * 0.70, s * 0.18)
        ..lineTo(s * 0.46, s * 0.26)
        ..close(),
      Paint()..color = mono,
    );
    c.restore();
    c.restore();
    return;
  }
  final peak = Path()
    ..moveTo(s * 0.14, s * 0.78)
    ..lineTo(s * 0.46, s * 0.26)
    ..lineTo(s * 0.62, s * 0.50)
    ..lineTo(s * 0.72, s * 0.38)
    ..lineTo(s * 0.88, s * 0.78)
    ..close();
  c.drawPath(peak, Paint()..color = const Color(0x55FFFFFF));
  final zig = Path()
    ..moveTo(s * 0.30, s * 0.78)
    ..lineTo(s * 0.50, s * 0.66)
    ..lineTo(s * 0.34, s * 0.56)
    ..lineTo(s * 0.50, s * 0.46)
    ..lineTo(s * 0.43, s * 0.36)
    ..lineTo(s * 0.46, s * 0.27);
  c.drawPath(
    zig,
    Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.045
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );
  c.drawLine(
    Offset(s * 0.46, s * 0.27),
    Offset(s * 0.46, s * 0.12),
    Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = s * 0.03
      ..strokeCap = StrokeCap.round,
  );
  final flag = Path()
    ..moveTo(s * 0.46, s * 0.12)
    ..lineTo(s * 0.64, s * 0.18)
    ..lineTo(s * 0.46, s * 0.24)
    ..close();
  c.drawPath(flag, Paint()..color = brandAccent);
  c.restore();
}

/// Draws [text] with [style]; returns the painted size. Wrapped to [maxWidth] when given.
Size drawText(Canvas c, String text, Offset at, TextStyle style,
    {double? maxWidth, TextAlign align = TextAlign.left, int? maxLines}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(maxWidth: maxWidth ?? double.infinity);
  tp.paint(c, at);
  return tp.size;
}

/// Width of [text] with [style], for right-aligning and centring.
double textWidth(String text, TextStyle style) {
  final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
  return tp.width;
}

/// Linear interpolation across [stops] (evenly spaced) for t in 0..1.
Color gradientColor(List<Color> stops, double t) {
  final v = t.clamp(0.0, 1.0) * (stops.length - 1);
  final i = math.min(v.floor(), stops.length - 2);
  return Color.lerp(stops[i], stops[i + 1], v - i)!;
}

/// Speed palette (slow to fast) and height palette (low to high) of the poster line.
const List<Color> speedStops = [Color(0xFF2979FF), Color(0xFF00E5FF), Color(0xFF76FF03), Color(0xFFFFEA00), Color(0xFFFF6D00), Color(0xFFFF1744)];
const List<Color> heightStops = [Color(0xFF00BFA5), Color(0xFFAEEA00), Color(0xFFFFD600), Color(0xFFFF6D00), Color(0xFFD50000)];
