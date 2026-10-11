import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'maps.dart';

/// Installed offline maps. A region is a single .pmtiles file.
class MapsPage extends StatefulWidget {
  const MapsPage({super.key});

  @override
  State<MapsPage> createState() => _MapsPageState();
}

class _MapsPageState extends State<MapsPage> {
  List<MapRegion> regions = [];
  String folder = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await MapStore.regions();
    final dir = await MapStore.regionsDir();
    if (mounted) {
      setState(() {
        regions = list;
        folder = dir.path;
      });
    }
  }

  String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} МБ';

  Future<void> _add() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.pmtiles')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нужен файл с расширением .pmtiles')));
      }
      return;
    }
    setState(() => busy = true);
    try {
      await MapStore.importRegion(File(path));
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await _reload();
  }

  String _bounds(RegionBounds? b) => b == null
      ? 'границы неизвестны'
      : '${b.minLat.toStringAsFixed(1)}…${b.maxLat.toStringAsFixed(1)}°N, ${b.minLon.toStringAsFixed(1)}…${b.maxLon.toStringAsFixed(1)}°E';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Карты')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: busy ? null : _add,
        icon: const Icon(Icons.add),
        label: Text(busy ? 'Копирую…' : 'Добавить карту'),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Карты работают без интернета. Один регион — один файл .pmtiles.'),
        const SizedBox(height: 8),
        Text('Папка на телефоне:\n$folder', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          'Файл можно просто скопировать в эту папку с компьютера.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (MapStore.lastListError != null)
          Text(MapStore.lastListError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (regions.isEmpty && MapStore.lastListError == null) const Text('Пока нет ни одной карты.'),
        for (final r in regions)
          Card(
            child: ListTile(
              leading: const Icon(Icons.map),
              title: Text(r.name),
              subtitle: Text('${_mb(r.sizeBytes)} · ${_bounds(r.bounds)}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text('Удалить карту «${r.name}»?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await MapStore.deleteRegion(r);
                    await _reload();
                  }
                },
              ),
            ),
          ),
        const SizedBox(height: 72),
        Text('Данные карты: © участники OpenStreetMap (ODbL), оформление Protomaps.',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
