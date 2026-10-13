import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/brand.dart';

/// Debug tool: draws logo candidates into dist/logos_options.png so they can be compared. Not a regression test.
Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

const _orange = Color(0xFFFF7043);
const _white = Color(0xFFFFFFFF);

void _badge(Canvas c, double s, List<Color> colors, {bool circle = false}) {
  final shader = ui.Gradient.linear(Offset.zero, Offset(s, s), colors);
  if (circle) {
    c.drawCircle(Offset(s / 2, s / 2), s / 2, Paint()..shader = shader);
  } else {
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.24)), Paint()..shader = shader);
  }
}

Paint _stroke(double w, Color color) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..color = color;

/// 1: an S-shaped trail from a start ring to an orange map pin.
void _logoTrailPin(Canvas c, double s) {
  _badge(c, s, const [Color(0xFF1B7F5C), Color(0xFF073B3A)]);
  final trail = Path()
    ..moveTo(s * 0.26, s * 0.80)
    ..cubicTo(s * 0.80, s * 0.80, s * 0.18, s * 0.52, s * 0.62, s * 0.46);
  c.drawPath(trail, _stroke(s * 0.07, _white));
  c.drawCircle(Offset(s * 0.26, s * 0.80), s * 0.055, Paint()..color = _white);
  c.drawCircle(Offset(s * 0.26, s * 0.80), s * 0.026, Paint()..color = const Color(0xFF0B4A3E));
  // The pin.
  final pin = Path();
  final cx = s * 0.66, cy = s * 0.33, r = s * 0.13;
  pin.moveTo(cx, cy + r * 2.1);
  pin.cubicTo(cx - r * 1.5, cy + r * 0.7, cx - r, cy - r, cx, cy - r);
  pin.cubicTo(cx + r, cy - r, cx + r * 1.5, cy + r * 0.7, cx, cy + r * 2.1);
  c.drawPath(pin, Paint()..color = _orange);
  c.drawCircle(Offset(cx, cy + r * 0.15), r * 0.42, Paint()..color = _white);
}

/// 2: the letter T: a bar (the horizon) and a trail that winds down from it.
void _logoLetterT(Canvas c, double s) {
  _badge(c, s, const [Color(0xFF2E7D32), Color(0xFF0A3622)]);
  c.drawLine(Offset(s * 0.25, s * 0.26), Offset(s * 0.75, s * 0.26), _stroke(s * 0.10, _white));
  final stem = Path()
    ..moveTo(s * 0.50, s * 0.30)
    ..cubicTo(s * 0.50, s * 0.46, s * 0.36, s * 0.48, s * 0.40, s * 0.62)
    ..cubicTo(s * 0.44, s * 0.74, s * 0.58, s * 0.72, s * 0.56, s * 0.84);
  c.drawPath(stem, _stroke(s * 0.10, _white));
  c.drawCircle(Offset(s * 0.56, s * 0.84), s * 0.07, Paint()..color = _orange);
}

/// 3: contour lines (the poster's own background) with the trail crossing them to an orange summit dot.
void _logoContours(Canvas c, double s) {
  _badge(c, s, const [Color(0xFF0E5A45), Color(0xFF071C2C)]);
  final ring = _stroke(s * 0.028, const Color(0x99FFFFFF));
  for (var k = 1; k <= 3; k++) {
    final path = Path();
    for (var a = 0; a <= 360; a += 8) {
      final t = a * math.pi / 180;
      final wob = 1 + 0.10 * math.sin(3 * t + k) + 0.05 * math.sin(5 * t - k);
      final rad = s * (0.10 + k * 0.105) * wob;
      final p = Offset(s * 0.5 + rad * math.cos(t), s * 0.52 + rad * 0.82 * math.sin(t));
      a == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    c.drawPath(path, ring);
  }
  final trail = Path()
    ..moveTo(s * 0.12, s * 0.80)
    ..cubicTo(s * 0.40, s * 0.82, s * 0.30, s * 0.60, s * 0.52, s * 0.56)
    ..cubicTo(s * 0.62, s * 0.54, s * 0.50, s * 0.50, s * 0.50, s * 0.50);
  c.drawPath(trail, _stroke(s * 0.06, _white));
  c.drawCircle(Offset(s * 0.5, s * 0.5), s * 0.075, Paint()..color = _orange);
  c.drawCircle(Offset(s * 0.5, s * 0.5), s * 0.075, _stroke(s * 0.022, _white));
}

/// 4: one big peak with a zigzag path up its face and a flag on the summit.
void _logoPeakFlag(Canvas c, double s) {
  _badge(c, s, const [Color(0xFF3B8E5A), Color(0xFF0B3D2E)], circle: true);
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
  c.drawPath(zig, _stroke(s * 0.045, _white));
  c.drawLine(Offset(s * 0.46, s * 0.27), Offset(s * 0.46, s * 0.12), _stroke(s * 0.03, _white));
  final flag = Path()
    ..moveTo(s * 0.46, s * 0.12)
    ..lineTo(s * 0.64, s * 0.18)
    ..lineTo(s * 0.46, s * 0.24)
    ..close();
  c.drawPath(flag, Paint()..color = _orange);
}

/// 5: footprints: four steps along a diagonal, the last one orange.
void _logoFootprints(Canvas c, double s) {
  _badge(c, s, const [Color(0xFF2F8F5B), Color(0xFF0A3B2E)]);
  void print(Offset at, double angle, bool left, Color color) {
    c.save();
    c.translate(at.dx, at.dy);
    c.rotate(angle);
    final sole = Rect.fromCenter(center: Offset(left ? -s * 0.012 : s * 0.012, 0), width: s * 0.10, height: s * 0.16);
    c.drawOval(sole, Paint()..color = color);
    c.drawOval(Rect.fromCenter(center: Offset(left ? -s * 0.012 : s * 0.012, s * 0.115), width: s * 0.075, height: s * 0.065), Paint()..color = color);
    c.restore();
  }

  final steps = [
    (Offset(s * 0.34, s * 0.78), -0.35, true),
    (Offset(s * 0.50, s * 0.62), -0.55, false),
    (Offset(s * 0.60, s * 0.45), -0.35, true),
    (Offset(s * 0.70, s * 0.27), -0.55, false),
  ];
  for (var i = 0; i < steps.length; i++) {
    print(steps[i].$1, steps[i].$2, steps[i].$3, i == steps.length - 1 ? _orange : _white);
  }
}

void main() {
  testWidgets('render logo options', (tester) async {
    await tester.runAsync(() async {
      await _loadFont('Rubik', 'assets/fonts/Rubik-Variable.ttf');
      await _loadFont('Unbounded', 'assets/fonts/Unbounded-Variable.ttf');
      const w = 2000.0, h = 1250.0;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF0B1F1A));
      c.drawRect(const Rect.fromLTWH(0, 880, w, h - 880), Paint()..color = const Color(0xFFF4F7F2));
      final options = <(String, String, void Function(Canvas, double))>[
        ('1 · Тропа и метка', 'извилистая тропа от старта к оранжевой метке', _logoTrailPin),
        ('2 · Буква T', 'T, где ножка — тропа', _logoLetterT),
        ('3 · Горизонтали', 'как фон постера: линии высот и вершина', _logoContours),
        ('4 · Вершина и флаг', 'пик, зигзаг-тропа и флаг на вершине', _logoPeakFlag),
        ('5 · Следы', 'четыре шага, последний оранжевый', _logoFootprints),
      ];
      for (var i = 0; i < options.length; i++) {
        final x = 60.0 + i * 392;
        c.save();
        c.translate(x, 60);
        options[i].$3(c, 340);
        c.restore();
        drawText(c, options[i].$1, Offset(x, 420), headingStyle(26, weight: 700), maxWidth: 360);
        drawText(c, options[i].$2, Offset(x, 468), bodyStyle(22, color: const Color(0xFFB0BEC5)), maxWidth: 350);
        // Small sizes: how it reads as an app icon and next to the name.
        for (final (k, sz) in const [(0, 150.0), (1, 96.0), (2, 56.0)]) {
          final px = x + [0.0, 170.0, 290.0][k];
          c.save();
          c.translate(px, 600);
          options[i].$3(c, sz);
          c.restore();
        }
        c.save();
        c.translate(x, 790);
        options[i].$3(c, 64);
        c.restore();
        drawText(c, 'Tropa', Offset(x + 80, 800), headingStyle(40, weight: 700), maxWidth: 260);
        // On a light background.
        c.save();
        c.translate(x, 940);
        options[i].$3(c, 200);
        c.restore();
        c.save();
        c.translate(x + 220, 1010);
        options[i].$3(c, 64);
        c.restore();
        drawText(c, 'Tropa', Offset(x + 220, 1090), headingStyle(30, weight: 700, color: const Color(0xFF0B3D2E)), maxWidth: 140);
      }
      final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      File('dist/logos_options.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  });
}
