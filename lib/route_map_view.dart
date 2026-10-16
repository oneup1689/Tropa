import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'debug_log.dart';
import 'heal.dart' show LatLon, haversine;
import 'l10n.dart';
import 'map_catalog_page.dart';
import 'map_downloads.dart';
import 'map_geojson.dart';
import 'maps.dart';
import 'pmtiles_extract.dart' show GeoBox;
import 'route_nav.dart';

/// The map of one saved route inside the route screen: the route on the offline map, start and finish, the turns the
/// navigator will announce, a dashed line from you to the start. Without a map that covers the whole route it shows
/// [preview] (the plain drawing) and a card that fetches the piece of map around the route.
class RouteMapView extends StatefulWidget {
  final int routeId;
  final String name;
  final List<({double lat, double lon})> points;
  final bool reverse;

  /// Where the person is now (null: unknown). Drawn as the marker; a dashed line goes from it to the start.
  final ValueListenable<Position?> me;

  /// Shown instead of the map while there is no map for the route.
  final Widget preview;
  final double height;
  final VoidCallback onFullscreen;

  /// Navigation mode: the camera stays on the person (zoomed in, turned to the direction of walking) until they touch
  /// the map; "Где я" brings it back.
  final bool follow;

  /// Added to the style file name, so that two screens showing the same route do not write one file.
  final String fileTag;

  const RouteMapView({
    super.key,
    required this.routeId,
    required this.name,
    required this.points,
    required this.reverse,
    required this.me,
    required this.preview,
    required this.onFullscreen,
    this.height = 280,
    this.follow = false,
    this.fileTag = '',
  });

  @override
  State<RouteMapView> createState() => _RouteMapViewState();
}

class _RouteMapViewState extends State<RouteMapView> {
  MapLibreMapController? _controller;
  String? _stylePath;
  bool _checking = true;
  bool _styleReady = false;
  double _bearing = 0;
  bool _hasBearing = false;
  String? _problem;
  late bool _follow = widget.follow;

  /// The frame of the route: min/max latitude and longitude.
  late final ({double minLat, double minLon, double maxLat, double maxLon}) _box = _frame();

  ({double minLat, double minLon, double maxLat, double maxLon}) _frame() {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in widget.points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    return (minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon);
  }

  ({double lat, double lon}) get _start => widget.reverse ? widget.points.last : widget.points.first;
  ({double lat, double lon}) get _finish => widget.reverse ? widget.points.first : widget.points.last;

  @override
  void initState() {
    super.initState();
    widget.me.addListener(_onMe);
    _check();
  }

  @override
  void didUpdateWidget(covariant RouteMapView old) {
    super.didUpdateWidget(old);
    if (old.me != widget.me) {
      old.me.removeListener(_onMe);
      widget.me.addListener(_onMe);
    }
    if (old.reverse != widget.reverse) {
      _updateDirection();
      _onMe();
    }
  }

  @override
  void dispose() {
    widget.me.removeListener(_onMe);
    super.dispose();
  }

  /// Is there one installed map that covers the whole route? Then the style is written and the map shown.
  Future<void> _check() async {
    try {
      final region = await MapStore.regionCovering(_box.minLat, _box.minLon, _box.maxLat, _box.maxLon);
      if (!mounted) return;
      if (region == null) {
        setState(() {
          _stylePath = null;
          _checking = false;
        });
        return;
      }
      final dark = Theme.of(context).brightness == Brightness.dark;
      final path = await MapStore.writeStyleWithOverlay(
        region,
        dark: dark,
        sources: {
          for (final id in ['route', 'marks', 'turns', 'mestart', 'locator'])
            id: {'type': 'geojson', 'data': geoFc(const [])},
        },
        layers: _layers(),
        fileName: 'style_route_${widget.routeId}${widget.fileTag}.json',
      );
      if (!mounted) return;
      setState(() {
        _stylePath = path;
        _checking = false;
        _styleReady = false;
      });
    } catch (e, st) {
      DebugLog.instance.log('MAP', 'route map prepare failed: $e\n$st');
      if (mounted) {
        setState(() {
          _checking = false;
          _problem = t('Не удалось подготовить карту: {p0}', {'p0': e});
        });
      }
    }
  }

  List<Map<String, Object?>> _layers() {
    Map<String, Object?> dots(String id, {double? minzoom}) => {
          'id': 'tropa-$id',
          'type': 'circle',
          'source': id,
          'minzoom': ?minzoom,
          'paint': {
            'circle-radius': ['get', 'r'],
            'circle-color': ['get', 'color'],
            'circle-stroke-color': '#FFFFFF',
            'circle-stroke-width': 2,
          },
        };
    Map<String, Object?> label(String id, String color, {double? minzoom, double offset = 1.5}) => {
          'id': 'tropa-$id-label',
          'type': 'symbol',
          'source': id,
          'minzoom': ?minzoom,
          'filter': ['!=', ['get', 'label'], ''],
          'layout': {
            'text-field': ['get', 'label'],
            'text-font': ['Noto Sans Regular'],
            'text-size': 13,
            'text-offset': [0, offset],
            'text-anchor': 'top',
            'text-max-width': 10,
          },
          'paint': {'text-color': color, 'text-halo-color': '#FFFFFF', 'text-halo-width': 1.6},
        };
    return [
      {
        'id': 'tropa-route',
        'type': 'line',
        'source': 'route',
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {'line-color': '#1E88E5', 'line-width': 5, 'line-opacity': 0.85},
      },
      {
        // From you to the start of the route.
        'id': 'tropa-mestart',
        'type': 'line',
        'source': 'mestart',
        'layout': {'line-cap': 'butt', 'line-join': 'round'},
        'paint': {'line-color': '#FF7043', 'line-width': 3, 'line-dasharray': [2, 2]},
      },
      dots('turns', minzoom: 12),
      label('turns', '#263238', minzoom: 13.5, offset: 1.1),
      dots('marks'),
      label('marks', '#4A148C'),
      {
        'id': 'tropa-locator',
        'type': 'symbol',
        'source': 'locator',
        'layout': {
          'icon-image': ['get', 'icon'],
          'icon-rotate': ['get', 'bearing'],
          'icon-rotation-alignment': 'map',
          'icon-allow-overlap': true,
          'icon-ignore-placement': true,
          'icon-size': 0.9,
        },
      },
    ];
  }

  LatLng _ll(({double lat, double lon}) p) => LatLng(p.lat, p.lon);

  List<Map<String, Object?>> _markFeatures() {
    final isLoop = haversine(_start.lat, _start.lon, _finish.lat, _finish.lon) < 40;
    return [
      geoPoint(_ll(_start), color: '#43A047', radius: 7, label: isLoop ? t('Старт / финиш') : t('Старт')),
      if (!isLoop) geoPoint(_ll(_finish), radius: 7, label: t('Финиш')),
    ];
  }

  /// The turns the navigator announces, numbered: left blue, right orange, sharp ones and U-turns red.
  List<Map<String, Object?>> _turnFeatures() {
    final path = RoutePath.build([for (final p in widget.points) LatLon(p.lat, p.lon)], reverse: widget.reverse);
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < path.maneuvers.length; i++) {
      final m = path.maneuvers[i];
      final at = path.pts[(m.at / RoutePath.step).round().clamp(0, path.pts.length - 1)];
      final sharp = m.turn == Turn.sharpLeft || m.turn == Turn.sharpRight || m.turn == Turn.uTurn;
      final color = sharp ? '#E53935' : (m.turn.isLeft ? '#1E88E5' : '#FB8C00');
      out.add(geoPoint(LatLng(at.lat, at.lon), color: color, radius: 6, label: '${i + 1}'));
    }
    return out;
  }

  Future<void> _updateDirection() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    await c.setGeoJsonSource('marks', geoFc(_markFeatures()));
    await c.setGeoJsonSource('turns', geoFc(_turnFeatures()));
  }

  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.addImage('me-dot', await locatorMarkerPng(arrow: false));
      await c.addImage('me-arrow', await locatorMarkerPng(arrow: true));
      final line = [for (final p in widget.points) LatLng(p.lat, p.lon)];
      await c.setGeoJsonSource('route', geoFc([geoLine(line)]));
      _styleReady = true;
      await _updateDirection();
      if (!(widget.follow && widget.me.value != null)) await _fit();
      await _onMe();
    } catch (e) {
      DebugLog.instance.log('MAP', 'route map style setup failed: $e');
    }
  }

  /// The route fills the map; with [withMe] the person's position is in the picture too.
  Future<void> _fit({bool withMe = false}) async {
    final c = _controller;
    if (c == null) return;
    var minLat = _box.minLat, minLon = _box.minLon, maxLat = _box.maxLat, maxLon = _box.maxLon;
    final me = widget.me.value;
    if (withMe && me != null) {
      minLat = math.min(minLat, me.latitude);
      maxLat = math.max(maxLat, me.latitude);
      minLon = math.min(minLon, me.longitude);
      maxLon = math.max(maxLon, me.longitude);
    }
    final b = LatLngBounds(southwest: LatLng(minLat, minLon), northeast: LatLng(maxLat, maxLon));
    await c.animateCamera(CameraUpdate.newLatLngBounds(b, left: 36, right: 36, top: 36, bottom: 56));
  }

  /// The position changed: move the marker, and draw (or hide) the dashed line to the start.
  Future<void> _onMe() async {
    final c = _controller;
    final p = widget.me.value;
    if (c == null || !_styleReady) return;
    if (p == null) {
      await c.setGeoJsonSource('locator', geoFc(const []));
      await c.setGeoJsonSource('mestart', geoFc(const []));
      return;
    }
    if (p.speed >= 1.0 && p.hasHeading && p.heading > 0) {
      _bearing = p.heading;
      _hasBearing = true;
    }
    final here = LatLng(p.latitude, p.longitude);
    await c.setGeoJsonSource('locator', geoFc([
      {
        'type': 'Feature',
        'properties': {'icon': _hasBearing ? 'me-arrow' : 'me-dot', 'bearing': _bearing},
        'geometry': {
          'type': 'Point',
          'coordinates': [here.longitude, here.latitude],
        },
      }
    ]));
    final far = haversine(p.latitude, p.longitude, _start.lat, _start.lon) > 50;
    await c.setGeoJsonSource('mestart', geoFc(far ? [geoLine([here, _ll(_start)])] : const []));
    if (widget.follow) {
      if (_follow) {
        await c.animateCamera(CameraUpdate.newCameraPosition(
            CameraPosition(target: here, zoom: 17, bearing: _hasBearing ? _bearing : 0)));
      }
      return;
    }
    if (!_fittedWithMe) {
      // The first position: show the route and the person together (the way to the start is the point).
      _fittedWithMe = true;
      await _fit(withMe: true);
    }
  }

  bool _fittedWithMe = false;

  Future<void> _centerOnMe() async {
    final p = widget.me.value;
    if (p == null) return;
    _follow = widget.follow;
    await _controller?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(p.latitude, p.longitude), widget.follow ? 17 : 15));
  }

  // ------------------------------------------------------------------ no map: download the piece around the route

  Future<void> _download() async {
    // A margin of a third of the route on each side (at least ~2 km), so that there is map all around it.
    final padLat = math.max(0.02, (_box.maxLat - _box.minLat) * 0.33), padLon = math.max(0.02, (_box.maxLon - _box.minLon) * 0.33);
    final box = GeoBox(_box.minLon - padLon, _box.minLat - padLat, _box.maxLon + padLon, _box.maxLat + padLat);
    final started = await offerDownload(
      context,
      nameRu: 'Карта: ${widget.name}',
      nameEn: 'Map: ${widget.name}',
      box: box,
      fileName: 'fragment_route_${widget.routeId}.pmtiles',
      fragment: true,
    );
    if (!started || !mounted) return;
    final ok = await MapDownloader.instance.whenFinished();
    MapDownloader.instance.acknowledge();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Карту загрузить не удалось. Попробуйте ещё раз.'))));
    }
    setState(() => _checking = true);
    await _check();
  }

  Widget _downloadCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dl = MapDownloader.instance;
    return ListenableBuilder(
      listenable: dl,
      builder: (context, _) {
        final planning = dl.state == DownloadState.planning || dl.state == DownloadState.ready;
        final downloading = dl.state == DownloadState.downloading;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('Карта этого маршрута не загружена'), style: text.titleSmall),
              const SizedBox(height: 4),
              Text(t('Можно скачать только кусок карты вокруг маршрута (обычно несколько МБ): маршрут будет виден на карте и без интернета.'),
                  style: text.bodySmall),
              const SizedBox(height: 10),
              if (planning || downloading) ...[
                LinearProgressIndicator(value: downloading && dl.fraction > 0 ? dl.fraction : null),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: Text(
                      downloading
                          ? t('Скачано {a} из {b} МБ', {'a': (dl.bytesDone / 1048576).toStringAsFixed(1), 'b': (dl.bytesTotal / 1048576).toStringAsFixed(1)})
                          : t('Считаю размер…'),
                      style: text.bodySmall,
                    ),
                  ),
                  TextButton(onPressed: dl.cancel, child: Text(t('Отмена'))),
                ]),
              ] else ...[
                if (dl.state == DownloadState.failed && dl.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(t('Не получилось: {e}', {'e': dl.error}), style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
                  ),
                FilledButton.tonalIcon(
                  onPressed: dl.busy ? null : _download,
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: Text(t('Скачать карту маршрута')),
                ),
              ],
            ]),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return SizedBox(height: widget.height, child: const Card(child: Center(child: CircularProgressIndicator())));
    }
    if (_stylePath == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        widget.preview,
        if (_problem != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_problem!)),
        _downloadCard(context),
      ]);
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: widget.height,
        child: Stack(children: [
          Positioned.fill(
            child: Listener(
              // The person moved the map by hand: stop following until "Где я" is pressed.
              onPointerDown: (_) => _follow = false,
              child: MapLibreMap(
              styleString: _stylePath!,
              initialCameraPosition: CameraPosition(
                target: LatLng((_box.minLat + _box.maxLat) / 2, (_box.minLon + _box.maxLon) / 2),
                zoom: 12,
              ),
              onMapCreated: (c) => _controller = c,
              onStyleLoadedCallback: _onStyleLoaded,
              compassEnabled: false,
              myLocationEnabled: false,
              attributionButtonPosition: AttributionButtonPosition.bottomLeft,
              // The map sits inside a scrolling page: it must win the touches that start on it.
              gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer())},
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: Column(children: [
              _mapButton(Icons.zoom_out_map, t('Весь маршрут'), () {
                _follow = false;
                _fit(withMe: widget.me.value != null);
              }),
              const SizedBox(height: 6),
              _mapButton(Icons.fullscreen, t('На весь экран'), widget.onFullscreen),
              ValueListenableBuilder<Position?>(
                valueListenable: widget.me,
                builder: (context, p, _) => p == null
                    ? const SizedBox.shrink()
                    : Padding(padding: const EdgeInsets.only(top: 6), child: _mapButton(Icons.my_location, t('Где я'), _centerOnMe)),
              ),
            ]),
          ),
          Positioned(
            left: 44,
            bottom: 6,
            child: const Text('© OpenStreetMap, Protomaps', style: TextStyle(fontSize: 10, color: Colors.black54)),
          ),
        ]),
      ),
    );
  }

  Widget _mapButton(IconData icon, String tooltip, VoidCallback onTap) => Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        elevation: 2,
        child: IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onTap, visualDensity: VisualDensity.compact),
      );
}
