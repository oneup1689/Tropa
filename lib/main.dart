import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_hooks.dart';
import 'app_shell.dart';
import 'brand.dart';
import 'db.dart';
import 'debug_log.dart';
import 'geoid.dart';
import 'l10n.dart';
import 'map_page.dart';
import 'modes.dart';
import 'notes.dart';
import 'auto_record_page.dart';
import 'readiness.dart';
import 'recorder.dart';
import 'route_view.dart';
import 'nav_page.dart';
import 'route_navigator.dart';
import 'routes_section.dart';
import 'settings.dart';
import 'stats.dart';
import 'theme.dart';
import 'units.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DebugLog.instance.init();
  await AppSettings.instance.load();
  await Geoid.instance.load();
  FlutterError.onError = (d) => DebugLog.instance.log('FLUTTER_ERROR', d.exceptionAsString());
  await _logDevice();
  await Recorder.instance.init();
  await RouteNavigator.instance.restore();
  runApp(TropaApp());
}

Future<void> _logDevice() async {
  try {
    final pkg = await PackageInfo.fromPlatform();
    final info = DeviceInfoPlugin();
    final String dev;
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      dev = '${a.manufacturer} ${a.model} Android ${a.version.release} (SDK ${a.version.sdkInt})';
    } else {
      final i = await info.iosInfo;
      dev = '${i.utsname.machine} iOS ${i.systemVersion}';
    }
    DebugLog.instance.log('APP', 'Tropa ${pkg.version}+${pkg.buildNumber} on $dev');
  } catch (e) {
    DebugLog.instance.log('APP', 'device info failed: $e');
  }
}

class TropaApp extends StatelessWidget {
  const TropaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: L10n.revision,
      builder: (context, _, _) => ValueListenableBuilder<ThemeMode>(
        valueListenable: AppSettings.instance.themeNotifier,
        builder: (context, mode, _) => MaterialApp(
          // No key here: a new key would rebuild the navigator and throw the person out of the Settings screen
          // after changing the language. The home and settings screens listen to AppSettings and repaint themselves;
          // other screens are opened after the language is chosen.
          title: 'Tropa',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          locale: Locale(L10n.code),
          supportedLocales: [Locale('ru'), Locale('en')],
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const AppShell(),
        ),
      ),
    );
  }
}

/// What the list of walks shows about one walk, computed once from its points.
class _Summary {
  final int pointCount;
  final double distanceM;
  final int totalSeconds;
  final List<TrackPoint> thumb;

  _Summary(this.pointCount, this.distanceM, this.totalSeconds, this.thumb);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final rec = Recorder.instance;
  List<SessionInfo> sessions = [];
  final Map<int, Future<_Summary>> _summaries = {};
  final Map<int, int> _summaryCount = {};
  Timer? _ticker;
  ReadinessResult? _ready; // can the phone record right now (the indicator on the start card)
  bool? _lastGps;
  double _weekM = 0; // distance and number of the walks of the last 7 days (idle start card)
  int _weekN = 0;
  int _section = 0; // the Trails tab: 0 walked, 1 routes
  List<RouteInfo> routes = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshReadiness();
    rec.addListener(_onChange);
    RouteNavigator.instance.addListener(_onChange);
    AppSettings.instance.addListener(_onChange); // e.g. Pro mode switched on: the menu shows the extra items
    var tick = 0;
    _ticker = Timer.periodic(Duration(seconds: 1), (_) {
      if (!rec.recording) return;
      _onChange();
      // Keep the list (point counts, the new walk) fresh while a recording is running.
      if (++tick % 5 == 0) _reload();
    });
    AppHooks.startAlongRoute = startAlongRoute;
    AppHooks.reloadWalks = _reload;
    _reload();
  }

  @override
  void dispose() {
    // A newer instance (the tree was rebuilt after the splash) may have registered already: only remove our own entries.
    if (AppHooks.startAlongRoute == startAlongRoute) AppHooks.startAlongRoute = null;
    if (AppHooks.reloadWalks == _reload) AppHooks.reloadWalks = null;
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    rec.removeListener(_onChange);
    RouteNavigator.instance.removeListener(_onChange);
    AppSettings.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    // GPS switched on or off in the phone: the indicator follows at once.
    if (_lastGps != rec.gpsEnabled) {
      _lastGps = rec.gpsEnabled;
      _refreshReadiness();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshReadiness(); // back from the system settings
  }

  Future<void> _refreshReadiness() async {
    final r = await checkReadiness();
    if (mounted) setState(() => _ready = r);
  }

  Future<void> _openReadiness() async {
    final r = _ready ?? await checkReadiness();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReadinessSheet(initial: r, onChanged: (v) => mounted ? setState(() => _ready = v) : null),
    );
    await _refreshReadiness();
  }

  Future<void> _reload() async {
    final s = await TrackDb.instance.sessions();
    final r = await TrackDb.instance.routes();
    if (mounted) {
      setState(() {
        sessions = s;
        routes = r;
      });
    }
    await _recomputeWeek();
  }

  Future<void> _recomputeWeek() async {
    final cutoff = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final week = [for (final x in sessions) if (x.startMs >= cutoff && x.pointCount > 1) x];
    var m = 0.0;
    for (final x in week) {
      m += (await _summary(x)).distanceM;
    }
    if (mounted && (m != _weekM || week.length != _weekN)) {
      setState(() {
        _weekM = m;
        _weekN = week.length;
      });
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Summary of a walk, recomputed only when its number of points changed.
  Future<_Summary> _summary(SessionInfo s) {
    if (_summaryCount[s.id] != s.pointCount) {
      _summaryCount[s.id] = s.pointCount;
      _summaries[s.id] = _computeSummary(s);
    }
    return _summaries[s.id]!;
  }

  Future<_Summary> _computeSummary(SessionInfo s) async {
    final pts = await TrackDb.instance.points(s.id);
    final st = computeStats(pts, movingSpeedMs: profileOf(TravelModeInfo.parse(s.mode)).movingSpeedMs);
    final step = (pts.length / 160).ceil().clamp(1, 1000);
    final thumb = [for (var i = 0; i < pts.length; i += step) pts[i], if (pts.isNotEmpty) pts.last];
    return _Summary(pts.length, st.distanceMeters, st.totalSeconds, thumb);
  }

  /// Step-by-step permissions: location -> notifications -> "always" -> battery.
  Future<bool> _ensurePermissions() async {
    final log = DebugLog.instance;
    final loc = await Permission.locationWhenInUse.request();
    log.log('PERM', 'locationWhenInUse=$loc');
    if (!loc.isGranted) {
      _snack(t('Нужен доступ к геолокации. Разрешите его в настройках приложения.'));
      if (loc.isPermanentlyDenied) await openAppSettings();
      return false;
    }
    if (Platform.isAndroid) {
      final n = await Permission.notification.request();
      log.log('PERM', 'notification=$n');
    }
    var always = await Permission.locationAlways.status;
    if (!always.isGranted) {
      if (!mounted) return false;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('Запись при выключенном экране')),
          content: Text(t('На следующем экране выберите «Разрешить всегда» (на iPhone — «Всегда»). '
              'Без этого запись может оборваться, когда экран погаснет.')),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Понятно')))],
        ),
      );
      always = await Permission.locationAlways.request();
      log.log('PERM', 'locationAlways=$always');
      if (!always.isGranted && mounted) {
        // Android 11+ only grants "Always" from the system settings screen.
        final open = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(t('Включите «Разрешить всегда»')),
            content: Text(t('Откроются настройки приложения: Разрешения → Местоположение → «Разрешить всегда» '
                '(и «Точное местоположение»). Затем вернитесь в Tropa.')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Позже'))),
              TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Открыть настройки'))),
            ],
          ),
        );
        if (open == true) {
          await openAppSettings();
          return false;
        }
      }
    }
    if (Platform.isAndroid) {
      final bat = await Permission.ignoreBatteryOptimizations.status;
      if (!bat.isGranted) {
        final r = await Permission.ignoreBatteryOptimizations.request();
        log.log('PERM', 'ignoreBatteryOptimizations=$r');
      }
    }
    return true;
  }

  Future<void> _toggle() async {
    if (rec.recording) {
      await rec.stop();
      await _reload();
      return;
    }
    if (!await _ensurePermissions()) return;
    final ok = await rec.start();
    if (!ok) _snack(t('Не удалось начать запись. Включите GPS в настройках телефона.'));
    await _reload();
  }

  Future<void> _resume(SessionInfo s) async {
    if (!await _ensurePermissions()) return;
    await rec.start(resumeSessionId: s.id);
    await _reload();
  }

  Future<void> _newNote() async {
    final saved = await showNoteSheet(context);
    if (saved) _snack(t('Заметка сохранена'));
  }

  /// Starts a recording along an imported route (also called from the Routes tab).
  Future<void> startAlongRoute(int routeId, {bool reverse = false}) async {
    if (rec.recording) {
      _snack(RouteNavigator.instance.active ? t('Навигация уже идёт') : t('Сначала остановите текущую запись'));
      if (RouteNavigator.instance.active && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const NavPage()));
      return;
    }
    if (!await _ensurePermissions()) return;
    final ok = await rec.start(routeId: routeId);
    if (!ok) {
      _snack(t('Не удалось начать запись'));
      await _reload();
      return;
    }
    final name = routes.where((r) => r.id == routeId).map((r) => r.name).firstOrNull ?? '';
    final started = await RouteNavigator.instance.begin(routeId, name, reverseDir: reverse);
    await _reload();
    if (started && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const NavPage()));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(Duration d) => '${_two(d.inHours)}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';

  /// "12 окт · 07:23" (the year is added for older walks).
  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final year = d.year == DateTime.now().year ? '' : ' ${d.year}';
    return '${d.day} ${monthShort(d.month)}$year · ${_two(d.hour)}:${_two(d.minute)}';
  }

  /// Plain "12.10.2026 07:23" for titles of other screens.
  static String _dateFull(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_two(d.day)}.${_two(d.month)}.${d.year} ${_two(d.hour)}:${_two(d.minute)}';
  }

  static String _duration(int seconds) {
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60;
    return h > 0 ? '$h:${_two(m)}' : '${m == 0 ? 1 : m} ${t('мин')}';
  }

  @override
  Widget build(BuildContext context) {
    // "Back" is handled in AppShell (a second PopScope here minimised the app on every tab).
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(children: [
          TropaLogo(size: 34),
          SizedBox(width: 10),
          Text('Tropa', style: TextStyle(fontFamily: headingFont, fontSize: 22, fontVariations: [FontVariation('wght', 700)])),
        ]),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          ..._banners(context),
          _recordCard(context),
          SizedBox(height: 22),
          // Trails: what was walked (the history, for posters) and routes (for walking again, with navigation).
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, icon: const Icon(Icons.history), label: Text('${t('Пройденные')}${sessions.isEmpty ? '' : ' ${sessions.length}'}')),
              ButtonSegment(value: 1, icon: const Icon(Icons.alt_route), label: Text('${t('Маршруты')}${routes.isEmpty ? '' : ' ${routes.length}'}')),
            ],
            selected: {_section},
            onSelectionChanged: (v) => setState(() => _section = v.first),
          ),
          SizedBox(height: 10),
          if (_section == 0) ...[
            if (sessions.isEmpty) _emptyState(context),
            for (final s in sessions) _sessionCard(context, s),
          ] else
            RoutesSection(routes: routes, onChanged: _reload, onFollow: startAlongRoute),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ banners

  List<Widget> _banners(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget banner(IconData icon, String title, String text, {Color? color, Widget? action}) => Card(
          color: color ?? cs.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(children: [
              Icon(icon, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(text, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              if (action != null) ...[const SizedBox(width: 8), action],
            ]),
          ),
        );
    final out = <Widget>[];
    if (rec.recording && !rec.gpsEnabled) {
      out.add(banner(
        Icons.location_off,
        t('GPS выключен — маршрут не пишется'),
        t('Включите геолокацию, запись продолжится сама.'),
        color: cs.errorContainer,
        action: FilledButton(onPressed: Geolocator.openLocationSettings, child: Text(t('Включить'))),
      ));
    }
    if (rec.watching && !rec.recording) {
      final noSensor = rec.motionSensor == 'none';
      out.add(banner(
        noSensor ? Icons.warning_amber : Icons.hearing,
        t('Автозапись 24/7 включена'),
        noSensor
            ? t('На этом телефоне нет датчика шагов или движения: автозапись не заметит, что вы пошли. Запускайте запись кнопкой.')
            : t('Жду движения: GPS выключен. Запись начнётся сама.'),
        color: noSensor ? cs.errorContainer : cs.primaryContainer,
      ));
    }
    if (rec.recording && RouteNavigator.instance.active) {
      out.add(banner(
        Icons.navigation,
        t('Навигация: {n}', {'n': RouteNavigator.instance.routeName}),
        t('Подсказки поворотов включены'),
        color: cs.primaryContainer,
        action: FilledButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NavPage())),
          child: Text(t('Открыть')),
        ),
      ));
    } else if (rec.recording && rec.offRouteMeters >= 0) {
      final off = rec.offRouteMeters > AppSettings.instance.offRouteMeters;
      out.add(banner(
        Icons.navigation,
        off ? t('Вы в {d} от маршрута', {'d': Units.shortDist(rec.offRouteMeters)}) : t('Вы на маршруте'),
        t('Расстояние до линии: {d}', {'d': Units.shortDist(rec.offRouteMeters)}),
        color: off ? cs.errorContainer : cs.secondaryContainer,
      ));
    }
    if (rec.interrupted != null && !rec.recording) {
      out.add(banner(
        Icons.history_toggle_off,
        t('Прошлая запись была прервана'),
        t('Сохранено точек: {n}. Можно продолжить.', {'n': rec.interrupted!.pointCount}),
        color: cs.errorContainer,
        action: TextButton(onPressed: () => _resume(rec.interrupted!), child: Text(t('Продолжить'))),
      ));
    }
    return out;
  }

  // ------------------------------------------------------------------ record card

  Widget _recordCard(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final elapsed = rec.startedAt == null ? Duration.zero : DateTime.now().difference(rec.startedAt!);
    final recording = rec.recording;
    final gradient = dark ? const [Color(0xFF14463A), Color(0xFF0B2A25)] : const [Color(0xFF1F6B4A), Color(0xFF0B3D2E)];
    final ready = _ready;
    final label = recording ? (rec.manualPause ? t('ПАУЗА') : t('ЗАПИСЬ')) : (ready?.label ?? t('ГОТОВ К ПРОГУЛКЕ'));
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: Container(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradient)),
        child: Stack(children: [
          const Positioned.fill(child: CustomPaint(painter: ContourPainter(color: Color(0x1FFFFFFF)))),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _StatusPill(
                  recording: recording,
                  paused: rec.manualPause,
                  label: label,
                  tone: recording || ready == null ? null : readinessColor(ready.level),
                  onTap: recording ? null : _openReadiness,
                ),
                const Spacer(),
                if (recording)
                  Text(_fmt(elapsed),
                      style: const TextStyle(
                          fontFamily: headingFont, fontSize: 26, color: Colors.white, fontVariations: [FontVariation('wght', 700)]))
                else if (Platform.isAndroid)
                  _plannerButton(),
              ]),
              const SizedBox(height: 16),
              _modeRow(recording),
              if (recording) ...[
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(flex: 5, child: Padding(padding: const EdgeInsets.only(right: 12), child: _stat(Units.dist(rec.distanceM), t('Дистанция')))),
                  Expanded(
                      flex: 4,
                      child: Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _stat(_fmt(Duration(seconds: rec.movingSeconds)), rec.autoPaused || rec.manualPause ? t('Пауза') : t('В движении')))),
                  Expanded(
                    flex: 4,
                    child: _stat(
                      rec.gpsEnabled && rec.sinceFixSec >= 20 ? t('нет {s} с', {'s': rec.sinceFixSec}) : Units.shortDist(rec.lastAccuracy),
                      rec.gpsEnabled && rec.sinceFixSec >= 20 ? t('Сигнал') : t('Точность'),
                    ),
                  ),
                ]),
              ] else if (_weekN > 0) ...[
                const SizedBox(height: 18),
                _weekLine(),
              ],
              if (recording && rec.goalM > 0) ...[
                const SizedBox(height: 16),
                _goalProgress(),
              ],
              const SizedBox(height: 22),
              Row(children: [
                if (Platform.isAndroid) ...[_goalButton(), const SizedBox(width: 10)],
                Expanded(child: _recordButton(recording)),
              ]),
              if (recording) ...[
                const SizedBox(height: 10),
                Row(children: [
                  if (Platform.isAndroid) ...[
                    Expanded(
                      child: _glassButton(
                        rec.manualPause ? Icons.play_arrow : Icons.pause,
                        rec.manualPause ? t('Продолжить') : t('Пауза'),
                        rec.manualPause ? rec.resume : rec.pause,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: _glassButton(Icons.edit_note, t('Заметка'), _newNote)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _glassButton(
                      Icons.map_outlined,
                      t('Карта'),
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MapPage(sessionId: rec.sessionId, live: true, title: t('Живая карта'), mode: AppSettings.instance.travelMode),
                        ),
                      ),
                    ),
                  ),
                ]),
                if (rec.manualPause)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      t('Запись продолжится сама, когда вы отойдёте больше чем на 20 м.'),
                      style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _stat(String value, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: const TextStyle(
                  fontFamily: headingFont, fontSize: 20, color: Colors.white, fontVariations: [FontVariation('wght', 700)])),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]);

  /// The ways of travelling as five round icons (the chosen one is white), its name underneath.
  Widget _modeRow(bool recording) {
    final current = recording ? rec.activeMode : AppSettings.instance.travelMode;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        for (final m in TravelMode.values)
          Expanded(
            child: Center(
              child: Tooltip(
                message: t(m.label),
                child: GestureDetector(
                  onTap: recording
                      ? null
                      : () async {
                          await AppSettings.instance.setTravelMode(m);
                          if (mounted) setState(() {});
                        },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: current == m ? Colors.white : const Color(0x26FFFFFF)),
                    child: Icon(modeIcon(m), size: 22, color: current == m ? TropaColors.forestDeep : (recording ? Colors.white38 : Colors.white)),
                  ),
                ),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 8),
      Text(t(current.label), style: const TextStyle(color: Colors.white70, fontSize: 13)),
    ]);
  }

  /// "This week: 18.4 km · 5 walks": what the idle card says instead of empty counters.
  Widget _weekLine() => Row(children: [
        const Icon(Icons.insights, size: 18, color: Colors.white70),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            t('За неделю: {d} · {n} {w}', {
              'd': Units.dist(_weekM, digits: 1),
              'n': _weekN,
              'w': plural(_weekN, 'прогулка', 'прогулки', 'прогулок', en1: 'walk', enN: 'walks'),
            }),
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ]);

  // ------------------------------------------------------------------ distance goal

  /// The corner of the start card: the Auto-record screen (24/7 and the planner), with a small "24/7" mark while the
  /// automatic recording is on, so that an always-on mode is visible without opening the settings.
  Widget _plannerButton() => Tooltip(
        message: t('Автозапись'),
        child: GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AutoRecordPage())),
          child: Container(
            height: 40,
            padding: EdgeInsets.symmetric(horizontal: AppSettings.instance.autoMode ? 12 : 0),
            constraints: const BoxConstraints(minWidth: 40),
            decoration: BoxDecoration(color: const Color(0x26FFFFFF), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.event_available_outlined, size: 21, color: Colors.white),
              if (AppSettings.instance.autoMode) ...[
                const SizedBox(width: 6),
                const Text('24/7', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ]),
          ),
        ),
      );

  /// A round flag button next to the record button: opens the goal sheet; shows the goal once it is set.
  Widget _goalButton() {
    final goal = rec.activeGoalM;
    final set = goal > 0;
    final fg = set ? TropaColors.forestDeep : Colors.white;
    return Tooltip(
      message: t('Цель'),
      child: GestureDetector(
        onTap: _openGoalSheet,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 58,
          constraints: const BoxConstraints(minWidth: 58),
          padding: EdgeInsets.symmetric(horizontal: set ? 14 : 0),
          decoration: BoxDecoration(color: set ? TropaColors.mint : const Color(0x26FFFFFF), borderRadius: BorderRadius.circular(29)),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.flag_outlined, size: 24, color: fg),
            if (set) ...[
              const SizedBox(width: 6),
              Text('${Units.distTrim(goal)}${rec.activeGoalRound ? ' ↔' : ''}',
                  style: TextStyle(fontSize: 14, fontVariations: const [FontVariation('wght', 700)], color: fg)),
            ],
          ]),
        ),
      ),
    );
  }

  /// Progress of the goal while recording: a bar and what is left.
  Widget _goalProgress() {
    final goal = rec.goalM;
    final done = rec.goalStage >= 2 || rec.distanceM >= goal;
    final left = (goal - rec.distanceM).clamp(0, goal).toDouble();
    final text = done
        ? t('Цель достигнута')
        : (rec.goalRound && rec.goalStage == 1
            ? t('Идём обратно: осталось {a}', {'a': Units.dist(left, digits: 1)})
            : t('До цели {a}', {'a': Units.dist(left, digits: 1)}));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(done ? Icons.check_circle : Icons.flag_outlined, size: 16, color: done ? TropaColors.mint : Colors.white70),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13.5))),
        Text('${Units.distTrim(goal)}${rec.goalRound ? ' ↔' : ''}', style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(children: [
          LinearProgressIndicator(
            value: (rec.distanceM / goal).clamp(0, 1).toDouble(),
            minHeight: 7,
            backgroundColor: const Color(0x33FFFFFF),
            color: done ? TropaColors.mint : TropaColors.orange,
          ),
          // The half-way mark of an out-and-back goal.
          if (rec.goalRound) Positioned.fill(child: Align(child: Container(width: 2, height: 7, color: Colors.white70))),
        ]),
      ),
    ]);
  }

  Future<void> _openGoalSheet() async {
    final result = await showModalBottomSheet<({double meters, bool round})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GoalSheet(currentMeters: rec.activeGoalM, currentRound: rec.activeGoalRound),
    );
    if (result == null || !mounted) return;
    await rec.setGoal(result.meters, roundTrip: result.round);
  }

  Widget _recordButton(bool recording) {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: FilledButton.icon(
        onPressed: _toggle,
        icon: Icon(recording ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 30),
        label: Text(recording ? t('Остановить') : t('Начать запись'), style: const TextStyle(fontSize: 16.5)),
        style: FilledButton.styleFrom(
          backgroundColor: recording ? const Color(0xFFE53935) : Theme.of(context).colorScheme.secondary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(58),
        ),
      ),
    );
  }

  Widget _glassButton(IconData icon, String label, VoidCallback onTap) => OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 19),
        label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color(0x1AFFFFFF),
          side: const BorderSide(color: Color(0x40FFFFFF)),
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
      );

  // ------------------------------------------------------------------ walks

  Widget _emptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 12),
      child: Column(children: [
        const TropaLogo(size: 64),
        const SizedBox(height: 14),
        Text(t('Пока пусто'), style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(t('Нажмите «Начать запись» и пройдитесь: маршрут появится здесь.'),
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
    );
  }

  IconData _statusIcon(String s) => switch (s) {
        'active' => Icons.fiber_manual_record,
        'interrupted' => Icons.warning_amber_rounded,
        _ => Icons.check_circle_outline,
      };

  Widget _sessionCard(BuildContext context, SessionInfo s) {
    final cs = Theme.of(context).colorScheme;
    final mode = TravelModeInfo.parse(s.mode);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => RouteViewPage(sessionId: s.id, title: s.title.isEmpty ? _dateFull(s.startMs) : s.title, mode: mode)),
          );
          // The walk may have been renamed, changed or deleted on its own screen.
          if (mounted) await _reload();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FutureBuilder<_Summary>(
            future: _summary(s),
            builder: (context, snap) {
              final sum = snap.data;
              return Row(children: [
                RouteThumb(
                  points: sum?.thumb ?? const [],
                  background: dark ? const Color(0xFF123B30) : const Color(0xFF1F6B4A),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.title.isEmpty ? _date(s.startMs) : s.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                    if (s.title.isNotEmpty)
                      Text(_date(s.startMs),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 5),
                    Row(children: [
                      Icon(modeIcon(mode), size: 16, color: cs.primary),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          sum == null ? t(mode.label) : '${Units.dist(sum.distanceM, digits: 1)} · ${_duration(sum.totalSeconds)}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(_statusIcon(s.status),
                          size: 13,
                          color: s.status == 'active' ? Colors.redAccent : (s.status == 'interrupted' ? cs.error : cs.primary)),
                      const SizedBox(width: 4),
                      Text(
                        s.status == 'active'
                            ? t('идёт запись')
                            : (s.status == 'interrupted'
                                ? t('прервана')
                                : '${sum == null ? '' : '${t(mode.label)} · '}${t('точек: {n}', {'n': s.pointCount})}'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ]),
                  ]),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

/// "ЗАПИСЬ" / "ПАУЗА" / "ГОТОВ К ПРОГУЛКЕ": a pill with a pulsing dot while recording.
class _StatusPill extends StatefulWidget {
  final bool recording;
  final bool paused;
  final String label;
  final Color? tone; // overrides the dot colour while not recording (ready / warning / blocked)
  final VoidCallback? onTap; // opens the readiness sheet

  const _StatusPill({required this.recording, required this.paused, required this.label, this.tone, this.onTap});

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.paused ? Colors.amber : (widget.recording ? const Color(0xFFFF5252) : (widget.tone ?? const Color(0xFF69F0AE)));
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(color: const Color(0x26FFFFFF), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (_, _) => Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: widget.recording && !widget.paused ? 0.45 + 0.55 * _pulse.value : 1),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(widget.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12.5, letterSpacing: 0.8, fontVariations: [FontVariation('wght', 700)])),
        ),
        if (widget.onTap != null) ...[const SizedBox(width: 2), const Icon(Icons.chevron_right, size: 18, color: Colors.white70)],
      ]),
    );
    return widget.onTap == null ? pill : GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: pill);
  }
}

/// The "goal for this walk" sheet: presets, own value, out-and-back switch. Pops with the chosen goal
/// (0 metres = remove the goal) or with nothing when closed. It owns its text controller.
class _GoalSheet extends StatefulWidget {
  final double currentMeters;
  final bool currentRound;

  const _GoalSheet({required this.currentMeters, required this.currentRound});

  @override
  State<_GoalSheet> createState() => _GoalSheetState();
}

/// The goal card: optional, one short explanation, a whole number of kilometres (miles) from 1 up, and "out and back".
class _GoalSheetState extends State<_GoalSheet> {
  static const int minGoal = 1;
  static const int maxGoal = 100;
  static const int sliderMax = 30; // the slider covers the usual walks, the plus button goes on to [maxGoal]

  late final List<int> presets = Units.imperial ? const [2, 3, 5, 10] : const [3, 5, 10, 15];
  late final double toMeters = Units.imperial ? 1609.344 : 1000.0;
  late int value = widget.currentMeters > 0 ? (widget.currentMeters / toMeters).round().clamp(minGoal, maxGoal) : 5;
  late bool round = widget.currentRound;

  void _set(int v) => setState(() => value = v.clamp(minGoal, maxGoal));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final unit = Units.kmUnit;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(t('Цель на прогулку'), style: text.titleLarge)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
            child: Text(t('необязательно'), style: text.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(t('Пройдёте это расстояние — придёт уведомление. Запись продолжится.'),
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton.filledTonal(
            tooltip: t('Меньше'),
            onPressed: value > minGoal ? () => _set(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 140,
            child: Text('$value $unit', textAlign: TextAlign.center, style: text.headlineMedium),
          ),
          IconButton.filledTonal(
            tooltip: t('Больше'),
            onPressed: value < maxGoal ? () => _set(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ]),
        Slider(
          min: minGoal.toDouble(),
          max: sliderMax.toDouble(),
          divisions: sliderMax - minGoal,
          value: value.clamp(minGoal, sliderMax).toDouble(),
          onChanged: (v) => _set(v.round()),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in presets)
            ChoiceChip(label: Text('$p $unit'), selected: value == p, onSelected: (_) => _set(p)),
        ]),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('Туда и обратно')),
          subtitle: Text(t('На половине пути подскажем, что пора разворачиваться')),
          value: round,
          onChanged: (v) => setState(() => round = v),
        ),
        const SizedBox(height: 8),
        Row(children: [
          TextButton(
            onPressed: () => Navigator.pop(context, (meters: 0.0, round: false)),
            child: Text(widget.currentMeters > 0 ? t('Убрать цель') : t('Без цели')),
          ),
          const Spacer(),
          FilledButton(
            onPressed: () => Navigator.pop(context, (meters: value * toMeters, round: round)),
            child: Text(t('Готово')),
          ),
        ]),
      ]),
    );
  }
}
