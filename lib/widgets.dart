import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'brand.dart';
import 'db.dart';
import 'heal.dart';

/// The logo as a widget.
class TropaLogo extends StatelessWidget {
  final double size;

  const TropaLogo({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => drawTropaLogo(canvas, Offset.zero, size.width);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Faint contour lines, the same motif as on the posters, for cards and headers.
class ContourPainter extends CustomPainter {
  final Color color;
  final double seed;

  const ContourPainter({this.color = const Color(0x22FFFFFF), this.seed = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = color;
    final cx = size.width * (0.78 + 0.05 * math.sin(seed)), cy = size.height * 0.25;
    final step = size.shortestSide * 0.16;
    for (var r = 1; r <= 14; r++) {
      final path = Path();
      for (var a = 0; a <= 360; a += 8) {
        final t = a * math.pi / 180;
        final wob = 1 + 0.12 * math.sin(3 * t + r * 0.45 + seed) + 0.07 * math.sin(5 * t - r * 0.3);
        final rad = r * step * wob;
        final p = Offset(cx + rad * math.cos(t), cy + rad * 0.78 * math.sin(t));
        a == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(covariant ContourPainter old) => old.color != color || old.seed != seed;
}

/// A small picture of a recorded route: the track fitted into a square, with its start and finish.
class RouteThumb extends StatelessWidget {
  final List<TrackPoint> points;
  final double size;
  final Color background;
  final Color line;

  const RouteThumb({
    super.key,
    required this.points,
    this.size = 76,
    this.background = const Color(0xFF0E4D3A),
    this.line = const Color(0xFF6FD6A3),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _ThumbPainter(points, background, line)),
      ),
    );
  }
}

class _ThumbPainter extends CustomPainter {
  final List<TrackPoint> pts;
  final Color background;
  final Color line;

  _ThumbPainter(this.pts, this.background, this.line);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    const ContourPainter(color: Color(0x1FFFFFFF)).paint(canvas, size);
    if (pts.length < 2) return;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    final kx = math.cos((minLat + maxLat) / 2 * math.pi / 180);
    final w = math.max((maxLon - minLon) * kx, 1e-6), h = math.max(maxLat - minLat, 1e-6);
    final pad = size.width * 0.16;
    final scale = math.min((size.width - 2 * pad) / w, (size.height - 2 * pad) / h);
    final ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2;
    Offset pos(TrackPoint p) => Offset(ox + (p.lon - minLon) * kx * scale, oy + (maxLat - p.lat) * scale);
    final paint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.045
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    var prev = pts.first;
    path.moveTo(pos(prev).dx, pos(prev).dy);
    for (var i = 1; i < pts.length; i++) {
      final dt = pts[i].tsMs - prev.tsMs;
      final d = haversine(prev.lat, prev.lon, pts[i].lat, pts[i].lon);
      // A long hole in the recording is not joined by a line.
      if (dt > 60000 && d > 150) {
        path.moveTo(pos(pts[i]).dx, pos(pts[i]).dy);
      } else {
        path.lineTo(pos(pts[i]).dx, pos(pts[i]).dy);
      }
      prev = pts[i];
    }
    canvas.drawPath(path, paint);
    canvas.drawCircle(pos(pts.first), size.width * 0.05, Paint()..color = const Color(0xFF69F0AE));
    canvas.drawCircle(pos(pts.last), size.width * 0.05, Paint()..color = const Color(0xFFFF7043));
  }

  @override
  bool shouldRepaint(covariant _ThumbPainter old) => old.pts != pts;
}
