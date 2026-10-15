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
import 'segments.dart';
import 'stats.dart';
import 'weather.dart';
import 'l10n.dart';
import 'units.dart';

/// Size of the horizontal poster in points; drawn at [scale] (2 gives 3600x2400 pixels).
const double wideW = 1800, wideH = 1200;

/// Where the map (or the drawn route) sits on the horizontal poster, and the elevation profile below it.
const Rect wideMapRect = Rect.fromLTWH(600, 64, 1136, 716);
const Rect wideChartRect = Rect.fromLTWH(600, 810, 1136, 326);
const Rect wideRouteArea = Rect.fromLTWH(660, 124, 1016, 596);

const Color _gold = Color(0xFFFFD54F);

/// The "pro map": a landscape sheet with the route and numbered notes on the map, a panel with the
/// statistics, weather and the list of notes, and an elevation profile along the whole walk.
Future<Uint8List> composeWidePoster({
  required PosterOptions o,
  required List<TrackPoint> pts,
  required List<TrackSegment> segments,
  required TravelMode mode,
  WeatherInfo? weather,
  MapCapture? map,
  List<TrackNote> notes = const [],
  Map<String, ui.Image> noteThumbs = const {},
  List<double>? altitude,
  bool altitudeFused = false,
  int scale = 2,
}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, wideW * scale, wideH * scale));
  c.scale(scale.toDouble());
  final useMap = o.background == PosterBackground.map && map != null;

  _background(c);
  if (map != null && o.background == PosterBackground.map) await _blurredBackdrop(c, map, o.darkMap);

  final alt = altitude ?? fusedAltitude(pts);
  final speeds = smoothedSpeeds(pts);
  final modeAt = List<TravelMode>.filled(pts.length, mode == TravelMode.mixed ? TravelMode.walk : mode);
  for (final s in segments) {
    for (var i = s.startIdx; i <= s.endIdx && i < pts.length; i++) {
      modeAt[i] = s.mode;
    }
  }
  final (i0, i1) = posterShownRange(pts, o.hideEnds);
  final colorScale = buildLineScale(o, mode, pts, i0, i1, modeAt, speeds, alt);
  final st = computeStats(pts, movingSpeedMs: profileOf(mode).movingSpeedMs);

  // --- the map frame
  final frame = RRect.fromRectAndRadius(wideMapRect, const Radius.circular(24));
  c.save();
  c.clipRRect(frame);
  if (useMap) {
    final img = (await (await ui.instantiateImageCodec(map.png)).getNextFrame()).image;
    c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), const Rect.fromLTWH(0, 0, wideW, wideH),
        Paint()
          ..filterQuality = FilterQuality.high
          ..colorFilter = mapToneFilter(o.darkMap));
  } else {
    c.drawRect(wideMapRect, Paint()..color = const Color(0xFF0C2924));
    _contours(c, wideMapRect);
  }
  final proj = useMap ? mapProjection(map, wideW) : fitProjection(pts, i0, i1, wideRouteArea);
  drawPosterRoute(c, o, pts, i0, i1, mode, colorScale, speeds, proj, useMap && !o.darkMap, lineScale: 0.72);
  drawPosterPeaks(c, o, pts, i0, i1, speeds, alt, proj, st.maxSpeedMs * 3.6, bounds: wideMapRect.deflate(14));
  if (o.notes) drawNoteMarkers(c, notes, proj, labels: false, bounds: wideMapRect.deflate(14), scale: 0.9, thumbs: noteThumbs);
  drawDistanceScale(c, proj, pts[pts.length ~/ 2], Offset(wideMapRect.left + 36, wideMapRect.bottom - 36), light: useMap && !o.darkMap, maxLen: 190);
  if (colorScale.coloring != LineColoring.single) {
    // The colour scale sits on a dark plate in the corner of the map, so it reads on any map.
    final extra = colorScale.coloring == LineColoring.speed && colorScale.split ? 26.0 : 0.0;
    final plate = Rect.fromLTWH(1736 - 366, 64 + 716 - 112 - extra, 330, 84 + extra);
    c.drawRRect(RRect.fromRectAndRadius(plate, const Radius.circular(16)), Paint()..color = const Color(0xB3000000));
    final heading = switch (colorScale.coloring) {
      LineColoring.speed => t('СКОРОСТЬ'),
      LineColoring.height => t('ВЫСОТА'),
      _ => t('УКЛОН'),
    };
    drawText(c, heading, Offset(plate.left + 16, plate.top + 8), headingStyle(14, weight: 600, color: _gold));
    drawColorScale(c, colorScale, Rect.fromLTWH(plate.left + 16, plate.top + 34, plate.width - 32, 12), labelSize: 20);
  }
  if (useMap) {
    const note = '© OpenStreetMap · Protomaps';
    final style = bodyStyle(18, color: const Color(0xCCFFFFFF));
    drawText(c, note, Offset(wideMapRect.right - 16 - textWidth(note, style), wideMapRect.bottom - 30), style);
  }
  c.restore();
  _frame(c, wideMapRect);

  // --- the elevation profile
  _chart(c, o, pts, i0, i1, alt, modeAt, speeds, notes, colorScale);

  // --- the left panel
  _panel(c, o, pts, segments, mode, st, alt, altitudeFused, weather, notes);

  // --- decoration: gold corners around the sheet
  _corners(c);

  final pic = rec.endRecording();
  final image = await pic.toImage((wideW * scale).toInt(), (wideH * scale).toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

// ====================================================================== decoration

void _background(Canvas c) {
  c.drawRect(
    const Rect.fromLTWH(0, 0, wideW, wideH),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(wideW, wideH), const [Color(0xFF0A1B20), Color(0xFF0F2F27)]),
  );
  _contours(c, const Rect.fromLTWH(0, 0, wideW, wideH));
}

void _contours(Canvas c, Rect clip) {
  c.save();
  c.clipRect(clip);
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final cx = clip.left + clip.width * 0.72, cy = clip.top + clip.height * 0.30;
  for (var r = 1; r <= 18; r++) {
    final path = Path();
    for (var a = 0; a <= 360; a += 6) {
      final t = a * math.pi / 180;
      final wob = 1 + 0.12 * math.sin(3 * t + r * 0.45) + 0.07 * math.sin(5 * t - r * 0.3);
      final rad = r * 58.0 * wob;
      final pt = Offset(cx + rad * math.cos(t), cy + rad * 0.78 * math.sin(t));
      a == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    c.drawPath(path, line..color = Color.fromARGB(r % 4 == 0 ? 40 : 20, 255, 255, 255));
  }
  c.restore();
}

/// Thin gold frame with a darker inner edge: a map "plate".
void _frame(Canvas c, Rect r) {
  final rr = RRect.fromRectAndRadius(r, const Radius.circular(24));
  c.drawRRect(rr, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..color = _gold.withAlpha(200));
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
    ..color = _gold;
  const m = 20.0, l = 54.0;
  for (final (x, y, dx, dy) in const [(m, m, 1.0, 1.0), (wideW - m, m, -1.0, 1.0), (m, wideH - m, 1.0, -1.0), (wideW - m, wideH - m, -1.0, -1.0)]) {
    c.drawLine(Offset(x, y), Offset(x + dx * l, y), p);
    c.drawLine(Offset(x, y), Offset(x, y + dy * l), p);
  }
}

// ====================================================================== elevation profile

void _chart(Canvas c, PosterOptions o, List<TrackPoint> pts, int i0, int i1, List<double> alt, List<TravelMode> modeAt,
    List<double> speeds, List<TrackNote> notes, LineScale scale) {
  final box = RRect.fromRectAndRadius(wideChartRect, const Radius.circular(24));
  c.drawRRect(box, Paint()..color = const Color(0x22000000));
  _frame(c, wideChartRect);
  drawText(c, t('ПРОФИЛЬ ВЫСОТЫ'), Offset(wideChartRect.left + 28, wideChartRect.top + 18), headingStyle(18, weight: 600, color: _gold));

  if (i1 <= i0) return;
  // Distance along the walk (km); holes in the recording add no distance.
  final dist = List<double>.filled(pts.length, 0);
  for (var i = i0 + 1; i <= i1; i++) {
    final dt = pts[i].tsMs - pts[i - 1].tsMs;
    final d = haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    dist[i] = dist[i - 1] + (dt <= 30000 && d / math.max(dt / 1000, 1) < 100 ? d : 0);
  }
  final total = dist[i1];
  if (total < 50) return;
  var lo = alt[i0], hi = alt[i0];
  for (var i = i0; i <= i1; i++) {
    lo = math.min(lo, alt[i]);
    hi = math.max(hi, alt[i]);
  }
  if (hi - lo < 20) {
    final mid = (hi + lo) / 2;
    lo = mid - 10;
    hi = mid + 10;
  }
  // Round numbers on the vertical axis: the range is stretched to multiples of a "nice" step.
  final step = [10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 500.0].firstWhere((v) => (hi - lo) / v <= 6, orElse: () => 1000.0);
  final pad = (hi - lo) * 0.06;
  lo -= pad;
  hi += pad * 2;

  final plot = Rect.fromLTRB(wideChartRect.left + 84, wideChartRect.top + 58, wideChartRect.right - 34, wideChartRect.bottom - 52);
  double xOf(int i) => plot.left + dist[i] / total * plot.width;
  double yOf(double a) => plot.bottom - (a - lo) / (hi - lo) * plot.height;

  // Grid and labels.
  final grid = Paint()
    ..color = const Color(0x22FFFFFF)
    ..strokeWidth = 1.5;
  final label = bodyStyle(20, color: const Color(0xFFB0BEC5));
  for (var a = (lo / step).ceil() * step; a <= hi + 0.001; a += step) {
    final y = yOf(a);
    c.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    final tick = Units.height(a);
    drawText(c, tick, Offset(plot.left - 12 - textWidth(tick, label), y - 12), label);
  }
  final unitM = Units.imperial ? 1609.344 : 1000.0;
  final totalKm = total / unitM;
  final kmStep = [0.5, 1.0, 2.0, 5.0, 10.0, 20.0].firstWhere((s) => totalKm / s <= 9, orElse: () => 50.0);
  for (var k = 0.0; k <= totalKm + 0.001; k += kmStep) {
    final x = plot.left + k * unitM / total * plot.width;
    c.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 8), grid..strokeWidth = 2);
    final t = k == k.roundToDouble() ? '${k.round()}' : k.toStringAsFixed(1);
    drawText(c, t, Offset(x - textWidth(t, label) / 2, plot.bottom + 12), label);
  }
  drawText(c, Units.kmUnit, Offset(plot.right - 28, plot.bottom + 12), label);

  // Filled area under the profile.
  final area = Path()..moveTo(xOf(i0), plot.bottom);
  for (var i = i0; i <= i1; i++) {
    area.lineTo(xOf(i), yOf(alt[i]));
  }
  area.lineTo(xOf(i1), plot.bottom);
  area.close();
  c.drawPath(
    area,
    Paint()..shader = ui.Gradient.linear(Offset(0, plot.top), Offset(0, plot.bottom), const [Color(0x55FFFFFF), Color(0x05FFFFFF)]),
  );

  // The profile line, coloured like the route.
  final colorAt = scale.colorAt;
  final line = Paint()
    ..strokeWidth = 5
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  for (var i = i0 + 1; i <= i1; i++) {
    c.drawLine(Offset(xOf(i - 1), yOf(alt[i - 1])), Offset(xOf(i), yOf(alt[i])), line..color = colorAt(i));
  }

  // Highest point.
  var top = i0;
  for (var i = i0; i <= i1; i++) {
    if (alt[i] > alt[top]) top = i;
  }
  if (alt[top] - lo > 25) {
    final at = Offset(xOf(top), yOf(alt[top]));
    c.drawCircle(at, 9, Paint()..color = const Color(0xFFFFFFFF));
    final tag = '▲ ${Units.height(alt[top])}';
    final style = bodyStyle(22, weight: 600, color: const Color(0xFF101010));
    final w = textWidth(tag, style) + 24;
    final x = (at.dx - w / 2).clamp(plot.left, plot.right - w);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, at.dy - 52, w, 36), const Radius.circular(18));
    c.drawRRect(r, Paint()..color = const Color(0xFFFFFFFF));
    drawText(c, tag, Offset(x + 12, at.dy - 47), style);
  }

  // Notes: a numbered marker above the profile at the place where the note was made.
  if (o.notes) {
    var n = 0;
    for (final note in notes) {
      n++;
      var best = i0;
      var bestD = double.infinity;
      for (var i = i0; i <= i1; i++) {
        final d = haversine(pts[i].lat, pts[i].lon, note.lat, note.lon);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      final at = Offset(xOf(best), yOf(alt[best]));
      c.drawLine(at, Offset(at.dx, plot.bottom), Paint()
        ..color = const Color(0x88AB47BC)
        ..strokeWidth = 2);
      c.drawCircle(at, 17, Paint()..color = const Color(0xFFFFFFFF));
      c.drawCircle(at, 14, Paint()..color = const Color(0xFFAB47BC));
      final num = '$n';
      final ns = bodyStyle(19, weight: 700);
      drawText(c, num, at.translate(-textWidth(num, ns) / 2, -11), ns);
    }
  }
}

// ====================================================================== left panel

void _panel(Canvas c, PosterOptions o, List<TrackPoint> pts, List<TrackSegment> segments, TravelMode mode, TrackStats st,
    List<double> alt, bool altFused, WeatherInfo? weather, List<TrackNote> notes) {
  const x = 64.0, w = 500.0;
  var y = 64.0;

  final title = o.title.trim().isEmpty ? t('Прогулка') : o.title.trim();
  y += drawText(c, title, Offset(x, y), headingStyle(title.length > 20 ? 38 : 46, weight: 800), maxWidth: w, maxLines: 3).height + 12;
  if (o.showRegion && o.region.trim().isNotEmpty) {
    y += drawText(c, '📍 ${o.region.trim()}', Offset(x, y), bodyStyle(30, weight: 500, color: const Color(0xFFE8F5E9)), maxWidth: w, maxLines: 1).height + 6;
  }
  if (o.dateTime) {
    final offset = weather?.utcOffsetSec ?? DateTime.fromMillisecondsSinceEpoch(pts.first.tsMs).timeZoneOffset.inSeconds;
    y += drawText(c, posterDateLine(pts.first.tsMs, pts.last.tsMs, offset), Offset(x, y), bodyStyle(25, color: const Color(0xFFCFD8DC)),
            maxWidth: w, maxLines: 1)
        .height;
  }
  y += 22;

  // Weather card.
  final hasWater = mode == TravelMode.water || segments.any((s) => s.mode == TravelMode.water);
  final water = o.waterTempManual ?? weather?.seaTemp;
  if (o.weather && weather != null) {
    final (emoji, text) = weather.condition;
    final card = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, 128), const Radius.circular(20));
    c.drawRRect(card, Paint()..color = const Color(0x16FFFFFF));
    c.drawRRect(card, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x33FFFFFF));
    drawText(c, emoji, Offset(x + 20, y + 26), bodyStyle(58));
    drawText(c, Units.temp(weather.tempAvg), Offset(x + 112, y + 18), headingStyle(44, weight: 700));
    drawText(c, text, Offset(x + 112, y + 74), bodyStyle(24, weight: 500, color: const Color(0xFFE0E0E0)), maxWidth: 190, maxLines: 1);
    final rain = weather.precipMm >= 0.2 ? t('осадки {p}', {'p': Units.precip(weather.precipMm)}) : t('без осадков');
    drawText(c, t('ощущается {a}\nветер {b}\n{c}', {'a': Units.temp(weather.feelsAvg), 'b': Units.speed(weather.windKmh / 3.6, digits: 0), 'c': rain}), Offset(x + 300, y + 18),
        bodyStyle(22, color: const Color(0xFFCFD8DC)), maxWidth: 190);
    y += 128 + 14;
  }
  if (o.waterTemp && hasWater && water != null) {
    drawText(c, t('🌊 вода {p}', {'p': Units.temp(water, digits: water == water.roundToDouble() ? 0 : 1)}), Offset(x + 6, y), bodyStyle(28, weight: 500));
    y += 42;
  }

  // Statistic tiles.
  final cells = <(String, String)>[];
  if (o.distance) cells.add((Units.dist(st.distanceMeters), t('дистанция')));
  if (o.time) cells.add((_hms(st.movingSeconds), t('в движении')));
  cells.add(('+${Units.height((altFused ? elevationOfFused(alt) : elevationOf(pts, alt)).gain)}', t('набор высоты')));
  if (o.speed && st.avgMovingSpeedMs > 0) {
    final single = segments.map((s) => s.mode).toSet().length <= 1;
    if (single) {
      cells.add((Units.speed(st.avgMovingSpeedMs), t('средняя скорость')));
    } else if (st.maxSpeedMs > 0) {
      cells.add((Units.speed(st.maxSpeedMs, digits: 0), t('макс. скорость')));
    }
  }
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
  y += (cells.length / 2).ceil() * (th + 16) + 6;

  // Ways of travelling.
  if (o.legend) {
    final byMode = <TravelMode, ({double d, int t})>{};
    for (final s in segments) {
      final prev = byMode[s.mode];
      byMode[s.mode] = (d: (prev?.d ?? 0) + s.stats.distanceMeters, t: (prev?.t ?? 0) + s.stats.movingSeconds);
    }
    for (final e in byMode.entries.where((e) => e.value.d > 50).take(3)) {
      final swatch = Paint()..color = const Color(0xFF90A4AE);
      if (e.key == TravelMode.car) {
        for (var k = 0; k < 2; k++) {
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 2 + k * 13, y + 11, 7, 12), const Radius.circular(3)), swatch);
        }
      } else {
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 2, y + 7, 20, 20), const Radius.circular(10)), swatch);
      }
      final v = e.value.t > 0 ? e.value.d / e.value.t : 0.0;
      final detail = v > 0 ? ' · ${Units.speed(v)}' : '';
      drawText(c, '${t(e.key.label)} · ${Units.dist(e.value.d, digits: 1)}$detail', Offset(x + 34, y), bodyStyle(24, weight: 500),
          maxWidth: w - 34, maxLines: 1);
      y += 36;
    }
    y += 10;
  }

  // Notes.
  const bottomLimit = 1040.0;
  if (o.notes && notes.isNotEmpty && y < bottomLimit - 60) {
    drawText(c, t('ЗАМЕТКИ'), Offset(x, y), headingStyle(18, weight: 600, color: _gold));
    y += 30;
    var n = 0;
    for (final note in notes) {
      n++;
      if (y > bottomLimit) {
        drawText(c, t('… и ещё {p0}', {'p0': notes.length - n + 1}), Offset(x + 36, y), bodyStyle(20, color: const Color(0xFFB0BEC5)));
        break;
      }
      c.drawCircle(Offset(x + 14, y + 14), 14, Paint()..color = const Color(0xFFAB47BC));
      final num = '$n';
      final ns = bodyStyle(18, weight: 700);
      drawText(c, num, Offset(x + 14 - textWidth(num, ns) / 2, y + 4), ns);
      final icon = note.mediaType == 'video' ? '🎬 ' : (note.mediaType == 'photo' ? '📷 ' : '');
      final text = note.text.trim().isEmpty ? (note.mediaType == 'video' ? t('видео') : t('фото')) : note.text.trim();
      final size = drawText(c, '$icon$text', Offset(x + 38, y + 1), bodyStyle(22, weight: 500), maxWidth: w - 40, maxLines: 2);
      y += math.max(32, size.height + 8);
    }
  }

  // Footer.
  const fy = 1090.0;
  drawTropaLogo(c, const Offset(x, fy), 70);
  drawText(c, 'Tropa', const Offset(x + 84, fy + 6), headingStyle(36, weight: 700));
  drawText(c, t('офлайн-трекер маршрутов'), const Offset(x + 86, fy + 48), bodyStyle(20, color: const Color(0xFF90A4AE)));
}

String _hms(int s) {
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two((s ~/ 60) % 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

/// The map, strongly blurred and darkened, over the whole sheet: the sharp map in its frame then sits on a
/// backdrop of the same place, and the texts on the panel stay readable.
Future<void> _blurredBackdrop(Canvas c, MapCapture map, bool dark) async {
  final img = (await (await ui.instantiateImageCodec(map.png)).getNextFrame()).image;
  const full = Rect.fromLTWH(0, 0, wideW, wideH);
  c.saveLayer(full, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14));
  c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), full, Paint()..filterQuality = FilterQuality.medium);
  c.restore();
  c.drawRect(full, Paint()..color = Color(dark ? 0xCC0A1B20 : 0xD90A1B20));
}
