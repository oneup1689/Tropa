import 'dart:async';

import 'package:flutter/material.dart';

import 'package:geolocator/geolocator.dart';

import 'db.dart';
import 'heal.dart' show haversine;
import 'l10n.dart';
import 'map_page.dart';
import 'route_map_view.dart';
import 'recorder.dart';
import 'route_nav.dart';
import 'route_navigator.dart';
import 'settings.dart';
import 'units.dart';

/// "север", "северо-восток", ... for a course in degrees (in the language of the app).
String compassWord(double deg) => switch (compassPoint8(deg)) {
      'N' => t('север'),
      'NE' => t('северо-восток'),
      'E' => t('восток'),
      'SE' => t('юго-восток'),
      'S' => t('юг'),
      'SW' => t('юго-запад'),
      'W' => t('запад'),
      _ => t('северо-запад'),
    };

/// The navigation screen: what to do next, how far to the turn and to the finish. The walk is recorded all the time.
class NavPage extends StatefulWidget {
  const NavPage({super.key});

  @override
  State<NavPage> createState() => _NavPageState();
}

class _NavPageState extends State<NavPage> {
  final nav = RouteNavigator.instance;
  final rec = Recorder.instance;
  Timer? _tick;

  /// The route for the map and the position of the person (made from what the recorder knows).
  List<({double lat, double lon})>? _points;
  final ValueNotifier<Position?> _me = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    nav.addListener(_changed);
    rec.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
    final id = nav.routeId;
    if (id != null) {
      TrackDb.instance.routePoints(id).then((p) {
        if (mounted) setState(() => _points = p);
      });
    }
    _updateMe();
  }

  @override
  void dispose() {
    _tick?.cancel();
    nav.removeListener(_changed);
    rec.removeListener(_changed);
    _me.dispose();
    super.dispose();
  }

  /// The recorder gives the last stored position; the direction of walking comes from the last two of them.
  void _updateMe() {
    if (rec.lastLat == 0 && rec.lastLon == 0) return;
    final prev = _me.value;
    if (prev != null && prev.latitude == rec.lastLat && prev.longitude == rec.lastLon) return;
    var heading = prev?.heading ?? 0.0;
    var speed = 0.0;
    if (prev != null && haversine(prev.latitude, prev.longitude, rec.lastLat, rec.lastLon) >= 4) {
      heading = bearingDeg(prev.latitude, prev.longitude, rec.lastLat, rec.lastLon);
      speed = 1.5; // walking: enough for the map to turn with the person
    } else if (prev != null) {
      speed = prev.speed;
    }
    _me.value = Position(
      latitude: rec.lastLat,
      longitude: rec.lastLon,
      timestamp: DateTime.now(),
      accuracy: rec.lastAccuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: heading,
      headingAccuracy: 0,
      speed: speed,
      speedAccuracy: 0,
    );
  }

  void _changed() {
    if (!mounted) return;
    if (!nav.active) {
      // Navigation ended (stopped, or finished): leave the screen.
      Navigator.of(context).maybePop();
      return;
    }
    _updateMe();
    setState(() {});
  }

  static IconData _icon(Turn t) => switch (t) {
        Turn.slightLeft => Icons.turn_slight_left,
        Turn.left => Icons.turn_left,
        Turn.sharpLeft => Icons.turn_sharp_left,
        Turn.slightRight => Icons.turn_slight_right,
        Turn.right => Icons.turn_right,
        Turn.sharpRight => Icons.turn_sharp_right,
        Turn.uTurn => Icons.u_turn_left,
      };

  String _elapsed() {
    final s = rec.startedAt;
    if (s == null) return '–';
    final d = DateTime.now().difference(s);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  Future<void> _finish() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('Завершить прогулку?')),
        content: Text(t('Запись остановится и сохранится как ваша прогулка по этому маршруту.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Продолжить'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Завершить'))),
        ],
      ),
    );
    if (ok != true) return;
    await rec.stop();
    await nav.end();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = nav.state;
    final next = s?.next;
    final arrived = s?.arrived ?? false;

    IconData icon;
    String big, small;
    final toStart = s?.toStartM;
    if (toStart != null) {
      icon = Icons.near_me;
      big = Units.dist(toStart, digits: toStart < 1000 ? 2 : 1);
      small = t('до старта, направление: {dir}', {'dir': compassWord(s!.startBearing ?? 0)});
    } else if (arrived) {
      icon = Icons.flag;
      big = t('Вы на месте');
      small = t('Можно завершить прогулку');
    } else if (s == null) {
      icon = Icons.gps_not_fixed;
      big = t('Ищем вас на маршруте…');
      small = t('Нужен сигнал GPS');
    } else if (next != null) {
      icon = _icon(next.turn);
      big = Units.shortDist(s.toNextM);
      small = RouteNavigator.turnWord(next.turn);
    } else {
      icon = Icons.straight;
      big = Units.dist(s.remainingM);
      small = t('до конца маршрута');
    }

    return Scaffold(
      appBar: AppBar(title: Text(nav.routeName, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        if (nav.offRoute)
          Card(
            color: cs.errorContainer,
            child: ListTile(
              leading: Icon(Icons.wrong_location, color: cs.onErrorContainer),
              title: Text(t('Вы сошли с маршрута'), style: TextStyle(color: cs.onErrorContainer)),
              subtitle: Text(t('До маршрута {d}', {'d': Units.shortDist(s?.offM ?? 0)}), style: TextStyle(color: cs.onErrorContainer)),
            ),
          ),
        Card(
          color: cs.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: Row(children: [
              Icon(icon, size: 76, color: cs.onPrimaryContainer),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(big,
                        style: (s != null && !arrived ? text.displaySmall : text.headlineMedium)?.copyWith(color: cs.onPrimaryContainer)),
                  ),
                  Text(small, style: text.titleMedium?.copyWith(color: cs.onPrimaryContainer)),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 4),
        // The map with the route and the person: the way to go is seen, not only told.
        if (_points != null && _points!.length >= 2)
          RouteMapView(
            routeId: nav.routeId!,
            fileTag: '_nav',
            name: nav.routeName,
            points: _points!,
            reverse: nav.reverse,
            me: _me,
            follow: true,
            height: (MediaQuery.of(context).size.height * 0.42).clamp(260.0, 520.0),
            preview: const SizedBox.shrink(),
            onFullscreen: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MapPage(
                    sessionId: rec.sessionId, routeId: nav.routeId, live: true, title: nav.routeName, mode: AppSettings.instance.travelMode),
              ),
            ),
          ),
        if (toStart != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: nav.skipApproach,
                icon: const Icon(Icons.login),
                label: Text(t('Я уже на маршруте, начать здесь')),
              ),
            ),
          ),
        const SizedBox(height: 12),
        if (s != null && toStart == null) ...[
          LinearProgressIndicator(value: (s.progressM / (s.progressM + s.remainingM).clamp(1, double.infinity)).clamp(0.0, 1.0), minHeight: 8),
          const SizedBox(height: 12),
        ],
        Row(children: [
          _stat(context, t('Осталось'), s == null ? '–' : Units.dist(s.remainingM)),
          _stat(context, t('Пройдено'), s == null ? '–' : Units.dist(s.progressM)),
          _stat(context, t('Время'), _elapsed()),
        ]),
        const SizedBox(height: 12),
        if (nav.voiceOn && nav.voiceStatus != null && nav.voiceStatus != 'ok')
          Card(
            child: ListTile(
              leading: const Icon(Icons.record_voice_over),
              title: Text(nav.voiceStatus == 'none' ? t('На телефоне нет синтезатора речи') : t('Нет голоса для языка приложения')),
              subtitle: Text(t('Подсказки будут только вибрацией. Установите голос в настройках телефона.')),
              trailing: TextButton(
                onPressed: () async {
                  await nav.installVoice();
                },
                child: Text(t('Установить')),
              ),
            ),
          ),
        SwitchListTile(
          title: Text(t('Голосовые подсказки')),
          value: nav.voiceOn,
          onChanged: (v) async {
            await AppSettings.instance.set('nav_voice', v);
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: _finish,
            style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
            icon: const Icon(Icons.stop),
            label: Text(t('Завершить')),
          ),
        ]),
        const SizedBox(height: 8),
        Text(t('Пока идёт навигация, ваш путь записывается как обычная прогулка.'),
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }

  Widget _stat(BuildContext context, String label, String value) => Expanded(
        child: Column(children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}
