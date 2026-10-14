import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/l10n.dart';
import 'package:tropa/readiness.dart';

ReadinessSnapshot snap({
  bool gps = true,
  LocationAccess loc = LocationAccess.always,
  bool? notif = true,
  bool? battOpt = true,
  int? pct = 80,
  bool? saver = false,
}) =>
    ReadinessSnapshot(gpsOn: gps, location: loc, notifications: notif, batteryUnrestricted: battOpt, batteryPercent: pct, batterySaver: saver);

void main() {
  setUp(() => L10n.set(AppLang.ru));

  test('everything fine: ready', () {
    final r = evaluateReadiness(snap());
    expect(r.level, ReadyLevel.ready);
    expect(r.problems, isEmpty);
    expect(r.label, 'ГОТОВ К ПРОГУЛКЕ');
  });

  test('GPS off blocks and the pill says so', () {
    final r = evaluateReadiness(snap(gps: false));
    expect(r.level, ReadyLevel.blocked);
    expect(r.label, 'GPS ВЫКЛЮЧЕН');
    expect(r.problems.single.id, 'gps');
    expect(r.problems.single.fixLabel, isNotNull);
  });

  test('no location permission blocks; GPS off wins as the first reason', () {
    final r = evaluateReadiness(snap(gps: false, loc: LocationAccess.none));
    expect(r.level, ReadyLevel.blocked);
    expect(r.label, 'GPS ВЫКЛЮЧЕН');
    expect(r.problems.map((i) => i.id), ['gps', 'location']);
    expect(evaluateReadiness(snap(loc: LocationAccess.none)).label, 'НЕТ ДОСТУПА К GPS');
  });

  test('"while in use" and battery trouble are only warnings and are counted', () {
    final r = evaluateReadiness(snap(loc: LocationAccess.whileInUse, battOpt: false, pct: 10));
    expect(r.level, ReadyLevel.warning);
    expect(r.problems.map((i) => i.id), ['location', 'battery_opt', 'charge']);
    expect(r.label, 'ЕСТЬ ЗАМЕЧАНИЯ: 3');
  });

  test('platform-less fields (iPhone) are skipped, battery saver is a warning', () {
    final r = evaluateReadiness(snap(notif: null, battOpt: null, saver: true));
    expect(r.items.map((i) => i.id), ['gps', 'location', 'saver']);
    expect(r.level, ReadyLevel.warning);
  });

  test('the English labels exist', () {
    L10n.set(AppLang.en);
    expect(evaluateReadiness(snap(gps: false)).label, 'GPS IS OFF');
    expect(evaluateReadiness(snap(loc: LocationAccess.whileInUse)).label, 'NOTES: 1');
  });
}
