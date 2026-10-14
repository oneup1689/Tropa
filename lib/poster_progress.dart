import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'db.dart';
import 'l10n.dart';
import 'theme.dart';

/// Shown while a poster is being made: the route of the walk is drawn as a line on a dark card, over and over
/// until the poster is ready. Same idea as the word "drawn" by a trail on the splash screen.
class PosterBuildOverlay extends StatefulWidget {
  final List<TrackPoint> points;

  const PosterBuildOverlay({super.key, required this.points});

  @override
  State<PosterBuildOverlay> createState() => _PosterBuildOverlayState();
}

class _PosterBuildOverlayState extends State<PosterBuildOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();
  late final List<Offset> _norm = _normalize(widget.points);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// The route fitted into a unit square (aspect ratio kept, north up), at most ~300 points.
  static List<Offset> _normalize(List<TrackPoint> pts) {
    if (pts.length < 2) return const [];
    final step = math.max(1, pts.length ~/ 300);
    final sample = [for (var i = 0; i < pts.length; i += step) pts[i], pts.last];
    final k = math.cos(sample.first.lat * math.pi / 180);
    var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
    final xy = [for (final p in sample) Offset(p.lon * k, -p.lat)];
    for (final o in xy) {
      minX = math.min(minX, o.dx);
      maxX = math.max(maxX, o.dx);
      minY = math.min(minY, o.dy);
      maxY = math.max(maxY, o.dy);
    }
    final size = math.max(math.max(maxX - minX, maxY - minY), 1e-9);
    final offX = (size - (maxX - minX)) / 2, offY = (size - (maxY - minY)) / 2;
    return [for (final o in xy) Offset((o.dx - minX + offX) / size, (o.dy - minY + offY) / size)];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0B3A2F), Color(0xFF071C2C)]),
      ),
      child: SafeArea(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AspectRatio(
            aspectRatio: 1,
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: AnimatedBuilder(
                animation: _ctl,
                builder: (_, _) => CustomPaint(painter: _TrailPainter(_norm, Curves.easeInOutCubic.transform(_ctl.value))),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(t('Рисую постер…'), style: const TextStyle(color: Colors.white, fontSize: 18)),
          const SizedBox(height: 6),
          Text(t('Это займёт несколько секунд'), style: const TextStyle(color: Colors.white60, fontSize: 13)),
        ]),
      ),
    );
  }
}

class _TrailPainter extends CustomPainter {
  final List<Offset> points;
  final double progress;

  _TrailPainter(this.points, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx * size.width, points.first.dy * size.height);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx * size.width, p.dy * size.height);
    }
    final metric = path.computeMetrics().first;
    final drawn = metric.extractPath(0, metric.length * progress);
    // Faint full route as a guide, then the part drawn so far with a soft glow.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0x22FFFFFF),
    );
    canvas.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = TropaColors.mint.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = TropaColors.mint,
    );
    final head = metric.getTangentForOffset(metric.length * progress)?.position;
    if (head != null) {
      canvas.drawCircle(head, 9, Paint()..color = Colors.white);
      canvas.drawCircle(head, 5, Paint()..color = TropaColors.orange);
    }
  }

  @override
  bool shouldRepaint(_TrailPainter old) => old.progress != progress || old.points != points;
}
