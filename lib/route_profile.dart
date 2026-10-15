import 'package:flutter/material.dart';

import 'elevation.dart' show DemSamples;
import 'heal.dart' show haversine;
import 'units.dart';

/// Height profile of a saved route: heights from the terrain model against the distance along the route.
class RouteProfileData {
  /// Metres from the start (of the direction the route is walked) of every sample.
  final List<double> dist;
  final List<double> elev;

  const RouteProfileData(this.dist, this.elev);

  double get lengthM => dist.isEmpty ? 0 : dist.last;
  double get minElev => elev.reduce((a, b) => a < b ? a : b);
  double get maxElev => elev.reduce((a, b) => a > b ? a : b);

  /// Worth drawing: a flat line says nothing (same limit as the poster profile).
  bool get meaningful => elev.length >= 3 && lengthM >= 100 && maxElev - minElev >= 20;
}

/// Distance along [points] of every sample of [dem] (its indexes point into [points]); for a route walked
/// [reverse] the series is turned round so it starts at the walked start.
RouteProfileData routeProfileSeries(List<({double lat, double lon})> points, DemSamples dem, {bool reverse = false}) {
  final cum = List<double>.filled(points.length, 0);
  for (var i = 1; i < points.length; i++) {
    cum[i] = cum[i - 1] + haversine(points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon);
  }
  final dist = <double>[], elev = <double>[];
  final n = dem.idx.length < dem.elev.length ? dem.idx.length : dem.elev.length;
  for (var k = 0; k < n; k++) {
    final i = dem.idx[k];
    if (i < 0 || i >= points.length) continue;
    dist.add(cum[i]);
    elev.add(dem.elev[k]);
  }
  if (!reverse || dist.isEmpty) return RouteProfileData(dist, elev);
  final total = dist.last;
  return RouteProfileData([for (final d in dist.reversed) total - d], elev.reversed.toList());
}

/// The profile as a compact chart: filled area, height range, length.
class RouteProfile extends StatelessWidget {
  final RouteProfileData data;
  final double height;

  const RouteProfile({super.key, required this.data, this.height = 110});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ProfilePainter(data, cs.primary, cs.onSurfaceVariant, Theme.of(context).textTheme.bodySmall?.fontSize ?? 12),
      ),
    );
  }
}

class _ProfilePainter extends CustomPainter {
  final RouteProfileData data;
  final Color line;
  final Color text;
  final double fontSize;

  _ProfilePainter(this.data, this.line, this.text, this.fontSize);

  void _label(Canvas c, String s, Offset at, {bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: text, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(right ? at.dx - tp.width : at.dx, at.dy));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (data.elev.length < 2) return;
    final lo = data.minElev, hi = data.maxElev;
    final span = (hi - lo).clamp(1.0, double.infinity);
    const top = 16.0, bottom = 16.0;
    final w = size.width, h = size.height - top - bottom;
    final len = data.lengthM <= 0 ? 1.0 : data.lengthM;
    Offset at(int i) => Offset(data.dist[i] / len * w, top + h - (data.elev[i] - lo) / span * h);

    final path = Path()..moveTo(0, top + h);
    for (var i = 0; i < data.elev.length; i++) {
      final o = at(i);
      path.lineTo(o.dx, o.dy);
    }
    path.lineTo(w, top + h);
    path.close();
    canvas.drawPath(path, Paint()..color = line.withValues(alpha: 0.18));
    final stroke = Path();
    for (var i = 0; i < data.elev.length; i++) {
      final o = at(i);
      i == 0 ? stroke.moveTo(o.dx, o.dy) : stroke.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      stroke,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round,
    );
    _label(canvas, '${Units.height(hi)} ↑', const Offset(0, 0));
    _label(canvas, Units.height(lo), Offset(0, top + h + 2));
    _label(canvas, Units.dist(data.lengthM, digits: 1), Offset(w, top + h + 2), right: true);
  }

  @override
  bool shouldRepaint(covariant _ProfilePainter old) => old.data != data || old.line != line;
}
