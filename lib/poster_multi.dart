import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'altitude.dart';
import 'brand.dart';
import 'db.dart';
import 'elevation.dart';
import 'heal.dart';
import 'modes.dart';
import 'poster.dart';
import 'splash.dart' show drawTropaWordmark;
import 'poster_wide.dart';
import 'stats.dart';
import 'l10n.dart';
import 'units.dart';

/// One walk on a multi-route poster.
class MultiRoute {
  final String name;
  final List<TrackPoint> pts;
  final List<double> altitude;
  final bool altitudeFused;
  final TravelMode mode;

  const MultiRoute(this.name, this.pts, this.altitude, this.altitudeFused, this.mode);
}

/// Colours of up to 12 routes: bright, far apart in hue, readable on a dark background and on a map.
const List<Color> multiColors = [
  Color(0xFFFF7043), Color(0xFF40C4FF), Color(0xFF69F0AE), Color(0xFFFFD54F), Color(0xFFE040FB), Color(0xFFFF5252),
  Color(0xFF18FFFF), Color(0xFFB2FF59), Color(0xFFFF9100), Color(0xFF7C4DFF), Color(0xFFF48FB1), Color(0xFFFFFFFF),
];

const int maxMultiRoutes = 12;

/// The tracks of all routes, fitted together into [area].
Projection fitProjectionMany(List<List<TrackPoint>> tracks, Rect area) {
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (final t in tracks) {
    for (final p in t) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
  }
  final kx = math.cos((minLat + maxLat) / 2 * math.pi / 180);
  final w = math.max((maxLon - minLon) * kx, 1e-6), h = math.max(maxLat - minLat, 1e-6);
  final scale = math.min(area.width / w, area.height / h);
  final ox = area.left + (area.width - w * scale) / 2, oy = area.top + (area.height - h * scale) / 2;
  return (lat, lon) => Offset(ox + (lon - minLon) * kx * scale, oy + (maxLat - lat) * scale);
}

/// Horizontal poster that puts several walks on one map: each walk in its own colour with a number at its
/// start, a list of the walks with their numbers, the totals, and the elevation profiles drawn over each other.
Future<Uint8List> composeMultiPoster({
  required PosterOptions o,
  required List<MultiRoute> routes,
  MapCapture? map,
  int scale = 2,
}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, wideW * scale, wideH * scale));
  c.scale(scale.toDouble());
  final useMap = o.background == PosterBackground.map && map != null;

  c.drawRect(
    const Rect.fromLTWH(0, 0, wideW, wideH),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(wideW, wideH), const [Color(0xFF0A1B20), Color(0xFF0F2F27)]),
  );
  ui.Image? img;
  if (useMap) {
    img = (await (await ui.instantiateImageCodec(map.png)).getNextFrame()).image;
    const full = Rect.fromLTWH(0, 0, wideW, wideH);
    c.saveLayer(full, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14));
    c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), full, Paint()..filterQuality = FilterQuality.medium);
    c.restore();
    c.drawRect(full, Paint()..color = Color(o.darkMap ? 0xCC0A1B20 : 0xD90A1B20));
  }

  // --- the map frame with all routes
  final frame = RRect.fromRectAndRadius(wideMapRect, const Radius.circular(24));
  c.save();
  c.clipRRect(frame);
  if (useMap && img != null) {
    c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), const Rect.fromLTWH(0, 0, wideW, wideH),
        Paint()
          ..filterQuality = FilterQuality.high
          ..colorFilter = mapToneFilter(o.darkMap));
  } else {
    c.drawRect(wideMapRect, Paint()..color = const Color(0xFF0C2924));
  }
  final proj = useMap ? mapProjection(map, wideW) : fitProjectionMany([for (final r in routes) r.pts], wideRouteArea);
  final light = useMap && !o.darkMap;
  _drawRoutes(c, routes, proj, light);
  drawDistanceScale(c, proj, routes.first.pts[routes.first.pts.length ~/ 2], Offset(wideMapRect.left + 36, wideMapRect.bottom - 36),
      light: light, maxLen: 190);
  if (useMap) {
    const note = '© OpenStreetMap · Protomaps';
    final style = bodyStyle(18, color: const Color(0xCCFFFFFF));
    drawText(c, note, Offset(wideMapRect.right - 16 - textWidth(note, style), wideMapRect.bottom - 30), style);
  }
  c.restore();
  _frame(c, wideMapRect);

  _profiles(c, routes);
  _panel(c, o, routes);
  _corners(c);

  final image = await rec.endRecording().toImage((wideW * scale).toInt(), (wideH * scale).toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void _drawRoutes(Canvas c, List<MultiRoute> routes, Projection proj, bool light) {
  final halo = Paint()
    ..color = light ? const Color(0xCCFFFFFF) : const Color(0x99000000)
    ..strokeWidth = 12
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  final faint = Paint()
    ..color = const Color(0x55FFFFFF)
    ..strokeWidth = 3
    ..style = PaintingStyle.stroke;
  for (var r = 0; r < routes.length; r++) {
    final pts = routes[r].pts;
    final line = <List<Offset>>[];
    var cur = <Offset>[];
    for (var i = 0; i < pts.length; i++) {
      final here = proj(pts[i].lat, pts[i].lon);
      if (i > 0) {
        final dt = pts[i].tsMs - pts[i - 1].tsMs;
        final d = haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
        if (dt > 60000 && d > 100) {
          // A hole in the recording: dashed hint, the line itself is not joined.
          if (cur.length > 1) line.add(cur);
          _dashed(c, proj(pts[i - 1].lat, pts[i - 1].lon), here, faint);
          cur = <Offset>[];
        }
      }
      cur.add(here);
    }
    if (cur.length > 1) line.add(cur);
    final paint = Paint()
      ..color = multiColors[r % multiColors.length]
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final l in line) {
      c.drawPoints(ui.PointMode.polygon, l, halo);
    }
    for (final l in line) {
      c.drawPoints(ui.PointMode.polygon, l, paint);
    }
  }
  // Starts: numbered markers on top of all lines.
  for (var r = 0; r < routes.length; r++) {
    final at = proj(routes[r].pts.first.lat, routes[r].pts.first.lon);
    final col = multiColors[r % multiColors.length];
    c.drawCircle(at.translate(0, 2), 22, Paint()..color = const Color(0x66000000));
    c.drawCircle(at, 22, Paint()..color = const Color(0xFFFFFFFF));
    c.drawCircle(at, 18, Paint()..color = col);
    final label = '${r + 1}';
    final style = bodyStyle(22, weight: 700, color: const Color(0xFF101010));
    drawText(c, label, at.translate(-textWidth(label, style) / 2, -14), style);
  }
}

void _dashed(Canvas c, Offset a, Offset b, Paint paint) {
  final len = (b - a).distance;
  if (len == 0) return;
  final dir = (b - a) / len;
  for (double d = 0; d < len; d += 14) {
    c.drawLine(a + dir * d, a + dir * math.min(d + 7, len), paint);
  }
}

// ====================================================================== decoration (same look as the pro map)

void _frame(Canvas c, Rect r) {
  final rr = RRect.fromRectAndRadius(r, const Radius.circular(24));
  c.drawRRect(rr, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..color = const Color(0xFFFFD54F).withAlpha(200));
  c.drawRRect(rr.deflate(6), Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = const Color(0x55FFFFFF));
}

void _corners(Canvas c) {
  final p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5
    ..strokeCap = StrokeCap.round
    ..color = const Color(0xFFFFD54F);
  const m = 20.0, l = 54.0;
  for (final (x, y, dx, dy) in const [(m, m, 1.0, 1.0), (wideW - m, m, -1.0, 1.0), (m, wideH - m, 1.0, -1.0), (wideW - m, wideH - m, -1.0, -1.0)]) {
    c.drawLine(Offset(x, y), Offset(x + dx * l, y), p);
    c.drawLine(Offset(x, y), Offset(x, y + dy * l), p);
  }
}

// ====================================================================== profiles of all routes

void _profiles(Canvas c, List<MultiRoute> routes) {
  c.drawRRect(RRect.fromRectAndRadius(wideChartRect, const Radius.circular(24)), Paint()..color = const Color(0x22000000));
  _frame(c, wideChartRect);
  drawText(c, t('ПРОФИЛИ ВЫСОТЫ'), Offset(wideChartRect.left + 28, wideChartRect.top + 18),
      headingStyle(18, weight: 600, color: const Color(0xFFFFD54F)));

  // Distance along every walk, and the common height range.
  final dists = <List<double>>[];
  final unitM = Units.imperial ? 1609.344 : 1000.0;
  var maxKm = 0.0, lo = double.infinity, hi = -double.infinity;
  for (final r in routes) {
    final d = List<double>.filled(r.pts.length, 0);
    for (var i = 1; i < r.pts.length; i++) {
      final dt = r.pts[i].tsMs - r.pts[i - 1].tsMs;
      final dd = haversine(r.pts[i - 1].lat, r.pts[i - 1].lon, r.pts[i].lat, r.pts[i].lon);
      d[i] = d[i - 1] + (dt <= 30000 && dd / math.max(dt / 1000, 1) < 100 ? dd : 0);
    }
    dists.add(d);
    maxKm = math.max(maxKm, d.last / unitM);
    for (final a in r.altitude) {
      lo = math.min(lo, a);
      hi = math.max(hi, a);
    }
  }
  if (maxKm < 0.05 || !lo.isFinite) return;
  if (hi - lo < 20) {
    final mid = (hi + lo) / 2;
    lo = mid - 10;
    hi = mid + 10;
  }
  final step = [10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 500.0].firstWhere((v) => (hi - lo) / v <= 6, orElse: () => 1000.0);
  final pad = (hi - lo) * 0.06;
  lo -= pad;
  hi += pad * 2;
  final plot = Rect.fromLTRB(wideChartRect.left + 84, wideChartRect.top + 58, wideChartRect.right - 34, wideChartRect.bottom - 52);
  double xOf(double m) => plot.left + m / unitM / maxKm * plot.width;
  double yOf(double a) => plot.bottom - (a - lo) / (hi - lo) * plot.height;

  final grid = Paint()
    ..color = const Color(0x22FFFFFF)
    ..strokeWidth = 1.5;
  final label = bodyStyle(20, color: const Color(0xFFB0BEC5));
  for (var a = (lo / step).ceil() * step; a <= hi + 0.001; a += step) {
    c.drawLine(Offset(plot.left, yOf(a)), Offset(plot.right, yOf(a)), grid);
    final tick = Units.height(a);
    drawText(c, tick, Offset(plot.left - 12 - textWidth(tick, label), yOf(a) - 12), label);
  }
  final kmStep = [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0].firstWhere((s) => maxKm / s <= 9, orElse: () => 100.0);
  for (var k = 0.0; k <= maxKm + 0.001; k += kmStep) {
    final x = plot.left + k / maxKm * plot.width;
    c.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 8), grid..strokeWidth = 2);
    final tick = k == k.roundToDouble() ? '${k.round()}' : k.toStringAsFixed(1);
    drawText(c, tick, Offset(x - textWidth(tick, label) / 2, plot.bottom + 12), label);
  }
  drawText(c, Units.kmUnit, Offset(plot.right - 28, plot.bottom + 12), label);

  for (var r = 0; r < routes.length; r++) {
    final alt = routes[r].altitude;
    final line = Path();
    final skip = math.max(1, alt.length ~/ 500);
    for (var i = 0; i < alt.length; i += skip) {
      final p = Offset(xOf(dists[r][i]), yOf(alt[i]));
      i == 0 ? line.moveTo(p.dx, p.dy) : line.lineTo(p.dx, p.dy);
    }
    c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = multiColors[r % multiColors.length],
    );
  }
}

// ====================================================================== left panel

String _hms(int s) {
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two((s ~/ 60) % 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

String _dateRange(int fromMs, int toMs) {
  final a = DateTime.fromMillisecondsSinceEpoch(fromMs), b = DateTime.fromMillisecondsSinceEpoch(toMs);
  final en = L10n.current == AppLang.en;
  if (a.year == b.year && a.month == b.month) {
    if (a.day == b.day) return longDate(a.day, a.month, a.year);
    return en ? '${monthName(a.month)} ${a.day}–${b.day}, ${a.year}' : '${a.day}–${b.day} ${monthName(a.month)} ${a.year}';
  }
  return a.year == b.year
      ? '${dayMonth(a.day, a.month)} – ${dayMonth(b.day, b.month)}${en ? ',' : ''} ${a.year}'
      : '${longDate(a.day, a.month, a.year)} – ${longDate(b.day, b.month, b.year)}';
}

void _panel(Canvas c, PosterOptions o, List<MultiRoute> routes) {
  const x = 64.0, w = 500.0;
  var y = 64.0;
  final title = o.title.trim().isEmpty ? t('Маршруты') : o.title.trim();
  y += drawText(c, title, Offset(x, y), headingStyle(title.length > 20 ? 38 : 46, weight: 800), maxWidth: w, maxLines: 3).height + 12;
  if (o.showRegion && o.region.trim().isNotEmpty) {
    y += drawText(c, '📍 ${o.region.trim()}', Offset(x, y), bodyStyle(30, weight: 500, color: const Color(0xFFE8F5E9)), maxWidth: w, maxLines: 1).height + 6;
  }
  if (o.dateTime) {
    final first = routes.map((r) => r.pts.first.tsMs).reduce(math.min);
    final last = routes.map((r) => r.pts.last.tsMs).reduce(math.max);
    y += drawText(c, _dateRange(first, last), Offset(x, y), bodyStyle(25, color: const Color(0xFFCFD8DC)), maxWidth: w, maxLines: 1).height;
  }
  y += 22;

  // Totals.
  var dist = 0.0, moving = 0, gain = 0.0;
  for (final r in routes) {
    final st = computeStats(r.pts, movingSpeedMs: profileOf(r.mode).movingSpeedMs);
    dist += st.distanceMeters;
    moving += st.movingSeconds;
    gain += (r.altitudeFused ? elevationOfFused(r.altitude) : elevationOf(r.pts, r.altitude)).gain;
  }
  final cells = [
    (Units.dist(dist, digits: 1), t('всего')),
    (_hms(moving), t('в движении')),
    ('+${Units.height(gain)}', t('набор высоты')),
    ('${routes.length}', routes.length == 1 ? t('маршрут') : (routes.length < 5 ? t('маршрута') : t('маршрутов'))),
  ];
  const tw = 240.0, th = 112.0;
  for (var i = 0; i < cells.length; i++) {
    final tx = x + (i % 2) * (tw + 20), ty = y + (i ~/ 2) * (th + 16);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(tx, ty, tw, th), const Radius.circular(18));
    c.drawRRect(r, Paint()..color = const Color(0x16FFFFFF));
    c.drawRRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x33FFFFFF));
    drawText(c, cells[i].$1, Offset(tx + 18, ty + 16), headingStyle(32, weight: 700), maxWidth: tw - 28, maxLines: 1);
    drawText(c, cells[i].$2, Offset(tx + 18, ty + 66), bodyStyle(22, color: const Color(0xFFB0BEC5)));
  }
  y += 2 * (th + 16) + 8;

  // The routes with their numbers.
  drawText(c, t('МАРШРУТЫ'), Offset(x, y), headingStyle(18, weight: 600, color: const Color(0xFFFFD54F)));
  y += 30;
  const bottomLimit = 1040.0;
  for (var r = 0; r < routes.length; r++) {
    if (y > bottomLimit) {
      drawText(c, t('… и ещё {p0}', {'p0': routes.length - r}), Offset(x + 40, y), bodyStyle(20, color: const Color(0xFFB0BEC5)));
      break;
    }
    final st = computeStats(routes[r].pts, movingSpeedMs: profileOf(routes[r].mode).movingSpeedMs);
    c.drawCircle(Offset(x + 15, y + 15), 15, Paint()..color = multiColors[r % multiColors.length]);
    final label = '${r + 1}';
    final ns = bodyStyle(19, weight: 700, color: const Color(0xFF101010));
    drawText(c, label, Offset(x + 15 - textWidth(label, ns) / 2, y + 4), ns);
    drawText(c, routes[r].name, Offset(x + 42, y + 2), bodyStyle(23, weight: 500), maxWidth: 300, maxLines: 1);
    final km = Units.dist(st.distanceMeters, digits: 1);
    final style = bodyStyle(23, weight: 600, color: const Color(0xFFCFD8DC));
    drawText(c, km, Offset(x + w - textWidth(km, style), y + 2), style);
    y += 34;
  }

  const fy = 1090.0;
  drawTropaLogo(c, const Offset(x, fy), 70);
  drawTropaWordmark(c, Rect.fromLTWH(x + 84, fy + 2, 140, 46));
  drawText(c, t('офлайн-трекер маршрутов'), const Offset(x + 86, fy + 48), bodyStyle(20, color: const Color(0xFF90A4AE)));
}
