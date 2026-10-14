import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/routes.dart';

void main() {
  test('a saved route is written as GPX and read back', () {
    final pts = [(lat: 20.25, lon: 105.97), (lat: 20.2512, lon: 105.9711), (lat: 20.2525, lon: 105.9725)];
    final gpx = routeToGpx('Набережная & парк', pts);
    final parsed = parseGpx(gpx);
    expect(parsed, isNotNull);
    expect(parsed!.name, 'Набережная & парк');
    expect(parsed.points.length, 3);
    expect(parsed.points.first.lat, closeTo(20.25, 1e-6));
  });

  test('thinning keeps the ends and a point about every 10 m', () {
    // 600 points, 2 m apart along a line (1.2 km): about 120 points remain.
    final pts = [for (var i = 0; i < 600; i++) (lat: 20.0 + i * 2 / 111320, lon: 105.0)];
    final thin = thinToRoute(pts);
    expect(thin.first, pts.first);
    expect(thin.last, pts.last);
    expect(thin.length, inInclusiveRange(100, 140));
  });

  test('a very short track is not thinned', () {
    final pts = [(lat: 20.0, lon: 105.0), (lat: 20.001, lon: 105.0)];
    expect(thinToRoute(pts), pts);
  });
}
