import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/altitude.dart';
import 'package:tropa/db.dart';
import 'package:tropa/geoid.dart';
import 'package:tropa/routes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('geoid table gives sensible EGM96 values', () {
    final bytes = File('assets/geoid/egm96_half_deg.bin').readAsBytesSync();
    final g = Geoid.instance..loadFromBytes(bytes.buffer.asByteData());
    expect(g.loaded, isTrue);
    expect(g.undulation(21.03, 105.85), closeTo(-27.9, 1.5)); // Hanoi
    expect(g.undulation(55.75, 37.62), closeTo(14.6, 1.5)); // Moscow
  });

  group('fused altitude', () {
    // A 10-minute climb from 0 to 30 m at 5 s sampling. GPS reports ellipsoid height = MSL + N (N = -25 m)
    // with +-4 m noise; the barometer follows the true profile but with a weather offset of 40 m.
    List<TrackPoint> climb({required bool barometer}) {
      final rnd = math.Random(1);
      return [
        for (var i = 0; i <= 120; i++)
          TrackPoint(
            i * 5000,
            20.0 + i * 0.00002,
            105.0,
            5,
            (i * 0.25) - 25 + (rnd.nextDouble() - 0.5) * 8,
            1.0,
            pressure: barometer ? 1013.25 * math.pow(1 - (((i * 0.25) + 40) / 44330.0), 5.255).toDouble() : 0,
          ),
      ];
    }

    test('with a barometer the climb is measured cleanly and anchored to sea level', () {
      final alt = fusedAltitude(climb(barometer: true), geoid: (_, _) => -25);
      final es = elevationStats(alt);
      expect(es.gain, closeTo(30, 4));
      expect(es.loss, lessThan(3));
      expect(alt.first, closeTo(0, 6)); // sea level, not offset by the 40 m weather shift
    });

    test('without a barometer GPS noise is smoothed and the geoid is removed', () {
      final alt = fusedAltitude(climb(barometer: false), geoid: (_, _) => -25);
      expect(alt.first, closeTo(0, 6));
      expect(elevationStats(alt).gain, lessThan(45)); // noise alone must not invent hundreds of metres
    });
  });

  group('GPX import', () {
    test('track points are read in order', () {
      const gpx = '<gpx><trk><name>Ridge</name><trkseg>'
          '<trkpt lat="20.1" lon="105.1"/><trkpt lat="20.2" lon="105.2"/><trkpt lat="20.3" lon="105.3"/>'
          '</trkseg></trk></gpx>';
      final r = parseGpx(gpx)!;
      expect(r.name, 'Ridge');
      expect(r.points.length, 3);
      expect(r.points.last.lat, 20.3);
    });

    test('route points are used when there is no track', () {
      const gpx = '<gpx><rte><rtept lat="1" lon="2"/><rtept lat="1.1" lon="2.1"/></rte></gpx>';
      expect(parseGpx(gpx)!.points.length, 2);
    });

    test('garbage and one-point files are rejected', () {
      expect(parseGpx('not xml'), isNull);
      expect(parseGpx('<gpx><trk><trkseg><trkpt lat="1" lon="2"/></trkseg></trk></gpx>'), isNull);
    });
  });
}
