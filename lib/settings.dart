import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'heal.dart';

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
    subtitle: 'Чаще — точнее маршрут, но быстрее садится батарея',
    section: 'Запись',
    kind: SettingKind.number,
    defaultValue: 2,
    proOnly: true,
    min: 1,
    max: 10,
    step: 1,
    unit: 'с',
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
    key: 'heal_bridge_max_m',
    title: 'Предел склейки пешком',
    subtitle: 'Более длинные разрывы не склеиваются прямой линией',
    section: 'Склейка',
    kind: SettingKind.number,
    defaultValue: 150,
    proOnly: true,
    min: 50,
    max: 500,
    step: 25,
    unit: 'м',
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
  int get fixIntervalMs => (getNum('fix_interval_s') * 1000).round();
  bool get healEnabled => getBool('heal_enabled');
  HealSettings get healSettings => HealSettings(bridgeMaxMeters: getNum('heal_bridge_max_m'));
}
