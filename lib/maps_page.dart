import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';
import 'map_catalog_page.dart';
import 'map_downloads.dart';
import 'maps.dart';

String _mb(num bytes) {
  final mb = bytes / 1048576;
  return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} ${t('ГБ')}' : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} ${t('МБ')}';
}

/// Maps for use without internet: download a region, update it, or add a .pmtiles file by hand.
class MapsPage extends StatefulWidget {
  const MapsPage({super.key});

  @override
  State<MapsPage> createState() => _MapsPageState();
}

class _MapsPageState extends State<MapsPage> {
  final dl = MapDownloader.instance;
  List<MapRegion> regions = [];
  String folder = '';
  bool busy = false;
  Map<String, Object?>? pending;
  ({String build, DateTime? date})? newest;

  @override
  void initState() {
    super.initState();
    dl.addListener(_onDownload);
    _reload();
    _checkUpdates();
  }

  @override
  void dispose() {
    dl.removeListener(_onDownload);
    super.dispose();
  }

  void _onDownload() {
    if (!mounted) return;
    setState(() {});
    if (dl.state == DownloadState.done) _reload();
  }

  Future<void> _reload() async {
    final list = await MapStore.regions();
    final dir = await MapStore.regionsDir();
    final saved = await dl.pending();
    if (mounted) {
      setState(() {
        regions = list;
        folder = dir.path;
        pending = saved;
      });
    }
  }

  /// Finds out the date of the newest data; maps older than that can be updated.
  Future<void> _checkUpdates() async {
    final n = await newestBuild();
    if (mounted) setState(() => newest = n);
  }

  Future<void> _addFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.pmtiles')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Нужен файл с расширением .pmtiles'))));
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

  Future<void> _delete(MapRegion r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('Удалить карту «{n}»?', {'n': r.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Удалить'))),
        ],
      ),
    );
    if (ok == true) {
      await MapStore.deleteRegion(r);
      await _reload();
    }
  }

  Future<void> _update(MapRegion r) async {
    final meta = r.meta;
    if (meta == null) return;
    await offerDownload(
      context,
      nameRu: meta.nameRu,
      nameEn: meta.nameEn,
      box: meta.box,
      fileName: r.file.uri.pathSegments.last,
      maxZoom: meta.maxZoom,
      fragment: meta.fragment,
    );
  }

  String _date(DateTime? d) => d == null ? '' : '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('Карты'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        Text(t('Карты работают без интернета. Скачайте регион, где будете ходить, пока есть Wi-Fi.'),
            style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 14),
        _downloadCard(context),
        if (pending != null && !dl.busy && dl.state != DownloadState.failed) _pendingCard(context),
        FilledButton.icon(
          onPressed: dl.busy
              ? null
              : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CountryListPage())).then((_) => _reload()),
          icon: const Icon(Icons.download_for_offline_outlined),
          label: Text(t('Скачать карту')),
        ),
        const SizedBox(height: 22),
        Text(t('Установленные карты'), style: text.titleLarge),
        const SizedBox(height: 6),
        if (MapStore.lastListError != null) Text(MapStore.lastListError!, style: TextStyle(color: cs.error)),
        if (regions.isEmpty && MapStore.lastListError == null)
          Card(
            color: cs.secondaryContainer.withValues(alpha: 0.55),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.route_outlined, color: cs.onSecondaryContainer),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t('Карта не обязательна'), style: text.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      t('Tropa записывает маршрут по GPS и без карты. Скачать её можно позже: пройденный путь ляжет на неё, им можно поделиться (GPX) или собрать постер.'),
                      style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        for (final r in regions) _regionCard(context, r),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: busy ? null : _addFile,
          icon: const Icon(Icons.folder_open),
          label: Text(busy ? t('Копирую…') : t('Добавить файл .pmtiles')),
        ),
        const SizedBox(height: 8),
        Text(t('Файл можно скопировать в папку на телефоне с компьютера:\n{f}', {'f': folder}), style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 18),
        Text(t('Данные карты: © участники OpenStreetMap (ODbL), оформление Protomaps.'), style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _regionCard(BuildContext context, MapRegion r) {
    final cs = Theme.of(context).colorScheme;
    final meta = r.meta;
    final mapDate = meta?.buildDate;
    final newer = newest?.date;
    final canUpdate = meta != null && mapDate != null && newer != null && newer.isAfter(mapDate);
    final stale = canUpdate && newer.difference(mapDate).inDays >= 30;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(14)),
            child: Icon(meta?.fragment == true ? Icons.crop_free : Icons.map_outlined, color: cs.onPrimaryContainer),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                [
                  _mb(r.sizeBytes),
                  if (mapDate != null) t('данные от {d}', {'d': _date(mapDate)}) else if (meta == null) t('файл добавлен вручную'),
                  if (meta?.fragment == true) t('кусок для постера'),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (canUpdate)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Icon(stale ? Icons.error_outline : Icons.update, size: 15, color: stale ? cs.error : cs.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        stale ? t('Карта устарела: есть данные от {d}', {'d': _date(newer)}) : t('Есть новее: данные от {d}', {'d': _date(newer)}),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: stale ? cs.error : cs.primary),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            if (canUpdate)
              IconButton(
                tooltip: t('Обновить'),
                icon: Icon(Icons.system_update_alt, color: stale ? cs.error : cs.primary),
                onPressed: dl.busy ? null : () => _update(r),
              ),
            IconButton(tooltip: t('Удалить'), icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
          ]),
        ]),
      ),
    );
  }

  Widget _pendingCard(BuildContext context) {
    final saved = pending!;
    final name = L10n.current == AppLang.en ? saved['nameEn'] as String : saved['nameRu'] as String;
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('Загрузка прервана: {n}', {'n': name}), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(t('Можно продолжить с того места, где остановились.'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton(
              onPressed: () async {
                final q = await dl.prepareResume(saved);
                if (q != null) await dl.start();
              },
              child: Text(t('Продолжить')),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                await dl.discardPending();
                await _reload();
              },
              child: Text(t('Отменить')),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _downloadCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    switch (dl.state) {
      case DownloadState.idle:
        return const SizedBox.shrink();
      case DownloadState.planning:
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 14),
              Expanded(child: Text(t('Считаю размер карты «{n}»…', {'n': dl.title}))),
            ]),
          ),
        );
      case DownloadState.ready:
      case DownloadState.downloading:
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.downloading, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(t('Загружается: {n}', {'n': dl.title}), style: text.titleSmall)),
              ]),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: dl.fraction == 0 ? null : dl.fraction, minHeight: 8, borderRadius: BorderRadius.circular(6)),
              const SizedBox(height: 8),
              Text('${_mb(dl.bytesDone)} / ${_mb(dl.bytesTotal)} · ${(dl.fraction * 100).round()}%', style: text.bodySmall),
              const SizedBox(height: 6),
              Text(t('Не закрывайте приложение: экран останется включённым. Если связь оборвётся, загрузку можно продолжить.'),
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              TextButton(onPressed: dl.cancel, child: Text(t('Отменить загрузку'))),
            ]),
          ),
        );
      case DownloadState.failed:
        return Card(
          color: cs.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('Загрузка не удалась'), style: text.titleSmall),
              const SizedBox(height: 4),
              Text(dl.error ?? '', style: text.bodySmall, maxLines: 4, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 10),
              Row(children: [
                FilledButton(
                  onPressed: () async {
                    final saved = await dl.pending();
                    dl.acknowledge();
                    if (saved != null) {
                      final q = await dl.prepareResume(saved);
                      if (q != null) await dl.start();
                    }
                  },
                  child: Text(t('Продолжить')),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    dl.acknowledge();
                    await dl.discardPending();
                    await _reload();
                  },
                  child: Text(t('Закрыть')),
                ),
              ]),
            ]),
          ),
        );
      case DownloadState.done:
        return Card(
          color: cs.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.check_circle, color: cs.primary),
            title: Text(t('Карта «{n}» загружена', {'n': dl.title})),
            trailing: TextButton(onPressed: dl.acknowledge, child: Text(t('Закрыть'))),
          ),
        );
    }
  }
}
