import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import 'altitude.dart';
import 'app_hooks.dart';
import 'db.dart';
import 'debug_log.dart';
import 'elevation.dart';
import 'gpx_export.dart';
import 'heal.dart';
import 'map_page.dart';
import 'modes.dart';
import 'note_thumbs.dart';
import 'notes.dart';
import 'poster_page.dart';
import 'recorder.dart';
import 'routes.dart';
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
      TravelMode.mixed => Icons.commute, // walking and a vehicle in one walk (alt_route is the Routes icon)
    };

/// The icon of a way of travelling. "Mixed" is a walker and a car side by side (walking and a vehicle in one walk);
/// the others are a single Material icon.
class ModeIcon extends StatelessWidget {
  final TravelMode mode;
  final double size;
  final Color? color;

  const ModeIcon(this.mode, {super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) {
    if (mode != TravelMode.mixed) return Icon(modeIcon(mode), size: size, color: color);
    final small = size * 0.74;
    return SizedBox(
      width: size * 1.55, // two icons of 0.74 of the size side by side
      height: size,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.directions_walk, size: small, color: color),
        Icon(Icons.directions_car, size: small, color: color),
      ]),
    );
  }
}

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
  _Loaded? _data; // the walk as last shown (the place of a note is chosen on it)

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

  void _reload() => setState(() {
        _future = _load();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title), actions: [_menu(context)]),
      body: FutureBuilder<_Loaded>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          _data = data;
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
            case 'route':
              _saveAsRoute();
            case 'follow':
              _saveAsRoute(follow: true);
            case 'delete':
              _delete();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'follow', child: ListTile(leading: const Icon(Icons.navigation), title: Text(t('Идти по этому маршруту')), dense: true)),
          PopupMenuItem(value: 'route', child: ListTile(leading: const Icon(Icons.alt_route), title: Text(t('Сохранить как маршрут')), dense: true)),
          PopupMenuItem(value: 'rename', child: ListTile(leading: const Icon(Icons.edit_outlined), title: Text(t('Переименовать')), dense: true)),
          PopupMenuItem(value: 'mode', child: ListTile(leading: const Icon(Icons.commute), title: Text(t('Изменить режим')), dense: true)),
          PopupMenuItem(value: 'delete', enabled: !_isRecording, child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(t('Удалить')), dense: true)),
        ],
      );

  /// Copies the walk to the saved routes (thinned to a point every ~10 m), to walk it again with navigation.
  Future<void> _saveAsRoute({bool follow = false}) async {
    final pts = await TrackDb.instance.points(widget.sessionId);
    if (pts.length < 2) {
      _snack(t('Недостаточно точек'));
      return;
    }
    final route = thinToRoute([for (final p in pts) (lat: p.lat, lon: p.lon)]);
    final name = _title.trim().isEmpty ? widget.title : _title;
    final id = await TrackDb.instance.addRoute(name, route);
    if (follow) {
      final go = AppHooks.startAlongRoute;
      if (go == null || !mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      await go(id);
      return;
    }
    _snack(t('Сохранено в «Тропы → Маршруты»: {p0} ({p1} точек)', {'p0': name, 'p1': route.length}));
  }

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
                ModeIcon(m, color: modeColor(m)),
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

  /// The walk that is being recorded right now: the service is still writing its points.
  bool get _isRecording => Recorder.instance.recording && Recorder.instance.sessionId == widget.sessionId;

  Future<void> _delete() async {
    if (_isRecording) {
      _snack(t('Эта прогулка записывается сейчас. Сначала остановите запись.'));
      return;
    }
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
    // The small photo copies of its notes go with it.
    final notes = await TrackDb.instance.notes(widget.sessionId);
    await TrackDb.instance.deleteSession(widget.sessionId);
    for (final n in notes) {
      await deleteNoteThumb(n.mediaName);
    }
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
            leading: ModeIcon(s.mode, color: modeColor(s.mode)),
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
                ModeIcon(m, color: modeColor(m)),
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
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(children: [
            Expanded(child: Text(t('Заметки'), style: Theme.of(context).textTheme.titleMedium)),
            // A note can be made after the walk too: the place is chosen on the route.
            TextButton.icon(onPressed: () => _addNote(data), icon: const Icon(Icons.add), label: Text(t('Добавить заметку'))),
          ]),
        ),
        if (data.notes.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Text(t('Заметок пока нет'), style: Theme.of(context).textTheme.bodySmall),
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
                PopupMenuItem(value: 'place', child: Text(t('Изменить место'))),
                PopupMenuItem(value: 'media', child: Text(t('Заменить фото или видео'))),
                if (n.mediaType == 'photo') PopupMenuItem(value: 'thumb', child: Text(t('Показать фото на постере…'))),
                if (n.mediaName.isNotEmpty) PopupMenuItem(value: 'open', child: Text(t('Открыть галерею'))),
                PopupMenuItem(value: 'delete', child: Text(t('Удалить заметку'))),
              ],
            ),
          ),
      ]),
    );
  }

  /// A new text note on the finished walk: the text and the place on the route.
  Future<void> _addNote(_Loaded data) async {
    if (data.pts.length < 2) return;
    final r = await showDialog<({String text, int index, String mediaType, String mediaName})>(
      context: context,
      builder: (_) => _NoteDialog(pts: data.pts, title: t('Новая заметка'), withText: true, initialIndex: data.pts.length - 1),
    );
    if (r == null || !mounted) return;
    final pt = data.pts[r.index];
    await TrackDb.instance.addNote(sessionId: widget.sessionId, tsMs: pt.tsMs, lat: pt.lat, lon: pt.lon,
        text: r.text, mediaType: r.mediaType, mediaName: r.mediaName);
    DebugLog.instance.log('NOTE', 'note added after the walk, session=${widget.sessionId} point=${r.index}');
    _reload();
  }

  /// Another place of the walk for an existing note.
  Future<void> _moveNote(TrackNote n) async {
    final data = _data;
    if (data == null) return;
    var idx = 0;
    var best = double.infinity;
    for (var i = 0; i < data.pts.length; i++) {
      final d = haversine(data.pts[i].lat, data.pts[i].lon, n.lat, n.lon);
      if (d < best) {
        best = d;
        idx = i;
      }
    }
    final r = await showDialog<({String text, int index, String mediaType, String mediaName})>(
      context: context,
      builder: (_) => _NoteDialog(pts: data.pts, title: t('Место заметки'), withText: false, initialIndex: idx),
    );
    if (r == null || !mounted) return;
    final pt = data.pts[r.index];
    await TrackDb.instance.updateNotePlace(n.id, pt.tsMs, pt.lat, pt.lon);
    _reload();
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
      case 'place':
        await _moveNote(n);
      case 'media':
        await _replaceMedia(n);
      case 'thumb':
        await _attachThumb(n);
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
        await deleteNoteThumb(n.mediaName);
        _reload();
    }
  }

  /// The photo of a note taken before the app kept small copies: pick it from the gallery once, and the poster shows
  /// it in the marker of the note.
  Future<void> _attachThumb(TrackNote n) async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      DebugLog.instance.log('NOTE', 'gallery pick failed: $e');
      return;
    }
    if (picked == null) return;
    final ok = await saveNoteThumb(picked.path, n.mediaName);
    if (!mounted) return;
    _snack(ok ? t('Готово: фото будет в маркере заметки на постере.') : t('Не удалось прочитать это фото.'));
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
    await deleteNoteThumb(n.mediaName);
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

/// The dialog of a note on a finished walk: the text (when [withText]) and the place, chosen by touching the route.
class _NoteDialog extends StatefulWidget {
  final List<TrackPoint> pts;
  final String title;
  final bool withText;
  final int initialIndex;

  const _NoteDialog({required this.pts, required this.title, required this.withText, required this.initialIndex});

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final TextEditingController _text = TextEditingController();
  late int _index = widget.initialIndex;
  String _mediaType = '', _mediaName = ''; // a photo or video chosen from the gallery
  static const double _height = 240;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Metres of the walk from its start to the chosen point (gaps of the recording are not distance).
  double _fromStart() {
    var d = 0.0;
    for (var i = 1; i <= _index; i++) {
      if (widget.pts[i].tsMs - widget.pts[i - 1].tsMs > 30000) continue;
      d += haversine(widget.pts[i - 1].lat, widget.pts[i - 1].lon, widget.pts[i].lat, widget.pts[i].lon);
    }
    return d;
  }

  /// A photo or a video that is already in the gallery (it was taken during the walk, or later): only its name is kept,
  /// as for the ones taken in the app; a photo also leaves the small copy for the poster.
  Future<void> _attach(bool video) async {
    try {
      final picker = ImagePicker();
      final XFile? f = video ? await picker.pickVideo(source: ImageSource.gallery) : await picker.pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final name = f.name.isEmpty ? f.path.split('/').last : f.name;
      if (!video) await saveNoteThumb(f.path, name);
      if (mounted) {
        setState(() {
          _mediaType = video ? 'video' : 'photo';
          _mediaName = name;
        });
      }
    } catch (e) {
      DebugLog.instance.log('NOTE', 'gallery pick failed: $e');
    }
  }

  void _pick(Offset local, Size size) {
    final fit = _PlaceFit(widget.pts, size);
    setState(() => _index = fit.nearest(local));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pt = widget.pts[_index];
    final d = DateTime.fromMillisecondsSinceEpoch(pt.tsMs);
    final clock = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final canSave = !widget.withText || _text.text.trim().isNotEmpty || _mediaName.isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.withText) ...[
              TextField(
                controller: _text,
                maxLines: 3,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(hintText: t('Текст заметки'), border: const OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                ActionChip(avatar: const Icon(Icons.photo_library_outlined), label: Text(t('Фото из галереи')), onPressed: () => _attach(false)),
                ActionChip(avatar: const Icon(Icons.video_library_outlined), label: Text(t('Видео из галереи')), onPressed: () => _attach(true)),
              ]),
              if (_mediaName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_mediaType == 'photo' ? t('Фото прикреплено') : t('Видео прикреплено'), style: Theme.of(context).textTheme.bodySmall),
                ),
              const SizedBox(height: 12),
            ],
            Text(t('Коснитесь маршрута, чтобы выбрать место'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            LayoutBuilder(builder: (context, box) {
              final size = Size(box.maxWidth, _height);
              return GestureDetector(
                onTapDown: (e) => _pick(e.localPosition, size),
                onPanUpdate: (e) => _pick(e.localPosition, size),
                child: Container(
                  height: _height,
                  decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CustomPaint(size: size, painter: _PlacePainter(widget.pts, _index, cs)),
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
            Text(t('Место: {p0}, {p1} от старта', {'p0': clock, 'p1': Units.dist(_fromStart())}),
                style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Отмена'))),
        TextButton(
          onPressed: canSave ? () => Navigator.pop(context, (text: _text.text.trim(), index: _index, mediaType: _mediaType, mediaName: _mediaName)) : null,
          child: Text(t('Сохранить')),
        ),
      ],
    );
  }
}

/// How a track is fitted into a rectangle (the same for drawing and for finding the touched point).
class _PlaceFit {
  final List<TrackPoint> pts;
  final Size size;
  late final double _minLat, _minLon, _kx, _scale, _ox, _oy;

  _PlaceFit(this.pts, this.size) {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    _kx = math.cos((minLat + maxLat) / 2 * math.pi / 180);
    final w = math.max((maxLon - minLon) * _kx, 1e-6), h = math.max(maxLat - minLat, 1e-6);
    _scale = math.min(size.width / w, size.height / h) * 0.88;
    _ox = (size.width - w * _scale) / 2;
    _oy = (size.height - h * _scale) / 2;
    _minLat = minLat;
    _minLon = minLon;
  }

  Offset at(TrackPoint p) => Offset(_ox + (p.lon - _minLon) * _kx * _scale, size.height - _oy - (p.lat - _minLat) * _scale);

  int nearest(Offset local) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final d = (at(pts[i]) - local).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }
}

class _PlacePainter extends CustomPainter {
  final List<TrackPoint> pts;
  final int index;
  final ColorScheme scheme;

  _PlacePainter(this.pts, this.index, this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    final fit = _PlaceFit(pts, size);
    final line = Paint()
      ..color = scheme.primary
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = fit.at(pts[i]);
      final jump = i > 0 && pts[i].tsMs - pts[i - 1].tsMs > 30000;
      if (i == 0 || jump) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(path, line);
    canvas.drawCircle(fit.at(pts.first), 6, Paint()..color = Colors.green);
    canvas.drawCircle(fit.at(pts.last), 6, Paint()..color = Colors.red);
    final at = fit.at(pts[index]);
    canvas.drawCircle(at, 13, Paint()..color = Colors.white);
    canvas.drawCircle(at, 10, Paint()..color = const Color(0xFFAB47BC));
    canvas.drawCircle(at, 3.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PlacePainter old) => old.index != index || old.pts != pts;
}
