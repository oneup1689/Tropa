import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'gpx.dart';
import 'l10n.dart';
import 'settings.dart';
import 'units.dart';

/// Export dialog: the person chooses what goes into the GPX file, then shares it.
Future<void> shareSessionGpx(BuildContext context, int id) async {
  var heal = AppSettings.instance.healEnabled, withTime = true, withEle = true;
  // Trimming is a Pro option, but a value set earlier keeps working in amateur mode.
  var trimStart = AppSettings.instance.trimStartM, trimEnd = AppSettings.instance.trimEndM;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: Text(t('Что включить в маршрут (GPX)')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CheckboxListTile(
              value: heal,
              onChanged: (v) => setS(() => heal = v ?? heal),
              title: Text(t('Склеить короткие разрывы')),
              subtitle: Text(t('Только короткие участки, где движение было правдоподобным')),
            ),
            CheckboxListTile(
              value: withTime,
              onChanged: (v) => setS(() => withTime = v ?? withTime),
              title: Text(t('Время')),
            ),
            CheckboxListTile(
              value: withEle,
              onChanged: (v) => setS(() => withEle = v ?? withEle),
              title: Text(t('Высота')),
            ),
            if (AppSettings.instance.pro) ...[
              const Divider(),
              Text(t('Обрезать начало: {n}', {'n': Units.shortDist(trimStart)})),
              Slider(value: trimStart, max: 500, divisions: 20, onChanged: (v) => setS(() => trimStart = v)),
              Text(t('Обрезать конец: {n}', {'n': Units.shortDist(trimEnd)})),
              Slider(value: trimEnd, max: 500, divisions: 20, onChanged: (v) => setS(() => trimEnd = v)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Поделиться'))),
        ],
      ),
    ),
  );
  if (ok != true) return;
  final f = await writeGpx(
    id,
    withTime: withTime,
    withElevation: withEle,
    heal: heal,
    trimStartM: trimStart,
    trimEndM: trimEnd,
  );
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: t('Tropa — маршрут')));
}
