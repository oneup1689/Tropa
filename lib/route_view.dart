import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'db.dart';
import 'heal.dart';

/// Simple offline preview of a recorded route (no map tiles yet):
/// solid line where GPS was continuous, a different colour where a short gap
/// was restored, dashed where the gap could not be restored safely.
class RouteViewPage extends StatefulWidget {
  final int sessionId;
  final String title;

  const RouteViewPage({super.key, required this.sessionId, required this.title});

  @override
  State<RouteViewPage> createState() => _RouteViewPageState();
}

class _RouteViewPageState extends State<RouteViewPage> {
  bool heal = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<List<TrackPoint>>(
        future: TrackDb.instance.points(widget.sessionId),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final pts = snap.data!;
          if (pts.length < 2) return const Center(child: Text('Недостаточно точек'));
          final result = analyzeGaps(pts);
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(_summary(result, pts.length)),
            ),
            SwitchListTile(
              title: const Text('Склеить короткие разрывы'),
              subtitle: const Text('Только пешие участки до 150 м. Длинные пропуски не склеиваются.'),
              value: heal,
              onChanged: (v) => setState(() => heal = v),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _RoutePainter(pts, result, heal, Theme.of(context).colorScheme),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }

  String _summary(HealResult r, int n) {
    final rec = (r.recordedMeters / 1000).toStringAsFixed(2);
    final restored = r.restoredMeters.round();
    final parts = ['Записано: $rec км', 'точек: $n'];
    if (restored > 0) parts.add(heal ? 'восстановлено: $restored м' : 'можно восстановить: $restored м');
    if (r.unresolved > 0) parts.add('не склеено разрывов: ${r.unresolved} (пунктир)');
    return parts.join(' · ');
  }
}

class _RoutePainter extends CustomPainter {
  final List<TrackPoint> pts;
  final HealResult result;
  final bool heal;
  final ColorScheme scheme;

  _RoutePainter(this.pts, this.result, this.heal, this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    final midLat = (minLat + maxLat) / 2;
    final kx = math.cos(midLat * math.pi / 180); // shrink longitude with latitude
    final w = math.max((maxLon - minLon) * kx, 1e-6);
    final h = math.max(maxLat - minLat, 1e-6);
    final scale = math.min(size.width / w, size.height / h) * 0.92;
    final ox = (size.width - w * scale) / 2;
    final oy = (size.height - h * scale) / 2;

    Offset pos(TrackPoint p) =>
        Offset(ox + (p.lon - minLon) * kx * scale, size.height - oy - (p.lat - minLat) * scale);

    final solid = Paint()
      ..color = scheme.primary
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final restored = Paint()
      ..color = Colors.deepOrange
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final dashed = Paint()
      ..color = scheme.error
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (var i = 1; i < pts.length; i++) {
      final a = pos(pts[i - 1]);
      final b = pos(pts[i]);
      final gap = result.gapAt(i);
      if (gap == null) {
        canvas.drawLine(a, b, solid);
      } else if (heal && gap.kind == GapKind.glueStill) {
        canvas.drawLine(a, b, solid);
      } else if (heal && gap.kind == GapKind.bridge) {
        canvas.drawLine(a, b, restored);
      } else {
        _dash(canvas, a, b, dashed);
      }
    }
    canvas.drawCircle(pos(pts.first), 8, Paint()..color = Colors.green);
    canvas.drawCircle(pos(pts.last), 8, Paint()..color = Colors.red);
  }

  void _dash(Canvas canvas, Offset a, Offset b, Paint paint) {
    final len = (b - a).distance;
    if (len == 0) return;
    final dir = (b - a) / len;
    for (double d = 0; d < len; d += 12) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + 6, len), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) => old.pts != pts || old.heal != heal;
}
