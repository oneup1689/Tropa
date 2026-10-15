import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'altitude.dart';
import 'brand.dart';
import 'db.dart';
import 'elevation.dart';
import 'heal.dart';
import 'modes.dart';
import 'segments.dart';
import 'settings.dart';
import 'stats.dart';
import 'trim.dart';
import 'poster_scale.dart';
export 'poster_scale.dart' show LineColoring, LineScale, slopeAvailable;
import 'weather.dart';
import 'l10n.dart';
import 'units.dart';

enum PosterBackground { tropa, map }

/// Vertical: for stories and reels. Horizontal: the "pro map" sheet with notes and an elevation profile.
enum PosterFormat { vertical, horizontal }


/// What goes onto the poster. Every item is a checkbox or a choice in the poster screen.
class PosterOptions {
  String title = '';
  String region = '';
  PosterFormat format = PosterFormat.vertical;
  PosterBackground background = PosterBackground.tropa;
  bool darkMap = true; // the map is always the dark, toned-down one; the field stays for the code that draws it
  LineColoring coloring = LineColoring.single;

  bool distance = true;
  bool time = true;
  bool speed = true;
  bool elevation = true;
  bool dateTime = true;
  bool showRegion = true;
  bool weather = true;
  bool waterTemp = true;
  bool peaks = true; // labels at the fastest point and the highest point
  bool legend = true; // list of the ways of travelling with distance and speed
  bool showRestored = false; // false: restored gaps look like the rest of the route
  bool notes = true; // numbered markers of the notes made during the walk
  bool profile = true; // small elevation profile under the statistics (vertical poster)

  /// Pro: no start/finish markers and the first and last [hideEndsMeters] of the line are not drawn.
  bool hideEnds = false;
  static const double hideEndsMeters = 150;

  /// Water temperature typed by hand (rivers and lakes have no data). Beats the sea temperature.
  double? waterTempManual;
}

/// Snapshot of the offline map with the camera it was taken with, so the route can be drawn on top
/// exactly where it belongs.
class MapCapture {
  final Uint8List png;
  final double centerLat;
  final double centerLon;

  /// Zoom of the 512-px world at the snapshot's own pixel size.
  final double zoom;
  final int widthPx;
  final int heightPx;

  const MapCapture(this.png, this.centerLat, this.centerLon, this.zoom, this.widthPx, this.heightPx);
}

const double posterW = 1080, posterH = 1920;

/// Area of the poster that is kept free for the route (the title is above, the statistics below).
const double routeTop = 400, routeBottom = 1130, routeSide = 90;

String _two(int n) => n.toString().padLeft(2, '0');

String _hms(int s) => s >= 3600 ? '${s ~/ 3600}:${_two((s ~/ 60) % 60)}:${_two(s % 60)}' : '${s ~/ 60}:${_two(s % 60)}';

/// "12 октября 2026 · 07:23–14:44", in the time of the place where the walk was (not the phone's zone).
String posterDateLine(int startMs, int endMs, int offsetSec) {
  DateTime local(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(Duration(seconds: offsetSec));
  final a = local(startMs), b = local(endMs);
  String hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
  final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
  if (sameDay) return '${longDate(a.day, a.month, a.year)} · ${hm(a)}–${hm(b)}';
  return '${dayMonth(a.day, a.month)} ${hm(a)} – ${dayMonth(b.day, b.month)} ${hm(b)}';
}

/// Builds the vertical poster for social networks. The picture is 1080x1920 "points" drawn at [scale]
/// (2 gives 2160x3840 pixels), so the text and the line stay sharp.
Future<Uint8List> composePoster({
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
  final c = Canvas(rec, Rect.fromLTWH(0, 0, posterW * scale, posterH * scale));
  c.scale(scale.toDouble());

  final useMap = o.background == PosterBackground.map && map != null;
  await _drawBackground(c, o, map: useMap ? map : null);

  // --- per-point attributes of the full track, then the part that is shown
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

  // --- projection of the track onto the poster
  final proj = useMap ? mapProjection(map) : fitProjection(pts, i0, i1);
  _drawScrims(c, o, useMap);

  drawPosterRoute(c, o, pts, i0, i1, mode, colorScale, speeds, proj, useMap && !o.darkMap);

  // --- text blocks
  final st = computeStats(pts, movingSpeedMs: profileOf(mode).movingSpeedMs);
  final endMs = pts.last.tsMs;
  final offset = weather?.utcOffsetSec ?? DateTime.fromMillisecondsSinceEpoch(pts.first.tsMs).timeZoneOffset.inSeconds;
  _drawHeader(c, o, pts.first.tsMs, endMs, offset);
  drawPosterPeaks(c, o, pts, i0, i1, speeds, alt, proj, st.maxSpeedMs * 3.6);
  drawDistanceScale(c, proj, pts[pts.length ~/ 2], const Offset(64, routeBottom - 6), light: useMap && !o.darkMap);
  if (o.notes) {
    drawNoteMarkers(c, notes, proj,
        labels: true, bounds: const Rect.fromLTRB(24, offsetTop, posterW - 24, routeBottom + 40), thumbs: noteThumbs);
  }
  _drawBottom(c, o, pts, segments, mode, st, alt, altitudeFused, weather, useMap, i0, i1, colorScale);

  final pic = rec.endRecording();
  final image = await pic.toImage((posterW * scale).toInt(), (posterH * scale).toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Index range of the points that are drawn: the whole track, or without the first and last
/// [PosterOptions.hideEndsMeters] when the start and the finish are hidden.
(int, int) posterShownRange(List<TrackPoint> pts, bool hideEnds) {
  if (!hideEnds) return (0, pts.length - 1);
  final cut = trimEnds(pts, PosterOptions.hideEndsMeters, PosterOptions.hideEndsMeters);
  if (cut.length < 2) return (0, pts.length - 1);
  final from = pts.indexWhere((e) => e.tsMs == cut.first.tsMs);
  return (from, from + cut.length - 1);
}

// ====================================================================== background

Future<void> _drawBackground(Canvas c, PosterOptions o, {MapCapture? map}) async {
  const full = Rect.fromLTWH(0, 0, posterW, posterH);
  if (map != null) {
    final img = (await (await ui.instantiateImageCodec(map.png)).getNextFrame()).image;
    c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), full,
        Paint()
          ..filterQuality = FilterQuality.high
          ..colorFilter = mapToneFilter(o.darkMap));
    return;
  }
  // The Tropa style: deep green gradient with faint contour lines, like a topographic map.
  c.drawRect(
    full,
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(posterW, posterH), const [Color(0xFF0E4D3A), Color(0xFF071C2C)]),
  );
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;
  for (final (cx, cy, rings) in const [(820.0, 380.0, 16), (180.0, 1500.0, 12)]) {
    for (var r = 1; r <= rings; r++) {
      final path = Path();
      for (var a = 0; a <= 360; a += 6) {
        final t = a * math.pi / 180;
        final wob = 1 + 0.12 * math.sin(3 * t + r * 0.45) + 0.07 * math.sin(5 * t - r * 0.3);
        final rad = r * 62.0 * wob;
        final pt = Offset(cx + rad * math.cos(t), cy + rad * 0.8 * math.sin(t));
        a == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      c.drawPath(path, line..color = Color.fromARGB(r % 4 == 0 ? 46 : 24, 255, 255, 255));
    }
  }
}

void _drawScrims(Canvas c, PosterOptions o, bool useMap) {
  // Dark bands behind the text so it stays readable on any map.
  final top = useMap && !o.darkMap ? const Color(0xB3FFFFFF) : const Color(0xB3000000);
  c.drawRect(
    const Rect.fromLTWH(0, 0, posterW, 360),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(0, 360), [top, top.withAlpha(0)]),
  );
  const bottomFrom = 1120.0;
  c.drawRect(
    const Rect.fromLTWH(0, bottomFrom, posterW, posterH - bottomFrom),
    Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, bottomFrom),
        const Offset(0, posterH),
        const [Color(0x00000000), Color(0xCC000000), Color(0xF2000000)],
        const [0.0, 0.25, 1.0],
      ),
  );
}

// ====================================================================== projection

typedef Projection = Offset Function(double lat, double lon);

/// Own drawing: the shown part of the track is fitted into the free band of the poster.
const Rect verticalRouteArea = Rect.fromLTRB(routeSide, routeTop, posterW - routeSide, routeBottom);

Projection fitProjection(List<TrackPoint> pts, int i0, int i1, [Rect area = verticalRouteArea]) {
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (var i = i0; i <= i1; i++) {
    minLat = math.min(minLat, pts[i].lat);
    maxLat = math.max(maxLat, pts[i].lat);
    minLon = math.min(minLon, pts[i].lon);
    maxLon = math.max(maxLon, pts[i].lon);
  }
  final kx = math.cos((minLat + maxLat) / 2 * math.pi / 180);
  final w = math.max((maxLon - minLon) * kx, 1e-6), h = math.max(maxLat - minLat, 1e-6);
  final aw = area.width, ah = area.height;
  final scale = math.min(aw / w, ah / h);
  final ox = area.left + (aw - w * scale) / 2, oy = area.top + (ah - h * scale) / 2;
  return (lat, lon) => Offset(ox + (lon - minLon) * kx * scale, oy + (maxLat - lat) * scale);
}

/// Map snapshot: Web Mercator with MapLibre's 512-px world tiles, relative to the snapshot's centre.
Projection mapProjection(MapCapture m, [double canvasW = posterW]) {
  final world = 512 * math.pow(2, m.zoom).toDouble();
  double x(double lon) => (lon + 180) / 360 * world;
  double y(double lat) {
    final s = math.sin(lat * math.pi / 180);
    return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * world;
  }

  final cx = x(m.centerLon), cy = y(m.centerLat);
  final k = canvasW / m.widthPx;
  return (lat, lon) => Offset((x(lon) - cx + m.widthPx / 2) * k, (y(lat) - cy + m.heightPx / 2) * k);
}

/// Camera for the map snapshot: centre and zoom (512-px world, snapshot pixel size [widthPx]) that put the
/// track into the route band of the poster. Used by the map screen before it takes the snapshot.
({double lat, double lon, double zoom})? posterCamera(List<TrackPoint> pts,
    {int widthPx = 1080, int i0 = 0, int? i1, Size canvas = const Size(posterW, posterH), Rect area = verticalRouteArea}) {
  final end = i1 ?? pts.length - 1;
  if (pts.length < 2 || end <= i0) return null;
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (var i = i0; i <= end; i++) {
    minLat = math.min(minLat, pts[i].lat);
    maxLat = math.max(maxLat, pts[i].lat);
    minLon = math.min(minLon, pts[i].lon);
    maxLon = math.max(maxLon, pts[i].lon);
  }
  // Work in poster points (1080 wide), then convert the zoom to the snapshot's pixel size.
  final aw = area.width, ah = area.height;
  double worldX(double lon, double z) => (lon + 180) / 360 * 512 * math.pow(2, z);
  double worldY(double lat, double z) {
    final s = math.sin(lat * math.pi / 180);
    return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * 512 * math.pow(2, z);
  }

  double lat(double yy, double z) {
    final n = math.pi - 2 * math.pi * yy / (512 * math.pow(2, z));
    return 180 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  }

  var z = 18.0;
  while (z > 3) {
    final w = (worldX(maxLon, z) - worldX(minLon, z)).abs();
    final h = (worldY(minLat, z) - worldY(maxLat, z)).abs();
    if (w <= aw && h <= ah) break;
    z -= 0.1;
  }
  final cx = (worldX(maxLon, z) + worldX(minLon, z)) / 2;
  final cy = (worldY(maxLat, z) + worldY(minLat, z)) / 2;
  // The route band is centred at y = routeTop..routeBottom, the picture centre is at posterH / 2.
  final shiftY = canvas.height / 2 - area.center.dy;
  final shiftX = canvas.width / 2 - area.center.dx;
  final camY = cy + shiftY;
  final camX = cx + shiftX;
  final zoomPx = z + math.log(widthPx / canvas.width) / math.ln2;
  return (lat: lat(camY, z), lon: camX / (512 * math.pow(2, z)) * 360 - 180, zoom: zoomPx);
}

// ====================================================================== route

void drawPosterRoute(Canvas c, PosterOptions o, List<TrackPoint> pts, int i0, int i1, TravelMode mode, LineScale scale,
    List<double> speeds, Projection proj, bool lightMap, {double lineScale = 1.0}) {
  if (i1 <= i0) return;
  final result = analyzeGaps(pts, settings: AppSettings.instance.healFor(mode));

  final colorAt = scale.colorAt;

  final halo = Paint()
    ..color = lightMap ? const Color(0xCCFFFFFF) : const Color(0x99000000)
    ..strokeWidth = 21 * lineScale
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  final faint = Paint()
    ..color = lightMap ? const Color(0x66000000) : const Color(0x66FFFFFF)
    ..strokeWidth = 4
    ..style = PaintingStyle.stroke;

  // Pieces of the line: (from, to, colour). A bridged gap uses a curve, a broken gap a faint line.
  // Where the walk goes back along itself, the two passes are moved apart so both stay visible.
  final sep = separatePasses(pts, i0, i1, proj, speeds, lineScale);
  final pieces = <(List<Offset>, Color?)>[];
  for (var i = i0 + 1; i <= i1; i++) {
    final a = sep.pos[i - i0 - 1], b = sep.pos[i - i0];
    final gap = result.gapAt(i);
    final col = colorAt(i);
    if (gap == null || gap.kind == GapKind.glueStill) {
      pieces.add(([a, b], col));
    } else if (gap.kind == GapKind.bridge) {
      pieces.add(([a, for (final q in gap.curve) proj(q.lat, q.lon), b], o.showRestored ? const Color(0xFFFFCA28) : col));
    } else {
      pieces.add(([a, b], null));
    }
  }
  for (final pc in pieces) {
    if (pc.$2 == null) {
      _dashed(c, pc.$1.first, pc.$1.last, faint);
    } else {
      c.drawPoints(ui.PointMode.polygon, pc.$1, halo);
    }
  }
  final paint = Paint()
    ..strokeWidth = 12 * lineScale
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  // Vehicle stretches (when the walk also has others) are dashed: the dash pattern runs on across pieces.
  var dashPhase = 0.0;
  for (var k = 0; k < pieces.length; k++) {
    final pc = pieces[k];
    if (pc.$2 == null) continue;
    if (scale.vehicleAt[i0 + 1 + k]) {
      dashPhase = _dashPolyline(c, pc.$1, paint..color = pc.$2!, dashPhase, on: 30.0 * lineScale, off: 20.0 * lineScale);
    } else {
      dashPhase = 0;
      c.drawPoints(ui.PointMode.polygon, pc.$1, paint..color = pc.$2!);
    }
  }

  _drawDirectionArrows(c, sep, lineScale, lightMap);

  if (!o.hideEnds) {
    // The finish is smaller and drawn last: on a loop both markers stay visible.
    _marker(c, proj(pts[i0].lat, pts[i0].lon), const Color(0xFF00E676), 29 * lineScale, 21 * lineScale);
    _marker(c, proj(pts[i1].lat, pts[i1].lon), const Color(0xFFFF1744), 20 * lineScale, 12 * lineScale);
  }
}

void _marker(Canvas c, Offset at, Color color, double outer, double inner) {
  c.drawCircle(at, outer, Paint()..color = const Color(0xFFFFFFFF));
  c.drawCircle(at, inner, Paint()..color = color);
}

/// Draws [pts] as dashes ([on] drawn, [off] skipped), starting [phase] units into the pattern; returns the phase at the end
/// so the next piece of the same stretch continues the pattern.
double _dashPolyline(Canvas c, List<Offset> pts, Paint paint, double phase, {required double on, required double off}) {
  final period = on + off;
  var p = phase % period; // position inside the dash pattern, always in [0, period)
  for (var k = 1; k < pts.length; k++) {
    final a = pts[k - 1], b = pts[k];
    final len = (b - a).distance;
    if (len == 0) continue;
    final dir = (b - a) / len;
    var d = 0.0;
    while (len - d > 1e-9) {
      final drawing = p < on;
      final remain = drawing ? on - p : period - p;
      if (remain < 1e-6) {
        // On the border of a dash: step over it explicitly (rounding must never leave the loop standing still).
        p = drawing ? on : 0;
        continue;
      }
      final step = math.min(remain, len - d);
      if (drawing) c.drawLine(a + dir * d, a + dir * (d + step), paint);
      d += step;
      p += step;
      if (p >= period) p -= period;
    }
  }
  return p;
}

void _dashed(Canvas c, Offset a, Offset b, Paint paint) {
  final len = (b - a).distance;
  if (len == 0) return;
  final dir = (b - a) / len;
  for (double d = 0; d < len; d += 16) {
    c.drawLine(a + dir * d, a + dir * math.min(d + 8, len), paint);
  }
}

/// Labels at the fastest point and at the highest point of the shown part.
void drawPosterPeaks(Canvas c, PosterOptions o, List<TrackPoint> pts, int i0, int i1, List<double> speeds, List<double> alt,
    Projection proj, double maxSpeedKmh, {Rect bounds = const Rect.fromLTRB(24, offsetTop, posterW - 24, routeBottom + 40)}) {
  if (!o.peaks || i1 <= i0) return;
  void pill(Offset at, String text, Color bg) {
    final style = bodyStyle(30, weight: 600, color: const Color(0xFF101010));
    final w = textWidth(text, style) + 36;
    var x = at.dx - w / 2;
    x = x.clamp(bounds.left, math.max(bounds.left, bounds.right - w));
    final y = (at.dy - 78).clamp(bounds.top, bounds.bottom);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, 50), const Radius.circular(25));
    c.drawRRect(r.shift(const Offset(0, 3)), Paint()..color = const Color(0x55000000));
    c.drawRRect(r, Paint()..color = bg);
    drawText(c, text, Offset(x + 18, y + 8), style);
  }

  // Fastest point: only worth a label when the walk had a real fast part.
  var vi = i0;
  for (var i = i0; i <= i1; i++) {
    if (speeds[i] > speeds[vi]) vi = i;
  }
  final vmax = maxSpeedKmh; // the same number as in the statistics; the label sits at the fastest stretch
  var hi = i0;
  for (var i = i0; i <= i1; i++) {
    if (alt[i] > alt[hi]) hi = i;
  }
  var lo = alt[i0];
  for (var i = i0; i <= i1; i++) {
    lo = math.min(lo, alt[i]);
  }
  final hasPeak = alt[hi] - lo >= 20;
  if (vmax >= 15) {
    pill(proj(pts[vi].lat, pts[vi].lon), '⚡ ${Units.speed(maxSpeedKmh / 3.6, digits: 0)}', const Color(0xFFFFEA00));
  }
  if (hasPeak) {
    pill(proj(pts[hi].lat, pts[hi].lon), '▲ ${Units.height(alt[hi])}', const Color(0xFFFFFFFF));
  }
}

const double offsetTop = 360;

// ====================================================================== text

void _drawHeader(Canvas c, PosterOptions o, int startMs, int endMs, int offsetSec) {
  final title = o.title.trim().isEmpty ? t('Прогулка') : o.title.trim();
  var y = 72.0;
  final size = drawText(c, title, Offset(64, y), headingStyle(title.length > 22 ? 46 : 58, weight: 800),
      maxWidth: posterW - 128, maxLines: 2);
  y += size.height + 14;
  if (o.showRegion && o.region.trim().isNotEmpty) {
    final s2 = drawText(c, '📍 ${o.region.trim()}', Offset(64, y), bodyStyle(40, weight: 500, color: const Color(0xFFE8F5E9)),
        maxWidth: posterW - 128, maxLines: 1);
    y += s2.height + 8;
  }
  if (o.dateTime) {
    drawText(c, posterDateLine(startMs, endMs, offsetSec), Offset(64, y), bodyStyle(36, color: const Color(0xFFCFD8DC)),
        maxWidth: posterW - 128, maxLines: 1);
  }
}

/// The colour scale of the poster line for the shown part of the track. A slope colouring on a flat walk
/// quietly becomes a single colour (the poster screen does not offer it there).
LineScale buildLineScale(PosterOptions o, TravelMode mode, List<TrackPoint> pts, int i0, int i1, List<TravelMode> modeAt,
    List<double> speeds, List<double> alt) {
  var coloring = o.coloring;
  if (coloring == LineColoring.slope && !slopeAvailable(alt, i0, i1)) coloring = LineColoring.single;
  if (coloring == LineColoring.height && alt.length <= i1) coloring = LineColoring.single;
  return LineScale.compute(coloring, mode, pts, i0, i1, modeAt, speeds, alt);
}

void _drawBottom(Canvas c, PosterOptions o, List<TrackPoint> pts, List<TrackSegment> segments, TravelMode mode, TrackStats st,
    List<double> alt, bool altFused, WeatherInfo? weather, bool useMap, int i0, int i1, LineScale scale) {
  var y = 1160.0;

  // Colour scale, then the legend: the ways of travelling with their own distance and speed.
  if (scale.coloring != LineColoring.single) {
    y += drawColorScale(c, scale, Rect.fromLTWH(64, y + 6, posterW - 128, 18), labelSize: 26) + 14;
  }
  if (o.legend) {
    final byMode = <TravelMode, ({double d, int t})>{};
    for (final s in segments) {
      final prev = byMode[s.mode];
      byMode[s.mode] = (d: (prev?.d ?? 0) + s.stats.distanceMeters, t: (prev?.t ?? 0) + s.stats.movingSeconds);
    }
    final entries = byMode.entries.where((e) => e.value.d > 50).toList();
    if (entries.length > 1) {
      for (final e in entries.take(3)) {
        final d = e.value.d, secs = e.value.t;
        _legendSwatch(c, Offset(64, y + 9), e.key == TravelMode.car);
        final v = secs > 0 ? d / secs : 0.0;
        final detail = v > 0 ? Units.speed(v) : '';
        drawText(c, '${t(e.key.label)} · ${Units.dist(d, digits: 1)}${detail.isEmpty ? '' : ' · $detail'}', Offset(108, y),
            bodyStyle(34, weight: 500), maxWidth: posterW - 172, maxLines: 1);
        y += 50;
      }
      y += 14;
    }
  }

  // Statistics grid: two columns.
  final cells = <(String, String)>[];
  if (o.distance) cells.add((Units.dist(st.distanceMeters), t('дистанция')));
  if (o.time) cells.add((_hms(st.movingSeconds), t('в движении')));
  if (o.elevation && alt.isNotEmpty) {
    final es = altFused ? elevationOfFused(alt) : elevationOf(pts, alt);
    cells.add(('+${Units.height(es.gain)}', t('набор высоты')));
  }
  if (o.speed && st.avgMovingSpeedMs > 0) {
    final single = segments.map((s) => s.mode).toSet().length <= 1;
    if (single) {
      cells.add((Units.speed(st.avgMovingSpeedMs), t('средняя скорость')));
    } else if (st.maxSpeedMs > 0) {
      cells.add((Units.speed(st.maxSpeedMs, digits: 0), t('макс. скорость')));
    }
  }
  const colW = (posterW - 128) / 2;
  final rows = (cells.length / 2).ceil();
  for (var i = 0; i < cells.length; i++) {
    final x = 64 + (i % 2) * colW, yy = y + (i ~/ 2) * 142;
    drawText(c, cells[i].$1, Offset(x, yy), headingStyle(54, weight: 700), maxWidth: colW - 16, maxLines: 1);
    drawText(c, cells[i].$2, Offset(x, yy + 70), bodyStyle(30, color: const Color(0xFFB0BEC5)));
  }
  y += rows * 142 + 8;

  // Weather and water temperature.
  final lines = <String>[];
  if (o.weather && weather != null) {
    final (emoji, _) = weather.condition;
    final feels = (weather.feelsAvg - weather.tempAvg).abs() >= 2 ? t(' (ощущ. {p})', {'p': Units.temp(weather.feelsAvg)}) : '';
    final rain = weather.precipMm >= 0.2 ? ' · 🌧 ${Units.precip(weather.precipMm)}' : '';
    lines.add('$emoji ${Units.temp(weather.tempAvg)}$feels · 💨 ${Units.speed(weather.windKmh / 3.6, digits: 0)}$rain');
  }
  final hasWater = mode == TravelMode.water || segments.any((s) => s.mode == TravelMode.water);
  if (o.waterTemp && hasWater) {
    final wt = o.waterTempManual ?? weather?.seaTemp;
    if (wt != null) lines.add(t('🌊 вода {p}', {'p': Units.temp(wt, digits: wt == wt.roundToDouble() ? 0 : 1)}));
  }
  if (lines.isNotEmpty) {
    drawText(c, lines.join('    '), Offset(64, y), bodyStyle(34, weight: 500), maxWidth: posterW - 128, maxLines: 1);
  }

  // Small elevation profile in the free space above the footer, when the walk has any relief.
  if (o.profile && y < 1650 && alt.isNotEmpty && i1 > i0) {
    drawMiniProfile(c, pts, alt, i0, i1, const Rect.fromLTWH(64, 1640, posterW - 128, 88));
  }

  // Footer: logo, name and, over a map, the data attribution.
  const fy = posterH - 150.0;
  c.drawLine(const Offset(64, fy - 14), const Offset(posterW - 64, fy - 14), Paint()..color = const Color(0x33FFFFFF)..strokeWidth = 2);
  drawTropaLogo(c, const Offset(64, fy + 8), 88);
  drawText(c, 'Tropa', const Offset(170, fy + 22), headingStyle(46, weight: 700));
  drawText(c, t('офлайн-трекер маршрутов'), const Offset(172, fy + 78), bodyStyle(24, color: const Color(0xFF90A4AE)));
  if (useMap) {
    const note = '© OpenStreetMap · Protomaps';
    final style = bodyStyle(22, color: const Color(0xFFB0BEC5));
    drawText(c, note, Offset(posterW - 64 - textWidth(note, style), fy + 62), style);
  }
}

/// Legend mark of a way of travelling: a solid bar on foot, dashes for a vehicle (as on the line itself).
void _legendSwatch(Canvas c, Offset at, bool dashed) {
  final paint = Paint()..color = const Color(0xFF90A4AE);
  if (!dashed) {
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(at.dx, at.dy, 26, 26), const Radius.circular(13)), paint);
    return;
  }
  for (var k = 0; k < 2; k++) {
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(at.dx + k * 17, at.dy + 6, 9, 14), const Radius.circular(4)), paint);
  }
}

/// Colour scale of the line (speed, height or slope): a gradient bar in [r] with the values under it. The speed values
/// are the 10th and 90th percentile that the line itself uses; a walk with a vehicle ride has one scale for each, written
/// under the bar. Returns the height used, from the top of [r] to the bottom of the labels.
double drawColorScale(Canvas c, LineScale scale, Rect r, {double labelSize = 24}) {
  final stops = switch (scale.coloring) {
    LineColoring.speed => speedStops,
    LineColoring.height => heightStops,
    _ => slopeStops,
  };
  c.drawRRect(
    RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)),
    Paint()
      ..shader = ui.Gradient.linear(Offset(r.left, 0), Offset(r.right, 0), stops, [for (var i = 0; i < stops.length; i++) i / (stops.length - 1)]),
  );
  final style = bodyStyle(labelSize, color: const Color(0xFFCFD8DC));
  final y = r.bottom + 4;
  String range(double lo, double hi) => '${Units.speedValue(lo).round()}–${Units.speed(hi, digits: 0)}';
  var lines = 1;
  switch (scale.coloring) {
    case LineColoring.speed when scale.split:
      // Wide bars have room for one line, the narrow plate of the horizontal poster gets two.
      final walk = '${t('Пешком')} ${range(scale.walkLo, scale.walkHi)}';
      final vehicle = '${t('Транспорт')} ${range(scale.vehicleLo, scale.vehicleHi)}';
      if (r.width > 700) {
        drawText(c, '$walk   ·   $vehicle', Offset(r.left, y), style);
      } else {
        drawText(c, walk, Offset(r.left, y), style);
        drawText(c, vehicle, Offset(r.left, y + labelSize * 1.3), style);
        lines = 2;
      }
    case LineColoring.speed:
      final lo = Units.speed(scale.walkLo, digits: 0), hi = Units.speed(scale.walkHi, digits: 0);
      drawText(c, lo, Offset(r.left, y), style);
      drawText(c, hi, Offset(r.right - textWidth(hi, style), y), style);
    case LineColoring.height:
      final lo = Units.height(scale.heightLo), hi = Units.height(scale.heightHi);
      drawText(c, lo, Offset(r.left, y), style);
      drawText(c, hi, Offset(r.right - textWidth(hi, style), y), style);
    default:
      final limit = scale.slopeLimit.round();
      final mid = '0 %';
      drawText(c, '−$limit %', Offset(r.left, y), style);
      drawText(c, mid, Offset(r.center.dx - textWidth(mid, style) / 2, y), style);
      final up = '+$limit %';
      drawText(c, up, Offset(r.right - textWidth(up, style), y), style);
  }
  return r.height + 10 + labelSize * 1.3 * lines;
}

Future<File> writePoster(Uint8List png, String name) async {
  final dir = await getTemporaryDirectory();
  return File(p.join(dir.path, '$name.png')).writeAsBytes(png);
}

/// Numbered markers of the notes on the route. With [labels] the first words of the note are written
/// next to its number (vertical poster); the horizontal poster lists the notes in a panel instead.
/// A note with a photo ([thumbs], by media name) shows the photo in a bigger round marker, its number in a small badge.
void drawNoteMarkers(Canvas c, List<TrackNote> notes, Projection proj,
    {required bool labels, required Rect bounds, double scale = 1.0, Map<String, ui.Image> thumbs = const {}}) {
  final taken = <Rect>[];
  var n = 0;
  final r = 21.0 * scale;
  final rPhoto = 40.0 * scale;
  // Markers first (they are never moved), labels afterwards in the free space around them.
  final spots = <(int, Offset, TrackNote, double)>[];
  for (final note in notes) {
    n++;
    final at = proj(note.lat, note.lon);
    if (!bounds.inflate(40).contains(at)) continue;
    final rr = thumbs[note.mediaName] != null ? rPhoto : r;
    spots.add((n, at, note, rr));
    taken.add(Rect.fromCircle(center: at, radius: rr + 6));
  }
  for (final (num, at, note, rr) in spots) {
    final photo = thumbs[note.mediaName];
    c.drawCircle(at.translate(0, 2), rr + 3, Paint()..color = const Color(0x66000000));
    c.drawCircle(at, rr + 3, Paint()..color = const Color(0xFFFFFFFF));
    if (photo != null) {
      // The photo, cropped to a square from its middle and clipped to the circle.
      final side = math.min(photo.width, photo.height).toDouble();
      final src = Rect.fromCenter(center: Offset(photo.width / 2, photo.height / 2), width: side, height: side);
      c.save();
      c.clipPath(Path()..addOval(Rect.fromCircle(center: at, radius: rr)));
      c.drawImageRect(photo, src, Rect.fromCircle(center: at, radius: rr), Paint()..filterQuality = FilterQuality.high);
      c.restore();
      // The number of the note in a badge on the rim.
      final badge = at + Offset(rr * 0.72, -rr * 0.72);
      final br = 15.0 * scale;
      c.drawCircle(badge, br + 2.5, Paint()..color = const Color(0xFFFFFFFF));
      c.drawCircle(badge, br, Paint()..color = const Color(0xFFAB47BC));
      final label = '$num';
      final st = bodyStyle(20 * scale, weight: 700);
      drawText(c, label, badge.translate(-textWidth(label, st) / 2, -12 * scale), st);
    } else {
      c.drawCircle(at, rr, Paint()..color = const Color(0xFFAB47BC));
      final label = '$num';
      final st = bodyStyle(24 * scale, weight: 700);
      drawText(c, label, at.translate(-textWidth(label, st) / 2, -15 * scale), st);
    }
  }
  if (!labels) return;
  for (final (_, at, note, rr) in spots) {
    final base = note.text.trim().isNotEmpty ? note.text.trim() : (note.mediaType == 'video' ? t('видео') : t('фото'));
    final text = base.length > 18 ? '${base.substring(0, 17)}…' : base;
    final ls = bodyStyle(26, weight: 500, color: const Color(0xFFFFFFFF));
    final w = textWidth(text, ls) + 28;
    const h = 42.0;
    // Right, left, above, below: the first position that stays inside the sheet and covers nothing else.
    final options = <Rect>[
      Rect.fromLTWH(at.dx + rr + 8, at.dy - h / 2, w, h),
      Rect.fromLTWH(at.dx - rr - 8 - w, at.dy - h / 2, w, h),
      Rect.fromLTWH(at.dx - w / 2, at.dy - rr - 8 - h, w, h),
      Rect.fromLTWH(at.dx - w / 2, at.dy + rr + 8, w, h),
    ];
    for (final box in options) {
      if (!bounds.contains(box.topLeft) || !bounds.contains(box.bottomRight)) continue;
      if (taken.any((t) => t.overlaps(box))) continue;
      taken.add(box.inflate(3));
      c.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(21)), Paint()..color = const Color(0xCC6A1B9A));
      drawText(c, text, Offset(box.left + 14, box.top + 7), ls);
      break;
    }
  }
}

/// Positions of the shown points after pulling apart the places where the track overlaps itself, the
/// weight of that separation (0..1) and the heading of the track at every point.
class SeparatedTrack {
  final List<Offset> pos;
  final List<double> weight;
  final List<Offset> heading;

  SeparatedTrack(this.pos, this.weight, this.heading);
}

/// A walk "there and back" draws one line over another. Points that meet an earlier (or later) pass of
/// the same path, closer than a line width, are shifted sideways: the earlier pass to one side, the later
/// one to the other, so the two lines run next to each other. The shift is smoothed along the track, so
/// the lines drift apart and together gently instead of jumping. Standing still is never a "pass".
SeparatedTrack separatePasses(List<TrackPoint> pts, int i0, int i1, Projection proj, List<double> speeds, double lineScale) {
  final n = i1 - i0 + 1;
  final pos = [for (var i = i0; i <= i1; i++) proj(pts[i].lat, pts[i].lon)];
  // Heading from points a few steps apart: robust against GPS jitter.
  final heading = List<Offset>.filled(n, const Offset(1, 0));
  for (var k = 0; k < n; k++) {
    final a = pos[math.max(0, k - 4)], b = pos[math.min(n - 1, k + 4)];
    final d = b - a;
    final len = d.distance;
    heading[k] = len < 1e-6 ? (k > 0 ? heading[k - 1] : const Offset(1, 0)) : d / len;
  }
  final thr = 15.0 * lineScale; // closer than this the two lines would cover each other
  final cell = thr * 2;
  final grid = <int, List<int>>{};
  int key(Offset p) => (p.dx / cell).floor() * 100003 + (p.dy / cell).floor();
  for (var k = 0; k < n; k++) {
    if (speeds[i0 + k] > 0.6) grid.putIfAbsent(key(pos[k]), () => []).add(k);
  }
  final shift = List<Offset>.filled(n, Offset.zero);
  final flag = List<double>.filled(n, 0);
  final half = 8.5 * lineScale;
  for (var k = 0; k < n; k++) {
    if (speeds[i0 + k] <= 0.6) continue;
    final cx = (pos[k].dx / cell).floor(), cy = (pos[k].dy / cell).floor();
    int? best;
    var bestD = thr;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final j in grid[(cx + dx) * 100003 + (cy + dy)] ?? const <int>[]) {
          // Another pass: far away in time (so not the neighbouring points of this very pass).
          if ((pts[i0 + j].tsMs - pts[i0 + k].tsMs).abs() < 180000) continue;
          final d = (pos[j] - pos[k]).distance;
          if (d < bestD) {
            bestD = d;
            best = j;
          }
        }
      }
    }
    if (best == null) continue;
    final earlier = pts[i0 + best].tsMs > pts[i0 + k].tsMs; // this point is the earlier pass
    // Normal of the earlier pass: both passes are pushed apart along it, in opposite directions.
    final h = earlier ? heading[k] : heading[best];
    final normal = Offset(-h.dy, h.dx);
    shift[k] = normal * (earlier ? half : -half);
    flag[k] = 1;
  }
  // Smooth the shift and its weight along the track.
  const w = 7;
  final out = List<Offset>.filled(n, Offset.zero);
  final weight = List<double>.filled(n, 0);
  for (var k = 0; k < n; k++) {
    var sx = 0.0, sy = 0.0, sw = 0.0;
    var cnt = 0;
    for (var m = math.max(0, k - w); m <= math.min(n - 1, k + w); m++) {
      sx += shift[m].dx;
      sy += shift[m].dy;
      sw += flag[m];
      cnt++;
    }
    out[k] = pos[k] + Offset(sx / cnt, sy / cnt);
    weight[k] = sw / cnt;
  }
  return SeparatedTrack(out, weight, heading);
}

/// Small chevrons along the places where two passes run side by side: they show which way each line goes.
void _drawDirectionArrows(Canvas c, SeparatedTrack t, double lineScale, bool lightMap) {
  final n = t.pos.length;
  var since = 0.0;
  const spacing = 78.0;
  final size = 8.5 * lineScale + 2;
  final fill = Paint()..color = const Color(0xFFFFFFFF);
  final edge = Paint()
    ..color = lightMap ? const Color(0x99000000) : const Color(0xCC000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  for (var k = 1; k < n; k++) {
    since += (t.pos[k] - t.pos[k - 1]).distance;
    if (t.weight[k] < 0.5 || since < spacing) continue;
    since = 0;
    final h = t.heading[k];
    final nrm = Offset(-h.dy, h.dx);
    final tip = t.pos[k] + h * size;
    final left = t.pos[k] - h * size * 0.6 + nrm * size * 0.8;
    final right = t.pos[k] - h * size * 0.6 - nrm * size * 0.8;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(t.pos[k].dx - h.dx * size * 0.15, t.pos[k].dy - h.dy * size * 0.15)
      ..lineTo(right.dx, right.dy)
      ..close();
    c.drawPath(path, fill);
    c.drawPath(path, edge);
  }
}

/// Colour filter for the map snapshot: the dark style is lifted a little (roads and water were hard to see
/// under the line), the light style is calmed down so the route and the texts stand out.
ColorFilter mapToneFilter(bool dark) => dark
    ? const ColorFilter.matrix(<double>[
        1.55, 0, 0, 0, 18, //
        0, 1.55, 0, 0, 18,
        0, 0, 1.55, 0, 20,
        0, 0, 0, 1, 0,
      ])
    : const ColorFilter.matrix(<double>[
        0.86, 0, 0, 0, 0, //
        0, 0.86, 0, 0, 0,
        0, 0, 0.86, 0, 0,
        0, 0, 0, 1, 0,
      ]);

/// Scale bar: a round distance (100 m ... 10 km) that is at most ~230 points long at the middle of the walk.
void drawDistanceScale(Canvas c, Projection proj, TrackPoint around, Offset at, {bool light = false, double maxLen = 230}) {
  final a = proj(around.lat, around.lon);
  final b = proj(around.lat + 0.01, around.lon);
  final perMeter = (a - b).distance / 1113.2; // points per metre (0.01 degree of latitude is 1113.2 m)
  if (perMeter <= 0) return;
  // Round lengths in the unit of the person: 100 m ... 50 km, or 0.1 ... 30 miles.
  final candidates = Units.imperial
      ? const [160.9344, 402.336, 804.672, 1609.344, 3218.688, 8046.72, 16093.44, 32186.88, 48280.32]
      : const [100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0];
  double meters = candidates.first;
  for (final m in candidates) {
    if (m * perMeter <= maxLen) meters = m;
  }
  final len = meters * perMeter;
  if (len < 40) return;
  final color = light ? const Color(0xFF263238) : const Color(0xFFFFFFFF);
  final shadow = light ? const Color(0x88FFFFFF) : const Color(0x99000000);
  final label = Units.imperial
      ? '${(meters / 1609.344) < 1 ? (meters / 1609.344).toStringAsFixed(meters / 1609.344 < 0.2 ? 1 : 2) : (meters / 1609.344).round()} ${Units.kmUnit}'
      : (meters >= 1000 ? '${(meters / 1000).round()} ${t('км')}' : '${meters.round()} ${t('м')}');
  for (final (dx, dy, col, w) in [(1.5, 1.5, shadow, 7.0), (0.0, 0.0, color, 3.5)]) {
    final p = Paint()
      ..color = col
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    c.drawLine(Offset(at.dx + dx, at.dy + dy), Offset(at.dx + len + dx, at.dy + dy), p);
    c.drawLine(Offset(at.dx + dx, at.dy + dy - 9), Offset(at.dx + dx, at.dy + dy + 9), p);
    c.drawLine(Offset(at.dx + len + dx, at.dy + dy - 9), Offset(at.dx + len + dx, at.dy + dy + 9), p);
  }
  final style = bodyStyle(24, weight: 600, color: color);
  drawText(c, label, Offset(at.dx + len + 14, at.dy - 15), style);
}

/// Elevation profile strip for the vertical poster: distance along the walk, height up, the climb filled.
void drawMiniProfile(Canvas c, List<TrackPoint> pts, List<double> alt, int i0, int i1, Rect r) {
  final dist = List<double>.filled(pts.length, 0);
  for (var i = i0 + 1; i <= i1; i++) {
    final dt = pts[i].tsMs - pts[i - 1].tsMs;
    final d = haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    dist[i] = dist[i - 1] + (dt <= 30000 && d / math.max(dt / 1000, 1) < 100 ? d : 0);
  }
  final total = dist[i1];
  var lo = alt[i0], hi = alt[i0];
  for (var i = i0; i <= i1; i++) {
    lo = math.min(lo, alt[i]);
    hi = math.max(hi, alt[i]);
  }
  if (total < 100 || hi - lo < 20) return; // flat walk: a profile would only be a line
  final label = bodyStyle(22, color: const Color(0xFFB0BEC5));
  final plot = Rect.fromLTRB(r.left + 70, r.top + 6, r.right, r.bottom - 6);
  double xOf(int i) => plot.left + dist[i] / total * plot.width;
  double yOf(double a) => plot.bottom - (a - lo) / (hi - lo) * plot.height;
  final area = Path()..moveTo(xOf(i0), plot.bottom);
  for (var i = i0; i <= i1; i += math.max(1, (i1 - i0) ~/ 400)) {
    area.lineTo(xOf(i), yOf(alt[i]));
  }
  area.lineTo(xOf(i1), yOf(alt[i1]));
  area.lineTo(xOf(i1), plot.bottom);
  area.close();
  c.drawPath(area, Paint()..shader = ui.Gradient.linear(Offset(0, plot.top), Offset(0, plot.bottom), const [Color(0x55FFFFFF), Color(0x08FFFFFF)]));
  final line = Path()..moveTo(xOf(i0), yOf(alt[i0]));
  for (var i = i0; i <= i1; i += math.max(1, (i1 - i0) ~/ 400)) {
    line.lineTo(xOf(i), yOf(alt[i]));
  }
  c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFFFFFF));
  drawText(c, Units.height(hi), Offset(r.left, plot.top - 4), label);
  drawText(c, Units.height(lo), Offset(r.left, plot.bottom - 20), label);
}
