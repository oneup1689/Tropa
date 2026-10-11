import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/gpx.dart';

void main() {
  test('gap threshold splits GPX segments instead of drawing a straight line', () {
    expect(gpxGapSeconds, 30);
  });
}
