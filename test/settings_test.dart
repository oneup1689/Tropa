import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/l10n.dart';
import 'package:tropa/modes.dart';
import 'package:tropa/settings.dart';
import 'package:tropa/units.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every pro-only setting has a default and amateur mode hides it', () {
    for (final d in settingDefs) {
      expect(d.defaultValue, isNotNull, reason: d.key);
    }
    final amateur = settingDefs.where((d) => !d.proOnly).map((d) => d.key);
    expect(amateur, contains('theme'));
    expect(amateur, isNot(contains('max_accuracy_m')));
  });

  test('values set in pro mode keep working after switching back to amateur', () async {
    final s = AppSettings.instance;
    await s.setPro(true);
    await s.set('heal_bridge_max_m', 200);
    await s.setPro(false);
    expect(s.pro, isFalse);
    expect(s.healFor(TravelMode.walk).walkLimit, 200);
    await s.resetAdvanced();
    expect(s.healFor(TravelMode.walk).walkLimit, 150); // 0 = automatic
  });

  test('GPS interval is chosen by the travel mode unless Pro overrides it', () async {
    final s = AppSettings.instance;
    await s.resetAdvanced();
    expect(s.fixIntervalMsFor(TravelMode.car), 1000);
    expect(s.fixIntervalMsFor(TravelMode.walk), 2000);
    await s.set('fix_interval_s', 5);
    expect(s.fixIntervalMsFor(TravelMode.car), 5000);
    await s.resetAdvanced();
  });

  test('miles exist only in the English interface and the switch repaints the screens', () async {
    final s = AppSettings.instance;
    await s.set('language', 'en');
    final before = L10n.revision.value;
    await s.set('imperial', true);
    expect(Units.imperial, isTrue);
    expect(L10n.revision.value, greaterThan(before));
    await s.set('language', 'ru'); // Russian is always metric, even with the switch on
    expect(Units.imperial, isFalse);
    await s.set('language', 'en');
    expect(Units.imperial, isTrue); // the choice is remembered
    await s.set('imperial', false);
    expect(Units.imperial, isFalse);
    await s.set('language', 'auto');
  });

  test('travel mode is remembered', () async {
    final s = AppSettings.instance;
    expect(s.travelMode, TravelMode.mixed); // default
    await s.setTravelMode(TravelMode.bike);
    expect(s.travelMode, TravelMode.bike);
    await s.setTravelMode(TravelMode.mixed);
  });

  test('theme setting drives the theme notifier', () async {
    final s = AppSettings.instance;
    await s.set('theme', 'dark');
    expect(s.themeNotifier.value, ThemeMode.dark);
    await s.set('theme', 'system');
    expect(s.themeNotifier.value, ThemeMode.system);
  });
}
