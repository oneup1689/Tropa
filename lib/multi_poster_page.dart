import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import 'altitude.dart';
import 'db.dart';
import 'debug_log.dart';
import 'elevation.dart';
import 'map_page.dart';
import 'modes.dart';
import 'poster.dart';
import 'poster_multi.dart';
import 'weather.dart';
import 'l10n.dart';

/// "Постер из нескольких прогулок" (Pro): pick walks, get one horizontal poster with all of them on one map.
class MultiPosterPage extends StatefulWidget {
  const MultiPosterPage({super.key});

  @override
  State<MultiPosterPage> createState() => _MultiPosterPageState();
}

class _MultiPosterPageState extends State<MultiPosterPage> {
  final o = PosterOptions()
    ..format = PosterFormat.horizontal
    ..background = PosterBackground.map
    ..title = t('Мои маршруты');
  final _title = TextEditingController(text: t('Мои маршруты'));
  final _region = TextEditingController();
  List<SessionInfo> _sessions = const [];
  final List<int> _picked = []; // selection order = number on the poster
  final Map<int, TextEditingController> _names = {};
  bool _loading = true;
  bool _busy = false;
  Uint8List? _png;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _region.dispose();
    for (final c in _names.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final all = await TrackDb.instance.sessions(limit: 300);
    if (!mounted) return;
    setState(() {
      _sessions = [for (final s in all) if (s.pointCount >= 2) s];
      _loading = false;
    });
  }

  String _dayLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day} ${monthShort(d.month)}';
  }

  String _defaultName(SessionInfo s) {
    final noun = switch (TravelModeInfo.parse(s.mode)) {
      TravelMode.bike => t('Велопрогулка'),
      TravelMode.car => t('Поездка'),
      TravelMode.water => t('Сплав'),
      _ => t('Прогулка'),
    };
    return '$noun ${_dayLabel(s.startMs)}';
  }

  void _toggle(SessionInfo s, bool on) {
    setState(() {
      if (on) {
        if (_picked.length >= maxMultiRoutes) {
          _snack(t('Не больше {p0} маршрутов на постере', {'p0': maxMultiRoutes}));
          return;
        }
        _picked.add(s.id);
        _names.putIfAbsent(s.id, () => TextEditingController(text: _defaultName(s)));
      } else {
        _picked.remove(s.id);
      }
    });
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _detectPlace() async {
    if (_picked.isEmpty) return;
    final pts = await TrackDb.instance.points(_picked.first);
    if (pts.isEmpty) return;
    final m = pts[pts.length ~/ 2];
    final name = await fetchPlaceName(m.lat, m.lon);
    if (!mounted) return;
    if (name == null) {
      _snack(t('Не удалось определить место. Введите его вручную.'));
      return;
    }
    setState(() => _region.text = name);
  }

  Future<void> _create() async {
    if (_picked.isEmpty) {
      _snack(t('Выберите хотя бы одну прогулку'));
      return;
    }
    o.title = _title.text;
    o.region = _region.text;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final routes = <MultiRoute>[];
      for (final id in _picked) {
        final pts = await TrackDb.instance.points(id);
        final mode = TravelModeInfo.parse(await TrackDb.instance.sessionMode(id));
        final gps = fusedAltitude(pts);
        final alt = await sessionAltitude(id, pts);
        final fused = alt.length == gps.length && [for (var i = 0; i < alt.length; i += 25) (alt[i] - gps[i]).abs()].any((d) => d > 0.01);
        routes.add(MultiRoute(_names[id]?.text.trim().isNotEmpty == true ? _names[id]!.text.trim() : t('Маршрут'), pts, alt, fused, mode));
      }
      MapCapture? map;
      if (!mounted) return;
      if (o.background == PosterBackground.map) {
        map = await Navigator.push<MapCapture>(
          context,
          MaterialPageRoute(
            builder: (_) => MapPage(
              sessionId: _picked.first,
              title: t('Готовлю карту…'),
              posterCapture: o,
              captureSessionIds: List.of(_picked),
            ),
          ),
        );
        if (!mounted) return;
        if (map == null) _snack(t('Карты для этого места нет: постер сделан в стиле Tropa.'));
      }
      final png = await composeMultiPoster(o: o, routes: routes, map: map);
      if (!mounted) return;
      setState(() => _png = png);
    } catch (e, st) {
      DebugLog.instance.log('POSTER', 'multi compose failed: $e\n$st');
      if (mounted) _snack(t('Не удалось создать постер: {p0}', {'p0': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final png = _png;
    if (png == null) return;
    try {
      final f = await writePoster(png, 'tropa_multi_${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putImage(f.path, album: 'Tropa');
      _snack(t('Постер сохранён в галерею (альбом Tropa)'));
    } catch (e) {
      _snack(t('Не удалось сохранить: {p0}', {'p0': e}));
    }
  }

  Future<void> _share() async {
    final png = _png;
    if (png == null) return;
    final f = await writePoster(png, 'tropa_multi_${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: 'Tropa'));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('Постер из нескольких прогулок'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              if (_png != null) ...[
                Center(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_png!))),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.download), label: Text(t('Сохранить постер')))),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(onPressed: _share, icon: const Icon(Icons.share), label: Text(t('Поделиться постером')))),
                ]),
                const Divider(height: 32),
              ],
              Text(t('Выберите прогулки (до {p0})', {'p0': maxMultiRoutes}), style: text.titleSmall),
              const SizedBox(height: 4),
              if (_sessions.isEmpty) Padding(padding: EdgeInsets.all(16), child: Text(t('Пока нет записанных прогулок'))),
              for (final s in _sessions)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _picked.contains(s.id),
                  onChanged: (v) => _toggle(s, v ?? false),
                  title: Text('${_defaultName(s)} · ${t(TravelModeInfo.parse(s.mode).label)}'),
                  subtitle: Text(t('точек: {p0}{p1}', {'p0': s.pointCount, 'p1': _picked.contains(s.id) ? ' · № ${_picked.indexOf(s.id) + 1}' : ''})),
                ),
              if (_picked.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(t('Названия в списке на постере'), style: text.titleSmall),
                const SizedBox(height: 8),
                for (final id in _picked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _names[id],
                      decoration: InputDecoration(labelText: '№ ${_picked.indexOf(id) + 1}', border: const OutlineInputBorder(), isDense: true),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: InputDecoration(labelText: t('Название постера'), border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _region,
                decoration: InputDecoration(
                  labelText: t('Место (регион)'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(icon: const Icon(Icons.my_location), tooltip: t('Определить место (нужен интернет)'), onPressed: _detectPlace),
                ),
              ),
              const SizedBox(height: 16),
              Text(t('Фон'), style: text.titleSmall),
              SizedBox(height: 8),
              SegmentedButton<PosterBackground>(
                segments: [
                  ButtonSegment(value: PosterBackground.tropa, label: Text(t('Стиль Tropa'))),
                  ButtonSegment(value: PosterBackground.map, label: Text(t('Карта'))),
                ],
                selected: {o.background},
                onSelectionChanged: (v) => setState(() => o.background = v.first),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: o.dateTime,
                onChanged: (v) => setState(() => o.dateTime = v ?? true),
                title: Text(t('Даты')),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: o.showRegion,
                onChanged: (v) => setState(() => o.showRegion = v ?? true),
                title: Text(t('Место (регион)')),
              ),
              const SizedBox(height: 8),
              Text(t('Высоты берутся из сохранённых данных каждой прогулки (если вы открывали её постер с интернетом, они уточнены по карте высот).'),
                  style: text.bodySmall),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(_png == null ? t('Создать постер') : t('Создать заново')),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              ),
            ]),
    );
  }
}
