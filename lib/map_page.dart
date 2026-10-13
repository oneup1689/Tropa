import 'dart:async';
import 'dart:math' as math;

import 'dart:ui' as ui;

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
import 'poster.dart';
import 'segments.dart';
import 'poster_page.dart';
import 'poster_wide.dart';
import 'l10n.dart';

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

  /// Set when the screen is only used to photograph the map for a poster: it frames the walk, takes
  /// the snapshot and returns a [MapCapture] (or null when there is no map for the place).
  final PosterOptions? posterCapture;

  /// With [posterCapture]: several walks for a multi-route poster (the map frames all of them).
  final List<int>? captureSessionIds;

  const MapPage({
    super.key,
    this.sessionId,
    this.routeId,
    this.live = false,
    this.title = '',
    this.mode = TravelMode.mixed,
    this.posterCapture,
    this.captureSessionIds,
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

  Future<List<TrackPoint>> _sessionPoints() async {
    final many = widget.captureSessionIds;
    if (many != null) {
      return [for (final id in many) ...await TrackDb.instance.points(id)];
    }
    return widget.sessionId == null ? const [] : await TrackDb.instance.points(widget.sessionId!);
  }

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
        if (widget.posterCapture != null) {
          if (mounted) Navigator.pop(context);
          return;
        }
        setState(() {
          _loading = false;
          _problem = all.isEmpty
              ? (MapStore.lastListError ?? t('Нет загруженных карт. Добавьте файл карты в разделе «Карты».'))
              : t('Для этого места нет карты. Загруженные регионы не покрывают его.');
        });
        return;
      }
      if (!mounted) return;
      final capture = widget.posterCapture;
      final dark = capture != null ? capture.darkMap : Theme.of(context).brightness == Brightness.dark;
      final chosen = region;
      final overlay = capture != null ? _Overlay(_fc(const []), _fc(const []), _fc(const []), _fc(const []), _fc(const []), const []) : await _buildOverlay(pts);
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
        layers: capture != null ? const [] : _overlayLayers(),
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
        _problem = t('Не удалось подготовить карту: {p0}', {'p0': e});
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
      {
        'id': 'tropa-track',
        'type': 'line',
        'source': 'track',
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {
          'line-color': ['coalesce', ['get', 'color'], '#E53935'],
          'line-width': 4.5,
          'line-opacity': 1,
        },
      },
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

      // The way of travelling of every point (walk / vehicle / bike / water): the line changes colour where it
      // changes, with a labelled marker. A live map has no finished walk to split, so it stays one colour.
      final modeAt = List<TravelMode?>.filled(pts.length, null);
      final segments = widget.live
          ? const <TrackSegment>[]
          : buildSegments(pts, widget.mode, overrides: await TrackDb.instance.segmentOverrides(widget.sessionId!));
      for (final s in segments) {
        for (var i = s.startIdx; i <= s.endIdx && i < pts.length; i++) {
          modeAt[i] = s.mode;
        }
      }
      final multiMode = segments.map((s) => s.mode).toSet().length > 1;
      var seg = <LatLng>[];
      var segMode = modeAt.isEmpty ? null : modeAt.first;
      void flush() {
        if (seg.length >= 2) {
          final f = _lineFeature(List.of(seg));
          if (multiMode && segMode != null) (f['properties'] as Map<String, Object?>)['color'] = _modeHex(segMode);
          track.add(f);
        }
        seg = <LatLng>[];
      }

      for (var i = 0; i < pts.length; i++) {
        final here = LatLng(pts[i].lat, pts[i].lon);
        all.add(here);
        if (multiMode && i > 0 && modeAt[i] != segMode) {
          // The mode changes here: close the line (it shares this point with the next one) and mark the change.
          seg.add(here);
          flush();
          final next = modeAt[i];
          segMode = next;
          seg = <LatLng>[here];
          if (next != null) marks.add(_pointFeature(here, color: _modeHex(next), radius: 6, label: t(next.label)));
          continue;
        }
        segMode = modeAt[i] ?? segMode;
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
            color: '#8E24AA', radius: 7, label: n.text.isNotEmpty ? n.text : (n.mediaType == 'video' ? t('видео') : t('фото'))));
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
    if (widget.posterCapture != null) {
      await _capturePosterMap(c);
      return;
    }
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

  /// Poster background: frames the walk the way the poster expects, waits for the tiles and takes a
  /// high-resolution snapshot of the bare map. The route itself is drawn by the poster code on top.
  Future<void> _capturePosterMap(MapLibreMapController c) async {
    try {
      final o = widget.posterCapture!;
      final wide = o.format == PosterFormat.horizontal;
      // Snapshot of the whole poster canvas at 2x: 2160x3840 (vertical) or 3600x2400 (horizontal).
      final widthPx = wide ? 3600 : 2160, heightPx = wide ? 2400 : 3840;
      final pts = await _sessionPoints();
      final (i0, i1) = posterShownRange(pts, o.hideEnds);
      final cam = wide
          ? posterCamera(pts, widthPx: widthPx, i0: i0, i1: i1, canvas: const Size(wideW, wideH), area: wideRouteArea)
          : posterCamera(pts, widthPx: widthPx, i0: i0, i1: i1);
      if (cam == null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      await c.moveCamera(CameraUpdate.newLatLngZoom(LatLng(cam.lat, cam.lon), cam.zoom));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final png = await c.takeSnapshot(width: widthPx, height: heightPx);
      final img = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
      // If the snapshotter used a pixel ratio, the picture is bigger than requested: the zoom (which is
      // measured in logical pixels) grows by log2 of that ratio for the projection in pixels.
      final ratio = img.width / widthPx;
      final zoomPx = cam.zoom + math.log(ratio) / math.ln2;
      DebugLog.instance.log('POSTER', 'map snapshot ${img.width}x${img.height} zoom=${cam.zoom.toStringAsFixed(2)}');
      if (mounted) Navigator.pop(context, MapCapture(png, cam.lat, cam.lon, zoomPx, img.width, img.height));
    } catch (e, st) {
      DebugLog.instance.log('MAP', 'poster snapshot failed: $e\n$st');
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? t('Карта') : widget.title),
        actions: [
          if (widget.sessionId != null && _stylePath != null && widget.posterCapture == null)
            IconButton(
              icon: const Icon(Icons.image_outlined),
              tooltip: t('Постер'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PosterPage(sessionId: widget.sessionId!, title: widget.title, mode: widget.mode),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: t('Карты'),
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
                      Text(_problem ?? t('Карта недоступна'), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapsPage())),
                        child: Text(t('Открыть «Карты»')),
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

/// Colour of a way of travelling on the map (the same as in the route preview).
String _modeHex(TravelMode m) => switch (m) {
      TravelMode.walk => '#2E7D32',
      TravelMode.bike => '#1565C0',
      TravelMode.car => '#EF6C00',
      TravelMode.water => '#00ACC1',
      TravelMode.mixed => '#6D4C41',
    };
