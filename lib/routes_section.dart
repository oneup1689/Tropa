import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'db.dart';
import 'l10n.dart';
import 'map_page.dart';
import 'routes.dart';
import 'units.dart';

/// The "Routes" part of the Trails tab: routes to walk again or to follow (imported GPX files, walks saved as a
/// route). A route is for navigation: it has no poster, posters are made only from walks that were recorded.
class RoutesSection extends StatelessWidget {
  final List<RouteInfo> routes;

  /// Called after a route was added, renamed or deleted (the list must be loaded again).
  final Future<void> Function() onChanged;

  /// "Follow the route": starts a recording with navigation along the route.
  final Future<void> Function(int routeId) onFollow;

  const RoutesSection({super.key, required this.routes, required this.onChanged, required this.onFollow});

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

  Future<void> _share(BuildContext context, RouteInfo r) async {
    final pts = await TrackDb.instance.routePoints(r.id);
    final dir = await getTemporaryDirectory();
    final safe = r.name.replaceAll(RegExp(r'[^\wА-Яа-яЁё\- ]'), '_').trim();
    final file = File('${dir.path}/${safe.isEmpty ? 'route' : safe}.gpx');
    await file.writeAsString(routeToGpx(r.name, pts));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: t('Tropa — маршрут')));
  }

  Future<void> _rename(BuildContext context, RouteInfo r) async {
    final name = await showDialog<String>(context: context, builder: (_) => _NameDialog(initial: r.name));
    if (name == null || name.isEmpty) return;
    await TrackDb.instance.renameRoute(r.id, name);
    await onChanged();
  }

  Future<void> _delete(BuildContext context, RouteInfo r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('Удалить маршрут «{p0}»?', {'p0': r.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Удалить'))),
        ],
      ),
    );
    if (ok != true) return;
    await TrackDb.instance.deleteRoute(r.id);
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        t('Маршруты, по которым можно идти заново: файл GPX или пройденная прогулка. Во время записи приложение предупредит, если вы сойдёте с маршрута.'),
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(r.name, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'rename':
                        _rename(context, r);
                      case 'share':
                        _share(context, r);
                      case 'delete':
                        _delete(context, r);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'rename', child: Text(t('Переименовать'))),
                    PopupMenuItem(value: 'share', child: Text(t('Поделиться GPX'))),
                    PopupMenuItem(value: 'delete', child: Text(t('Удалить'))),
                  ],
                ),
              ]),
              Text(t('{p0} · {p1} точек', {'p0': Units.dist(r.lengthM), 'p1': r.pointCount}),
                  style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: [
                FilledButton.icon(
                  onPressed: () => onFollow(r.id),
                  icon: const Icon(Icons.navigation),
                  label: Text(t('Идти по маршруту')),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MapPage(routeId: r.id, title: r.name))),
                  icon: const Icon(Icons.map),
                  label: Text(t('На карте')),
                ),
              ]),
            ]),
          ),
        ),
    ]);
  }
}

class _NameDialog extends StatefulWidget {
  final String initial;

  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(t('Название маршрута')),
        content: TextField(controller: _ctl, autofocus: true, textCapitalization: TextCapitalization.sentences),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(context, _ctl.text.trim()), child: Text(t('Сохранить'))),
        ],
      );
}
