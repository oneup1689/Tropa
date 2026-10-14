import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'db.dart';
import 'l10n.dart';
import 'poster.dart';
import 'poster_wide.dart';
import 'theme.dart';

/// Shown while a poster is being made: the route of the walk is drawn as a line, over and over, until the poster is
/// ready. With a map snapshot ([map], taken for the poster) the line is drawn on that map, darkened, exactly where it
/// will be on the poster; without a map on the dark green background of the app.
class PosterBuildOverlay extends StatefulWidget {
  final List<TrackPoint> points;
  final MapCapture? map;

  /// The horizontal "pro map" poster: its canvas is 1800 x 1200 instead of 1080 x 1920.
  final bool wide;

  const PosterBuildOverlay({super.key, required this.points, this.map, this.wide = false});

  @override
  State<PosterBuildOverlay> createState() => _PosterBuildOverlayState();
}

class _PosterBuildOverlayState extends State<PosterBuildOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();
  late final List<Offset> _norm = _normalize(widget.points);
  ui.Image? _mapImage;
  List<Offset> _onMap = const []; // the route in the pixels of the poster canvas, when there is a map

  @override
  void initState() {
    super.initState();
    _loadMap();
  }

  @override
  void didUpdateWidget(covariant PosterBuildOverlay old) {
    super.didUpdateWidget(old);
    // The map snapshot arrives after the overlay was created (it is taken first, on its own screen).
    if (widget.map != null && old.map != widget.map) _loadMap();
  }

  Future<void> _loadMap() async {
    final m = widget.map;
    if (m == null) return;
    try {
      final img = (await (await ui.instantiateImageCodec(m.png, targetWidth: 1080)).getNextFrame()).image;
      final proj = mapProjection(m, widget.wide ? wideW : posterW);
      final pts = widget.points;
      final step = math.max(1, pts.length ~/ 300);
      final sample = [for (var i = 0; i < pts.length; i += step) pts[i], pts.last];
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _mapImage = img;
        _onMap = [for (final p in sample) proj(p.lat, p.lon)];
      });
    } catch (_) {
      // Without the picture the plain background stays: the animation is decoration only.
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    _mapImage?.dispose();
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
    final hasMap = _mapImage != null && _onMap.length >= 2;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0B3A2F), Color(0xFF071C2C)]),
      ),
      child: Stack(children: [
        if (hasMap)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _ctl,
              builder: (_, _) => CustomPaint(
                painter: _MapTrailPainter(
                  _mapImage!,
                  _onMap,
                  widget.wide ? const Size(wideW, wideH) : const Size(posterW, posterH),
                  Curves.easeInOutCubic.transform(_ctl.value),
                ),
              ),
            ),
          )
        else
          Positioned.fill(
            child: SafeArea(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: AnimatedBuilder(
                      animation: _ctl,
                      builder: (_, _) => CustomPaint(painter: _TrailPainter(_norm, Curves.easeInOutCubic.transform(_ctl.value))),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 36),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(t('Рисую постер…'), style: const TextStyle(color: Colors.white, fontSize: 18, shadows: [Shadow(blurRadius: 8)])),
                const SizedBox(height: 6),
                Text(t('Это займёт несколько секунд'), style: const TextStyle(color: Colors.white70, fontSize: 13, shadows: [Shadow(blurRadius: 8)])),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The darkened map of the poster with the route drawn on it, in the place where it will be on the poster.
class _MapTrailPainter extends CustomPainter {
  final ui.Image image;
  final List<Offset> route; // poster canvas pixels
  final Size canvas;
  final double progress;

  _MapTrailPainter(this.image, this.route, this.canvas, this.progress);

  @override
  void paint(Canvas c, Size size) {
    // The poster canvas is fitted into the screen (whole map visible, the rest of the screen stays the dark background).
    final k = math.min(size.width / canvas.width, size.height / canvas.height);
    final dx = (size.width - canvas.width * k) / 2, dy = (size.height - canvas.height * k) / 2;
    final dst = Rect.fromLTWH(dx, dy, canvas.width * k, canvas.height * k);
    c.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = mapToneFilter(true),
    );
    c.drawRect(dst, Paint()..color = const Color(0x66000000)); // darker still: the line has to be the bright thing
    final path = Path()..moveTo(dx + route.first.dx * k, dy + route.first.dy * k);
    for (final p in route.skip(1)) {
      path.lineTo(dx + p.dx * k, dy + p.dy * k);
    }
    final metric = path.computeMetrics().first;
    final drawn = metric.extractPath(0, metric.length * progress);
    c.save();
    c.clipRect(dst);
    c.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = TropaColors.mint.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    c.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = TropaColors.mint,
    );
    final head = metric.getTangentForOffset(metric.length * progress)?.position;
    if (head != null) {
      c.drawCircle(head, 10, Paint()..color = Colors.white);
      c.drawCircle(head, 5.5, Paint()..color = TropaColors.orange);
    }
    c.restore();
  }

  @override
  bool shouldRepaint(_MapTrailPainter old) => old.progress != progress || old.image != image;
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
