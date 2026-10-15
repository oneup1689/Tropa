import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'altitude.dart';
import 'app_hooks.dart';
import 'db.dart';
import 'debug_log.dart';
import 'device_net.dart';
import 'elevation.dart';
import 'heal.dart' show haversine;
import 'l10n.dart';
import 'map_page.dart';
import 'route_estimate.dart';
import 'route_nav.dart' show bearingDeg;
import 'nav_page.dart';
import 'route_view.dart';
import 'routes.dart';
import 'settings.dart';
import 'units.dart';

/// One saved route: a preview, how long and how high it is, where it starts and ends, how far you are from the
/// start, how many times you have walked it, and the "Start" button (see HomePage.startAlongRoute for what happens).
class RoutePage extends StatefulWidget {
  final RouteInfo route;

  const RoutePage({super.key, required this.route});

  @override
  State<RoutePage> createState() => _RoutePageState();
}

class _RoutePageState extends State<RoutePage> {
  late String _name = widget.route.name;
  List<({double lat, double lon})> _pts = const [];
  bool _loaded = false;
  bool _reverse = false;
  Position? _me;
  bool _locating = false;
  String? _locError;
  ElevationStats? _elev;
  bool _elevLoading = false;
  List<({int sessionId, int startMs})> _walks = const [];
  bool _changed = false; // the list behind this page must be reloaded

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pts = await TrackDb.instance.routePoints(widget.route.id);
    final walks = await TrackDb.instance.routeWalks(widget.route.id);
    if (!mounted) return;
    setState(() {
      _pts = pts;
      _walks = walks;
      _loaded = true;
    });
    // Heights: from the cache at once; otherwise from the terrain service when the phone is online.
    final cached = await routeElevationStats(widget.route.id, pts, allowFetch: false);
    if (!mounted) return;
    if (cached != null) {
      setState(() => _elev = cached);
      return;
    }
    final net = await networkInfo();
    if (net != null && !net.online) return;
    setState(() => _elevLoading = true);
    final fetched = await routeElevationStats(widget.route.id, pts);
    if (!mounted) return;
    setState(() {
      _elev = fetched;
      _elevLoading = false;
    });
  }

  ({double lat, double lon}) get _start => _reverse ? _pts.last : _pts.first;
  ({double lat, double lon}) get _finish => _reverse ? _pts.first : _pts.last;

  Future<void> _whereAmI() async {
    setState(() {
      _locating = true;
      _locError = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _locError = t('GPS выключен. Включите геолокацию в настройках телефона.');
      } else {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
          _locError = t('Нет доступа к геолокации. Разрешите его в настройках приложения.');
        } else {
          _me = await Geolocator.getCurrentPosition(
            locationSettings: AndroidSettings(accuracy: LocationAccuracy.high, forceLocationManager: true, timeLimit: const Duration(seconds: 10)),
          );
        }
      }
    } catch (e) {
      DebugLog.instance.log('NAV', 'route page position failed: $e');
      _me = await Geolocator.getLastKnownPosition();
      if (_me == null) _locError = t('Не удалось определить положение: сигнала GPS пока нет.');
    }
    if (mounted) setState(() => _locating = false);
  }

  static String _coords(({double lat, double lon}) p) => '${p.lat.toStringAsFixed(5)}, ${p.lon.toStringAsFixed(5)}';

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Координаты скопированы'))));
  }

  Future<void> _openMaps(({double lat, double lon}) p, String label) async {
    final ok = await openInMaps(p.lat, p.lon, label);
    if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('На телефоне нет приложения с картами'))));
  }

  Future<void> _begin() async {
    final go = AppHooks.startAlongRoute;
    if (go == null) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await go(widget.route.id, reverse: _reverse);
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: _name);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(t('Название маршрута')),
        content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.sentences),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(t('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: Text(t('Сохранить'))),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.isEmpty) return;
    await TrackDb.instance.renameRoute(widget.route.id, name);
    _changed = true;
    if (mounted) setState(() => _name = name);
  }

  Future<void> _share() async {
    final dir = await getTemporaryDirectory();
    final safe = _name.replaceAll(RegExp(r'[^\wА-Яа-яЁё\- ]'), '_').trim();
    final file = File('${dir.path}/${safe.isEmpty ? 'route' : safe}.gpx');
    await file.writeAsString(routeToGpx(_name, _pts));
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: t('Tropa — маршрут')));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('Удалить маршрут «{p0}»?', {'p0': _name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Удалить'))),
        ],
      ),
    );
    if (ok != true) return;
    await TrackDb.instance.deleteRoute(widget.route.id);
    if (mounted) Navigator.pop(context, true);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_two(d.day)}.${_two(d.month)}.${d.year}';
  }

  static String _duration(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60;
    return h > 0 ? t('{h} ч {m} мин', {'h': h, 'm': m}) : t('{m} мин', {'m': math.max(1, m)});
  }

  String _dir(double deg) => compassWord(deg);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final len = widget.route.lengthM;
    final time = estimateRouteTime(len, ascentM: _elev?.gain, mode: AppSettings.instance.travelMode);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _rename();
                  case 'share':
                    _share();
                  case 'delete':
                    _delete();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rename', child: Text(t('Переименовать'))),
                PopupMenuItem(value: 'share', child: Text(t('Поделиться GPX'))),
                PopupMenuItem(value: 'delete', child: Text(t('Удалить'))),
              ],
            ),
          ],
        ),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: 230,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _PreviewPainter(_pts, _reverse, _me, cs.primary, cs.tertiary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  _stat(context, t('Длина'), Units.dist(len)),
                  _stat(context, t('В пути ≈'), _duration(time)),
                  _stat(
                    context,
                    t('Набор высоты'),
                    _elev != null ? '↑ ${Units.height(_elev!.gain)}' : (_elevLoading ? '…' : '–'),
                  ),
                ]),
                if (_elev == null && !_elevLoading)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(t('Высоты подгрузятся при подключении к интернету; пока время оценено только по длине.'),
                        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: false, icon: const Icon(Icons.arrow_forward), label: Text(t('Вперёд'))),
                    ButtonSegment(value: true, icon: const Icon(Icons.arrow_back), label: Text(t('Обратно'))),
                  ],
                  selected: {_reverse},
                  onSelectionChanged: (v) => setState(() => _reverse = v.first),
                ),
                const SizedBox(height: 12),
                _pointCard(context, Icons.trip_origin, t('Старт'), _start),
                _pointCard(context, Icons.flag, t('Финиш'), _finish),
                _meCard(context),
                if (_walks.isNotEmpty) _walksCard(context),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _begin,
                      icon: const Icon(Icons.navigation),
                      label: Text(t('Идти по маршруту')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MapPage(routeId: widget.route.id, title: _name))),
                      icon: const Icon(Icons.map),
                      label: Text(t('Карта')),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                  t('Если вы не у старта, приложение предложит дождаться вас там или начать с текущего места.'),
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) => Expanded(
        child: Column(children: [
          Text(value, style: Theme.of(context).textTheme.titleMedium),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );

  Widget _pointCard(BuildContext context, IconData icon, String label, ({double lat, double lon}) p) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: Text(_coords(p), style: text.bodyMedium),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: t('Скопировать координаты'), icon: const Icon(Icons.copy), onPressed: () => _copy(_coords(p))),
          IconButton(tooltip: t('Открыть в приложении карт'), icon: const Icon(Icons.open_in_new), onPressed: () => _openMaps(p, '$_name — $label')),
        ]),
      ),
    );
  }

  Widget _meCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    String line;
    if (_locError != null) {
      line = _locError!;
    } else if (_me != null) {
      final d = haversine(_me!.latitude, _me!.longitude, _start.lat, _start.lon);
      final deg = bearingDeg(_me!.latitude, _me!.longitude, _start.lat, _start.lon);
      line = d <= 50
          ? t('Вы у старта маршрута')
          : t('До старта {d} по прямой, направление: {dir}', {'d': Units.dist(d, digits: d < 1000 ? 2 : 1), 'dir': _dir(deg)});
    } else {
      line = t('Узнайте, как далеко вы от старта.');
    }
    return Card(
      child: ListTile(
        leading: Icon(Icons.my_location, color: _locError != null ? cs.error : null),
        title: Text(line, style: text.bodyMedium),
        trailing: _locating
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
            : TextButton(onPressed: _whereAmI, child: Text(_me == null ? t('Где я') : t('Обновить'))),
      ),
    );
  }

  Widget _walksCard(BuildContext context) {
    final n = _walks.length;
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.history),
        title: Text(t('Вы проходили этот маршрут: {n}', {'n': n})),
        subtitle: Text(t('Последний раз: {d}', {'d': _date(_walks.first.startMs)})),
        children: [
          for (final w in _walks)
            ListTile(
              dense: true,
              title: Text(_date(w.startMs)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => RouteViewPage(sessionId: w.sessionId, title: _name)),
              ),
            ),
        ],
      ),
    );
  }
}

/// The line of the route fitted into the box, with the start (green) and the finish (red); a dot for you when you
/// are inside the picture.
class _PreviewPainter extends CustomPainter {
  final List<({double lat, double lon})> pts;
  final bool reverse;
  final Position? me;
  final Color line;
  final Color mine;

  _PreviewPainter(this.pts, this.reverse, this.me, this.line, this.mine);

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.length < 2) return;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    final kx = math.cos((minLat + maxLat) / 2 * math.pi / 180);
    final w = math.max((maxLon - minLon) * kx, 1e-6);
    final h = math.max(maxLat - minLat, 1e-6);
    final scale = math.min(size.width / w, size.height / h) * 0.9;
    final ox = (size.width - w * scale) / 2;
    final oy = (size.height - h * scale) / 2;
    Offset at(double lat, double lon) => Offset(ox + (lon - minLon) * kx * scale, size.height - oy - (lat - minLat) * scale);

    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = at(pts[i].lat, pts[i].lon);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final first = at(pts.first.lat, pts.first.lon), last = at(pts.last.lat, pts.last.lon);
    canvas.drawCircle(reverse ? last : first, 8, Paint()..color = Colors.green);
    canvas.drawCircle(reverse ? first : last, 8, Paint()..color = Colors.red);
    final m = me;
    if (m != null) {
      final o = at(m.latitude, m.longitude);
      if (o.dx >= 0 && o.dx <= size.width && o.dy >= 0 && o.dy <= size.height) {
        canvas.drawCircle(o, 9, Paint()..color = Colors.white);
        canvas.drawCircle(o, 6, Paint()..color = mine);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) => old.pts != pts || old.reverse != reverse || old.me != me;
}
