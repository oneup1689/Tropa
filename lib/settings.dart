import 'debug_log.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'heal.dart';
import 'l10n.dart';
import 'modes.dart';
import 'units.dart';

enum SettingKind { toggle, choice, number }

/// One user-facing setting. [proOnly] settings are hidden from the "Любитель"
/// screen but keep their stored value and keep working.
class SettingDef {
  final String key;
  final String title;
  final String subtitle;
  final String section;
  final SettingKind kind;
  final Object defaultValue;
  final bool proOnly;

  /// Shown only in the English interface (the Russian one is always metric).
  final bool englishOnly;
  final List<(String, String)> options; // choice: (stored value, label)
  final double min;
  final double max;
  final double step;
  final String unit;

  /// For numbers: 0 means "choose automatically" (by travel mode) and is shown as "авто".
  final bool zeroMeansAuto;

  const SettingDef({
    required this.key,
    required this.title,
    required this.section,
    required this.kind,
    required this.defaultValue,
    this.subtitle = '',
    this.proOnly = false,
    this.englishOnly = false,
    this.options = const [],
    this.min = 0,
    this.max = 0,
    this.step = 1,
    this.unit = '',
    this.zeroMeansAuto = false,
  });
}

/// Registry of all settings. New features add their settings here and the
/// settings screen picks them up; amateur mode shows only the non-pro ones.
const List<SettingDef> settingDefs = [
  SettingDef(
    key: 'theme',
    title: 'Тема оформления',
    section: 'Оформление',
    kind: SettingKind.choice,
    defaultValue: 'system',
    options: [('system', 'Как на смартфоне'), ('light', 'Светлая'), ('dark', 'Тёмная')],
  ),
  SettingDef(
    key: 'language',
    title: 'Язык',
    section: 'Язык и единицы',
    kind: SettingKind.choice,
    defaultValue: 'auto',
    options: [('auto', 'Как в телефоне'), ('ru', 'Русский'), ('en', 'English')],
  ),
  SettingDef(
    key: 'imperial',
    title: 'Мили и футы',
    subtitle: 'Выключено: километры и метры',
    section: 'Язык и единицы',
    kind: SettingKind.toggle,
    defaultValue: false,
    englishOnly: true,
  ),
  SettingDef(
    key: 'temp_unit',
    title: 'Температура',
    subtitle: 'Можно оставить °C при милях (или наоборот)',
    section: 'Язык и единицы',
    kind: SettingKind.choice,
    defaultValue: 'auto',
    proOnly: true,
    englishOnly: true,
    options: [('auto', 'Как расстояния'), ('c', '°C'), ('f', '°F')],
  ),
  SettingDef(
    key: 'auto_mode',
    title: 'Автозапись 24/7',
    subtitle: 'Запись начнётся сама, когда вы пойдёте, и закончится после нескольких минут без движения. '
        'В остальное время GPS выключен и батарея почти не тратится.',
    section: 'Автоматическая запись',
    kind: SettingKind.toggle,
    defaultValue: false,
  ),
  SettingDef(
    key: 'day_split',
    title: 'Как делить на прогулки',
    subtitle: 'По паузе: новая прогулка после остановки движения. По полуночи: каждый день отдельный файл',
    section: 'Автоматическая запись',
    kind: SettingKind.choice,
    defaultValue: 'idle',
    proOnly: true,
    options: [('idle', 'По паузе'), ('midnight', 'По полуночи')],
  ),
  SettingDef(
    key: 'idle_minutes',
    title: 'Пауза, после которой запись заканчивается',
    section: 'Автоматическая запись',
    kind: SettingKind.number,
    defaultValue: 5,
    proOnly: true,
    min: 2,
    max: 30,
    step: 1,
    unit: 'мин',
  ),
  SettingDef(
    key: 'max_accuracy_m',
    title: 'Порог точности GPS',
    subtitle: 'Точки с худшей точностью не записываются',
    section: 'Запись',
    kind: SettingKind.number,
    defaultValue: 50,
    proOnly: true,
    min: 15,
    max: 100,
    step: 5,
    unit: 'м',
  ),
  SettingDef(
    key: 'fix_interval_s',
    title: 'Интервал опроса GPS',
    subtitle: 'Авто — подбирается по режиму путешествия. Чаще — точнее маршрут, но быстрее садится батарея',
    section: 'Запись',
    kind: SettingKind.number,
    defaultValue: 0,
    proOnly: true,
    min: 0,
    max: 10,
    step: 1,
    unit: 'с',
    zeroMeansAuto: true,
  ),
  SettingDef(
    key: 'autopause',
    title: 'Автопауза',
    subtitle: 'На стоянке GPS опрашивается реже (раз в 5 с), чтобы экономить батарею',
    section: 'Запись',
    kind: SettingKind.toggle,
    defaultValue: true,
    proOnly: true,
  ),
  SettingDef(
    key: 'heal_enabled',
    title: 'Склеивать короткие разрывы',
    subtitle: 'По умолчанию для просмотра и экспорта GPX',
    section: 'Маршрут и данные',
    kind: SettingKind.toggle,
    defaultValue: true,
    proOnly: true,
  ),
  SettingDef(
    key: 'trim_start_m',
    title: 'Обрезать начало маршрута',
    subtitle: 'Убирает первые метры при экспорте (например, чтобы не показывать дом). Маршрут не меняется и не удлиняется.',
    section: 'Маршрут и данные',
    kind: SettingKind.number,
    defaultValue: 0,
    proOnly: true,
    min: 0,
    max: 500,
    step: 25,
    unit: 'м',
  ),
  SettingDef(
    key: 'trim_end_m',
    title: 'Обрезать конец маршрута',
    subtitle: 'Убирает последние метры при экспорте',
    section: 'Маршрут и данные',
    kind: SettingKind.number,
    defaultValue: 0,
    proOnly: true,
    min: 0,
    max: 500,
    step: 25,
    unit: 'м',
  ),
  SettingDef(
    key: 'heal_bridge_max_m',
    title: 'Предел склейки пешком',
    subtitle: 'Авто — 150 м. Более длинные разрывы не склеиваются. Для велосипеда и авто пределы подбираются сами',
    section: 'Маршрут и данные',
    kind: SettingKind.number,
    defaultValue: 0,
    proOnly: true,
    min: 0,
    max: 500,
    step: 25,
    unit: 'м',
    zeroMeansAuto: true,
  ),
  SettingDef(
    key: 'nav_voice',
    title: 'Голосовые подсказки',
    subtitle: 'При ходьбе по маршруту: «Через 100 метров налево». Голос берётся из настроек телефона',
    section: 'Навигация',
    kind: SettingKind.toggle,
    defaultValue: true,
  ),
  SettingDef(
    key: 'nav_vibrate',
    title: 'Вибрация перед поворотом',
    subtitle: 'Один импульс — налево, два — направо',
    section: 'Навигация',
    kind: SettingKind.toggle,
    defaultValue: true,
  ),
  SettingDef(
    key: 'nav_keep_screen',
    title: 'Не гасить экран при навигации',
    subtitle: 'Надёжнее для голоса, но быстрее садит батарею',
    section: 'Навигация',
    kind: SettingKind.toggle,
    defaultValue: true,
  ),
  SettingDef(
    key: 'sound_mode',
    title: 'Звуки и вибрация',
    subtitle: 'Сигналы начала и конца записи, цели, схода с маршрута, поворотов и тревоги',
    section: 'Звуки и вибрация',
    kind: SettingKind.choice,
    defaultValue: 'both',
    options: [('both', 'Звук и вибрация'), ('sound', 'Только звук'), ('vibe', 'Только вибрация'), ('silent', 'Без звука')],
  ),
  SettingDef(
    key: 'offroute',
    title: 'Чувствительность «вы сошли с маршрута»',
    subtitle: 'Строгая — предупреждение при отклонении от 25 м, свободная — от 70 м',
    section: 'Навигация',
    kind: SettingKind.choice,
    defaultValue: 'normal',
    proOnly: true,
    options: [('strict', 'Строгая'), ('normal', 'Обычная'), ('free', 'Свободная')],
  ),
];

/// Persistent app settings. Values are stored regardless of the UI mode.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  final Map<String, Object?> _values = {};
  final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);
  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File(p.join(dir.path, 'settings.json'));
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        if (data is Map<String, dynamic>) _values.addAll(data);
      } else {
        // Migrate the theme file from earlier test builds.
        final old = File(p.join(dir.path, 'theme_mode.txt'));
        if (await old.exists()) _values['theme'] = (await old.readAsString()).trim();
      }
    } catch (e) {
      DebugLog.instance.log('SETTINGS', 'load failed, defaults used: $e');
      // defaults are used
    }
    _syncTheme();
    _syncLocale();
  }

  Future<void> _save() async {
    try {
      await _file?.writeAsString(jsonEncode(_values));
    } catch (e) {
      DebugLog.instance.log('SETTINGS', 'save failed: $e');
      // value still applies for this run
    }
  }

  /// Language and units follow the settings; "auto" takes the language of the phone.
  void _syncLocale() {
    final lang = getString('language');
    L10n.set(switch (lang) {
      'ru' => AppLang.ru,
      'en' => AppLang.en,
      _ => L10n.fromSystem(PlatformDispatcher.instance.locale.languageCode),
    });
    // Miles and feet exist only in the English interface; Russian is always kilometres and metres.
    final english = L10n.current == AppLang.en;
    final units = english && getBool('imperial') ? UnitSystem.imperial : UnitSystem.metric;
    // Pro: the temperature unit can differ from the distance units ('auto' = follows them).
    final tempUnit = english ? getString('temp_unit') : 'auto';
    final bool? fahrenheit = tempUnit == 'f' ? true : (tempUnit == 'c' ? false : null);
    if (units != Units.system || fahrenheit != Units.fahrenheitOverride) {
      Units.system = units;
      Units.fahrenheitOverride = fahrenheit;
      L10n.revision.value++; // screens repaint with the new units (a language change already does this)
    }
  }

  void _syncTheme() {
    themeNotifier.value =
        ThemeMode.values.firstWhere((m) => m.name == getString('theme'), orElse: () => ThemeMode.system);
  }

  SettingDef? _def(String key) {
    for (final d in settingDefs) {
      if (d.key == key) return d;
    }
    return null;
  }

  Object? _raw(String key) => _values[key] ?? _def(key)?.defaultValue;

  /// Stored value without defaults, for data that is not a user setting (planned trips).
  Object? raw(String key) => _values[key];

  bool getBool(String key) => _raw(key) == true;
  String getString(String key) => (_raw(key) ?? '').toString();
  double getNum(String key) => (_raw(key) as num?)?.toDouble() ?? 0;

  Future<void> set(String key, Object value) async {
    _values[key] = value;
    if (key == 'theme') _syncTheme();
    if (key == 'language' || key == 'imperial' || key == 'temp_unit') _syncLocale();
    notifyListeners();
    await _save();
  }

  /// Amateur/pro switch. It only changes what the settings screen shows.
  bool get pro => _values['pro_mode'] == true;
  Future<void> setPro(bool v) => set('pro_mode', v);

  Future<void> resetAdvanced() async {
    for (final d in settingDefs.where((d) => d.proOnly)) {
      _values.remove(d.key);
    }
    notifyListeners();
    await _save();
  }

  // Typed accessors used by the rest of the app.
  double get maxAccuracyM => getNum('max_accuracy_m');

  /// GPS interval: the Pro override if set, otherwise the travel mode's own.
  int fixIntervalMsFor(TravelMode mode) {
    final custom = getNum('fix_interval_s');
    return custom > 0 ? (custom * 1000).round() : profileOf(mode).intervalMs;
  }

  bool get autoPause => getBool('autopause');
  bool get autoMode => getBool('auto_mode');
  bool get splitAtMidnight => getString('day_split') == 'midnight';
  int get idleMinutes => getNum('idle_minutes').round();

  /// Base off-route distance in metres; the service raises it to 2x the current GPS accuracy.
  double get offRouteMeters => switch (getString('offroute')) {
        'strict' => 25,
        'free' => 70,
        _ => 40,
      };
  TravelMode get travelMode => TravelModeInfo.parse(_values['travel_mode'] as String?);
  Future<void> setTravelMode(TravelMode m) => set('travel_mode', m.code);

  HealSettings healFor(TravelMode mode) =>
      HealSettings.forMode(mode, walkLimitOverride: getNum('heal_bridge_max_m'));

  bool get healEnabled => getBool('heal_enabled');
  double get trimStartM => getNum('trim_start_m');
  double get trimEndM => getNum('trim_end_m');
}
