import 'dart:math' as math;

import 'db.dart';
import 'geoid.dart';

/// Altitude from air pressure (international standard atmosphere), metres above the 1013.25 hPa level.
double pressureAltitude(double hPa) => 44330.0 * (1 - math.pow(hPa / 1013.25, 1 / 5.255));

class ElevationStats {
  final double gain;
  final double loss;
  final double min;
  final double max;

  const ElevationStats(this.gain, this.loss, this.min, this.max);
}

/// Sea-level altitude for every point.
///
/// With a barometer: the barometer gives accurate *changes* (a few decimetres), while the weather
/// slowly shifts the absolute level, so the barometric curve is anchored to the GPS altitude
/// (corrected for the geoid) with a slow filter (time constant ~10 min). Without a barometer: GPS
/// altitude is median-filtered and smoothed.
List<double> fusedAltitude(List<TrackPoint> pts, {double Function(double lat, double lon)? geoid}) {
  if (pts.isEmpty) return const [];
  final undulation = geoid ?? Geoid.instance.undulation;

  final gps = [for (final p in pts) p.altitude - undulation(p.lat, p.lon)];
  final withBaro = pts.where((p) => p.pressure > 0).length;
  if (withBaro < pts.length * 0.5 || withBaro < 10) return _smoothGps(gps);

  // Barometric altitude with gaps filled by the previous value, lightly smoothed.
  final baro = List<double>.filled(pts.length, 0);
  double? last;
  for (var i = 0; i < pts.length; i++) {
    if (pts[i].pressure > 0) last = pressureAltitude(pts[i].pressure);
    baro[i] = last ?? double.nan;
  }
  final firstValid = baro.indexWhere((v) => !v.isNaN);
  for (var i = 0; i < firstValid; i++) {
    baro[i] = baro[firstValid];
  }
  final smooth = _movingAverage(baro, 5);

  // Initial offset: median over the first good GPS fixes.
  final diffs = <double>[];
  for (var i = 0; i < pts.length && diffs.length < 20; i++) {
    if (pts[i].accuracy > 0 && pts[i].accuracy <= 15 && pts[i].altitude != 0) diffs.add(gps[i] - smooth[i]);
  }
  if (diffs.isEmpty) return _smoothGps(gps);
  diffs.sort();
  var offset = diffs[diffs.length ~/ 2];

  const tau = 600.0; // seconds
  final out = List<double>.filled(pts.length, 0);
  for (var i = 0; i < pts.length; i++) {
    if (i > 0 && pts[i].accuracy > 0 && pts[i].accuracy <= 15 && pts[i].altitude != 0) {
      final dt = math.max(0.0, (pts[i].tsMs - pts[i - 1].tsMs) / 1000.0);
      final alpha = dt / (tau + dt);
      offset += alpha * ((gps[i] - smooth[i]) - offset);
    }
    out[i] = smooth[i] + offset;
  }
  return out;
}

List<double> _smoothGps(List<double> gps) {
  // Median of 7 then moving average of 5 removes the spikes typical for GPS altitude.
  final med = List<double>.generate(gps.length, (i) {
    final from = math.max(0, i - 3), to = math.min(gps.length, i + 4);
    final w = gps.sublist(from, to)..sort();
    return w[w.length ~/ 2];
  });
  return _movingAverage(med, 5);
}

List<double> _movingAverage(List<double> v, int window) {
  final half = window ~/ 2;
  return List<double>.generate(v.length, (i) {
    final from = math.max(0, i - half), to = math.min(v.length, i + half + 1);
    var s = 0.0;
    for (var j = from; j < to; j++) {
      s += v[j];
    }
    return s / (to - from);
  });
}

/// Total climb and descent, ignoring changes smaller than [threshold] metres (noise).
ElevationStats elevationStats(List<double> alt, {double threshold = 3}) {
  if (alt.isEmpty) return const ElevationStats(0, 0, 0, 0);
  var gain = 0.0, loss = 0.0;
  var ref = alt.first;
  var lo = alt.first, hi = alt.first;
  for (final a in alt) {
    lo = math.min(lo, a);
    hi = math.max(hi, a);
    if (a - ref >= threshold) {
      gain += a - ref;
      ref = a;
    } else if (ref - a >= threshold) {
      loss += ref - a;
      ref = a;
    }
  }
  return ElevationStats(gain, loss, lo, hi);
}
