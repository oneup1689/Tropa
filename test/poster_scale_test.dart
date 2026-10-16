import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/db.dart';
import 'package:tropa/modes.dart';
import 'package:tropa/poster_scale.dart';
import 'package:tropa/stats.dart';

const double _mPerDegLon = 104500.0; // at ~20 deg latitude
const double _mPerDegLat = 111000.0;

/// An eastbound track: one point every 2 s from (speed m/s, seconds, climb m/s) legs.
List<TrackPoint> _track(List<(double, int, double)> legs) {
  final pts = <TrackPoint>[];
  var t = 1000000000000, lon = 105.9, h = 10.0;
  pts.add(TrackPoint(t, 20.2, lon, 5, h, 0));
  for (final (v, secs, climb) in legs) {
    for (var s = 2; s <= secs; s += 2) {
      t += 2000;
      lon += v * 2 / _mPerDegLon;
      h += climb * 2;
      pts.add(TrackPoint(t, 20.2, lon, 5, h, v));
    }
  }
  return pts;
}

void main() {
  test('slope is positive uphill, negative downhill and near zero on the flat', () {
    // 200 s at 1.4 m/s: 10 % up, then flat, then 10 % down.
    final pts = _track([(1.4, 200, 0.14), (1.4, 200, 0), (1.4, 200, -0.14)]);
    final alt = [for (final p in pts) p.altitude];
    final s = LineScale.slopes(pts, alt, 50);
    expect(s[pts.length ~/ 6], closeTo(10, 2));
    expect(s[pts.length ~/ 2], closeTo(0, 1));
    expect(s[pts.length * 5 ~/ 6], closeTo(-10, 2));
  });

  test('slope colouring needs some relief', () {
    final flat = _track([(1.4, 300, 0.001)]);
    final hill = _track([(1.4, 300, 0.1)]);
    expect(slopeAvailable([for (final p in flat) p.altitude], 0, flat.length - 1), false);
    expect(slopeAvailable([for (final p in hill) p.altitude], 0, hill.length - 1), true);
  });

  test('relief: flat, one climb and many ups and downs are told apart', () {
    List<double> up(int n, double from, double to) => [for (var i = 0; i < n; i++) from + (to - from) * i / (n - 1)];
    final flat = up(100, 100, 105);
    expect(pickRelief(flat, 0, flat.length - 1), LineColoring.single);
    final climb = [...up(100, 100, 260), ...up(100, 260, 100)]; // up a hill and back: total 2x the range
    expect(pickRelief(climb, 0, climb.length - 1), LineColoring.height);
    final rolling = <double>[];
    for (var k = 0; k < 8; k++) {
      rolling.addAll(up(30, 100, 160));
      rolling.addAll(up(30, 160, 100));
    }
    expect(pickRelief(rolling, 0, rolling.length - 1), LineColoring.slope); // 16 x 60 m over a range of 60 m
    final small = [...up(50, 100, 125), ...up(50, 125, 100)];
    expect(pickRelief(small, 0, small.length - 1), LineColoring.height); // 25 m: too little for slopes
  });

  test('a walk with a taxi ride gets separate speed scales and a dashed vehicle stretch', () {
    final pts = _track([(1.4, 300, 0), (12.0, 240, 0), (1.4, 120, 0)]);
    final speeds = [for (final p in pts) p.speed];
    final modeAt = [
      for (var i = 0; i < pts.length; i++)
        (pts[i].tsMs - pts.first.tsMs) ~/ 1000 >= 300 && (pts[i].tsMs - pts.first.tsMs) ~/ 1000 < 540 ? TravelMode.car : TravelMode.walk
    ];
    final alt = [for (final p in pts) p.altitude];
    final scale = LineScale.compute(LineColoring.speed, TravelMode.walk, pts, 0, pts.length - 1, modeAt, speeds, alt);
    expect(scale.split, true);
    expect(scale.walkHi, lessThan(3));
    expect(scale.vehicleLo, greaterThan(8));
    expect(scale.vehicleAt[pts.length ~/ 2], true);
    expect(scale.vehicleAt[2], false);
    // The same position on the scale means a different speed for each kind: walking at its top end is as "hot" as the taxi.
    expect(scale.colorAt(2), scale.colorAt(pts.length ~/ 2));
  });

  test('an all-walking track has one scale and no dashes', () {
    final pts = _track([(1.4, 300, 0)]);
    final speeds = [for (final p in pts) p.speed];
    final modeAt = List<TravelMode>.filled(pts.length, TravelMode.walk);
    final alt = [for (final p in pts) p.altitude];
    final scale = LineScale.compute(LineColoring.speed, TravelMode.walk, pts, 0, pts.length - 1, modeAt, speeds, alt);
    expect(scale.split, false);
    expect(scale.vehicleAt.contains(true), false);
  });

  test('a long silence that ends where it began is "indoors", not a gap', () {
    // 60 s of walking, 40 minutes of nothing at the same place, 60 s of walking.
    final first = _track([(1.4, 60, 0)]);
    final last = first.last;
    final pts = [
      ...first,
      TrackPoint(last.tsMs + 40 * 60 * 1000, last.lat + 5 / _mPerDegLat, last.lon, 5, 10, 0),
      TrackPoint(last.tsMs + 40 * 60 * 1000 + 2000, last.lat + 5 / _mPerDegLat, last.lon + 2.8 / _mPerDegLon, 5, 10, 1.4),
    ];
    final st = computeStats(pts);
    expect(st.indoorSeconds, closeTo(40 * 60, 5));
    expect(st.gapSeconds, 0);
  });

  test('a long silence with a big displacement stays a gap', () {
    final first = _track([(1.4, 60, 0)]);
    final last = first.last;
    final pts = [
      ...first,
      TrackPoint(last.tsMs + 20 * 60 * 1000, last.lat + 3000 / _mPerDegLat, last.lon, 5, 10, 0),
    ];
    final st = computeStats(pts);
    expect(st.indoorSeconds, 0);
    expect(st.gapSeconds, closeTo(20 * 60, 5));
  });
}
