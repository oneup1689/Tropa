import 'dart:math' as math;

import 'db.dart';
import 'heal.dart';
import 'modes.dart';
import 'stats.dart';

/// A user's manual correction: the stretch [startMs]..[endMs] was really travelled in [mode].
class SegmentOverride {
  final int startMs;
  final int endMs;
  final TravelMode mode;

  const SegmentOverride(this.startMs, this.endMs, this.mode);
}

/// One stretch of a walk travelled in a single way (on foot, by vehicle, by bike, on water).
class TrackSegment {
  /// Inclusive point indexes. Neighbouring segments share their boundary point.
  final int startIdx;
  final int endIdx;
  final int startMs;
  final int endMs;
  final TravelMode mode;
  final TrackStats stats;

  const TrackSegment(this.startIdx, this.endIdx, this.startMs, this.endMs, this.mode, this.stats);
}

// Speeds (m/s) that separate standing, walking and "fast" movement, measured over a +-20 s window.
const double _stillMs = 0.7;
const double _walkMaxMs = 2.3; // 8.3 km/h: brisk walking; a sustained faster pace is a vehicle
const int _windowSec = 20;
const int _toFastSec = 40; // this long at vehicle speed before the stretch becomes "vehicle"
const int _toWalkSec = 60; // slower to leave a vehicle: traffic lights and jams must not split it

TrackStats _statsOf(List<TrackPoint> pts, int a, int b, TravelMode m) =>
    computeStats(pts.sublist(a, b + 1), movingSpeedMs: profileOf(m).movingSpeedMs);

enum _Label { still, walk, fast }

/// Splits a walk into stretches by how fast the person moved. Only "mixed" sessions are split by
/// speed: a mode chosen before the start (walk, bike, vehicle, water) is the user's own decision and
/// is kept for the whole walk. A bike cannot be told from a scooter by speed alone, so the fast
/// class is always "vehicle"; the user can change any stretch by hand ([overrides]).
List<TrackSegment> buildSegments(List<TrackPoint> pts, TravelMode sessionMode, {List<SegmentOverride> overrides = const []}) {
  if (pts.length < 2) return const [];
  final raw = <(int, int, TravelMode)>[];
  if (sessionMode != TravelMode.mixed) {
    raw.add((0, pts.length - 1, sessionMode));
  } else {
    raw.addAll(_autoSplit(pts));
  }

  // Apply the manual corrections: an override wins when it covers at least half of a stretch.
  final modes = <TravelMode>[];
  for (final r in raw) {
    final s = pts[r.$1].tsMs, e = pts[r.$2].tsMs;
    var mode = r.$3;
    for (final o in overrides) {
      final overlap = math.min(e, o.endMs) - math.max(s, o.startMs);
      if (overlap > 0 && overlap * 2 >= (e - s)) mode = o.mode;
    }
    modes.add(mode);
  }

  // Merge neighbours that ended up with the same mode.
  final merged = <(int, int, TravelMode)>[];
  for (var i = 0; i < raw.length; i++) {
    if (merged.isNotEmpty && merged.last.$3 == modes[i]) {
      merged[merged.length - 1] = (merged.last.$1, raw[i].$2, modes[i]);
    } else {
      merged.add((raw[i].$1, raw[i].$2, modes[i]));
    }
  }
  return [
    for (final m in merged)
      TrackSegment(m.$1, m.$2, pts[m.$1].tsMs, pts[m.$2].tsMs, m.$3, _statsOf(pts, m.$1, m.$2, m.$3)),
  ];
}

List<(int, int, TravelMode)> _autoSplit(List<TrackPoint> pts) {
  final n = pts.length;
  // Label of every interval i (pts[i-1] -> pts[i]) from the displacement over a +-20 s window.
  final labels = List<_Label>.filled(n, _Label.still);
  var lo = 0, hi = 0;
  for (var i = 1; i < n; i++) {
    final t = pts[i].tsMs;
    while (pts[lo].tsMs < t - _windowSec * 1000 && lo < i) {
      lo++;
    }
    if (hi < i) hi = i;
    while (hi + 1 < n && pts[hi + 1].tsMs <= t + _windowSec * 1000) {
      hi++;
    }
    final dt = (pts[i].tsMs - pts[i - 1].tsMs) / 1000.0;
    double v;
    if (dt > 300) {
      v = 0; // a long hole in the recording says nothing about the speed
    } else if (dt > 30) {
      v = haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon) / dt;
    } else {
      final span = (pts[hi].tsMs - pts[lo].tsMs) / 1000.0;
      v = span <= 0 ? 0 : haversine(pts[lo].lat, pts[lo].lon, pts[hi].lat, pts[hi].lon) / span;
    }
    labels[i] = v < _stillMs ? _Label.still : (v <= _walkMaxMs ? _Label.walk : _Label.fast);
  }

  final out = <(int, int, TravelMode)>[];
  _Label? cur;
  var segStart = 0;
  int? candStart;
  var candSec = 0.0;
  for (var i = 1; i < n; i++) {
    final l = labels[i];
    if (l == _Label.still) continue;
    if (cur == null) {
      cur = l;
      continue;
    }
    if (l == cur) {
      candStart = null;
      candSec = 0;
      continue;
    }
    candStart ??= i - 1;
    candSec += math.min((pts[i].tsMs - pts[i - 1].tsMs) / 1000.0, 60);
    if (candSec >= (cur == _Label.walk ? _toFastSec : _toWalkSec)) {
      out.add((segStart, candStart, _modeOf(cur)));
      segStart = candStart;
      cur = l;
      candStart = null;
      candSec = 0;
    }
  }
  out.add((segStart, n - 1, _modeOf(cur ?? _Label.walk)));

  // A stretch shorter than 90 s (the first steps before getting into a car, a crossing) is not
  // worth a separate line: it takes the mode of its neighbour.
  if (out.length > 1) {
    for (var i = 0; i < out.length; i++) {
      final dur = pts[out[i].$2].tsMs - pts[out[i].$1].tsMs;
      if (dur < 90000) {
        final neighbour = i > 0 ? out[i - 1].$3 : out[i + 1].$3;
        out[i] = (out[i].$1, out[i].$2, neighbour);
      }
    }
  }
  return out;
}

TravelMode _modeOf(_Label l) => l == _Label.fast ? TravelMode.car : TravelMode.walk;

/// Speed (m/s) of every point from the displacement over a +-[windowSec] window: jitter on a stop
/// cancels out, and a hole in the recording gives 0.
List<double> smoothedSpeeds(List<TrackPoint> pts, {int windowSec = _windowSec}) {
  final n = pts.length;
  final out = List<double>.filled(n, 0);
  var lo = 0, hi = 0;
  for (var i = 1; i < n; i++) {
    final t = pts[i].tsMs;
    while (pts[lo].tsMs < t - windowSec * 1000 && lo < i) {
      lo++;
    }
    if (hi < i) hi = i;
    while (hi + 1 < n && pts[hi + 1].tsMs <= t + windowSec * 1000) {
      hi++;
    }
    if (pts[i].tsMs - pts[i - 1].tsMs > 30000) continue;
    final span = (pts[hi].tsMs - pts[lo].tsMs) / 1000.0;
    out[i] = span <= 0 ? 0 : haversine(pts[lo].lat, pts[lo].lon, pts[hi].lat, pts[hi].lon) / span;
  }
  if (n > 1) out[0] = out[1];
  return out;
}
