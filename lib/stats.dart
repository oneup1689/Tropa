import 'db.dart';
import 'heal.dart';

class TrackStats {
  /// First to last point, including time without recording.
  final int totalSeconds;
  final int movingSeconds;
  final int pausedSeconds;

  /// Seconds inside gaps (no points recorded).
  final int gapSeconds;
  final double distanceMeters;
  final double maxSpeedMs;

  const TrackStats({
    required this.totalSeconds,
    required this.movingSeconds,
    required this.pausedSeconds,
    required this.gapSeconds,
    required this.distanceMeters,
    required this.maxSpeedMs,
  });

  double get avgMovingSpeedMs => movingSeconds == 0 ? 0 : distanceMeters / movingSeconds;

  /// Minutes per kilometre while moving, or null when there is no movement.
  double? get paceMinPerKm => avgMovingSpeedMs <= 0 ? null : (1000 / avgMovingSpeedMs) / 60;
}

/// Splits the time into moving / paused / no-recording and measures distance only while moving,
/// so GPS jitter during a pause never inflates the distance.
TrackStats computeStats(List<TrackPoint> pts, {double movingSpeedMs = 0.5, int gapSeconds = 30}) {
  if (pts.length < 2) {
    return const TrackStats(
        totalSeconds: 0, movingSeconds: 0, pausedSeconds: 0, gapSeconds: 0, distanceMeters: 0, maxSpeedMs: 0);
  }
  var moving = 0.0, paused = 0.0, gap = 0.0, dist = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final dt = (b.tsMs - a.tsMs) / 1000.0;
    if (dt <= 0) continue;
    if (dt > gapSeconds) {
      gap += dt;
      continue;
    }
    final d = haversine(a.lat, a.lon, b.lat, b.lon);
    if (d / dt >= movingSpeedMs && d >= 2) {
      moving += dt;
      dist += d;
    } else {
      paused += dt;
    }
  }

  // Max speed: the median of 5 consecutive segment speeds, so one or two wild fixes cannot set the record.
  var maxV = 0.0;
  for (var i = 5; i < pts.length; i++) {
    final speeds = <double>[];
    var ok = true;
    for (var j = i - 4; j <= i; j++) {
      final dt = (pts[j].tsMs - pts[j - 1].tsMs) / 1000.0;
      if (dt <= 0 || dt > gapSeconds) {
        ok = false;
        break;
      }
      speeds.add(haversine(pts[j - 1].lat, pts[j - 1].lon, pts[j].lat, pts[j].lon) / dt);
    }
    if (!ok) continue;
    speeds.sort();
    if (speeds[2] > maxV) maxV = speeds[2];
  }

  return TrackStats(
    totalSeconds: ((pts.last.tsMs - pts.first.tsMs) / 1000).round(),
    movingSeconds: moving.round(),
    pausedSeconds: paused.round(),
    gapSeconds: gap.round(),
    distanceMeters: dist,
    maxSpeedMs: maxV,
  );
}
