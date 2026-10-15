import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import 'db.dart';
import 'debug_log.dart';
import 'elevation.dart';
import 'altitude.dart';
import 'map_page.dart';
import 'map_catalog_page.dart';
import 'map_downloads.dart';
import 'l10n.dart';
import 'units.dart';
import 'maps.dart';
import 'note_thumbs.dart';
import 'pmtiles_extract.dart';
import 'modes.dart';
import 'multi_poster_page.dart';
import 'poster.dart';
import 'poster_progress.dart';
import 'poster_wide.dart';
import 'segments.dart';
import 'settings.dart';
import 'weather.dart';

/// "Постер": the picture of a walk for social networks. The person picks what it shows, the screen
/// builds it, shows a preview, and saves it to the gallery or shares it.
class PosterPage extends StatefulWidget {
  final int sessionId;
  final String title;
  final TravelMode mode;

  const PosterPage({super.key, required this.sessionId, required this.title, required this.mode});

  @override
  State<PosterPage> createState() => _PosterPageState();
}

class _PosterPageState extends State<PosterPage> {
  final o = PosterOptions();
  final _title = TextEditingController();
  final _region = TextEditingController();
  final _water = TextEditingController();

  List<TrackPoint> _pts = const [];
  List<TrackSegment> _segments = const [];
  List<TrackNote> _notes = const [];
  Map<String, ui.Image> _thumbs = const {}; // photos of the notes for the markers
  WeatherInfo? _weather;
  DemSamples? _dem;
  String _demStatus = '';
  String _weatherStatus = t('Проверяю…');
  bool _loading = true;
  bool _hasMap = false;
  bool _busy = false;
  final ScrollController _scroll = ScrollController();
  MapCapture? _buildMap; // the map snapshot of the poster being made, for the animation
  Uint8List? _png;

  bool get _pro => AppSettings.instance.pro;

  /// Is the relief big enough for the slope colouring (a flat walk would only show noise)?
  bool get _slopeOk => slopeAvailable(_altitude ?? fusedAltitude(_pts), 0, _pts.length - 1);

  /// A walk with a vehicle ride and walking stretches: the vehicle part is dashed.
  bool get _hasVehicle => _segments.any((s) => s.mode == TravelMode.car) && _segments.any((s) => s.mode != TravelMode.car);

  String _coloringHint() => switch (o.coloring) {
        LineColoring.single => t('Линия одного цвета'),
        LineColoring.speed => t('Цвет показывает скорость: синий медленнее, красный быстрее'),
        LineColoring.height => t('Цвет показывает высоту над уровнем моря'),
        LineColoring.slope => t('Тёплый — подъём, холодный — спуск'),
      };
  bool get _hasWater => widget.mode == TravelMode.water || _segments.any((s) => s.mode == TravelMode.water);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _title.dispose();
    _region.dispose();
    _water.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = TrackDb.instance;
    final pts = await db.points(widget.sessionId);
    final overrides = await db.segmentOverrides(widget.sessionId);
    final meta = await db.sessionMeta(widget.sessionId);
    final notes = await db.notes(widget.sessionId);
    final thumbs = await loadNoteThumbs(notes);
    // The dark map is the main background; without a map for the place the Tropa style is used.
    final region = pts.isEmpty ? null : await MapStore.regionFor(pts.first.lat, pts.first.lon);
    if (!mounted) return;
    setState(() {
      _hasMap = region != null;
      o.background = _hasMap ? PosterBackground.map : PosterBackground.tropa;
      _pts = pts;
      _notes = notes;
      _thumbs = thumbs;
      _segments = buildSegments(pts, widget.mode, overrides: overrides);
      _title.text = _defaultTitle(pts);
      _region.text = (meta['region'] as String?) ?? '';
      final wt = (meta['water_temp'] as num?)?.toDouble();
      if (wt != null) _water.text = wt.toString();
      final demRaw = meta['elevation'] as String?;
      if (demRaw != null) {
        try {
          _dem = DemSamples.fromJson(jsonDecode(demRaw) as Map<String, dynamic>);
          _demStatus = _demLine(_dem!);
        } catch (e) {
          DebugLog.instance.log('POSTER', 'cached elevation unreadable: $e');
        }
      }
      final raw = meta['weather'] as String?;
      if (raw != null) {
        try {
          _weather = WeatherInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        } catch (e) {
          DebugLog.instance.log('POSTER', 'cached weather unreadable: $e');
        }
      }
      _loading = false;
      _weatherStatus = _weather == null ? t('Погода ещё не загружена') : _weatherLine(_weather!);
    });
    if (pts.length >= 2) {
      // Both need internet; without it the poster is simply made without them.
      if (_weather == null) await _refreshWeather(quiet: true);
      if (_region.text.isEmpty) await _detectPlace(quiet: true);
      if (_dem == null) await _refreshDem(quiet: true);
    }
  }

  /// "Прогулка" / "Велопрогулка" / "Поездка" / "Сплав" by the way of travelling; the date is on the poster anyway.
  String _defaultTitle(List<TrackPoint> pts) {
    if (pts.isEmpty) return widget.title;
    final noun = switch (widget.mode) {
      TravelMode.bike => t('Велопрогулка'),
      TravelMode.car => t('Поездка'),
      TravelMode.water => t('Сплав'),
      _ => t('Прогулка'),
    };
    return noun;
  }

  String _demLine(DemSamples d) =>
      t('Уточнены по карте высот ({s}); на отвесных скалах точность ниже', {'s': d.source == 'srtm30' ? t('SRTM 30 м') : d.source});

  /// Height profile for the poster: GPS, refined by the terrain model when the person wants it and it is there.
  List<double>? get _altitude => _dem != null ? fuseWithDem(fusedAltitude(_pts), _dem!) : null;

  Future<void> _refreshDem({bool quiet = false}) async {
    if (_pts.length < 2) return;
    setState(() => _demStatus = t('Загружаю высоты…'));
    final dem = await fetchDem(_pts);
    if (!mounted) return;
    if (dem == null) {
      setState(() => _demStatus = _dem == null ? t('Нет интернета: высоты по GPS') : _demLine(_dem!));
      if (!quiet) _snack(t('Не удалось получить высоты. Проверьте интернет.'));
      return;
    }
    await TrackDb.instance.setSessionMeta(widget.sessionId, {'elevation': jsonEncode(dem.toJson())});
    setState(() {
      _dem = dem;
      _demStatus = _demLine(dem);
    });
  }

  String _weatherLine(WeatherInfo w) {
    final (emoji, text) = w.condition;
    return t('{a} {b}, {c} · ветер {d} (данные модели Open-Meteo)', {'a': emoji, 'b': Units.temp(w.tempAvg), 'c': text, 'd': Units.speed(w.windKmh / 3.6, digits: 0)});
  }

  ({double lat, double lon}) get _middle {
    final m = _pts[_pts.length ~/ 2];
    return (lat: m.lat, lon: m.lon);
  }

  Future<void> _refreshWeather({bool quiet = false}) async {
    if (_pts.length < 2) return;
    setState(() => _weatherStatus = t('Загружаю погоду…'));
    final mid = _middle;
    final w = await fetchWeather(mid.lat, mid.lon, _pts.first.tsMs, _pts.last.tsMs);
    if (!mounted) return;
    if (w == null) {
      setState(() => _weatherStatus = _weather == null
          ? t('Нет интернета или данных: постер можно создать без погоды, а позже обновить её здесь')
          : _weatherLine(_weather!));
      if (!quiet) _snack(t('Не удалось получить погоду. Проверьте интернет.'));
      return;
    }
    await TrackDb.instance.setSessionMeta(widget.sessionId, {'weather': jsonEncode(w.toJson())});
    setState(() {
      _weather = w;
      _weatherStatus = _weatherLine(w);
    });
  }

  Future<void> _detectPlace({bool quiet = false}) async {
    if (_pts.length < 2) return;
    final mid = _middle;
    final name = await fetchPlaceName(mid.lat, mid.lon);
    if (!mounted) return;
    if (name == null) {
      if (!quiet) _snack(t('Не удалось определить место. Введите его вручную.'));
      return;
    }
    setState(() => _region.text = name);
    await TrackDb.instance.setSessionMeta(widget.sessionId, {'region': name});
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// No map covers the walk: a small piece around the track can be fetched for the poster.
  Future<void> _fetchFragment() async {
    if (_pts.length < 2) return;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in _pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    // A margin of a third of the walk on each side (at least ~2 km), so that the poster has map all around the route.
    final padLat = math.max(0.02, (maxLat - minLat) * 0.33), padLon = math.max(0.02, (maxLon - minLon) * 0.33);
    final box = GeoBox(minLon - padLon, minLat - padLat, maxLon + padLon, maxLat + padLat);
    final d = DateTime.fromMillisecondsSinceEpoch(_pts.first.tsMs);
    final label = '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    final started = await offerDownload(
      context,
      nameRu: 'Фрагмент $label',
      nameEn: 'Fragment $label',
      box: box,
      fileName: 'fragment_${widget.sessionId}.pmtiles',
      fragment: true,
    );
    if (!started || !mounted) return;
    final ok = await MapDownloader.instance.whenFinished();
    MapDownloader.instance.acknowledge();
    if (!mounted) return;
    final region = await MapStore.regionFor(_pts.first.lat, _pts.first.lon);
    setState(() {
      _hasMap = region != null;
      if (_hasMap) o.background = PosterBackground.map;
    });
    if (!ok) _snack(t('Карту загрузить не удалось. Постер можно сделать в стиле Tropa.'));
  }

  Widget _fragmentCard(TextTheme text) {
    final dl = MapDownloader.instance;
    return ListenableBuilder(
      listenable: dl,
      builder: (context, _) {
        final loading = dl.state == DownloadState.downloading || dl.state == DownloadState.planning || dl.state == DownloadState.ready;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('Для этого места нет загруженной карты.'), style: text.titleSmall),
              const SizedBox(height: 4),
              Text(t('Можно скачать только нужный кусок карты вокруг маршрута (обычно несколько МБ) или сделать постер в стиле Tropa.'),
                  style: text.bodySmall),
              const SizedBox(height: 10),
              if (loading)
                LinearProgressIndicator(value: dl.state == DownloadState.downloading && dl.fraction > 0 ? dl.fraction : null)
              else
                FilledButton.tonalIcon(
                  onPressed: _fetchFragment,
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: Text(t('Скачать кусок карты')),
                ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _create() async {
    if (_pts.length < 2) {
      _snack(t('Для постера нужны хотя бы две точки маршрута'));
      return;
    }
    o.title = _title.text;
    o.region = _region.text;
    o.waterTempManual = double.tryParse(_water.text.trim().replaceAll(',', '.'));
    if (o.region.trim().isNotEmpty) {
      await TrackDb.instance.setSessionMeta(widget.sessionId, {'region': o.region.trim()});
    }
    if (o.waterTempManual != null) {
      await TrackDb.instance.setSessionMeta(widget.sessionId, {'water_temp': o.waterTempManual});
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      MapCapture? map;
      if (o.background == PosterBackground.map) {
        map = await Navigator.push<MapCapture>(
          context,
          MaterialPageRoute(
            builder: (_) => MapPage(
              sessionId: widget.sessionId,
              title: t('Готовлю карту…'),
              mode: widget.mode,
              posterCapture: o,
            ),
          ),
        );
        if (!mounted) return;
        if (mounted) setState(() => _buildMap = map); // the animation shows the route on this map
        if (map == null) {
          _snack(t('Карты для этого места нет: постер сделан в стиле Tropa. Карты добавляются в разделе «Карты».'));
        }
      }
      final started = DateTime.now(); // the drawing of the route is shown for one full pass after the map step
      final png = o.format == PosterFormat.horizontal
          ? await composeWidePoster(
              o: o, pts: _pts, segments: _segments, mode: widget.mode, weather: _weather, map: map, notes: _notes,
              noteThumbs: _thumbs, altitude: _altitude, altitudeFused: _altitude != null)
          : await composePoster(
              o: o, pts: _pts, segments: _segments, mode: widget.mode, weather: _weather, map: map, notes: _notes,
              noteThumbs: _thumbs, altitude: _altitude, altitudeFused: _altitude != null);
      // A quick poster still gets one full drawing of the route on screen.
      final left = const Duration(milliseconds: 2600) - DateTime.now().difference(started);
      if (left > Duration.zero) await Future<void>.delayed(left);
      if (!mounted) return;
      setState(() => _png = png);
      // Show the new poster: it sits at the top of the screen, the person pressed the button at the bottom.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);
      });
    } catch (e, st) {
      DebugLog.instance.log('POSTER', 'compose failed: $e\n$st');
      _snack(t('Не удалось создать постер: {p0}', {'p0': e}));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _buildMap = null;
        });
      }
    }
  }

  Future<void> _save() async {
    final png = _png;
    if (png == null) return;
    try {
      final f = await writePoster(png, 'tropa_poster_${widget.sessionId}_${o.format.name}_${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putImage(f.path, album: 'Tropa');
      _snack(t('Постер сохранён в галерею (альбом Tropa)'));
    } catch (e) {
      DebugLog.instance.log('POSTER', 'save failed: $e');
      _snack(t('Не удалось сохранить: {p0}', {'p0': e}));
    }
  }

  Future<void> _share() async {
    final png = _png;
    if (png == null) return;
    final f = await writePoster(png, 'tropa_poster_${widget.sessionId}_${o.format.name}_${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: 'Tropa'));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final screen = Scaffold(
      appBar: AppBar(title: Text(t('Постер'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              if (_pro) ...[
                // The poster of several walks is a variant of this screen, not a separate menu item.
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(t('Эта прогулка')), icon: const Icon(Icons.route)),
                    ButtonSegment(value: true, label: Text(t('Несколько прогулок')), icon: const Icon(Icons.collections_outlined)),
                  ],
                  selected: const {false},
                  onSelectionChanged: (v) {
                    if (v.first) {
                      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MultiPosterPage()));
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],
              if (_png != null) ...[
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 520),
                    // The new poster appears gently once the drawing of the route fades out.
                    child: TweenAnimationBuilder<double>(
                      key: ObjectKey(_png),
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      builder: (_, v, child) => Opacity(opacity: v, child: Transform.scale(scale: 0.94 + 0.06 * v, child: child)),
                      child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_png!)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: FilledButton.icon(
                          onPressed: _save, icon: const Icon(Icons.download), label: Text(t('Сохранить постер')))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: OutlinedButton.icon(
                          onPressed: _share, icon: const Icon(Icons.share), label: Text(t('Поделиться постером')))),
                ]),
                const Divider(height: 32),
              ],
              TextField(
                controller: _title,
                decoration: InputDecoration(labelText: t('Название'), border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _region,
                decoration: InputDecoration(
                  labelText: t('Место (регион)'),
                  hintText: t('Например: Ниньбинь, Вьетнам'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.my_location),
                    tooltip: t('Определить место (нужен интернет)'),
                    onPressed: _detectPlace,
                  ),
                ),
              ),
              if (_pro) ...[
                const SizedBox(height: 16),
                Text(t('Формат'), style: text.titleSmall),
                SizedBox(height: 8),
                SegmentedButton<PosterFormat>(
                  segments: [
                    ButtonSegment(value: PosterFormat.vertical, label: Text(t('Для соцсетей')), icon: Icon(Icons.smartphone)),
                    ButtonSegment(value: PosterFormat.horizontal, label: Text(t('Профи-карта')), icon: Icon(Icons.map)),
                  ],
                  selected: {o.format},
                  onSelectionChanged: (v) => setState(() => o.format = v.first),
                ),
              ],
              const SizedBox(height: 16),
              Text(t('Фон'), style: text.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<PosterBackground>(
                segments: [
                  ButtonSegment(value: PosterBackground.tropa, label: Text(t('Стиль Tropa'))),
                  ButtonSegment(value: PosterBackground.map, label: Text(t('Карта')), enabled: _hasMap),
                ],
                selected: {o.background},
                onSelectionChanged: (v) => setState(() => o.background = v.first),
              ),
              if (!_hasMap) _fragmentCard(text),
              const SizedBox(height: 16),
              Text(t('Окраска линии'), style: text.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final (v, label) in [
                  (LineColoring.single, t('Один цвет')),
                  (LineColoring.speed, t('Скорость')),
                  (LineColoring.height, t('Высота')),
                  (LineColoring.slope, t('Уклон')),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: o.coloring == v,
                    onSelected: v == LineColoring.slope && !_slopeOk ? null : (_) => setState(() => o.coloring = v),
                  ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _slopeOk ? _coloringHint() : t('Маршрут ровный'),
                  style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              if (_hasVehicle)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(t('Участки на транспорте рисуются пунктиром'),
                      style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              const SizedBox(height: 12),
              Text(t('Что показать'), style: text.titleSmall),
              _check(t('Дистанция'), o.distance, (v) => o.distance = v),
              _check(t('Время в движении'), o.time, (v) => o.time = v),
              _check(t('Скорость'), o.speed, (v) => o.speed = v),
              _check(t('Набор высоты'), o.elevation, (v) => o.elevation = v, subtitle: _demStatus.isEmpty ? null : _demStatus),
              _check(t('Дата, время начала и окончания'), o.dateTime, (v) => o.dateTime = v),
              _check(t('Место (регион)'), o.showRegion, (v) => o.showRegion = v),
              _check(t('Погода во время маршрута'), o.weather, (v) => o.weather = v, subtitle: _weatherStatus),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                    onPressed: () async {
                      await _refreshWeather();
                      await _refreshDem();
                    },
                    icon: const Icon(Icons.cloud_sync),
                    label: Text(t('Обновить погоду и высоты'))),
              ),
              if (_hasWater) ...[
                _check(t('Температура воды'), o.waterTemp, (v) => o.waterTemp = v,
                    subtitle: _weather?.seaTemp == null
                        ? t('Для рек и озёр данных нет: впишите температуру вручную')
                        : t('Море: {p} (данные модели). Можно указать свою', {'p': Units.temp(_weather!.seaTemp!, digits: 1)})),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: TextField(
                    controller: _water,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: InputDecoration(
                        labelText: t('Температура воды, °C (необязательно)'), border: OutlineInputBorder()),
                  ),
                ),
              ],
              _check(t('Подписи: максимум скорости и высоты'), o.peaks, (v) => o.peaks = v),
              if (o.format == PosterFormat.vertical) _check(t('Мини-профиль высоты'), o.profile, (v) => o.profile = v),
              if (_notes.isNotEmpty) _check(t('Заметки на маршруте ({p0})', {'p0': _notes.length}), o.notes, (v) => o.notes = v),
              _check(t('Способы движения с дистанцией и скоростью'), o.legend, (v) => o.legend = v),
              if (_pro) ...[
                _check(t('Выделять восстановленные участки'), o.showRestored, (v) => o.showRestored = v),
                _check(t('Скрыть старт и финиш'), o.hideEnds, (v) => o.hideEnds = v,
                    subtitle: t('Без маркеров, первые и последние {p0} линии не рисуются', {'p0': Units.shortDist(PosterOptions.hideEndsMeters)})),
              ],
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
    // While the poster is made, the route is drawn on the whole screen; it fades out when the poster is ready.
    return Stack(children: [
      screen,
      Positioned.fill(
        child: IgnorePointer(
          ignoring: !_busy,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: _busy && _pts.length > 1
                ? Material(key: const ValueKey("building"), child: PosterBuildOverlay(points: _pts, map: _buildMap, wide: o.format == PosterFormat.horizontal))
                : const SizedBox.shrink(key: ValueKey("idle")),
          ),
        ),
      ),
    ]);
  }

  Widget _check(String title, bool value, void Function(bool) set, {String? subtitle}) => CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: value,
        onChanged: (v) => setState(() => set(v ?? value)),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        controlAffinity: ListTileControlAffinity.leading,
      );
}
