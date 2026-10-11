import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/db.dart';
import 'package:tropa/gpx.dart';
import 'package:tropa/heal.dart';

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
    });
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
