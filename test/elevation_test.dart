import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/db.dart';
import 'package:tropa/elevation.dart';

/// A straight track along a meridian, one point every 10 m (about 0.00009 deg of latitude).
List<TrackPoint> line(int n) => [for (var i = 0; i < n; i++) TrackPoint(1000000000000 + i * 5000, 20 + i * 0.00009, 105.9, 5, 0, 1.4)];

void main() {
  test('samples are spaced along the path and include both ends', () {
    final pts = line(200); // ~2 km
    final idx = demSampleIndexes(pts);
    expect(idx.first, 0);
    expect(idx.last, 199);
    expect(idx.length, inInclusiveRange(40, 60)); // 40 m spacing
  });

  test('at most maxSamples samples for a very long walk', () {
    final idx = demSampleIndexes(line(20000), maxSamples: 300);
    expect(idx.length, lessThanOrEqualTo(302));
  });

  test('slow GPS drift on flat ground is removed using the terrain model', () {
    final pts = line(300);
    final dem = DemSamples(demSampleIndexes(pts), [for (final _ in demSampleIndexes(pts)) 10.0], 'srtm30');
    // GPS reads 25 m too high: flat ground, so the model is trusted for the offset.
    final gps = List<double>.filled(300, 35);
    final fused = fuseWithDem(gps, dem);
    expect(fused[150], closeTo(10, 1.5));
  });

  test('a narrow peak that the model smooths away is still mostly kept from GPS', () {
    final pts = line(300);
    final idx = demSampleIndexes(pts);
    // Real shape: flat at 0 m with a 100 m spike in the middle. The model only sees a 60 m bump (smoothed).
    final gps = [for (var i = 0; i < 300; i++) (i > 140 && i < 160) ? 100.0 : 0.0];
    final elev = [for (final i in idx) (i > 130 && i < 170) ? 60.0 : 0.0];
    final fused = fuseWithDem(gps, DemSamples(idx, elev, 'srtm30'));
    final top = fused.reduce((a, b) => a > b ? a : b);
    expect(top, greaterThan(75)); // closer to GPS (100) than to the model (60)
    expect(top, lessThan(100));
    expect(fused.first, closeTo(0, 3)); // the flat parts agree
  });

  test('stored samples survive JSON', () {
    const d = DemSamples([0, 5, 9], [1.5, 2.5, 3.5], 'srtm30');
    final back = DemSamples.fromJson(d.toJson());
    expect(back.idx, [0, 5, 9]);
    expect(back.elev, [1.5, 2.5, 3.5]);
    expect(back.source, 'srtm30');
  });
}
