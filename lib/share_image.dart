import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'altitude.dart';
import 'db.dart';
import 'heal.dart';
import 'modes.dart';
import 'settings.dart';
import 'stats.dart';

/// What to show on the picture for social networks. Each item is a checkbox in the dialog.
class ShareOptions {
  bool distance = true;
  bool time = true;
  bool speed = true;
  bool elevation = true;
  bool modeIcons = true;
  bool showRestored = false; // false: restored gaps look like the rest of the route

  ShareOptions();
}

const double _w = 1080, _h = 1920;

String _hm(int s) {
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two((s ~/ 60) % 60)}:${two(s % 60)}' : '${(s ~/ 60)}:${two(s % 60)}';
}

String _emoji(int a) => a == 0 ? '🚶' : (a == 1 ? '🚴' : '🚗');

/// 0 walking, 1 cycling, 2 driving - judged from the median speed over a short window.
List<int> _activities(List<TrackPoint> pts) {
  final out = List<int>.filled(pts.length, 0);
  for (var i = 0; i < pts.length; i++) {
    final from = math.max(1, i - 6), to = math.min(pts.length - 1, i + 6);
    final v = <double>[];
    for (var j = from; j <= to; j++) {
      final dt = (pts[j].tsMs - pts[j - 1].tsMs) / 1000.0;
      if (dt > 0 && dt <= 30) v.add(haversine(pts[j - 1].lat, pts[j - 1].lon, pts[j].lat, pts[j].lon) / dt);
    }
    if (v.isEmpty) {
      out[i] = i > 0 ? out[i - 1] : 0;
      continue;
    }
    v.sort();
    final m = v[v.length ~/ 2];
    out[i] = m < 2.4 ? 0 : (m < 8.5 ? 1 : 2);
  }
  return out;
}

void _text(Canvas c, String text, Offset at, double size,
    {FontWeight weight = FontWeight.w600, Color color = const Color(0xFFFFFFFF), double? maxWidth, TextAlign align = TextAlign.left}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: TextStyle(fontSize: size, fontWeight: weight, color: color, height: 1.15)),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(maxWidth: maxWidth ?? _w);
  tp.paint(c, at);
}

/// Builds the 1080x1920 picture. With [mapPng] (a snapshot of the live map) the map is the background;
/// otherwise the route is drawn on a plain gradient.
Future<Uint8List> composeShareImage({
  required String title,
  required List<TrackPoint> pts,
  required TravelMode mode,
  required ShareOptions o,
  Uint8List? mapPng,
  Rect? mapRect, // part of [mapPng] that holds the map (the rest is app chrome); whole image if null
}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, const Rect.fromLTWH(0, 0, _w, _h));

  // --- background
  if (mapPng != null) {
    final codec = await ui.instantiateImageCodec(mapPng);
    final img = (await codec.getNextFrame()).image;
    final src = mapRect ?? Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    // "Cover" fit: the map area fills the 9:16 picture, the overflow is cropped from the source.
    final scale = math.max(_w / src.width, _h / src.height);
    final cropW = _w / scale, cropH = _h / scale;
    final srcCrop = Rect.fromLTWH(
      src.left + (src.width - cropW) / 2,
      src.top + (src.height - cropH) / 2,
      cropW,
      cropH,
    );
    c.drawImageRect(img, srcCrop, const Rect.fromLTWH(0, 0, _w, _h), Paint()..filterQuality = FilterQuality.high);
  } else {
    c.drawRect(
      const Rect.fromLTWH(0, 0, _w, _h),
      Paint()
        ..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(_w, _h), const [Color(0xFF0E3B2B), Color(0xFF0A1F2E)]),
    );
    _drawOwnRoute(c, pts, mode, o);
  }

  // --- scrims for readable text
  c.drawRect(
    const Rect.fromLTWH(0, 0, _w, 330),
    Paint()..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 330), const [Color(0xCC000000), Color(0x00000000)]),
  );
  c.drawRect(
    const Rect.fromLTWH(0, _h - 900, _w, 900),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, _h - 900),
        const Offset(0, _h),
        const [Color(0x00000000), Color(0xB0000000), Color(0xF2000000)],
        const [0.0, 0.4, 1.0],
      ),
  );

  // --- texts
  final st = computeStats(pts, movingSpeedMs: profileOf(mode).movingSpeedMs);
  _text(c, title, const Offset(64, 70), 64, weight: FontWeight.w800, maxWidth: _w - 128);
  if (o.modeIcons) {
    _text(c, '${_emoji(mode == TravelMode.car ? 2 : (mode == TravelMode.bike ? 1 : 0))}  ${mode.label}', const Offset(64, 160), 44,
        weight: FontWeight.w500, color: const Color(0xFFE0E0E0));
  }

  // Stack the statistics upwards from the bottom edge so that none of them is cut off.
  final shown = [
    o.distance,
    o.time,
    o.speed && st.avgMovingSpeedMs > 0,
    o.elevation,
  ].where((v) => v).length;
  var y = _h - 150.0 - shown * 190.0;
  void big(String value, String label) {
    _text(c, value, Offset(64, y), 120, weight: FontWeight.w800);
    _text(c, label, Offset(64, y + 128), 38, weight: FontWeight.w500, color: const Color(0xFFCFD8DC));
    y += 190;
  }

  if (o.distance) big('${(st.distanceMeters / 1000).toStringAsFixed(2)} км', 'дистанция');
  if (o.time) big(_hm(st.movingSeconds), 'в движении');
  if (o.speed && st.avgMovingSpeedMs > 0) {
    final pace = st.paceMinPerKm;
    final paceText = (pace != null && mode != TravelMode.car && pace < 60)
        ? '${pace.floor()}:${((pace - pace.floor()) * 60).round().toString().padLeft(2, '0')} мин/км'
        : '${(st.avgMovingSpeedMs * 3.6).toStringAsFixed(1)} км/ч';
    big(paceText, mode == TravelMode.car || mode == TravelMode.bike ? 'средняя скорость' : 'средний темп');
  }
  if (o.elevation) {
    final alt = fusedAltitude(pts);
    if (alt.isNotEmpty) {
      final es = elevationStats(alt);
      big('+${es.gain.round()} м', 'набор высоты');
    }
  }
  _text(c, 'Tropa', const Offset(_w - 220, _h - 90), 40, weight: FontWeight.w700, color: const Color(0xCCFFFFFF));

  final pic = rec.endRecording();
  final image = await pic.toImage(_w.toInt(), _h.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void _drawOwnRoute(Canvas c, List<TrackPoint> pts, TravelMode mode, ShareOptions o) {
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
  const areaTop = 360.0, areaBottom = _h - 800, pad = 90.0;
  final scale = math.min((_w - 2 * pad) / w, (areaBottom - areaTop) / h);
  final ox = (_w - w * scale) / 2, oy = areaTop + ((areaBottom - areaTop) - h * scale) / 2;
  Offset pos(double lat, double lon) => Offset(ox + (lon - minLon) * kx * scale, oy + (maxLat - lat) * scale);

  final result = analyzeGaps(pts, settings: AppSettings.instance.healFor(mode));
  final line = Paint()
    ..color = const Color(0xFFFF7043)
    ..strokeWidth = 12
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  final restored = Paint()
    ..color = o.showRestored ? const Color(0xFFFFCA28) : const Color(0xFFFF7043)
    ..strokeWidth = 12
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  final faint = Paint()
    ..color = const Color(0x55FF7043)
    ..strokeWidth = 4
    ..style = PaintingStyle.stroke;

  for (var i = 1; i < pts.length; i++) {
    final a = pos(pts[i - 1].lat, pts[i - 1].lon), b = pos(pts[i].lat, pts[i].lon);
    final gap = result.gapAt(i);
    if (gap == null || gap.kind == GapKind.glueStill) {
      c.drawLine(a, b, line);
    } else if (gap.kind == GapKind.bridge) {
      var prev = a;
      for (final q in gap.curve) {
        final next = pos(q.lat, q.lon);
        c.drawLine(prev, next, restored);
        prev = next;
      }
      c.drawLine(prev, b, restored);
    } else {
      c.drawLine(a, b, faint);
    }
  }
  c.drawCircle(pos(pts.first.lat, pts.first.lon), 20, Paint()..color = const Color(0xFF66BB6A));
  c.drawCircle(pos(pts.last.lat, pts.last.lon), 20, Paint()..color = const Color(0xFFEF5350));

  if (o.modeIcons && mode == TravelMode.mixed) {
    // Icons where the kind of movement changes (a run of at least 10 points).
    final act = _activities(pts);
    var runStart = 0;
    for (var i = 1; i <= pts.length; i++) {
      if (i == pts.length || act[i] != act[runStart]) {
        if (i - runStart >= 10 && (runStart == 0 || act[runStart] != act[math.max(0, runStart - 1)])) {
          final at = pos(pts[runStart].lat, pts[runStart].lon);
          _text(c, _emoji(act[runStart]), at.translate(-26, -70), 52);
        }
        runStart = i;
      }
    }
  }
}

Future<File> writeShareImage(Uint8List png, String name) async {
  final dir = await getTemporaryDirectory();
  final f = File(p.join(dir.path, '$name.png'));
  return f.writeAsBytes(png);
}
