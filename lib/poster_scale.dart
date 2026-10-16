import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'brand.dart';
import 'db.dart';
import 'heal.dart';
import 'modes.dart';

/// How the line of the poster is coloured. Stretches travelled by vehicle are always drawn dashed on top
/// of any of these (see [LineScale.vehicleAt]).
///
/// [relief] is what the person chooses ("Рельеф"): [pickRelief] turns it into [height] or [slope] (or [single] on a flat
/// walk) by the shape of the walk, so that nobody has to know the difference. A [LineScale] never holds [relief].
enum LineColoring { single, speed, relief, height, slope }

/// A relief smaller than this (metres between the lowest and the highest point) is too flat for a slope colouring:
/// GPS and terrain-model noise would be the whole picture.
const double minReliefForSlope = 15;

bool slopeAvailable(List<double> alt, int i0, int i1) {
  if (alt.length <= i1 || i1 <= i0) return false;
  var lo = alt[i0], hi = alt[i0];
  for (var i = i0; i <= i1; i++) {
    lo = math.min(lo, alt[i]);
    hi = math.max(hi, alt[i]);
  }
  return hi - lo >= minReliefForSlope;
}

/// Which relief colouring tells more about this walk.
///
/// Flat (under [minReliefForSlope] between the lowest and the highest point): nothing to show, one colour.
/// Otherwise the walk is described by its range (highest minus lowest) and by how much it climbs and descends in
/// total (gain + loss, small ups and downs under [hysteresisM] ignored):
/// - total close to the range (one climb, one descent, or up and back down a hill) and a real range (40 m and more):
///   the height colouring, which shows where the high point is;
/// - the walk goes up and down many times (total over 2.6 times the range): the slope colouring, which shows which
///   stretches were steep (the height colours would be a muddle of the same few shades);
/// - a small range (15-40 m): the height colouring, smooth; slopes of such a walk are mostly GPS noise.
LineColoring pickRelief(List<double> alt, int i0, int i1, {double hysteresisM = 6}) {
  if (!slopeAvailable(alt, i0, i1)) return LineColoring.single;
  var lo = alt[i0], hi = alt[i0];
  for (var i = i0; i <= i1; i++) {
    lo = math.min(lo, alt[i]);
    hi = math.max(hi, alt[i]);
  }
  final range = hi - lo;
  if (range < 40) return LineColoring.height;
  // Total climb and descent with a dead band, as a hiking app counts them.
  var ref = alt[i0], gain = 0.0, loss = 0.0;
  for (var i = i0 + 1; i <= i1; i++) {
    final d = alt[i] - ref;
    if (d >= hysteresisM) {
      gain += d;
      ref = alt[i];
    } else if (d <= -hysteresisM) {
      loss -= d;
      ref = alt[i];
    }
  }
  return (gain + loss) > 2.6 * range ? LineColoring.slope : LineColoring.height;
}

/// Everything the colour of the line and its scale bar need, computed once for the part of the track that is shown.
///
/// Speed: the colours run from the 10th to the 90th percentile of the shown speeds, so one outlier cannot flatten
/// the gradient. When the walk has both walking and vehicle stretches ([split]) each kind has its own scale,
/// otherwise the taxi would turn the whole walk blue.
/// Slope: smoothed over a window of the track (50 m on foot, 150 m by bike), in percent; the scale is fixed by the
/// way of travelling (steeper limits on foot than by bike) so that equal slopes always get equal colours.
class LineScale {
  final LineColoring coloring;
  final bool split;
  final double walkLo, walkHi, vehicleLo, vehicleHi; // m/s
  final double heightLo, heightHi; // metres
  final double slopeLimit; // percent: +-limit spans the whole palette
  final List<double> slope; // percent at every point of the full track (0 where unknown)
  final List<bool> vehicleAt; // true where the stretch is a vehicle ride and the walk also has non-vehicle stretches
  final List<double> _speeds;
  final List<double> _alt;
  final List<TravelMode> _modeAt;

  LineScale._(this.coloring, this.split, this.walkLo, this.walkHi, this.vehicleLo, this.vehicleHi, this.heightLo, this.heightHi,
      this.slopeLimit, this.slope, this.vehicleAt, this._speeds, this._alt, this._modeAt);

  static double _percentile(List<double> sorted, double q, double fallback) =>
      sorted.isEmpty ? fallback : sorted[math.min(sorted.length - 1, (sorted.length * q).floor())];

  /// Narrowest speed range (m/s) a scale may have: 1.5 m/s (5.4 km/h) on foot, 6 m/s (22 km/h) in a vehicle.
  static const double minWalkSpanMs = 1.5;
  static const double minVehicleSpanMs = 6;

  static (double, double) _widen(double lo, double hi, double minSpan) {
    if (hi - lo >= minSpan) return (lo, hi);
    final mid = (lo + hi) / 2;
    final newLo = math.max(0.0, mid - minSpan / 2);
    return (newLo, newLo + minSpan);
  }

  static double slopeLimitFor(TravelMode mode) => switch (mode) {
        TravelMode.bike => 6,
        TravelMode.car => 8,
        TravelMode.water => 3,
        _ => 15,
      };

  static LineScale compute(LineColoring coloring, TravelMode mode, List<TrackPoint> pts, int i0, int i1, List<TravelMode> modeAt,
      List<double> speeds, List<double> alt) {
    final walk = <double>[], vehicle = <double>[];
    var vehiclePts = 0, otherPts = 0;
    for (var i = i0; i <= i1; i++) {
      final fast = modeAt[i] == TravelMode.car;
      if (fast) {
        vehiclePts++;
      } else {
        otherPts++;
      }
      if (speeds[i] > 0.5) (fast ? vehicle : walk).add(speeds[i]);
    }
    walk.sort();
    vehicle.sort();
    final split = vehicle.length >= 20 && walk.length >= 20 && vehiclePts > 0 && otherPts > 0;
    final all = [...walk, ...vehicle]..sort();
    // A narrow range (steady 4-5 km/h) would stretch noise over the whole palette: it is widened to a minimum span.
    final (wLo, wHi) = _widen(_percentile(split ? walk : all, 0.1, 0), _percentile(split ? walk : all, 0.9, 1), minWalkSpanMs);
    final (vLo, vHi) = _widen(_percentile(vehicle, 0.1, 0), _percentile(vehicle, 0.9, 1), minVehicleSpanMs);
    var aLo = 0.0, aHi = 1.0;
    if (alt.length > i1) {
      aLo = alt[i0];
      aHi = alt[i0];
      for (var i = i0; i <= i1; i++) {
        aLo = math.min(aLo, alt[i]);
        aHi = math.max(aHi, alt[i]);
      }
    }
    final mixedMotion = vehiclePts > 0 && otherPts > 0;
    return LineScale._(
      coloring,
      split,
      wLo,
      wHi,
      vLo,
      vHi,
      aLo,
      aHi,
      slopeLimitFor(mode),
      coloring == LineColoring.slope ? slopes(pts, alt, mode == TravelMode.bike ? 150 : 50) : const [],
      [for (var i = 0; i < pts.length; i++) mixedMotion && modeAt[i] == TravelMode.car],
      speeds,
      alt,
      modeAt,
    );
  }

  /// Slope in percent at every point: height change over a window of [windowM] metres of track centred on the
  /// point, so noise of single fixes cancels out. Points with no usable window get 0.
  static List<double> slopes(List<TrackPoint> pts, List<double> alt, double windowM) {
    final n = pts.length;
    final out = List<double>.filled(n, 0);
    if (n < 3 || alt.length != n) return out;
    final cum = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      final dt = pts[i].tsMs - pts[i - 1].tsMs;
      cum[i] = cum[i - 1] + (dt > 30000 ? 0 : haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon));
    }
    var lo = 0, hi = 0;
    for (var i = 0; i < n; i++) {
      while (lo < i && cum[i] - cum[lo] > windowM / 2) {
        lo++;
      }
      if (hi < i) hi = i;
      while (hi + 1 < n && cum[hi + 1] - cum[i] <= windowM / 2) {
        hi++;
      }
      final run = cum[hi] - cum[lo];
      if (run >= windowM * 0.6) out[i] = ((alt[hi] - alt[lo]) / run * 100).clamp(-60.0, 60.0);
    }
    return out;
  }

  /// Colour of the line at point [i].
  Color colorAt(int i) {
    switch (coloring) {
      case LineColoring.single:
      case LineColoring.relief:
        return brandAccent;
      case LineColoring.speed:
        final fast = split && _modeAt[i] == TravelMode.car;
        final lo = fast ? vehicleLo : walkLo, hi = fast ? vehicleHi : walkHi;
        return gradientColor(speedStops, hi > lo ? (_speeds[i] - lo) / (hi - lo) : 0.5);
      case LineColoring.height:
        return gradientColor(heightStops, heightHi - heightLo > 5 ? (_alt[i] - heightLo) / (heightHi - heightLo) : 0.5);
      case LineColoring.slope:
        return gradientColor(slopeStops, (slope[i] / slopeLimit + 1) / 2);
    }
  }
}
