import 'dart:math' as math;

import 'heal.dart' show LatLon, haversine;

/// Pure turn-by-turn logic for following a route (no Flutter, no platform): turn detection by the geometry of the
/// line and progress along it from GPS fixes. The recording itself and the "off route" alarm stay in the native
/// service; this only decides what to say and show.

enum Turn { slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn }

extension TurnInfo on Turn {
  bool get isLeft => this == Turn.slightLeft || this == Turn.left || this == Turn.sharpLeft;
}

class Maneuver {
  /// Metres from the start of the (possibly reversed) route.
  final double at;
  final Turn turn;

  /// Signed change of course in degrees (positive = right).
  final double angle;

  const Maneuver(this.at, this.turn, this.angle);
}

/// A route resampled to a step of [step] metres, with the turns found on it.
class RoutePath {
  static const step = 5.0;

  final List<LatLon> pts;
  final List<Maneuver> maneuvers;

  RoutePath._(this.pts, this.maneuvers);

  double get lengthM => (pts.length - 1) * step;

  /// [reverse] walks the route from its end to its start (left and right swap by themselves).
  /// [minAngle] is the smallest change of course that counts as a turn.
  factory RoutePath.build(List<LatLon> raw, {bool reverse = false, double minAngle = 35}) {
    final src = reverse ? raw.reversed.toList() : List<LatLon>.of(raw);
    final pts = _resample(src);
    return RoutePath._(pts, _findTurns(pts, minAngle));
  }

  static List<LatLon> _resample(List<LatLon> src) {
    if (src.length < 2) return List.of(src);
    final out = <LatLon>[src.first];
    var carry = 0.0; // distance already walked since the last output point
    for (var i = 1; i < src.length; i++) {
      final a = src[i - 1], b = src[i];
      final len = haversine(a.lat, a.lon, b.lat, b.lon);
      if (len < 0.01) continue;
      var pos = step - carry;
      while (pos <= len) {
        final f = pos / len;
        out.add(LatLon(a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f));
        pos += step;
      }
      carry = len - (pos - step);
    }
    // The route ends where the source ends; the last step may be shorter, which the path length ignores (<5 m).
    final last = src.last;
    if (haversine(out.last.lat, out.last.lon, last.lat, last.lon) > 1) out.add(last);
    return out;
  }

  static double _bearing(LatLon a, LatLon b) {
    final p1 = a.lat * math.pi / 180, p2 = b.lat * math.pi / 180;
    final dl = (b.lon - a.lon) * math.pi / 180;
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static double _delta(double from, double to) {
    var d = (to - from) % 360;
    if (d > 180) d -= 360;
    if (d <= -180) d += 360;
    return d;
  }

  static Turn _classify(double d) {
    final a = d.abs();
    if (a > 165) return Turn.uTurn;
    final right = d > 0;
    if (a > 120) return right ? Turn.sharpRight : Turn.sharpLeft;
    if (a > 60) return right ? Turn.right : Turn.left;
    return right ? Turn.slightRight : Turn.slightLeft;
  }

  /// The course 25 m behind a point against the course 25 m ahead; peaks above [minAngle] are turns.
  static List<Maneuver> _findTurns(List<LatLon> p, double minAngle) {
    const k = 5; // steps of 5 m = 25 m on each side
    final n = p.length;
    if (n < 2 * k + 1) return const [];
    final delta = List<double>.filled(n, 0);
    for (var i = k; i < n - k; i++) {
      delta[i] = _delta(_bearing(p[i - k], p[i]), _bearing(p[i], p[i + k]));
    }
    final out = <Maneuver>[];
    var i = k;
    while (i < n - k) {
      if (delta[i].abs() < minAngle) {
        i++;
        continue;
      }
      // One bend spreads over several samples: take the strongest of the run, then skip the run's shadow (30 m).
      var best = i;
      var j = i;
      while (j < n - k && delta[j].abs() >= minAngle * 0.6 && (j - i) <= 8) {
        if (delta[j].abs() > delta[best].abs()) best = j;
        j++;
      }
      // A turn is the full change of course across the bend, not only the part seen from the middle sample.
      final full = _delta(_bearing(p[math.max(0, best - 2 * k)], p[math.max(0, best - k)]),
          _bearing(p[math.min(n - 1, best + k)], p[math.min(n - 1, best + 2 * k)]));
      final ang = full.abs() > delta[best].abs() ? full : delta[best];
      out.add(Maneuver(best * step, _classify(ang), ang));
      i = math.max(j, best + 6);
    }
    return out;
  }
}

class NavAlert {
  final Maneuver maneuver;

  /// Metres left to the turn at the moment of the alert.
  final double distM;

  /// The last warning before the turn (the near one).
  final bool near;

  const NavAlert(this.maneuver, this.distM, this.near);
}

class NavState {
  final double progressM;
  final double remainingM;

  /// Distance from the route line, metres.
  final double offM;
  final Maneuver? next;
  final double toNextM;
  final bool arrived;

  /// Set only on the update that crosses a warning distance (once per turn and distance).
  final NavAlert? alert;

  /// Set only on the update that reaches the finish.
  final bool justArrived;

  const NavState({
    required this.progressM,
    required this.remainingM,
    required this.offM,
    required this.next,
    required this.toNextM,
    required this.arrived,
    this.alert,
    this.justArrived = false,
  });
}

/// Follows a [RoutePath]: feed it GPS fixes, read progress and warnings.
class NavEngine {
  final RoutePath path;

  /// Warn this far from a turn: first [farM], then [nearM].
  final double farM, nearM;

  late final List<double> _x, _y;
  late final double _lat0;
  int _seg = 0;
  bool _started = false;
  bool _arrived = false;
  final Set<int> _fired = {};

  NavEngine(this.path, {this.farM = 100, this.nearM = 30}) {
    _lat0 = path.pts.first.lat;
    final lon0 = path.pts.first.lon;
    final kx = math.cos(_lat0 * math.pi / 180) * 111320;
    _x = [for (final p in path.pts) (p.lon - lon0) * kx];
    _y = [for (final p in path.pts) (p.lat - _lat0) * 111320];
    _lon0 = lon0;
    _kx = kx;
  }

  late final double _lon0, _kx;

  /// Nearest point of segments [lo..hi]: (distance, segment, fraction).
  ({double d, int seg, double f}) _nearest(double x, double y, int lo, int hi) {
    var bestD = double.infinity, bestSeg = lo;
    var bestF = 0.0;
    for (var j = lo; j <= hi; j++) {
      final ax = _x[j], ay = _y[j], bx = _x[j + 1], by = _y[j + 1];
      final dx = bx - ax, dy = by - ay;
      final l2 = dx * dx + dy * dy;
      final f = l2 == 0 ? 0.0 : (((x - ax) * dx + (y - ay) * dy) / l2).clamp(0.0, 1.0);
      final px = ax + dx * f - x, py = ay + dy * f - y;
      final d = math.sqrt(px * px + py * py);
      if (d < bestD) {
        bestD = d;
        bestSeg = j;
        bestF = f;
      }
    }
    return (d: bestD, seg: bestSeg, f: bestF);
  }

  NavState update(double lat, double lon, {double accuracy = 10}) {
    final n = path.pts.length;
    final total = path.lengthM;
    if (n < 2) {
      return const NavState(progressM: 0, remainingM: 0, offM: 0, next: null, toNextM: 0, arrived: false);
    }
    final x = (lon - _lon0) * _kx, y = (lat - _lat0) * 111320;
    final last = n - 2;
    var r = _started
        ? _nearest(x, y, math.max(0, _seg - 10), math.min(last, _seg + 80))
        : _nearest(x, y, 0, last);
    if (_started && r.d > math.max(60, 2 * accuracy)) {
      // Lost in the window: the person may have cut a corner or come back elsewhere on the route.
      final g = _nearest(x, y, 0, last);
      if (g.d < 30) {
        r = g;
      } else if (g.d < r.d) {
        r = (d: g.d, seg: _seg, f: 0); // far from the line; keep the old place, report the distance
      }
    }
    if (r.d <= math.max(60, 2 * accuracy) || !_started) {
      _seg = r.seg;
      _started = true;
    }
    final progress = math.min(total, (_seg + r.f) * RoutePath.step);
    final remaining = math.max(0.0, total - progress);

    // Next turn still ahead (a few metres of slack so a turn being passed is not dropped too early).
    Maneuver? next;
    var nextIdx = -1;
    for (var i = 0; i < path.maneuvers.length; i++) {
      if (path.maneuvers[i].at > progress - 3) {
        next = path.maneuvers[i];
        nextIdx = i;
        break;
      }
    }
    final toNext = next == null ? remaining : next.at - progress;

    NavAlert? alert;
    if (next != null && r.d <= math.max(60, 2 * accuracy)) {
      if (toNext <= nearM && !_fired.contains(nextIdx * 2 + 1)) {
        _fired..add(nextIdx * 2)..add(nextIdx * 2 + 1);
        alert = NavAlert(next, toNext, true);
      } else if (toNext <= farM && toNext > nearM && !_fired.contains(nextIdx * 2)) {
        _fired.add(nextIdx * 2);
        alert = NavAlert(next, toNext, false);
      }
    }

    final done = remaining < 25 && progress >= total * 0.9;
    final just = done && !_arrived;
    if (done) _arrived = true;
    return NavState(
      progressM: progress,
      remainingM: remaining,
      offM: r.d,
      next: next,
      toNextM: toNext,
      arrived: _arrived,
      alert: alert,
      justArrived: just,
    );
  }
}
