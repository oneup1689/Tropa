import 'package:flutter/material.dart';

import 'data_section.dart';
import 'l10n.dart';
import 'recorder.dart';
import 'settings.dart';
import 'units.dart';

/// Icons of the groups of settings.
IconData _sectionIcon(String section) => switch (section) {
      'Оформление' => Icons.palette_outlined,
      'Язык и единицы' => Icons.language,
      'Автоматическая запись' => Icons.motion_photos_auto_outlined,
      'Запись' => Icons.fiber_manual_record_outlined,
      'Маршрут и данные' => Icons.route_outlined,
      'Навигация' => Icons.navigation_outlined,
      'Звуки и вибрация' => Icons.volume_up_outlined,
      'Данные' => Icons.folder_outlined,
      'Приватность' => Icons.lock_outline,
      _ => Icons.tune,
    };

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final english = L10n.current == AppLang.en;
        final visible = settingDefs.where((d) => d.key != 'auto_mode' && (s.pro || !d.proOnly) && (english || !d.englishOnly)).toList();
        final sections = <String>[];
        for (final d in visible) {
          if (!sections.contains(d.section)) sections.add(d.section);
        }
        // Auto-record itself (24/7 and the planner) lives on the start card; only its Pro settings are here.
        return Scaffold(
          appBar: AppBar(title: Text(t('Настройки'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Card(
                color: cs.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t('Режим приложения'), style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.onPrimaryContainer)),
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(value: false, label: Text(t('Любитель')), icon: const Icon(Icons.hiking)),
                        ButtonSegment(value: true, label: Text(t('Профи')), icon: const Icon(Icons.tune)),
                      ],
                      selected: {s.pro},
                      onSelectionChanged: (v) => s.setPro(v.first),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      s.pro
                          ? t('Показаны все настройки. Вы можете тонко настроить запись, склейку и другие параметры.')
                          : t('Минимум настроек: остальное подобрано автоматически. Всё, что вы настроили в режиме «Профи», продолжает работать.'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onPrimaryContainer),
                    ),
                  ]),
                ),
              ),
              for (final section in sections) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 22, 4, 6),
                  child: Row(children: [
                    Icon(_sectionIcon(section), size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(t(section), style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.primary)),
                  ]),
                ),
                Card(
                  child: Column(children: [
                    for (final d in visible.where((d) => d.section == section)) _tile(context, s, d),
                  ]),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 22, 4, 6),
                child: Row(children: [
                  Icon(_sectionIcon('Данные'), size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(t('Данные'), style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.primary)),
                ]),
              ),
              const DataSection(),
              if (s.pro)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: OutlinedButton(
                    onPressed: s.resetAdvanced,
                    child: Text(t('Сбросить расширенные настройки')),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// The unit of a number setting, in the unit system of the person for distances.
  String _unit(SettingDef d, num value) {
    if (d.unit == 'м') return Units.shortDist(value.toDouble());
    return '${value.round()} ${t(d.unit)}';
  }

  Widget _tile(BuildContext context, AppSettings s, SettingDef d) {
    switch (d.kind) {
      case SettingKind.toggle:
        return SwitchListTile(
          title: Text(t(d.title)),
          subtitle: d.subtitle.isEmpty ? null : Text(t(d.subtitle)),
          value: s.getBool(d.key),
          onChanged: (v) async {
            await s.set(d.key, v);
            if (d.key == 'auto_mode') await Recorder.instance.applyAutoMode();
          },
        );
      case SettingKind.choice:
        return ListTile(
          title: Text(t(d.title)),
          subtitle: d.subtitle.isEmpty ? null : Text(t(d.subtitle)),
          trailing: DropdownButton<String>(
            value: d.options.any((o) => o.$1 == s.getString(d.key)) ? s.getString(d.key) : d.options.first.$1,
            underline: const SizedBox.shrink(),
            items: [for (final o in d.options) DropdownMenuItem(value: o.$1, child: Text(t(o.$2)))],
            onChanged: (v) {
              if (v != null) s.set(d.key, v);
            },
          ),
        );
      case SettingKind.number:
        final value = s.getNum(d.key).clamp(d.min, d.max).toDouble();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(t(d.title), style: Theme.of(context).textTheme.bodyLarge)),
              Text(d.zeroMeansAuto && value == 0 ? t('авто') : _unit(d, value), style: Theme.of(context).textTheme.titleSmall),
            ]),
            if (d.subtitle.isNotEmpty) Text(t(d.subtitle), style: Theme.of(context).textTheme.bodySmall),
            Slider(
              value: value,
              min: d.min,
              max: d.max,
              divisions: ((d.max - d.min) / d.step).round(),
              onChanged: (v) => s.set(d.key, v.round()),
            ),
          ]),
        );
    }
  }
}
