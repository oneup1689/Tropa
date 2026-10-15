import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/elevation.dart';
import 'package:tropa/maps.dart';
import 'package:tropa/route_profile.dart';

const _m = 1 / 111320;

({double lat, double lon}) _p(double northM) => (lat: 10 + northM * _m, lon: 106.0);

void main() {
  // A 400 m straight route (a point every 100 m); heights sampled at points 0, 2 and 4.
  final points = [for (var i = 0; i <= 4; i++) _p(i * 100.0)];
  const dem = DemSamples([0, 2, 4], [100.0, 140.0, 120.0], 'srtm');

  test('distances follow the route, heights stay as sampled', () {
    final d = routeProfileSeries(points, dem);
    expect(d.dist.first, 0);
    expect(d.dist[1], closeTo(200, 2));
    expect(d.lengthM, closeTo(400, 3));
    expect(d.elev, [100.0, 140.0, 120.0]);
    expect(d.meaningful, isTrue);
  });

  test('walked in reverse the series starts at the other end', () {
    final d = routeProfileSeries(points, dem, reverse: true);
    expect(d.elev, [120.0, 140.0, 100.0]);
    expect(d.dist.first, 0);
    expect(d.dist.last, closeTo(400, 3));
  });

  test('a nearly flat route is not worth a chart', () {
    final flat = routeProfileSeries(points, const DemSamples([0, 2, 4], [100.0, 104.0, 102.0], 'srtm'));
    expect(flat.meaningful, isFalse);
  });

  test('a map region covers a route only when it contains the whole frame', () {
    const region = RegionBounds(105.0, 20.0, 106.0, 21.0);
    expect(region.containsBox(20.2, 105.2, 20.8, 105.8), isTrue);
    expect(region.containsBox(20.2, 105.2, 21.4, 105.8), isFalse); // sticks out to the north
    expect(region.containsBox(19.5, 105.2, 20.8, 105.8), isFalse);
  });
}
