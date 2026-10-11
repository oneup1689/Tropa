import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/db.dart';
import 'package:tropa/heal.dart';
import 'package:tropa/modes.dart';
import 'package:tropa/stats.dart';

TrackPoint pt(int sec, double lat, double lon) => TrackPoint(sec * 1000, lat, lon, 5, 0, 0);

void main() {
  group('gap rules depend on the travel mode', () {
    final walk = HealSettings.forMode(TravelMode.walk);
    final bike = HealSettings.forMode(TravelMode.bike);
    final mixed = HealSettings.forMode(TravelMode.mixed);

    test('walking: a 300 m / 60 s gap (18 km/h) is not something a walker does -> stays open', () {
      expect(classifyGap(300, 60, walk), GapKind.keepBreak);
    });

    test('bike: a 300 m / 60 s gap (5 m/s) is bridged', () {
      expect(classifyGap(300, 60, bike), GapKind.bridge);
    });

    test('bike: a 600 m cycling gap is too long for a straight bridge', () {
      expect(classifyGap(600, 120, bike), GapKind.snapLater);
    });

    test('mixed: a car-speed gap within the car limit is bridged', () {
      expect(classifyGap(800, 60, mixed), GapKind.bridge); // 13 m/s
    });

    test('mixed: a walking gap still uses the short walking limit', () {
      expect(classifyGap(300, 400, mixed), GapKind.snapLater); // 0.75 m/s but > 150 m
    });

    test('anything faster than a car can plausibly go stays open', () {
      expect(classifyGap(5000, 60, mixed), GapKind.keepBreak);
    });
  });

  test('every mode has a sane recording profile', () {
    for (final m in TravelMode.values) {
      final p = profileOf(m);
      expect(p.intervalMs, inInclusiveRange(500, 5000));
      expect(p.jumpSpeedMs, greaterThan(p.movingSpeedMs));
    }
    expect(profileOf(TravelMode.car).intervalMs, lessThan(profileOf(TravelMode.walk).intervalMs));
  });

  group('stats', () {
    test('moving, paused and no-recording time are separated; jitter in a pause adds no distance', () {
      final pts = <TrackPoint>[
        // 10 steps of ~10 m in 5 s each: moving at 2 m/s
        for (var k = 0; k <= 10; k++) pt(k * 5, 20.0 + k * 0.00009, 105.0),
        // standing for 40 s with small jitter (~1 m)
        for (var k = 1; k <= 8; k++) pt(50 + k * 5, 20.0009 + (k.isEven ? 0.000005 : 0), 105.0),
        // 100 s without recording, then movement continues
        pt(240, 20.0015, 105.0),
        pt(245, 20.00159, 105.0),
      ];
      final s = computeStats(pts, movingSpeedMs: 0.5);
      expect(s.movingSeconds, closeTo(55, 6)); // 50 s walking + the first step after the gap
      expect(s.pausedSeconds, closeTo(40, 6));
      expect(s.gapSeconds, closeTo(150, 5)); // 90 -> 240 s is a gap
      expect(s.totalSeconds, 245);
      expect(s.distanceMeters, closeTo(110, 15)); // jitter and the gap are not counted
      expect(s.avgMovingSpeedMs, closeTo(2, 0.3));
    });

    test('a single noisy fix cannot set the maximum speed', () {
      final pts = [
        for (var k = 0; k < 20; k++) pt(k * 2, 20.0 + k * 0.00002, 105.0), // ~1.1 m/s
      ];
      // one wild fix 200 m away for a single second
      pts[10] = pt(20, 20.002, 105.0);
      final s = computeStats(pts);
      expect(s.maxSpeedMs, lessThan(30)); // a 5-point window dilutes one bad fix
    });
  });
}
