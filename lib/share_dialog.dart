import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'db.dart';
import 'modes.dart';
import 'share_image.dart';

/// Checkbox dialog: what appears on the picture. Returns null when cancelled.
Future<ShareOptions?> askShareOptions(BuildContext context) {
  final o = ShareOptions();
  return showDialog<ShareOptions>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: const Text('Что показать на картинке'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CheckboxListTile(
                value: o.distance, onChanged: (v) => setS(() => o.distance = v ?? true), title: const Text('Дистанция')),
            CheckboxListTile(
                value: o.time, onChanged: (v) => setS(() => o.time = v ?? true), title: const Text('Время в движении')),
            CheckboxListTile(
                value: o.speed, onChanged: (v) => setS(() => o.speed = v ?? true), title: const Text('Темп / скорость')),
            CheckboxListTile(
                value: o.elevation, onChanged: (v) => setS(() => o.elevation = v ?? true), title: const Text('Набор высоты')),
            CheckboxListTile(
                value: o.modeIcons,
                onChanged: (v) => setS(() => o.modeIcons = v ?? true),
                title: const Text('Иконки режима (пешком, велосипед, авто)')),
            CheckboxListTile(
                value: o.showRestored,
                onChanged: (v) => setS(() => o.showRestored = v ?? false),
                title: const Text('Выделять восстановленные участки')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(c, o), child: const Text('Создать')),
        ],
      ),
    ),
  );
}

/// Creates the picture and opens the system share sheet.
Future<void> shareRouteImage({
  required String title,
  required List<TrackPoint> pts,
  required TravelMode mode,
  required ShareOptions options,
  List<int>? mapPng,
  Rect? mapRect,
  required String fileName,
}) async {
  final png = await composeShareImage(
    title: title,
    pts: pts,
    mode: mode,
    o: options,
    mapPng: mapPng == null ? null : Uint8List.fromList(mapPng),
    mapRect: mapRect,
  );
  final f = await writeShareImage(png, fileName);
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: 'Tropa — маршрут'));
}
