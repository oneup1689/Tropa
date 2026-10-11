import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/settings.dart';

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
    expect(s.healSettings.bridgeMaxMeters, 200);
    await s.resetAdvanced();
    expect(s.healSettings.bridgeMaxMeters, 150);
  });

  test('theme setting drives the theme notifier', () async {
    final s = AppSettings.instance;
    await s.set('theme', 'dark');
    expect(s.themeNotifier.value, ThemeMode.dark);
    await s.set('theme', 'system');
    expect(s.themeNotifier.value, ThemeMode.system);
  });
}
