import 'package:flutter/material.dart';

import 'device_net.dart';
import 'l10n.dart';
import 'map_downloads.dart';
import 'pmtiles_extract.dart';

const _spareBytes = 50 * 1048576; // always leave this much free so the phone itself keeps working
const _mobileWarnBytes = 20 * 1048576; // below this the mobile-data warning is not worth showing

String _mb(num bytes) {
  final mb = bytes / 1048576;
  return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} ${t('ГБ')}' : '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} ${t('МБ')}';
}

/// Plans a download, tells the person the exact size and, when they agree, starts it in the background.
/// Returns true when the download was started.
Future<bool> offerDownload(
  BuildContext context, {
  required String nameRu,
  required String nameEn,
  required GeoBox box,
  required String fileName,
  int maxZoom = 14,
  bool fragment = false,
}) async {
  final dl = MapDownloader.instance;
  final messenger = ScaffoldMessenger.of(context);
  if (dl.busy) {
    messenger.showSnackBar(SnackBar(content: Text(t('Уже идёт другая загрузка карты'))));
    return false;
  }
  final name = L10n.current == AppLang.en ? nameEn : nameRu;
  // While the directories are read the person sees a short "counting" dialog.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Expanded(child: Text(t('Считаю размер карты «{n}»…', {'n': name}))),
        ]),
      ),
    ),
  );
  final quote = await dl.prepare(nameRu: nameRu, nameEn: nameEn, box: box, fileName: fileName, maxZoom: maxZoom, fragment: fragment);
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  if (quote == null) {
    messenger.showSnackBar(SnackBar(content: Text(t('Не удалось связаться с сервером карт. Проверьте интернет.'))));
    dl.acknowledge();
    return false;
  }
  if (!context.mounted) {
    dl.cancel();
    return false;
  }
  // Not enough room: the download is not started at all.
  final free = await freeStorageBytes();
  final need = quote.fileBytes + _spareBytes;
  if (free != null && free < need) {
    dl.cancel();
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('Не хватает места')),
          content: Text(t('Карте «{n}» нужно {a} (с небольшим запасом для системы), а на телефоне свободно {f}. Освободите место и попробуйте снова.',
              {'n': name, 'a': _mb(need), 'f': _mb(free)})),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(t('Понятно')))],
        ),
      );
    }
    return false;
  }
  // Mobile internet: say how much it will take and let the person decide.
  final net = await networkInfo();
  final onMobile = net != null && net.online && !net.wifi && quote.downloadBytes > _mobileWarnBytes;
  if (!context.mounted) {
    dl.cancel();
    return false;
  }
  final big = quote.downloadBytes > 800 * 1048576;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(onMobile ? t('Wi-Fi не подключён') : t('Скачать карту «{n}»?', {'n': name})),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (onMobile) ...[
          Text(t('Карта «{n}» весит {a}, а вы не в Wi-Fi: загрузка пойдёт по мобильному интернету. Скачать?',
              {'n': name, 'a': _mb(quote.downloadBytes)})),
          const SizedBox(height: 10),
        ],
        Text(t('Будет загружено: {a}', {'a': _mb(quote.downloadBytes)})),
        Text(t('Займёт на телефоне: {a}', {'a': _mb(quote.fileBytes)})),
        const SizedBox(height: 10),
        Text(big ? t('Это большая карта. Лучше скачивать по Wi-Fi и при зарядке.') : t('Лучше скачивать по Wi-Fi.'),
            style: Theme.of(context).textTheme.bodySmall),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(onMobile ? t('Скачать по мобильной сети') : t('Скачать'))),
      ],
    ),
  );
  if (ok != true) {
    dl.cancel();
    return false;
  }
  // The download runs in the background; the maps screen shows its progress.
  dl.start();
  return true;
}

/// Step 1 of the catalog: countries, with a search field.
class CountryListPage extends StatefulWidget {
  const CountryListPage({super.key});

  @override
  State<CountryListPage> createState() => _CountryListPageState();
}

class _CountryListPageState extends State<CountryListPage> {
  List<CatalogCountry> _all = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    RegionCatalog.load().then((v) {
      if (mounted) setState(() => _all = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final list = [
      for (final c in _all)
        if (q.isEmpty || c.ru.toLowerCase().contains(q) || c.en.toLowerCase().contains(q)) c
    ]..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      appBar: AppBar(title: Text(t('Скачать карту'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t('Страна')),
          ),
        ),
        Expanded(
          child: _all.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final c = list[i];
                    return Card(
                      child: ListTile(
                        title: Text(c.name),
                        subtitle: Text(c.regions.isEmpty
                            ? t('вся страна')
                            : t('{n} {w}', {'n': c.regions.length, 'w': plural(c.regions.length, 'регион', 'региона', 'регионов', en1: 'region', enN: 'regions')})),
                        trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CountryPage(country: c))),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// Step 2: the whole country or one of its regions.
class CountryPage extends StatelessWidget {
  final CatalogCountry country;

  const CountryPage({super.key, required this.country});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final regions = [...country.regions]..sort((a, b) => a.name.compareTo(b.name));
    Future<void> download(String ru, String en, GeoBox box, String file) async {
      final started = await offerDownload(context, nameRu: ru, nameEn: en, box: box, fileName: '$file.pmtiles');
      if (started && context.mounted) {
        // Back to the maps screen, where the progress is shown.
        Navigator.of(context)
          ..pop()
          ..pop();
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(country.name)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        if (country.whole)
          Card(
            color: cs.primaryContainer,
            child: ListTile(
              leading: Icon(Icons.public, color: cs.onPrimaryContainer),
              title: Text(t('Вся страна: {n}', {'n': country.name}), style: TextStyle(color: cs.onPrimaryContainer)),
              subtitle: Text(t('Размер покажу перед загрузкой'), style: TextStyle(color: cs.onPrimaryContainer.withAlpha(200))),
              onTap: () => download(country.ru, country.en, country.box, country.iso),
            ),
          ),
        if (!country.whole)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(t('Эта страна пересекает линию перемены дат, поэтому доступны только регионы.'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
        for (final r in regions)
          Card(
            child: ListTile(
              title: Text(r.name),
              trailing: Icon(Icons.download_for_offline_outlined, color: cs.primary),
              onTap: () => download(r.ru, r.en, r.box, r.key),
            ),
          ),
      ]),
    );
  }
}
