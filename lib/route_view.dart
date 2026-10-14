import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';

import 'altitude.dart';
import 'db.dart';
import 'debug_log.dart';
import 'elevation.dart';
import 'gpx_export.dart';
import 'heal.dart';
import 'map_page.dart';
import 'modes.dart';
import 'notes.dart';
import 'poster_page.dart';
import 'segments.dart';
import 'settings.dart';
import 'stats.dart';
import 'l10n.dart';
import 'units.dart';

/// Notes of a walk can have their photo or video replaced only this close to where they were made.
const double mediaReplaceRadiusM = 100;

/// Colour and icon of a way of travelling, shared by the route preview and the segment list.
Color modeColor(TravelMode m) => switch (m) {
      TravelMode.walk => const Color(0xFF2E7D32),
      TravelMode.bike => const Color(0xFF1565C0),
      TravelMode.car => const Color(0xFFEF6C00),
      TravelMode.water => const Color(0xFF00ACC1),
      TravelMode.mixed => const Color(0xFF6D4C41),
    };

IconData modeIcon(TravelMode m) => switch (m) {
      TravelMode.walk => Icons.directions_walk,
      TravelMode.bike => Icons.directions_bike,
      TravelMode.car => Icons.directions_car,
      TravelMode.water => Icons.kayaking,
      TravelMode.mixed => Icons.alt_route,
    };

class _Loaded {
  final List<TrackPoint> pts;
  final List<TrackSegment> segments;
  final List<TrackNote> notes;
  final List<double> altitude;
  final bool fused;

  _Loaded(this.pts, this.segments, this.notes, this.altitude, this.fused);
}

/// Simple offline preview of a recorded route (no map tiles yet):
/// solid line where GPS was continuous, a different colour where a short gap
/// was restored, dashed where the gap could not be restored safely. Below it: the stretches of the
/// walk by way of travel (editable) and the notes (editable).
class RouteViewPage extends StatefulWidget {
  final int sessionId;
  final String title;
  final TravelMode mode;

  const RouteViewPage({super.key, required this.sessionId, required this.title, this.mode = TravelMode.mixed});

  @override
  State<RouteViewPage> createState() => _RouteViewPageState();
}

class _RouteViewPageState extends State<RouteViewPage> {
  bool heal = AppSettings.instance.healEnabled;
  late TravelMode _mode = widget.mode;
  late String _title = widget.title;
  late Future<_Loaded> _future = _load();

  Future<_Loaded> _load() async {
    final db = TrackDb.instance;
    final pts = await db.points(widget.sessionId);
    final overrides = await db.segmentOverrides(widget.sessionId);
    final notes = await db.notes(widget.sessionId);
    final gps = fusedAltitude(pts);
    final alt = await sessionAltitude(widget.sessionId, pts);
    final fused = alt.length == gps.length && _differs(alt, gps);
    return _Loaded(pts, buildSegments(pts, _mode, overrides: overrides), notes, alt, fused);
  }

  static bool _differs(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i += math.max(1, a.length ~/ 20)) {
      if ((a[i] - b[i]).abs() > 0.01) return true;
    }
    return false;
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title), actions: [_menu(context)]),
      body: FutureBuilder<_Loaded>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          final pts = data.pts;
          if (pts.length < 2) return Center(child: Text(t('Недостаточно точек')));
          final healCfg = AppSettings.instance.healFor(_mode);
          final result = analyzeGaps(pts, settings: healCfg);
          final stats = computeStats(pts, movingSpeedMs: profileOf(_mode).movingSpeedMs);
          final multi = data.segments.map((s) => s.mode).toSet().length > 1;
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${t(_mode.label)} · ${_summary(result, pts.length)}'),
                const SizedBox(height: 4),
                Text(_statsLine(stats, data.fused ? elevationOfFused(data.altitude) : elevationOf(pts, data.altitude)),
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                _actions(context),
              ]),
            ),
            SwitchListTile(
              title: Text(t('Склеить короткие разрывы')),
              subtitle: Text(t('Только участки, где движение было правдоподобным. Длинные пропуски не склеиваются.')),
              value: heal,
              onChanged: (v) => setState(() => heal = v),
            ),
            SizedBox(
              height: 360,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _RoutePainter(pts, result, heal, Theme.of(context).colorScheme,
                      multi ? _modePerPoint(pts.length, data.segments) : null),
                ),
              ),
            ),
            _segmentsCard(context, data),
            _notesCard(context, data),
          ]);
        },
      ),
    );
  }

  /// The three things a person does with a walk: look at it on the map, make a poster, share the GPX file.
  Widget _actions(BuildContext context) {
    Widget button(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: FilledButton.tonalIcon(
            onPressed: onTap,
            icon: Icon(icon, size: 20),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12)),
          ),
        );
    return Row(children: [
      button(Icons.map_outlined, t('Карта'), () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => MapPage(sessionId: widget.sessionId, title: _title, mode: _mode)))),
      const SizedBox(width: 8),
      button(Icons.image_outlined, t('Постер'), () async {
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => PosterPage(sessionId: widget.sessionId, title: _title, mode: _mode)));
      }),
      const SizedBox(width: 8),
      button(Icons.ios_share, t('GPX'), () => shareSessionGpx(context, widget.sessionId)),
    ]);
  }

  Widget _menu(BuildContext context) => PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'rename':
              _rename();
            case 'mode':
              _changeMode();
            case 'delete':
              _delete();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'rename', child: ListTile(leading: const Icon(Icons.edit_outlined), title: Text(t('Переименовать')), dense: true)),
          PopupMenuItem(value: 'mode', child: ListTile(leading: const Icon(Icons.alt_route), title: Text(t('Изменить режим')), dense: true)),
          PopupMenuItem(value: 'delete', child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(t('Удалить')), dense: true)),
        ],
      );

  Future<void> _rename() async {
    final name = await showDialog<String>(context: context, builder: (_) => _RenameDialog(initial: _title));
    if (name == null || !mounted) return;
    await TrackDb.instance.setSessionMeta(widget.sessionId, {'title': name});
    if (mounted) setState(() => _title = name.isEmpty ? widget.title : name);
  }

  Future<void> _changeMode() async {
    final choice = await showDialog<TravelMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(t('Режим прогулки')),
        children: [
          for (final m in TravelMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, m),
              child: Row(children: [
                Icon(modeIcon(m), color: modeColor(m)),
                const SizedBox(width: 12),
                Expanded(child: Text(t(m.label))),
                if (m == _mode) const Icon(Icons.check, size: 18),
              ]),
            ),
        ],
      ),
    );
    if (choice == null || choice == _mode) return;
    await TrackDb.instance.setSessionMode(widget.sessionId, choice.code);
    if (!mounted) return;
    setState(() => _mode = choice);
    _reload();
  }

  Future<void> _delete() async {
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('Удалить прогулку?')),
        content: Text(t('Точки, заметки и участки этой прогулки будут удалены. Фото и видео в галерее останутся.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Удалить'))),
        ],
      ),
    );
    if (ok != true) return;
    await TrackDb.instance.deleteSession(widget.sessionId);
    nav.pop();
  }

  static List<TravelMode> _modePerPoint(int n, List<TrackSegment> segs) {
    final out = List<TravelMode>.filled(n, segs.first.mode);
    for (final s in segs) {
      for (var i = s.startIdx; i <= s.endIdx; i++) {
        out[i] = s.mode;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- segments

  Widget _segmentsCard(BuildContext context, _Loaded data) {
    final segs = data.segments;
    if (segs.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(t('Участки маршрута'), style: Theme.of(context).textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Text(
              (_mode == TravelMode.mixed || _mode == TravelMode.walk)
                  ? t('Участки определены по скорости движения. Нажмите на участок, чтобы изменить способ.')
                  : t('Весь маршрут записан в режиме «{p0}». Нажмите на участок, чтобы изменить способ.', {'p0': t(_mode.label)}),
              style: Theme.of(context).textTheme.bodySmall),
        ),
        for (final s in segs)
          ListTile(
            dense: true,
            leading: Icon(modeIcon(s.mode), color: modeColor(s.mode)),
            title: Text('${t(s.mode.label)} · ${Units.dist(s.stats.distanceMeters)}'),
            subtitle: Text('${_clock(s.startMs)}–${_clock(s.endMs)} · ${_segmentLine(s)}'),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () => _editSegment(s),
          ),
      ]),
    );
  }

  static String _clock(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Pace is only meaningful on foot; for vehicles, bikes and boats the speed is shown.
  String _segmentLine(TrackSegment s) {
    final st = s.stats;
    final parts = <String>[t('в движении {t}', {'t': _hms(st.movingSeconds)})];
    if (st.avgMovingSpeedMs > 0) {
      final pace = st.paceMinPerKm;
      if (s.mode == TravelMode.walk && pace != null && pace < 60) {
        parts.add(t('темп {p}', {'p': Units.pace(pace)}));
      } else {
        parts.add(t('ср. {s}', {'s': Units.speed(st.avgMovingSpeedMs)}));
      }
    }
    return parts.join(' · ');
  }

  Future<void> _editSegment(TrackSegment s) async {
    final choice = await showDialog<TravelMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(t('Как вы двигались на этом участке?')),
        children: [
          for (final m in const [TravelMode.walk, TravelMode.bike, TravelMode.car, TravelMode.water])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, m),
              child: Row(children: [
                Icon(modeIcon(m), color: modeColor(m)),
                const SizedBox(width: 12),
                Expanded(child: Text(t(m.label))),
                if (m == s.mode) const Icon(Icons.check, size: 18),
              ]),
            ),
        ],
      ),
    );
    if (choice == null || choice == s.mode) return;
    await TrackDb.instance.setSegmentOverride(widget.sessionId, s.startMs, s.endMs, choice);
    _reload();
  }

  // ---------------------------------------------------------------- notes

  Widget _notesCard(BuildContext context, _Loaded data) {
    if (data.notes.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(t('Заметки'), style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final n in data.notes)
          ListTile(
            dense: true,
            leading: Icon(n.mediaType == 'video'
                ? Icons.videocam
                : (n.mediaType == 'photo' ? Icons.photo : Icons.sticky_note_2)),
            title: Text(n.text.isEmpty ? (n.mediaType == 'video' ? t('Видео') : t('Фото')) : n.text),
            subtitle: Text(_clock(n.tsMs) + (n.mediaName.isEmpty ? '' : t(' · в галерее, альбом Tropa'))),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => _noteAction(n, v),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'text', child: Text(t('Изменить текст'))),
                PopupMenuItem(value: 'media', child: Text(t('Заменить фото или видео'))),
                if (n.mediaName.isNotEmpty) PopupMenuItem(value: 'open', child: Text(t('Открыть галерею'))),
                PopupMenuItem(value: 'delete', child: Text(t('Удалить заметку'))),
              ],
            ),
          ),
      ]),
    );
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _noteAction(TrackNote n, String action) async {
    switch (action) {
      case 'text':
        final ctl = TextEditingController(text: n.text);
        final text = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(t('Текст заметки')),
            content: TextField(controller: ctl, maxLines: 4, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Отмена'))),
              TextButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: Text(t('Сохранить'))),
            ],
          ),
        );
        if (text == null) return;
        if (text.isEmpty && n.mediaName.isEmpty) {
          _snack(t('Пустую заметку без фото не сохранить. Удалите её через меню.'));
          return;
        }
        await TrackDb.instance.updateNoteText(n.id, text);
        _reload();
      case 'media':
        await _replaceMedia(n);
      case 'open':
        await Gal.open();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(t('Удалить заметку?')),
            content: Text(n.mediaName.isEmpty
                ? t('Заметка будет удалена.')
                : t('Заметка будет удалена. Фото или видео останется в галерее телефона (альбом Tropa), его можно удалить там.')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
              TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Удалить'))),
            ],
          ),
        );
        if (ok != true) return;
        await TrackDb.instance.deleteNote(n.id);
        _reload();
    }
  }

  /// A photo or video must really have been taken at this place, so it can only be replaced
  /// while the person is still within [mediaReplaceRadiusM] of the note.
  Future<void> _replaceMedia(TrackNote n) async {
    double? away;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 15)),
      );
      away = haversine(pos.latitude, pos.longitude, n.lat, n.lon);
    } catch (e) {
      DebugLog.instance.log('NOTE', 'position for media replace failed: $e');
    }
    if (!mounted) return;
    if (away == null) {
      _snack(t('Не удалось определить, где вы. Включите GPS: фото можно заменить только на месте заметки.'));
      return;
    }
    if (away > mediaReplaceRadiusM) {
      _snack(t('Заменить можно только на месте (до {p0}), сейчас вы в {p1}. Можно удалить заметку.', {'p0': Units.shortDist(mediaReplaceRadiusM), 'p1': Units.shortDist(away)}));
      return;
    }
    final video = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(t('Новое фото')),
              onTap: () => Navigator.pop(c, false)),
          ListTile(
              leading: const Icon(Icons.videocam),
              title: Text(t('Новое видео')),
              onTap: () => Navigator.pop(c, true)),
        ]),
      ),
    );
    if (video == null) return;
    final m = await captureMedia(video: video);
    if (m == null) return;
    await TrackDb.instance.updateNoteMedia(n.id, m.type, m.name);
    DebugLog.instance.log('NOTE', 'media replaced for note ${n.id}, ${away.round()} m from the place');
    if (!mounted) return;
    _snack(t('Сохранено. Прежний файл остался в галерее, удалите его там при желании.'));
    _reload();
  }

  static String _hms(int s) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(s ~/ 3600)}:${two((s ~/ 60) % 60)}:${two(s % 60)}';
  }

  /// Totals only: pace and average speed of the whole walk would mix walking with driving,
  /// so they are shown per segment instead.
  String _statsLine(TrackStats s, ElevationStats e) {
    final parts = <String>[
      t('Всего {p0}', {'p0': _hms(s.totalSeconds)}),
      t('в движении {p0}', {'p0': _hms(s.movingSeconds)}),
      t('пауза {p0}', {'p0': _hms(s.pausedSeconds)}),
      if (s.indoorSeconds > 0) t('в помещении {p0}', {'p0': _hms(s.indoorSeconds)}),
    ];
    if (s.maxSpeedMs > 0) parts.add(t('макс. {p}', {'p': Units.speed(s.maxSpeedMs)}));
    if (e.gain > 0 || e.loss > 0) {
      parts.add('↑${Units.height(e.gain)} ↓${Units.height(e.loss)} (${Units.height(e.min)}…${Units.height(e.max)})');
    }
    return parts.join(' · ');
  }

  String _summary(HealResult r, int n) {
    final restored = r.restoredMeters;
    final parts = [t('Записано: {p}', {'p': Units.dist(r.recordedMeters)}), t('точек: {p0}', {'p0': n})];
    if (restored >= 1) parts.add(heal ? t('восстановлено: {p}', {'p': Units.shortDist(restored)}) : t('можно восстановить: {p}', {'p': Units.shortDist(restored)}));
    if (r.unresolved > 0) parts.add(t('не склеено разрывов: {p0} (пунктир)', {'p0': r.unresolved}));
    return parts.join(' · ');
  }
}

class _RoutePainter extends CustomPainter {
  final List<TrackPoint> pts;
  final HealResult result;
  final bool heal;
  final ColorScheme scheme;

  /// Mode of every point when the walk has several (the line is coloured by mode), else null.
  final List<TravelMode>? modes;

  _RoutePainter(this.pts, this.result, this.heal, this.scheme, this.modes);

  @override
  void paint(Canvas canvas, Size size) {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    void grow(double lat, double lon) {
      minLat = math.min(minLat, lat);
      maxLat = math.max(maxLat, lat);
      minLon = math.min(minLon, lon);
      maxLon = math.max(maxLon, lon);
    }

    for (final p in pts) {
      grow(p.lat, p.lon);
    }
    if (heal) {
      // A smooth continuation may bulge slightly outside the recorded points.
      for (final g in result.gaps) {
        for (final c in g.curve) {
          grow(c.lat, c.lon);
        }
      }
    }
    final midLat = (minLat + maxLat) / 2;
    final kx = math.cos(midLat * math.pi / 180); // shrink longitude with latitude
    final w = math.max((maxLon - minLon) * kx, 1e-6);
    final h = math.max(maxLat - minLat, 1e-6);
    final scale = math.min(size.width / w, size.height / h) * 0.92;
    final ox = (size.width - w * scale) / 2;
    final oy = (size.height - h * scale) / 2;

    Offset posLL(double lat, double lon) =>
        Offset(ox + (lon - minLon) * kx * scale, size.height - oy - (lat - minLat) * scale);
    Offset pos(TrackPoint p) => posLL(p.lat, p.lon);

    Paint stroke(Color c, double width) => Paint()
      ..color = c
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final solid = stroke(scheme.primary, 4);
    final restored = stroke(scheme.tertiary, 4);
    final dashed = stroke(scheme.error, 2);
    final byMode = {for (final m in TravelMode.values) m: stroke(modeColor(m), 4)};

    for (var i = 1; i < pts.length; i++) {
      final a = pos(pts[i - 1]);
      final b = pos(pts[i]);
      final gap = result.gapAt(i);
      final line = modes == null ? solid : byMode[modes![i]]!;
      if (gap == null) {
        canvas.drawLine(a, b, line);
      } else if (heal && gap.kind == GapKind.glueStill) {
        canvas.drawLine(a, b, line);
      } else if (heal && gap.kind == GapKind.bridge) {
        // Smooth continuation of the route; a straight line when headings are unknown.
        var prev = a;
        for (final c in gap.curve) {
          final next = posLL(c.lat, c.lon);
          canvas.drawLine(prev, next, restored);
          prev = next;
        }
        canvas.drawLine(prev, b, restored);
      } else {
        _dash(canvas, a, b, dashed);
      }
    }
    canvas.drawCircle(pos(pts.first), 8, Paint()..color = Colors.green);
    canvas.drawCircle(pos(pts.last), 8, Paint()..color = Colors.red);
  }

  void _dash(Canvas canvas, Offset a, Offset b, Paint paint) {
    final len = (b - a).distance;
    if (len == 0) return;
    final dir = (b - a) / len;
    for (double d = 0; d < len; d += 12) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + 6, len), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) => old.pts != pts || old.heal != heal || old.modes != modes;
}

/// Asks for the name of a walk; an empty answer removes the name.
class _RenameDialog extends StatefulWidget {
  final String initial;

  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(t('Название прогулки')),
        content: TextField(
          controller: _ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: t('Например, «Набережная»')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(context, _ctl.text.trim()), child: Text(t('Сохранить'))),
        ],
      );
}
