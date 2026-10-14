import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'brand.dart';

/// The word "tropa" as one trail: lowercase monoline letters, the last one hooks into a rising tail that ends in
/// the finish dot. The letters are paths in a box of 354 x 112 units (x 28..382, y 5..117), drawn in order, so the
/// splash screen can "walk" the trail from the t to the dot. [progress] 0..1 of the strokes; the dot pops in at the end.
const double _wmW = 354, _wmH = 112;
const double _stroke = 10.5, _round = 20.5;

List<Path> _wordPaths() {
  Path circle(double cx) => Path()..addArc(Rect.fromCircle(center: Offset(cx, 60), radius: _round), -math.pi / 2, 2 * math.pi);
  return [
    // t: crossbar, then the stem with its hook
    Path()
      ..moveTo(34, 40)
      ..lineTo(68, 40),
    Path()
      ..moveTo(50, 16)
      ..lineTo(50, 60)
      ..arcToPoint(const Offset(70, 80), radius: const Radius.circular(20), clockwise: false),
    // r
    Path()
      ..moveTo(95, 40)
      ..lineTo(95, 80),
    Path()
      ..moveTo(95, 60)
      ..arcToPoint(const Offset(115, 40), radius: const Radius.circular(20)),
    circle(160), // o
    Path() // p
      ..moveTo(205, 40)
      ..lineTo(205, 112),
    circle(225),
    circle(280), // a, with the stem that becomes the trail
    Path()
      ..moveTo(300, 40)
      ..lineTo(300, 60)
      ..arcToPoint(const Offset(320, 80), radius: const Radius.circular(20), clockwise: false)
      ..cubicTo(342, 80, 342, 56, 364, 56),
  ];
}

/// Paints the wordmark fitted into [box]. [color] is the letters, [dot] the finish dot.
void drawTropaWordmark(Canvas c, Rect box, {double progress = 1, Color color = brandSand, Color dot = brandAccent}) {
  final k = math.min(box.width / _wmW, box.height / _wmH);
  c.save();
  c.translate(box.center.dx, box.center.dy);
  c.scale(k);
  c.translate(-(28 + _wmW / 2), -(5 + _wmH / 2));
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = _stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final paths = _wordPaths();
  final lens = [for (final p in paths) p.computeMetrics().fold<double>(0, (a, m) => a + m.length)];
  final total = lens.fold<double>(0, (a, b) => a + b);
  var left = progress.clamp(0.0, 1.0) * total;
  for (var i = 0; i < paths.length && left > 0; i++) {
    var take = math.min(left, lens[i]);
    left -= lens[i];
    for (final m in paths[i].computeMetrics()) {
      if (take <= 0) break;
      final part = math.min(take, m.length);
      c.drawPath(m.extractPath(0, part), paint);
      take -= part;
    }
  }
  // The finish dot pops in during the last tenth of the walk.
  final pop = ((progress - 0.9) / 0.1).clamp(0.0, 1.0);
  if (pop > 0) c.drawCircle(const Offset(373.5, 56), 8.5 * Curves.easeOutBack.transform(pop), Paint()..color = dot);
  c.restore();
}

class _SplashPainter extends CustomPainter {
  final double progress;

  _SplashPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [brandGreen, brandNight]).createShader(Offset.zero & size),
    );
    final w = size.width * 0.74;
    drawTropaWordmark(canvas, Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.46), width: w, height: w * _wmH / _wmW), progress: progress);
  }

  @override
  bool shouldRepaint(covariant _SplashPainter old) => old.progress != progress;
}

/// The start screen: the poster gradient and the word "tropa" drawn as a trail. Tap to skip.
class TropaSplash extends StatefulWidget {
  final VoidCallback onDone;

  const TropaSplash({super.key, required this.onDone});

  @override
  State<TropaSplash> createState() => _TropaSplashState();
}

class _TropaSplashState extends State<TropaSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  bool _out = false;

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (mounted) setState(() => _out = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _out = true),
      child: AnimatedOpacity(
        opacity: _out ? 0 : 1,
        duration: const Duration(milliseconds: 300),
        onEnd: () {
          if (_out) widget.onDone();
        },
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _SplashPainter(Curves.easeInOut.transform(_c.value)), size: Size.infinite),
        ),
      ),
    );
  }
}
