import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'db.dart';
import 'debug_log.dart';
import 'heal.dart';
import 'maps.dart';
import 'maps_page.dart';
import 'modes.dart';
import 'recorder.dart';
import 'settings.dart';
import 'share_dialog.dart';

/// Offline map with a recorded walk, an imported route, notes, or the live position.
///
/// Everything that is drawn (track, restored gaps, route, notes) is part of the map *style* as GeoJSON
/// layers, not map annotations: that way the plugin's snapshotter, which re-reads the style, produces the
/// share picture with the route on it.
class MapPage extends StatefulWidget {
  final int? sessionId;
  final int? routeId;

  /// Follow the current position and redraw the track while recording.
  final bool live;
  final String title;
  final TravelMode mode;

  const MapPage({
    super.key,
    this.sessionId,
    this.routeId,
    this.live = false,
    this.title = 'Карта',
    this.mode = TravelMode.mixed,
  });

  @override
  State<MapPage> createState() => _MapPageState();
}

Map<String, Object?> _fc(List<Map<String, Object?>> features) => {'type': 'FeatureCollection', 'features': features};

Map<String, Object?> _lineFeature(List<LatLng> pts) => {
      'type': 'Feature',
      'properties': <String, Object?>{},
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (final p in pts) [p.longitude, p.latitude],
        ],
      },
    };

Map<String, Object?> _pointFeature(LatLng p, {String color = '#E53935', double radius = 8, String label = ''}) => {
      'type': 'Feature',
      'properties': {'color': color, 'r': radius, 'label': label},
      'geometry': {
        'type': 'Point',
        'coordinates': [p.longitude, p.latitude],
      },
    };

class _Overlay {
  final Map<String, Object?> track, restored, gaps, route, marks;
  final List<LatLng> bounds;

  _Overlay(this.track, this.restored, this.gaps, this.route, this.marks, this.bounds);
}

class _MapPageState extends State<MapPage> {
  MapLibreMapController? _controller;
  String? _stylePath;
  MapRegion? _region;
  bool _loading = true;
  String? _problem;
  Timer? _liveTimer;
  bool _follow = true;
  LatLng? _initial;
  double _zoom = 13;
  _Overlay? _overlay;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  Future<List<TrackPoint>> _sessionPoints() async =>
      widget.sessionId == null ? const [] : await TrackDb.instance.points(widget.sessionId!);

  /// Picks the installed region that covers the walk (or the current position) and builds the style.
  Future<void> _prepare() async {
    try {
      double? lat, lon;
      final pts = await _sessionPoints();
      if (pts.isNotEmpty) {
        lat = pts.first.lat;
        lon = pts.first.lon;
      } else if (widget.routeId != null) {
        final rp = await TrackDb.instance.routePoints(widget.routeId!);
        if (rp.isNotEmpty) {
          lat = rp.first.lat;
          lon = rp.first.lon;
        }
      } else if (Recorder.instance.lastLat != 0) {
        lat = Recorder.instance.lastLat;
        lon = Recorder.instance.lastLon;
      }

      MapRegion? region;
      final all = await MapStore.regions();
      if (lat != null && lon != null) {
        region = await MapStore.regionFor(lat, lon);
      } else if (all.isNotEmpty) {
        region = all.first;
      }
      if (region == null) {
        setState(() {
          _loading = false;
          _problem = all.isEmpty
              ? (MapStore.lastListError ?? 'Нет загруженных карт. Добавьте файл карты в разделе «Карты».')
              : 'Для этого места нет карты. Загруженные регионы не покрывают его.';
        });
        return;
      }
      if (!mounted) return;
      final dark = Theme.of(context).brightness == Brightness.dark;
      final chosen = region;
      final overlay = await _buildOverlay(pts);
      final path = await MapStore.writeStyleWithOverlay(
        chosen,
        dark: dark,
        sources: {
          for (final (id, fc) in [
            ('route', overlay.route),
            ('track', overlay.track),
            ('restored', overlay.restored),
            ('gaps', overlay.gaps),
            ('marks', overlay.marks),
            ('me', _fc(const [])),
          ])
            id: {'type': 'geojson', 'data': fc},
        },
        layers: _overlayLayers(),
      );
      final b = chosen.bounds;
      setState(() {
        _region = chosen;
        _stylePath = path;
        _overlay = overlay;
        // No position to show: start in the middle of the installed region, zoomed out.
        _initial = lat != null
            ? LatLng(lat, lon!)
            : (b == null ? null : LatLng((b.minLat + b.maxLat) / 2, (b.minLon + b.maxLon) / 2));
        _zoom = lat != null ? 13 : 9;
        _loading = false;
      });
    } catch (e, st) {
      DebugLog.instance.log('MAP', 'prepare failed: $e\n$st');
      setState(() {
        _loading = false;
        _problem = 'Не удалось подготовить карту: $e';
      });
    }
  }

  List<Map<String, Object?>> _overlayLayers() {
    Map<String, Object?> line(String id, String color, double width, [double opacity = 1]) => {
          'id': 'tropa-$id',
          'type': 'line',
          'source': id,
          'layout': {'line-cap': 'round', 'line-join': 'round'},
          'paint': {'line-color': color, 'line-width': width, 'line-opacity': opacity},
        };
    Map<String, Object?> dots(String id) => {
          'id': 'tropa-$id',
          'type': 'circle',
          'source': id,
          'paint': {
            'circle-radius': ['get', 'r'],
            'circle-color': ['get', 'color'],
            'circle-stroke-color': '#FFFFFF',
            'circle-stroke-width': 2,
          },
        };
    return [
      line('route', '#1E88E5', 5, 0.85),
      line('gaps', '#E53935', 1.5, 0.4),
      line('track', '#E53935', 4.5),
      line('restored', '#FB8C00', 4.5),
      dots('marks'),
      dots('me'),
      {
        // Note texts next to their markers (fonts are the bundled Noto Sans glyphs).
        'id': 'tropa-marks-label',
        'type': 'symbol',
        'source': 'marks',
        'filter': ['!=', ['get', 'label'], ''],
        'layout': {
          'text-field': ['get', 'label'],
          'text-font': ['Noto Sans Regular'],
          'text-size': 14,
          'text-offset': [0, 1.6],
          'text-anchor': 'top',
          'text-max-width': 10,
        },
        'paint': {'text-color': '#4A148C', 'text-halo-color': '#FFFFFF', 'text-halo-width': 1.6},
      },
    ];
  }

  /// Track, restored gaps, unresolved gaps, imported route, start/end/note markers as GeoJSON.
  Future<_Overlay> _buildOverlay(List<TrackPoint> pts) async {
    final all = <LatLng>[];
    final track = <Map<String, Object?>>[];
    final restored = <Map<String, Object?>>[];
    final gaps = <Map<String, Object?>>[];
    final marks = <Map<String, Object?>>[];
    var route = _fc(const []);

    if (widget.routeId != null) {
      final rp = await TrackDb.instance.routePoints(widget.routeId!);
      final line = [for (final p in rp) LatLng(p.lat, p.lon)];
      if (line.length >= 2) {
        route = _fc([_lineFeature(line)]);
        all.addAll(line);
      }
    }

    if (widget.sessionId != null && pts.isNotEmpty) {
      final result = analyzeGaps(pts, settings: AppSettings.instance.healFor(widget.mode));
      var seg = <LatLng>[];
      void flush() {
        if (seg.length >= 2) track.add(_lineFeature(List.of(seg)));
        seg = <LatLng>[];
      }

      for (var i = 0; i < pts.length; i++) {
        final here = LatLng(pts[i].lat, pts[i].lon);
        all.add(here);
        final gap = i > 0 ? result.gapAt(i) : null;
        if (gap == null) {
          seg.add(here);
          continue;
        }
        final prev = LatLng(pts[i - 1].lat, pts[i - 1].lon);
        final heal = AppSettings.instance.healEnabled && (gap.kind == GapKind.glueStill || gap.kind == GapKind.bridge);
        flush();
        if (heal) {
          // Smooth continuation of the route across the gap.
          restored.add(_lineFeature([prev, for (final p in gap.curve) LatLng(p.lat, p.lon), here]));
        } else {
          // Unresolved gap: a faint straight hint, the real track stays broken.
          gaps.add(_lineFeature([prev, here]));
        }
        seg = <LatLng>[here];
      }
      flush();

      marks.add(_pointFeature(LatLng(pts.first.lat, pts.first.lon), color: '#43A047'));
      if (!widget.live) marks.add(_pointFeature(LatLng(pts.last.lat, pts.last.lon)));
      for (final n in await TrackDb.instance.notes(widget.sessionId!)) {
        marks.add(_pointFeature(LatLng(n.lat, n.lon),
            color: '#8E24AA', radius: 7, label: n.text.isNotEmpty ? n.text : (n.mediaType == 'video' ? 'видео' : 'фото')));
      }
    }
    return _Overlay(_fc(track), _fc(restored), _fc(gaps), route, _fc(marks), all);
  }

  LatLngBounds? _bounds(Iterable<LatLng> pts) {
    if (pts.isEmpty) return null;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    return LatLngBounds(southwest: LatLng(minLat, minLon), northeast: LatLng(maxLat, maxLon));
  }

  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;
    if (widget.live) {
      _liveTimer = Timer.periodic(const Duration(seconds: 2), (_) => _tickLive());
      _tickLive();
      return;
    }
    final b = _bounds(_overlay?.bounds ?? const []);
    if (b != null) {
      await c.animateCamera(CameraUpdate.newLatLngBounds(b, left: 40, right: 40, top: 60, bottom: 60));
    }
  }

  /// Camera (centre, zoom) that frames [pts] in the band y = 360..1120 of a 1080x1920 picture.
  (LatLng, double)? _fitForSnapshot(List<LatLng> pts) {
    final b = _bounds(pts);
    if (b == null) return null;
    const size = 512.0; // MapLibre uses 512 px world tiles, so zoom z spans 512 * 2^z pixels
    double lonToX(double lon, double z) => (lon + 180) / 360 * size * math.pow(2, z);
    double latToY(double lat, double z) {
      final s = math.sin(lat * math.pi / 180);
      return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * size * math.pow(2, z);
    }

    double yToLat(double y, double z) {
      final n = math.pi - 2 * math.pi * y / (size * math.pow(2, z));
      return 180 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
    }

    // The route must stay clear of the title (top) and of up to four statistics (from y ~ 1010 down).
    const availW = 900.0, availH = 610.0;
    // Zoom at which the bounds fill the available band.
    var z = 18.0;
    while (z > 3) {
      final w = (lonToX(b.northeast.longitude, z) - lonToX(b.southwest.longitude, z)).abs();
      final h = (latToY(b.southwest.latitude, z) - latToY(b.northeast.latitude, z)).abs();
      if (w <= availW && h <= availH) break;
      z -= 0.25;
    }
    final cx = (lonToX(b.northeast.longitude, z) + lonToX(b.southwest.longitude, z)) / 2;
    final cy = (latToY(b.northeast.latitude, z) + latToY(b.southwest.latitude, z)) / 2;
    // The band (y = 340..950) is centred at y = 645 while the picture centre is at y = 960: move the camera
    // centre south by the difference.
    final camY = cy + (960 - 645);
    final lon = cx / (size * math.pow(2, z)) * 360 - 180;
    return (LatLng(yToLat(camY, z), lon), z);
  }

  /// Live mode: redraw the recorded part and keep the camera on the current position.
  Future<void> _tickLive() async {
    final c = _controller;
    final rec = Recorder.instance;
    if (c == null || !mounted) return;
    final sid = rec.sessionId;
    if (sid != null) {
      final pts = await TrackDb.instance.points(sid);
      final line = [for (final p in pts) LatLng(p.lat, p.lon)];
      if (line.length >= 2) await c.setGeoJsonSource('track', _fc([_lineFeature(line)]));
    }
    if (rec.lastLat != 0) {
      final here = LatLng(rec.lastLat, rec.lastLon);
      await c.setGeoJsonSource('me', _fc([_pointFeature(here, color: '#1E88E5', radius: 9)]));
      if (_follow) await c.animateCamera(CameraUpdate.newLatLng(here));
    }
  }

  /// Picture for social networks: the plugin's snapshotter renders the map (with the route, because the
  /// route is part of the style) and the statistics are drawn on top.
  Future<void> _shareImage() async {
    final c = _controller;
    if (c == null) return;
    final options = await askShareOptions(context);
    if (options == null || !mounted) return;
    try {
      // The snapshot is 1080x1920 pixels, so frame the route for that size: it goes into the free band
      // between the title (top) and the statistics (bottom), then wait for the tiles.
      final fit = _fitForSnapshot(_overlay?.bounds ?? const []);
      if (fit != null) {
        await c.moveCamera(CameraUpdate.newLatLngZoom(fit.$1, fit.$2));
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      // Restored gaps look like the rest of the route unless the user asked to highlight them.
      final overlay = _overlay;
      final blend = !options.showRestored && overlay != null;
      if (blend) {
        final features = [
          ...(overlay.track['features'] as List<Object?>),
          ...(overlay.restored['features'] as List<Object?>),
        ].cast<Map<String, Object?>>();
        await c.setGeoJsonSource('track', _fc(features));
        await c.setLayerVisibility('tropa-restored', false);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final Uint8List map;
      try {
        map = await c.takeSnapshot(width: 1080, height: 1920);
      } finally {
        if (blend) {
          await c.setGeoJsonSource('track', overlay.track);
          await c.setLayerVisibility('tropa-restored', true);
        }
      }
      final pts = await _sessionPoints();
      await shareRouteImage(
        title: widget.title,
        pts: pts,
        mode: widget.mode,
        options: options,
        mapPng: map,
        fileName: 'tropa_${widget.sessionId}',
      );
    } catch (e) {
      DebugLog.instance.log('MAP', 'share image failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось создать картинку: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.sessionId != null && _stylePath != null)
            IconButton(
              icon: const Icon(Icons.image_outlined),
              tooltip: 'Картинка для соцсетей',
              onPressed: _shareImage,
            ),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Карты',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapsPage())),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null || _stylePath == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_problem ?? 'Карта недоступна', textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapsPage())),
                        child: const Text('Открыть «Карты»'),
                      ),
                    ]),
                  ),
                )
              : Stack(children: [
                  MapLibreMap(
                    styleString: _stylePath!,
                    initialCameraPosition: CameraPosition(target: _initial ?? const LatLng(20, 106), zoom: _zoom),
                    onMapCreated: (c) => _controller = c,
                    onStyleLoadedCallback: _onStyleLoaded,
                    compassEnabled: true,
                    myLocationEnabled: false,
                    attributionButtonPosition: AttributionButtonPosition.bottomLeft,
                  ),
                  if (widget.live)
                    Positioned(
                      right: 12,
                      bottom: 28,
                      child: FloatingActionButton.small(
                        onPressed: () => setState(() => _follow = !_follow),
                        child: Icon(_follow ? Icons.my_location : Icons.location_searching),
                      ),
                    ),
                  Positioned(
                    left: 8,
                    bottom: 4,
                    child: Text(
                      '© OpenStreetMap, Protomaps${_region == null ? '' : ' · ${_region!.name}'}',
                      style: const TextStyle(fontSize: 10, color: Colors.black54),
                    ),
                  ),
                ]),
    );
  }
}
