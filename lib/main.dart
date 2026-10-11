import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'backup.dart';
import 'db.dart';
import 'debug_log.dart';
import 'geoid.dart';
import 'gpx.dart';
import 'map_page.dart';
import 'maps_page.dart';
import 'modes.dart';
import 'notes.dart';
import 'planner_page.dart';
import 'recorder.dart';
import 'route_view.dart';
import 'routes_page.dart';
import 'settings.dart';
import 'settings_page.dart';
import 'share_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DebugLog.instance.init();
  await AppSettings.instance.load();
  await Geoid.instance.load();
  FlutterError.onError = (d) => DebugLog.instance.log('FLUTTER_ERROR', d.exceptionAsString());
  await _logDevice();
  await Recorder.instance.init();
  runApp(const TropaApp());
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
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: 'Tropa',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2E7D32), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF2E7D32), brightness: Brightness.dark, useMaterial3: true),
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final rec = Recorder.instance;
  List<SessionInfo> sessions = [];
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    rec.addListener(_onChange);
    var tick = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!rec.recording) return;
      _onChange();
      // Keep the list (point counts, the new walk) fresh while a recording is running.
      if (++tick % 5 == 0) _reload();
    });
    _reload();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    rec.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final s = await TrackDb.instance.sessions();
    if (mounted) setState(() => sessions = s);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Step-by-step permissions: location -> notifications -> "always" -> battery.
  Future<bool> _ensurePermissions() async {
    final log = DebugLog.instance;
    final loc = await Permission.locationWhenInUse.request();
    log.log('PERM', 'locationWhenInUse=$loc');
    if (!loc.isGranted) {
      _snack('Нужен доступ к геолокации. Разрешите его в настройках приложения.');
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
          title: const Text('Запись при выключенном экране'),
          content: const Text(
              'На следующем экране выберите «Разрешить всегда» (на iPhone — «Всегда»). '
              'Без этого запись может оборваться, когда экран погаснет.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Понятно'))],
        ),
      );
      always = await Permission.locationAlways.request();
      log.log('PERM', 'locationAlways=$always');
      if (!always.isGranted && mounted) {
        // Android 11+ only grants "Always" from the system settings screen.
        final open = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Включите «Разрешить всегда»'),
            content: const Text(
                'Откроются настройки приложения: Разрешения → Местоположение → «Разрешить всегда» '
                '(и «Точное местоположение»). Затем вернитесь в Tropa.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Позже')),
              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Открыть настройки')),
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
    if (!ok) _snack('Не удалось начать запись. Включите GPS в настройках телефона.');
    await _reload();
  }

  Future<void> _resume(SessionInfo s) async {
    if (!await _ensurePermissions()) return;
    await rec.start(resumeSessionId: s.id);
    await _reload();
  }

  /// Export dialog: the user chooses what goes into the GPX file.
  Future<void> _exportGpx(int id) async {
    var heal = AppSettings.instance.healEnabled, withTime = true, withEle = true;
    // Trimming is a Pro option, but a value set earlier keeps working in amateur mode.
    var trimStart = AppSettings.instance.trimStartM, trimEnd = AppSettings.instance.trimEndM;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: const Text('Что включить в GPX'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            CheckboxListTile(
              value: heal,
              onChanged: (v) => setS(() => heal = v ?? heal),
              title: const Text('Склеить короткие разрывы'),
              subtitle: const Text('Только короткие участки, где движение было правдоподобным'),
            ),
            CheckboxListTile(
              value: withTime,
              onChanged: (v) => setS(() => withTime = v ?? withTime),
              title: const Text('Время'),
            ),
            CheckboxListTile(
              value: withEle,
              onChanged: (v) => setS(() => withEle = v ?? withEle),
              title: const Text('Высота'),
            ),
            if (AppSettings.instance.pro) ...[
              const Divider(),
              Text('Обрезать начало: ${trimStart.round()} м'),
              Slider(
                value: trimStart,
                max: 500,
                divisions: 20,
                onChanged: (v) => setS(() => trimStart = v),
              ),
              Text('Обрезать конец: ${trimEnd.round()} м'),
              Slider(
                value: trimEnd,
                max: 500,
                divisions: 20,
                onChanged: (v) => setS(() => trimEnd = v),
              ),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Поделиться')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final f = await writeGpx(
      id,
      withTime: withTime,
      withElevation: withEle,
      heal: heal,
      trimStartM: trimStart,
      trimEndM: trimEnd,
    );
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: 'Tropa — маршрут'));
  }

  Future<void> _newNote() async {
    final saved = await showNoteSheet(context);
    if (saved) _snack('Заметка сохранена');
  }

  /// Opens the imported routes; if the user picks "go along this route", the recording starts with
  /// off-route warnings.
  Future<void> _openRoutes() async {
    final routeId = await Navigator.push<int>(context, MaterialPageRoute(builder: (_) => const RoutesPage()));
    if (routeId == null || !mounted) return;
    if (rec.recording) {
      _snack('Сначала остановите текущую запись');
      return;
    }
    if (!await _ensurePermissions()) return;
    final ok = await rec.start(routeId: routeId);
    _snack(ok ? 'Запись идёт по выбранному маршруту' : 'Не удалось начать запись');
    await _reload();
  }

  Future<void> _backup() async {
    _snack('Готовлю резервную копию…');
    try {
      final r = await exportBackup();
      await SharePlus.instance.share(ShareParams(files: [XFile(r.file.path)], text: 'Tropa — резервная копия'));
      _snack('Копия: прогулок ${r.sessions}, точек ${r.points}');
    } catch (e) {
      DebugLog.instance.log('BACKUP', 'export failed: $e');
      _snack('Не удалось создать копию: $e');
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    try {
      final r = await importBackup(File(path));
      _snack('Восстановлено прогулок: ${r.sessions}, пропущено повторов: ${r.skipped}, заметок: ${r.notes}, маршрутов: ${r.routes}');
      await _reload();
    } catch (e) {
      DebugLog.instance.log('BACKUP', 'import failed: $e');
      _snack('Не удалось восстановить: $e');
    }
  }

  /// Picture without a map background (works even without a downloaded map).
  Future<void> _imageWithoutMap(SessionInfo s) async {
    final options = await askShareOptions(context);
    if (options == null || !mounted) return;
    final pts = await TrackDb.instance.points(s.id);
    await shareRouteImage(
      title: _date(s.startMs),
      pts: pts,
      mode: TravelModeInfo.parse(s.mode),
      options: options,
      fileName: 'tropa_${s.id}',
    );
  }

  /// Quick notes for the test walk: what the user did with the phone and when.
  Future<void> _addMark() async {
    const presets = [
      'Режим самолёта ВКЛ',
      'Режим самолёта ВЫКЛ',
      'Экономия батареи ВКЛ',
      'Экономия батареи ВЫКЛ',
      'GPS ВКЛ',
      'GPS ВЫКЛ',
      'Экран погашен',
      'Экран включён',
      'Телефон в кармане',
    ];
    final ctl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Метка в лог'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 6, children: [
              for (final p in presets) ActionChip(label: Text(p), onPressed: () => Navigator.pop(c, p)),
            ]),
            TextField(controller: ctl, decoration: const InputDecoration(hintText: 'Своя заметка')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Записать')),
        ],
      ),
    );
    if (note != null && note.isNotEmpty) {
      rec.mark(note);
      _snack('Метка записана');
    }
  }

  Future<void> _shareLog() async {
    final path = DebugLog.instance.path;
    if (path == null) return;
    DebugLog.instance.log('LOG', 'shared by user');
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: 'Tropa debug log'));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(Duration d) => '${_two(d.inHours)}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_two(d.day)}.${_two(d.month)}.${d.year} ${_two(d.hour)}:${_two(d.minute)}';
  }

  String _status(String s) => switch (s) {
        'active' => 'идёт запись',
        'interrupted' => 'прервана',
        _ => 'завершена',
      };

  Widget _stat(String label, String value) => Column(children: [
        Text(value, style: Theme.of(context).textTheme.titleMedium),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);

  @override
  Widget build(BuildContext context) {
    final elapsed = rec.startedAt == null ? Duration.zero : DateTime.now().difference(rec.startedAt!);
    return PopScope(
      // While recording, "Back" only minimises the app: closing the activity can stop the recorder.
      canPop: !rec.recording,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && Platform.isAndroid) {
          DebugLog.instance.log('LIFECYCLE', 'Back pressed while recording -> moveTaskToBack');
          const MethodChannel('tropa/system').invokeMethod('moveToBack');
        }
      },
      child: _scaffold(context, elapsed),
    );
  }

  Widget _scaffold(BuildContext context, Duration elapsed) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tropa'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              final nav = Navigator.of(context);
              if (v == 'settings') {
                await nav.push(MaterialPageRoute(builder: (_) => const SettingsPage()));
              }
              if (v == 'maps') {
                await nav.push(MaterialPageRoute(builder: (_) => const MapsPage()));
              }
              if (v == 'openmap') {
                await nav.push(MaterialPageRoute(builder: (_) => const MapPage()));
              }
              if (v == 'routes') await _openRoutes();
              if (v == 'planner') {
                await nav.push(MaterialPageRoute(builder: (_) => const PlannerPage()));
              }
              if (v == 'backup') await _backup();
              if (v == 'restore') await _restore();
              if (v == 'mark') await _addMark();
              if (v == 'log') await _shareLog();
              if (v == 'clear') {
                await DebugLog.instance.clear();
                _snack('Лог очищен');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Настройки')),
              PopupMenuItem(value: 'openmap', child: Text('Открыть карту')),
              PopupMenuItem(value: 'maps', child: Text('Карты (загрузка)')),
              PopupMenuItem(value: 'routes', child: Text('Маршруты (импорт GPX)')),
              PopupMenuItem(value: 'planner', child: Text('Планировщик')),
              PopupMenuItem(value: 'backup', child: Text('Резервная копия')),
              PopupMenuItem(value: 'restore', child: Text('Восстановить из копии')),
              PopupMenuItem(value: 'mark', child: Text('Добавить метку в лог')),
              PopupMenuItem(value: 'log', child: Text('Отправить лог отладки')),
              PopupMenuItem(value: 'clear', child: Text('Очистить лог')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (rec.recording && !rec.gpsEnabled)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.location_off),
                title: const Text('GPS выключен — маршрут не пишется'),
                subtitle: const Text('Включите геолокацию, запись продолжится сама.'),
                trailing: FilledButton(
                  onPressed: Geolocator.openLocationSettings,
                  child: const Text('Включить'),
                ),
              ),
            ),
          if (rec.watching && !rec.recording)
            Card(
              color: rec.motionSensor == 'none' ? Theme.of(context).colorScheme.errorContainer : null,
              child: ListTile(
                leading: Icon(rec.motionSensor == 'none' ? Icons.warning_amber : Icons.hearing),
                title: const Text('Автозапись 24/7 включена'),
                subtitle: Text(rec.motionSensor == 'none'
                    ? 'На этом телефоне нет датчика шагов или движения: автозапись не заметит, что вы пошли. '
                        'Запускайте запись кнопкой.'
                    : 'Жду движения: GPS выключен. Запись начнётся сама.'),
              ),
            ),
          if (rec.recording && rec.offRouteMeters >= 0)
            Card(
              color: rec.offRouteMeters > AppSettings.instance.offRouteMeters
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.navigation),
                title: Text(rec.offRouteMeters > AppSettings.instance.offRouteMeters
                    ? 'Вы в ${rec.offRouteMeters.round()} м от маршрута'
                    : 'Вы на маршруте'),
                subtitle: Text('Расстояние до линии: ${rec.offRouteMeters.round()} м'),
              ),
            ),
          if (rec.interrupted != null && !rec.recording)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                title: const Text('Прошлая запись была прервана'),
                subtitle: Text('Сохранено точек: ${rec.interrupted!.pointCount}. Можно продолжить.'),
                trailing: TextButton(
                  onPressed: () => _resume(rec.interrupted!),
                  child: const Text('Продолжить'),
                ),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(rec.recording ? 'Идёт запись' : 'Запись остановлена',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  // Travel mode: chosen before the start, locked while recording.
                  Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
                    for (final m in TravelMode.values)
                      ChoiceChip(
                        label: Text(m.label),
                        selected: (rec.recording ? rec.activeMode : AppSettings.instance.travelMode) == m,
                        onSelected: rec.recording ? null : (_) async {
                          await AppSettings.instance.setTravelMode(m);
                          if (mounted) setState(() {});
                        },
                      ),
                  ]),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _stat('Дистанция', '${(rec.distanceM / 1000).toStringAsFixed(2)} км'),
                      _stat('Время', rec.recording ? _fmt(elapsed) : '—'),
                      _stat(rec.autoPaused ? 'Пауза' : 'В движении',
                          rec.recording ? _fmt(Duration(seconds: rec.movingSeconds)) : '—'),
                      _stat(
                        rec.recording && rec.gpsEnabled && rec.sinceFixSec >= 20 ? 'Сигнал' : 'Точность',
                        !rec.recording
                            ? '—'
                            : (rec.gpsEnabled && rec.sinceFixSec >= 20
                                ? 'нет ${rec.sinceFixSec} с'
                                : '${rec.lastAccuracy.toStringAsFixed(0)} м'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _toggle,
                    icon: Icon(rec.recording ? Icons.stop : Icons.play_arrow),
                    label: Text(rec.recording ? 'Остановить' : 'Начать запись'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  ),
                  if (rec.recording) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _newNote,
                          icon: const Icon(Icons.edit_note),
                          label: const Text('Заметка'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MapPage(
                                sessionId: rec.sessionId,
                                live: true,
                                title: 'Живая карта',
                                mode: AppSettings.instance.travelMode,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.map),
                          label: const Text('Живая карта'),
                        ),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Прогулки', style: Theme.of(context).textTheme.titleMedium),
          if (sessions.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Пока пусто')),
          for (final s in sessions)
            Card(
              child: ListTile(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => RouteViewPage(
                            sessionId: s.id,
                            title: _date(s.startMs),
                            mode: TravelModeInfo.parse(s.mode),
                          )),
                ),
                title: Text(_date(s.startMs)),
                subtitle: Text(
                    '${TravelModeInfo.parse(s.mode).label} · точек: ${s.pointCount} · ${_status(s.status)}'),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    final mode = TravelModeInfo.parse(s.mode);
                    if (v == 'map') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MapPage(sessionId: s.id, title: _date(s.startMs), mode: mode),
                        ),
                      );
                    } else if (v == 'image') {
                      await _imageWithoutMap(s);
                    } else if (v == 'gpx') {
                      await _exportGpx(s.id);
                    } else if (v == 'delete' && s.status != 'active') {
                      await TrackDb.instance.deleteSession(s.id);
                      await _reload();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'map', child: Text('На карте')),
                    PopupMenuItem(value: 'image', child: Text('Картинка без карты')),
                    PopupMenuItem(value: 'gpx', child: Text('Файл GPX')),
                    PopupMenuItem(value: 'delete', child: Text('Удалить')),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
