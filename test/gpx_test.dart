import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/db.dart';
import 'package:tropa/gpx.dart';
import 'package:tropa/heal.dart';
import 'package:tropa/trim.dart';

TrackPoint pt(int sec, double lat, double lon) => TrackPoint(sec * 1000, lat, lon, 5, 0, 0);

void main() {
  test('gap threshold splits GPX segments instead of drawing a straight line', () {
    expect(gpxGapSeconds, 30);
  });

  group('gap classification', () {
    const s = HealSettings();

    test('same place is glued', () {
      expect(classifyGap(3, 54, s), GapKind.glueStill);
    });

    test('short walkable gap is bridged', () {
      expect(classifyGap(122, 199, s), GapKind.bridge);
    });

    test('long walkable gap is NOT bridged with a straight line', () {
      expect(classifyGap(323, 386, s), GapKind.snapLater);
    });

    test('too fast for walking is kept as a break', () {
      expect(classifyGap(140, 20, s), GapKind.keepBreak);
    });

    test('very long gap is kept as a break', () {
      expect(classifyGap(100, 30 * 60, s), GapKind.keepBreak);
      expect(classifyGap(10, 50 * 60, s), GapKind.glueStill); // long stop in one place loses nothing
    });
  });

  group('smooth bridge curve', () {
    // A path walking north, a gap, then continuing north: the curve should stay almost straight.
    List<TrackPoint> northWalk({double offsetLon = 0}) => [
          for (var k = 0; k < 6; k++) pt(k * 3, 20.0 + k * 0.00009, 105.0),
          for (var k = 0; k < 6; k++) pt(150 + k * 3, 20.0012 + k * 0.00009, 105.0 + offsetLon),
        ];

    test('collinear gap gives an almost straight curve', () {
      final pts = northWalk();
      final c = bridgeCurve(pts, 6);
      expect(c, isNotEmpty);
      for (final p in c) {
        expect((p.lon - 105.0).abs() * 111320 * 0.94, lessThan(2)); // within 2 m of the line
      }
    });

    test('curve bends toward the side where the route continues, not into a straight chord', () {
      // Walks north, then the route continues about 30 m east: curve should be smooth, with all points between.
      final pts = northWalk(offsetLon: 0.00029);
      final c = bridgeCurve(pts, 6);
      expect(c, isNotEmpty);
      // every curve point lies between the two edge longitudes (plus a little overshoot)
      for (final p in c) {
        expect(p.lon, inInclusiveRange(105.0 - 0.0001, 105.00029 + 0.0001));
      }
    });

    test('returns nothing when the heading cannot be determined', () {
      final pts = [pt(0, 20.0, 105.0), pt(150, 20.001, 105.0)];
      expect(bridgeCurve(pts, 1), isEmpty);
    });
  });

  test('trimEnds cuts only the ends and never extends', () {
    final pts = [for (var k = 0; k < 20; k++) pt(k * 3, 20.0 + k * 0.00009, 105.0)]; // ~10 m per point
    final t = trimEnds(pts, 30, 30);
    expect(t.length, lessThan(pts.length));
    expect(t.first.tsMs, greaterThan(pts.first.tsMs));
    expect(t.last.tsMs, lessThan(pts.last.tsMs));
    expect(pts.contains(t.first), isTrue); // only original points survive
    expect(trimEnds(pts, 1000, 1000), isEmpty); // nothing left to share
    expect(trimEnds(pts, 0, 0).length, pts.length);
  });

  test('analyzeGaps counts only continuous distance as recorded', () {
    // 0.001 deg lat is about 111 m. Two close points, then a 100 s gap with ~111 m jump.
    final pts = [
      pt(0, 20.000, 105.0),
      pt(5, 20.0001, 105.0),
      pt(105, 20.0011, 105.0),
    ];
    final r = analyzeGaps(pts);
    expect(r.gaps.length, 1);
    expect(r.gaps.first.index, 2);
    expect(r.gaps.first.kind, GapKind.bridge);
    expect(r.recordedMeters, closeTo(11, 2));
    expect(r.restoredMeters, closeTo(111, 3));
  });
}
