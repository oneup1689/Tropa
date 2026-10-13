import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/l10n.dart';
import 'package:tropa/l10n_en.dart';
import 'package:tropa/units.dart';

void main() {
  tearDown(() {
    L10n.set(AppLang.ru);
    Units.system = UnitSystem.metric;
  });

  test('every English text keeps the placeholders of the Russian one', () {
    final ph = RegExp(r'\{(\w+)\}');
    for (final e in enStrings.entries) {
      final ru = ph.allMatches(e.key).map((m) => m.group(1)).toSet();
      final en = ph.allMatches(e.value).map((m) => m.group(1)).toSet();
      expect(en, ru, reason: 'placeholders differ in "${e.key}"');
      expect(e.value.trim().isNotEmpty, true);
    }
  });

  test('t() translates, fills placeholders and falls back to the Russian text', () {
    expect(t('Остановить'), 'Остановить');
    L10n.set(AppLang.en);
    expect(t('Остановить'), 'Stop');
    expect(t('Вы в {d} от маршрута', {'d': '50 m'}), 'You are 50 m from the route');
    expect(t('Нет такого перевода'), 'Нет такого перевода');
  });

  test('the language of the phone', () {
    expect(L10n.fromSystem('ru'), AppLang.ru);
    expect(L10n.fromSystem('uk'), AppLang.ru);
    expect(L10n.fromSystem('en'), AppLang.en);
    expect(L10n.fromSystem('de'), AppLang.en);
  });

  test('Russian plural forms', () {
    String w(int n) => plural(n, 'регион', 'региона', 'регионов', en1: 'region', enN: 'regions');
    expect([w(1), w(2), w(5), w(11), w(21), w(22), w(25)], ['регион', 'региона', 'регионов', 'регионов', 'регион', 'региона', 'регионов']);
    L10n.set(AppLang.en);
    expect([w(1), w(2)], ['region', 'regions']);
  });

  test('precipitation in millimetres or inches', () {
    expect(Units.precip(1.5), '1.5 мм');
    L10n.set(AppLang.en);
    Units.system = UnitSystem.imperial;
    expect(Units.precip(2.54), '0.10 in');
  });

  test('units: kilometres or miles, km/h or mph, min/km or min/mi, metres or feet', () {
    expect(Units.dist(1500, digits: 1), '1.5 км');
    expect(Units.speed(10), '36.0 км/ч');
    expect(Units.pace(15.5), '15:30 мин/км');
    expect(Units.shortDist(120), '120 м');
    expect(Units.temp(20), '20°');
    L10n.set(AppLang.en);
    Units.system = UnitSystem.imperial;
    expect(Units.dist(1609.344, digits: 1), '1.0 mi');
    expect(Units.speed(10), '22.4 mph');
    expect(Units.pace(10), '16:06 min/mi');
    expect(Units.shortDist(100), '328 ft');
    expect(Units.temp(20), '68°F');
  });
}
