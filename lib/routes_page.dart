import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'db.dart';
import 'map_page.dart';
import 'routes.dart';
import 'l10n.dart';
import 'units.dart';

/// Imported routes (GPX files from other people or other apps). "Идти по маршруту" returns the
/// route id to the caller, which starts a recording with off-route warnings.
class RoutesPage extends StatefulWidget {
  const RoutesPage({super.key});

  @override
  State<RoutesPage> createState() => _RoutesPageState();
}

class _RoutesPageState extends State<RoutesPage> {
  List<RouteInfo> routes = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final r = await TrackDb.instance.routes();
    if (mounted) setState(() => routes = r);
  }

  void _say(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    final fileName = path.split(RegExp(r'[\\/]')).last;
    if (!path.toLowerCase().endsWith('.gpx')) {
      _say(t('Нужен файл .gpx'));
      return;
    }
    final parsed = parseGpx(await File(path).readAsString(), fallbackName: fileName.replaceAll('.gpx', ''));
    if (parsed == null) {
      _say(t('В файле нет маршрута (нужно минимум две точки)'));
      return;
    }
    await TrackDb.instance.addRoute(parsed.name, parsed.points);
    _say(t('Маршрут «{p0}» добавлен ({p1} точек)', {'p0': parsed.name, 'p1': parsed.points.length}));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Маршруты'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _import,
        icon: const Icon(Icons.file_open),
        label: Text(t('Импорт GPX')),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
            t('Загрузите маршрут из файла GPX. Во время записи приложение предупредит, если вы сойдёте с него.')),
        const SizedBox(height: 12),
        if (routes.isEmpty) Text(t('Пока нет импортированных маршрутов.')),
        for (final r in routes)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: Theme.of(context).textTheme.titleMedium),
                Text(t('{p0} · {p1} точек', {'p0': Units.dist(r.lengthM), 'p1': r.pointCount})),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, r.id),
                    icon: const Icon(Icons.navigation),
                    label: Text(t('Идти по маршруту')),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => MapPage(routeId: r.id, title: r.name)),
                    ),
                    icon: const Icon(Icons.map),
                    label: Text(t('На карте')),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await TrackDb.instance.deleteRoute(r.id);
                      await _reload();
                    },
                  ),
                ]),
              ]),
            ),
          ),
        const SizedBox(height: 72),
      ]),
    );
  }
}
