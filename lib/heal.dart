import 'dart:math' as math;

import 'db.dart';
import 'modes.dart';

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

/// What kind of movement a gap looks like, judged by its implied speed.
enum Activity { walk, bike, car }

class HealSettings {
  /// A gap longer than this many seconds starts a new segment.
  final int gapSeconds;
  final double stillMeters;
  final int longGapSeconds;

  /// Speed ceilings (m/s) that separate walking / cycling / driving gaps.
  final double walkMaxSpeed;
  final double bikeMaxSpeed;
  final double carMaxSpeed;

  /// Longest gap that may be bridged, per activity.
  final double walkLimit;
  final double bikeLimit;
  final double carLimit;

  /// Activities this travel mode may bridge; a gap of any other kind stays open.
  final Set<Activity> allowed;

  const HealSettings({
    this.gapSeconds = 30,
    this.stillMeters = 20,
    this.longGapSeconds = 20 * 60,
    this.walkMaxSpeed = 2.8,
    this.bikeMaxSpeed = 12,
    this.carMaxSpeed = 45,
    this.walkLimit = 150,
    this.bikeLimit = 400,
    this.carLimit = 1000,
    this.allowed = const {Activity.walk},
  });

  /// Rules for a travel mode. [walkLimitOverride] is the Pro setting, if the user changed it.
  factory HealSettings.forMode(TravelMode mode, {double? walkLimitOverride}) {
    final walk = walkLimitOverride != null && walkLimitOverride > 0 ? walkLimitOverride : 150.0;
    final allowed = switch (mode) {
      TravelMode.walk => const {Activity.walk},
      TravelMode.bike || TravelMode.water => const {Activity.walk, Activity.bike},
      TravelMode.car || TravelMode.mixed => const {Activity.walk, Activity.bike, Activity.car},
    };
    return HealSettings(walkLimit: walk, allowed: allowed);
  }

  /// Kept for the UI texts: the walking limit.
  double get bridgeMaxMeters => walkLimit;

  Activity? activityForSpeed(double v) {
    if (v <= walkMaxSpeed) return Activity.walk;
    if (v <= bikeMaxSpeed) return Activity.bike;
    if (v <= carMaxSpeed) return Activity.car;
    return null;
  }

  double limitFor(Activity a) => switch (a) {
        Activity.walk => walkLimit,
        Activity.bike => bikeLimit,
        Activity.car => carLimit,
      };
}

class GapInfo {
  /// Gap lies between points[index - 1] and points[index].
  final int index;
  final GapKind kind;
  final double meters;
  final int seconds;

  /// Intermediate points of the smooth continuation (bridge gaps only), endpoints excluded.
  /// Empty means "draw a straight line".
  final List<LatLon> curve;

  const GapInfo(this.index, this.kind, this.meters, this.seconds, [this.curve = const []]);

  double get speedMs => meters / math.max(seconds, 1);

  /// Length of the restored stretch: the curve if there is one, else the straight chord.
  double lengthMeters(TrackPoint a, TrackPoint b) {
    if (curve.isEmpty) return meters;
    var prevLat = a.lat, prevLon = a.lon, sum = 0.0;
    for (final c in curve) {
      sum += haversine(prevLat, prevLon, c.lat, c.lon);
      prevLat = c.lat;
      prevLon = c.lon;
    }
    return sum + haversine(prevLat, prevLon, b.lat, b.lon);
  }
}

class LatLon {
  final double lat;
  final double lon;
  const LatLon(this.lat, this.lon);
}

class HealResult {
  final List<GapInfo> gaps;
  final double recordedMeters;

  /// Restored length (smooth curves included); computed once by [analyzeGaps].
  final double restoredMeters;

  const HealResult(this.gaps, this.recordedMeters, [this.restoredMeters = 0]);

  GapInfo? gapAt(int index) {
    for (final g in gaps) {
      if (g.index == index) return g;
    }
    return null;
  }

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
  // Same place before and after: nothing was lost, however long the recording paused (a long stop, lunch).
  if (meters <= s.stillMeters) return GapKind.glueStill;
  if (seconds > s.longGapSeconds) return GapKind.keepBreak;
  final activity = s.activityForSpeed(meters / math.max(seconds, 1));
  // Too fast for any activity, or not something this travel mode would do: leave it open.
  if (activity == null || !s.allowed.contains(activity)) return GapKind.keepBreak;
  if (meters <= s.limitFor(activity)) return GapKind.bridge;
  return GapKind.snapLater;
}

/// Analyses a recorded track. Never modifies the points: healing is only a
/// presentation/export layer, so the raw recording stays untouched.
HealResult analyzeGaps(List<TrackPoint> pts, {HealSettings settings = const HealSettings()}) {
  final gaps = <GapInfo>[];
  var recorded = 0.0;
  var restored = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final d = haversine(a.lat, a.lon, b.lat, b.lon);
    final dtMs = b.tsMs - a.tsMs;
    if (dtMs > settings.gapSeconds * 1000) {
      final secs = (dtMs / 1000).round();
      final kind = classifyGap(d, secs, settings);
      final curve = kind == GapKind.bridge ? bridgeCurve(pts, i) : const <LatLon>[];
      final gap = GapInfo(i, kind, d, secs, curve);
      if (kind == GapKind.bridge) restored += gap.lengthMeters(a, b);
      gaps.add(gap);
    } else {
      recorded += d;
    }
  }
  return HealResult(gaps, recorded, restored);
}

/// Smooth continuation of the route across the gap between pts[i-1] and pts[i].
///
/// A cubic Hermite curve leaves the last recorded point along the direction the
/// person was walking and arrives at the first point after the gap along the
/// direction they continued. Returns the intermediate points (about every 5 m),
/// or an empty list when the headings are unreliable (then a straight line is used).
List<LatLon> bridgeCurve(List<TrackPoint> pts, int i, {double spacingM = 5, double headingSpanM = 10}) {
  final a = pts[i - 1], b = pts[i];
  final kx = 111320.0 * math.cos(a.lat * math.pi / 180);
  const ky = 110540.0;
  (double, double) local(double lat, double lon) => ((lon - a.lon) * kx, (lat - a.lat) * ky);

  final (bx, by) = local(b.lat, b.lon);
  final chord = math.sqrt(bx * bx + by * by);
  if (chord < 2) return const [];
  final ux = bx / chord, uy = by / chord;

  // Heading before the gap: from a point ~headingSpanM behind a, up to a.
  (double, double)? dirIn;
  for (var j = i - 2; j >= 0 && i - 1 - j <= 20; j--) {
    if (pts[j + 1].tsMs - pts[j].tsMs > 30000) break; // do not look across an earlier gap
    final (px, py) = local(pts[j].lat, pts[j].lon);
    final len = math.sqrt(px * px + py * py);
    if (len >= headingSpanM) {
      dirIn = (-px / len, -py / len);
      break;
    }
  }
  // Heading after the gap: from b to a point ~headingSpanM ahead.
  (double, double)? dirOut;
  for (var j = i + 1; j < pts.length && j - i <= 20; j++) {
    if (pts[j].tsMs - pts[j - 1].tsMs > 30000) break;
    final (px, py) = local(pts[j].lat, pts[j].lon);
    final dx = px - bx, dy = py - by;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len >= headingSpanM) {
      dirOut = (dx / len, dy / len);
      break;
    }
  }
  if (dirIn == null || dirOut == null) return const [];

  final cosIn = dirIn.$1 * ux + dirIn.$2 * uy;
  final cosOut = dirOut.$1 * ux + dirOut.$2 * uy;
  // Walking away from the target or doubling back: nothing sensible to extrapolate.
  if (cosIn < 0 || cosOut < 0) return const [];

  final k = 0.5 + 0.5 * math.min(cosIn, cosOut).clamp(0.0, 1.0);
  final m0x = dirIn.$1 * chord * k, m0y = dirIn.$2 * chord * k;
  final m1x = dirOut.$1 * chord * k, m1y = dirOut.$2 * chord * k;

  final steps = math.max(2, (chord / spacingM).round());
  final out = <LatLon>[];
  for (var s = 1; s < steps; s++) {
    final t = s / steps;
    final t2 = t * t, t3 = t2 * t;
    final h10 = t3 - 2 * t2 + t;
    final h01 = -2 * t3 + 3 * t2;
    final h11 = t3 - t2;
    // The h00 * A term is zero because A is the local origin.
    final x = h10 * m0x + h01 * bx + h11 * m1x;
    final y = h10 * m0y + h01 * by + h11 * m1y;
    out.add(LatLon(a.lat + y / ky, a.lon + x / kx));
  }
  return out;
}
