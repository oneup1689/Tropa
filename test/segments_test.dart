import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/db.dart';
import 'package:tropa/modes.dart';
import 'package:tropa/segments.dart';

/// Builds a straight eastbound track from (speed m/s, seconds) legs, one point every 2 s.
List<TrackPoint> track(List<(double, int)> legs) {
  const mPerDegLon = 104500.0; // at ~20 deg latitude
  final pts = <TrackPoint>[];
  var t = 1000000000000, lon = 105.9;
  pts.add(TrackPoint(t, 20.2, lon, 5, 10, 0));
  for (final (v, secs) in legs) {
    for (var s = 2; s <= secs; s += 2) {
      t += 2000;
      lon += v * 2 / mPerDegLon;
      pts.add(TrackPoint(t, 20.2, lon, 5, 10, v));
    }
  }
  return pts;
}

void main() {
  test('walk, drive, walk is split into three stretches', () {
    final pts = track([(1.4, 300), (11.0, 240), (1.4, 300)]);
    final segs = buildSegments(pts, TravelMode.mixed);
    expect(segs.map((s) => s.mode).toList(), [TravelMode.walk, TravelMode.car, TravelMode.walk]);
    // The switch is detected close to the real boundaries (300 s and 540 s).
    expect((segs[0].endMs - pts.first.tsMs) / 1000, closeTo(300, 30));
    expect((segs[1].endMs - pts.first.tsMs) / 1000, closeTo(540, 30));
    expect(segs[1].stats.distanceMeters, closeTo(11 * 240, 400));
  });

  test('a short stop in traffic does not end the vehicle stretch', () {
    final pts = track([(1.4, 120), (10.0, 120), (0.0, 50), (10.0, 120), (1.4, 120)]);
    final segs = buildSegments(pts, TravelMode.mixed);
    expect(segs.map((s) => s.mode).toList(), [TravelMode.walk, TravelMode.car, TravelMode.walk]);
  });

  test('a brief burst of speed is not a vehicle', () {
    final pts = track([(1.4, 200), (4.0, 20), (1.4, 200)]);
    final segs = buildSegments(pts, TravelMode.mixed);
    expect(segs.length, 1);
    expect(segs.single.mode, TravelMode.walk);
  });

  test('a walk that turns into a taxi ride is split even in walk mode', () {
    final pts = track([(1.4, 300), (11.0, 240), (1.4, 120)]);
    final segs = buildSegments(pts, TravelMode.walk);
    expect(segs.map((s) => s.mode).toList(), [TravelMode.walk, TravelMode.car, TravelMode.walk]);
  });

  test('a mode chosen before the start is kept for the whole walk', () {
    final pts = track([(1.4, 200), (11.0, 200)]);
    for (final m in [TravelMode.bike, TravelMode.water]) {
      final segs = buildSegments(pts, m);
      expect(segs.length, 1);
      expect(segs.single.mode, m);
    }
  });

  test('a manual correction overrides the automatic mode', () {
    final pts = track([(1.4, 300), (11.0, 240), (1.4, 300)]);
    final auto = buildSegments(pts, TravelMode.mixed);
    final drive = auto[1];
    final fixed = buildSegments(pts, TravelMode.mixed,
        overrides: [SegmentOverride(drive.startMs, drive.endMs, TravelMode.water)]);
    expect(fixed.map((s) => s.mode).toList(), [TravelMode.walk, TravelMode.water, TravelMode.walk]);
    // Correcting it back to walking merges everything into one stretch.
    final all = buildSegments(pts, TravelMode.mixed,
        overrides: [SegmentOverride(drive.startMs, drive.endMs, TravelMode.walk)]);
    expect(all.length, 1);
  });
}
