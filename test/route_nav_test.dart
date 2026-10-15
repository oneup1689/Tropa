import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/heal.dart';
import 'package:tropa/route_nav.dart';

const _m = 1 / 111320; // degrees of latitude per metre

LatLon _p(double northM, double eastM) => LatLon(10 + northM * _m, 106 + eastM * _m); // cos(10 deg) ~ 0.985, fine here

/// Straight legs given as (north, east) corners; every 20 m a point is added.
List<LatLon> _route(List<(double, double)> corners) {
  final out = <LatLon>[];
  for (var i = 1; i < corners.length; i++) {
    final a = corners[i - 1], b = corners[i];
    final len = ((b.$1 - a.$1) * (b.$1 - a.$1) + (b.$2 - a.$2) * (b.$2 - a.$2));
    final steps = (len == 0 ? 1 : (len / 400)).clamp(1, 1e9).ceil();
    for (var s = 0; s < steps; s++) {
      final f = s / steps;
      out.add(_p(a.$1 + (b.$1 - a.$1) * f, a.$2 + (b.$2 - a.$2) * f));
    }
  }
  out.add(_p(corners.last.$1, corners.last.$2));
  return out;
}

void main() {
  final lShape = _route([(0, 0), (300, 0), (300, 300)]); // north, then east: one right turn

  test('finds one right turn at the corner', () {
    final path = RoutePath.build(lShape);
    expect(path.maneuvers.length, 1);
    expect(path.maneuvers.first.turn, Turn.right);
    expect(path.maneuvers.first.at, closeTo(300, 12));
    expect(path.lengthM, closeTo(600, 6));
  });

  test('reversed route turns the other way', () {
    final path = RoutePath.build(lShape, reverse: true);
    expect(path.maneuvers.length, 1);
    expect(path.maneuvers.first.turn, Turn.left);
  });

  test('a straight line and a gentle curve have no turns', () {
    expect(RoutePath.build(_route([(0, 0), (500, 0)])).maneuvers, isEmpty);
    final curve = <LatLon>[];
    for (var i = 0; i <= 60; i++) {
      final a = i * 0.5 * 3.14159 / 180 * 1.0; // 30 degrees over 300 m
      curve.add(_p(i * 5.0 * (1 - a * a / 2), i * 5.0 * a));
    }
    expect(RoutePath.build(curve).maneuvers, isEmpty);
  });

  test('U-turn and sharp turn are classified', () {
    final u = RoutePath.build(_route([(0, 0), (200, 0), (200, 6), (0, 6)]));
    expect(u.maneuvers.any((m) => m.turn == Turn.uTurn || m.turn == Turn.sharpRight), isTrue);
  });

  test('warns once at 100 m and once at 30 m, then reports arrival', () {
    final path = RoutePath.build(lShape);
    final nav = NavEngine(path);
    final alerts = <NavAlert>[];
    NavState? s;
    for (var d = 0.0; d <= 300; d += 5) {
      s = nav.update(_p(d, 0).lat, _p(d, 0).lon);
      if (s.alert != null) alerts.add(s.alert!);
    }
    expect(alerts.length, 2);
    expect(alerts[0].near, isFalse);
    expect(alerts[0].distM, closeTo(100, 8));
    expect(alerts[1].near, isTrue);
    expect(alerts[1].distM, closeTo(30, 8));
    for (var e = 5.0; e <= 300; e += 5) {
      s = nav.update(_p(300, e).lat, _p(300, e).lon);
    }
    expect(s!.arrived, isTrue);
    expect(s.remainingM, lessThan(25));
  });

  test('off-route distance is reported and progress is kept', () {
    final nav = NavEngine(RoutePath.build(lShape));
    nav.update(_p(100, 0).lat, _p(100, 0).lon);
    final s = nav.update(_p(110, 150).lat, _p(110, 150).lon); // 150 m east of the line
    expect(s.offM, greaterThan(100));
    expect(s.progressM, closeTo(100, 15));
  });

  test('a loop does not jump to the end at the start point', () {
    final loop = _route([(0, 0), (300, 0), (300, 300), (0, 300), (0, 0)]);
    final nav = NavEngine(RoutePath.build(loop));
    var s = nav.update(_p(0, 0).lat, _p(0, 0).lon);
    expect(s.progressM, lessThan(10));
    expect(s.arrived, isFalse);
    for (var d = 0.0; d <= 300; d += 5) {
      s = nav.update(_p(d, 0).lat, _p(d, 0).lon);
    }
    expect(s.progressM, closeTo(300, 15));
    expect(s.arrived, isFalse);
  });
}
