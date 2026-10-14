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

const Color brandGreen = Color(0xFF0E4D3A);
const Color brandDeep = Color(0xFF0B3D2E);
const Color brandAccent = Color(0xFFFF7043);
const Color brandTerracotta = Color(0xFFC8553D);
const Color brandSand = Color(0xFFF2E8CF);
const Color brandNight = Color(0xFF071C2C);

/// The Tropa mark: the letter t. Its crossbar is a path that crosses ours; the stem is our trail, which hooks and
/// rises into the finish dot. Drawn in code (no image files), so it is sharp at any size.
/// - [badge] true: a rounded square in the poster gradient (deep green to night) with the mark in sand and orange.
/// - [badge] false: only the mark (for the adaptive icon foreground and for use on a dark background).
/// - [mono]: a one-colour silhouette (status bar icons, Android 13 themed icon) in that colour.
/// [size] is the side of the square the mark is fitted into; the mark fills [fill] of it (the Android adaptive
/// icon needs it to stay within the central 66 %).
void drawTropaLogo(Canvas c, Offset topLeft, double size, {bool badge = true, Color? mono, double fill = 0.62}) {
  final s = size;
  c.save();
  c.translate(topLeft.dx, topLeft.dy);
  if (badge && mono == null) {
    final box = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.22));
    c.drawRRect(box, Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(s, s), const [brandGreen, brandNight]));
    c.drawRRect(
      box.deflate(s * 0.006),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.012
        ..color = const Color(0x2EF2E8CF),
    );
  }
  Paint line(Color col, double w) => Paint()
    ..color = col
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  if (mono != null) {
    // t with a short hook ending in a dot; fits a box 76.5 x 81 units around (63.75, 48).
    final k = s * fill / 81;
    c.translate(s / 2, s / 2);
    c.scale(k);
    c.translate(-63.75, -48);
    final p = Paint()..color = mono;
    c.drawPath(
      Path()
        ..moveTo(34, 40)
        ..lineTo(68, 40)
        ..moveTo(50, 16)
        ..lineTo(50, 60)
        ..arcToPoint(const Offset(70, 80), radius: const Radius.circular(20), clockwise: false),
      line(mono, 17),
    );
    c.drawCircle(const Offset(92, 80), 10, p);
    c.restore();
    return;
  }
  // The mark spans x 26..134.8 and y 8..88 in its own units; centre (80.4, 48).
  final k = s * fill / 109;
  c.translate(s / 2, s / 2);
  c.scale(k);
  c.translate(-80.4, -48);
  const w = 16.0;
  c.drawPath(Path()..moveTo(34, 40)..lineTo(68, 40), line(brandSand, w));
  c.drawPath(
    Path()
      ..moveTo(50, 16)
      ..lineTo(50, 60)
      ..arcToPoint(const Offset(70, 80), radius: const Radius.circular(20), clockwise: false)
      ..cubicTo(92, 80, 92, 56, 114, 56),
    line(brandSand, w),
  );
  c.drawCircle(const Offset(122, 56), w * 0.8, Paint()..color = brandAccent);
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

/// Slope palette of the poster line: steep descent (cold) through flat (pale) to steep climb (hot).
const List<Color> slopeStops = [Color(0xFF2979FF), Color(0xFF4DD0E1), Color(0xFFE0F2F1), Color(0xFFFFB300), Color(0xFFD50000)];
