import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/modes.dart';
import 'package:tropa/route_estimate.dart';

void main() {
  test('walking pace is 4.5 km/h by length alone', () {
    expect(estimateRouteTime(9000).inMinutes, 120);
  });

  test('climbing adds an hour per 600 m on foot', () {
    expect(estimateRouteTime(9000, ascentM: 600).inMinutes, 180);
  });

  test('bike is faster; the car ignores the climb', () {
    expect(estimateRouteTime(30000, mode: TravelMode.bike).inMinutes, 120);
    expect(estimateRouteTime(40000, ascentM: 900, mode: TravelMode.car).inMinutes, 60);
  });
}
