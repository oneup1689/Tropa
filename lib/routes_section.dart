import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'db.dart';
import 'l10n.dart';
import 'route_page.dart';
import 'routes.dart';
import 'units.dart';

/// The "Routes" part of the Trails tab: routes to walk again or to follow (imported GPX files, walks saved as a
/// route). A route is for navigation: it has no poster, posters are made only from walks that were recorded.
class RoutesSection extends StatelessWidget {
  final List<RouteInfo> routes;

  /// Called after a route was added, renamed or deleted (the list must be loaded again).
  final Future<void> Function() onChanged;

  const RoutesSection({super.key, required this.routes, required this.onChanged});

  void _say(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _import(BuildContext context) async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    final fileName = path.split(RegExp(r'[\\/]')).last;
    if (!context.mounted) return;
    if (!path.toLowerCase().endsWith('.gpx')) {
      _say(context, t('Нужен файл .gpx'));
      return;
    }
    final parsed = parseGpx(await File(path).readAsString(), fallbackName: fileName.replaceAll('.gpx', ''));
    if (!context.mounted) return;
    if (parsed == null) {
      _say(context, t('В файле нет маршрута (нужно минимум две точки)'));
      return;
    }
    await TrackDb.instance.addRoute(parsed.name, parsed.points);
    if (context.mounted) _say(context, t('Маршрут «{p0}» добавлен ({p1} точек)', {'p0': parsed.name, 'p1': parsed.points.length}));
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        t('Маршруты, по которым можно идти: файл GPX или пройденная прогулка. Откройте маршрут, чтобы посмотреть его и начать.'),
        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: () => _import(context),
        icon: const Icon(Icons.file_open),
        label: Text(t('Импорт GPX')),
      ),
      const SizedBox(height: 6),
      if (routes.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
          child: Column(children: [
            Icon(Icons.alt_route, size: 54, color: cs.primary),
            const SizedBox(height: 10),
            Text(t('Пока нет маршрутов'), style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              t('Импортируйте GPX или откройте пройденную прогулку и выберите «Сохранить как маршрут».'),
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ]),
        ),
      for (final r in routes)
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
            leading: const Icon(Icons.alt_route),
            title: Text(r.name, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(t('{p0} · {p1} точек', {'p0': Units.dist(r.lengthM), 'p1': r.pointCount}),
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => RoutePage(route: r)));
              if (changed == true) await onChanged();
            },
          ),
        ),
    ]);
  }
}
