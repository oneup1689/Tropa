import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'heal.dart';
import 'modes.dart';

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
    subtitle: 'На стоянке GPS опрашивается реже, чтобы экономить батарею',
    section: 'Запись',
    kind: SettingKind.toggle,
    defaultValue: true,
    proOnly: true,
  ),
  SettingDef(
    key: 'heal_enabled',
    title: 'Склеивать короткие разрывы',
    subtitle: 'По умолчанию для просмотра и экспорта GPX',
    section: 'Склейка',
    kind: SettingKind.toggle,
    defaultValue: true,
    proOnly: true,
  ),
  SettingDef(
    key: 'trim_start_m',
    title: 'Обрезать начало маршрута',
    subtitle: 'Убирает первые метры при экспорте (например, чтобы не показывать дом). Маршрут не меняется и не удлиняется.',
    section: 'Приватность',
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
    section: 'Приватность',
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
    section: 'Склейка',
    kind: SettingKind.number,
    defaultValue: 0,
    proOnly: true,
    min: 0,
    max: 500,
    step: 25,
    unit: 'м',
    zeroMeansAuto: true,
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
    } catch (_) {
      // defaults are used
    }
    _syncTheme();
  }

  Future<void> _save() async {
    try {
      await _file?.writeAsString(jsonEncode(_values));
    } catch (_) {
      // value still applies for this run
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

  bool getBool(String key) => _raw(key) == true;
  String getString(String key) => (_raw(key) ?? '').toString();
  double getNum(String key) => (_raw(key) as num?)?.toDouble() ?? 0;

  Future<void> set(String key, Object value) async {
    _values[key] = value;
    if (key == 'theme') _syncTheme();
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
  TravelMode get travelMode => TravelModeInfo.parse(_values['travel_mode'] as String?);
  Future<void> setTravelMode(TravelMode m) => set('travel_mode', m.code);

  HealSettings healFor(TravelMode mode) =>
      HealSettings.forMode(mode, walkLimitOverride: getNum('heal_bridge_max_m'));

  bool get healEnabled => getBool('heal_enabled');
  double get trimStartM => getNum('trim_start_m');
  double get trimEndM => getNum('trim_end_m');
}
