import 'package:flutter/material.dart';

import 'recorder.dart';
import 'settings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final visible = settingDefs.where((d) => s.pro || !d.proOnly).toList();
        final sections = <String>[];
        for (final d in visible) {
          if (!sections.contains(d.section)) sections.add(d.section);
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Настройки')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Режим приложения', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Любитель'), icon: Icon(Icons.hiking)),
                        ButtonSegment(value: true, label: Text('Профи'), icon: Icon(Icons.tune)),
                      ],
                      selected: {s.pro},
                      onSelectionChanged: (v) => s.setPro(v.first),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s.pro
                          ? 'Показаны все настройки. Вы можете тонко настроить запись, склейку и другие параметры.'
                          : 'Минимум настроек: остальное подобрано автоматически. '
                              'Всё, что вы настроили в режиме «Профи», продолжает работать.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ]),
                ),
              ),
              for (final section in sections) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
                  child: Text(section, style: Theme.of(context).textTheme.titleSmall),
                ),
                Card(
                  child: Column(children: [
                    for (final d in visible.where((d) => d.section == section)) _tile(context, s, d),
                  ]),
                ),
              ],
              if (s.pro)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: OutlinedButton(
                    onPressed: s.resetAdvanced,
                    child: const Text('Сбросить расширенные настройки'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(BuildContext context, AppSettings s, SettingDef d) {
    switch (d.kind) {
      case SettingKind.toggle:
        return SwitchListTile(
          title: Text(d.title),
          subtitle: d.subtitle.isEmpty ? null : Text(d.subtitle),
          value: s.getBool(d.key),
          onChanged: (v) async {
            await s.set(d.key, v);
            if (d.key == 'auto_mode') await Recorder.instance.applyAutoMode();
          },
        );
      case SettingKind.choice:
        return ListTile(
          title: Text(d.title),
          subtitle: d.subtitle.isEmpty ? null : Text(d.subtitle),
          trailing: DropdownButton<String>(
            value: d.options.any((o) => o.$1 == s.getString(d.key)) ? s.getString(d.key) : d.options.first.$1,
            items: [for (final o in d.options) DropdownMenuItem(value: o.$1, child: Text(o.$2))],
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
              Expanded(child: Text(d.title, style: Theme.of(context).textTheme.bodyLarge)),
              Text(d.zeroMeansAuto && value == 0 ? 'авто' : '${value.round()} ${d.unit}',
                  style: Theme.of(context).textTheme.titleSmall),
            ]),
            if (d.subtitle.isNotEmpty) Text(d.subtitle, style: Theme.of(context).textTheme.bodySmall),
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
