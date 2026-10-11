import 'dart:math' as math;

import 'db.dart';

/// How a gap between two consecutive recorded segments is treated.
enum GapKind {
  /// Practically the same place (standing, GPS briefly off): just glue.
  glueStill,

  /// Short and walkable: join with a straight line, counted as "restored".
  bridge,

  /// Plausible movement but too long for a straight line; waits for trail snapping.
  snapLater,

  /// Too fast (transport?) or too long: never joined automatically.
  keepBreak,
}

class HealSettings {
  /// A gap longer than this many seconds starts a new segment.
  final int gapSeconds;
  final double stillMeters;
  final double bridgeMaxMeters;
  final double walkMaxSpeed; // m/s
  final int longGapSeconds;

  const HealSettings({
    this.gapSeconds = 30,
    this.stillMeters = 20,
    this.bridgeMaxMeters = 150,
    this.walkMaxSpeed = 2.8,
    this.longGapSeconds = 20 * 60,
  });
}

class GapInfo {
  /// Gap lies between points[index - 1] and points[index].
  final int index;
  final GapKind kind;
  final double meters;
  final int seconds;

  const GapInfo(this.index, this.kind, this.meters, this.seconds);

  double get speedMs => meters / math.max(seconds, 1);
}

class HealResult {
  final List<GapInfo> gaps;
  final double recordedMeters;

  const HealResult(this.gaps, this.recordedMeters);

  GapInfo? gapAt(int index) {
    for (final g in gaps) {
      if (g.index == index) return g;
    }
    return null;
  }

  double get restoredMeters =>
      gaps.where((g) => g.kind == GapKind.bridge).fold(0.0, (s, g) => s + g.meters);

  int get unresolved =>
      gaps.where((g) => g.kind == GapKind.snapLater || g.kind == GapKind.keepBreak).length;
}

double haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
  final h = math.pow(math.sin(dp / 2), 2) + math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

GapKind classifyGap(double meters, int seconds, HealSettings s) {
  if (seconds > s.longGapSeconds) return GapKind.keepBreak;
  if (meters <= s.stillMeters) return GapKind.glueStill;
  if (meters / math.max(seconds, 1) > s.walkMaxSpeed) return GapKind.keepBreak;
  if (meters <= s.bridgeMaxMeters) return GapKind.bridge;
  return GapKind.snapLater;
}

/// Analyses a recorded track. Never modifies the points: healing is only a
/// presentation/export layer, so the raw recording stays untouched.
HealResult analyzeGaps(List<TrackPoint> pts, {HealSettings settings = const HealSettings()}) {
  final gaps = <GapInfo>[];
  var recorded = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final d = haversine(a.lat, a.lon, b.lat, b.lon);
    final dtMs = b.tsMs - a.tsMs;
    if (dtMs > settings.gapSeconds * 1000) {
      final secs = (dtMs / 1000).round();
      gaps.add(GapInfo(i, classifyGap(d, secs, settings), d, secs));
    } else {
      recorded += d;
    }
  }
  return HealResult(gaps, recorded);
}
