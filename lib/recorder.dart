import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import 'db.dart';
import 'debug_log.dart';

/// Recording facade.
///
/// Android: the native [TrackingService] (Kotlin) records and writes points to
/// SQLite on its own, so the UI can be closed or swiped away. This class only
/// starts/stops it and polls its status.
/// iOS: records in Dart through the geolocator plugin (background location mode).
class Recorder extends ChangeNotifier with WidgetsBindingObserver {
  Recorder._();
  static final Recorder instance = Recorder._();

  static const MethodChannel _sys = MethodChannel('tropa/system');
  static const double _maxAccuracyM = 50; // iOS path only
  static const Duration _heartbeat = Duration(seconds: 30);
  static const Duration _watchdog = Duration(seconds: 90);

  final _log = DebugLog.instance;
  final _battery = Battery();

  bool recording = false;
  int? sessionId;
  DateTime? startedAt;
  int pointCount = 0;
  double distanceM = 0;
  double lastAccuracy = 0;

  /// Seconds since the last GPS fix, and whether the system location service is on.
  int sinceFixSec = 0;
  bool gpsEnabled = true;

  /// Set at startup when the previous run ended without "stop" and nothing is recording now.
  SessionInfo? interrupted;

  String? _lastModes;

  // iOS-only state
  StreamSubscription<Position>? _sub;
  Timer? _timer;
  DateTime? _lastFix;
  Position? _lastStored;

  // ---------------------------------------------------------------- init

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    _watchModes();
    if (Platform.isAndroid) {
      await _refresh();
      Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    }
    if (!recording) {
      final prev = await TrackDb.instance.activeSession();
      if (prev != null) {
        final last = await TrackDb.instance.lastPointTime(prev.id);
        _log.log('RECOVERY',
            'previous session ${prev.id} was NOT stopped properly (app killed?). points=${prev.pointCount} lastPoint=$last');
        await TrackDb.instance.endSession(prev.id, 'interrupted');
        interrupted = prev;
      }
    } else {
      _log.log('RECOVERY', 'native service is already recording session=$sessionId, UI attached');
    }
    await _logEnvironment();
  }

  Future<void> _refresh() async {
    try {
      final m = await _sys.invokeMapMethod<String, dynamic>('trackingStatus');
      if (m == null) return;
      final running = m['running'] == true;
      final id = (m['session'] as num?)?.toInt();
      final pts = (m['points'] as num?)?.toInt() ?? 0;
      final dist = (m['distance'] as num?)?.toDouble() ?? 0;
      final acc = (m['accuracy'] as num?)?.toDouble() ?? 0;
      final start = (m['startMs'] as num?)?.toInt();
      final since = (m['sinceFix'] as num?)?.toInt() ?? 0;
      final changed = running != recording ||
          (since >= 20) != (sinceFixSec >= 20) ||
          pts != pointCount ||
          (dist - distanceM).abs() > 0.5 ||
          acc != lastAccuracy;
      recording = running;
      sessionId = running ? id : null;
      pointCount = pts;
      distanceM = dist;
      lastAccuracy = acc;
      sinceFixSec = since;
      startedAt = running && start != null && start > 0 ? DateTime.fromMillisecondsSinceEpoch(start) : null;
      if (running) interrupted = null;
      if (changed) notifyListeners();
    } catch (e) {
      _log.log('RECORDER', 'status poll failed: $e');
    }
  }

  // ---------------------------------------------------------------- diagnostics

  /// Android system modes that explain interruptions: airplane, power saver, Doze, screen.
  Future<String> _modes() async {
    if (!Platform.isAndroid) return 'modes=n/a';
    try {
      final m = await _sys.invokeMapMethod<String, dynamic>('state');
      return 'airplane=${m?['airplane']} powerSave=${m?['powerSave']} doze=${m?['doze']} '
          'screenOn=${m?['interactive']} battOptIgnored=${m?['ignoringBatteryOpt']}';
    } catch (e) {
      return 'modes=error($e)';
    }
  }

  /// User note written into the log (e.g. "turned on airplane mode").
  void mark(String note) => _log.log('MARK', note);

  void _watchModes() {
    Timer.periodic(const Duration(seconds: 5), (_) async {
      final now = '${await _modes()} ${await _saverInfo()}';
      if (now != _lastModes) {
        _log.log('MODE', now);
        _lastModes = now;
      }
    });
    Geolocator.isLocationServiceEnabled().then((v) {
      gpsEnabled = v;
      notifyListeners();
    });
    Geolocator.getServiceStatusStream().listen(
      (s) {
        _log.log('GPS_SERVICE', s == ServiceStatus.enabled ? 'GPS ON' : 'GPS OFF');
        gpsEnabled = s == ServiceStatus.enabled;
        notifyListeners();
      },
      onError: (Object e) => _log.log('GPS_SERVICE', 'status stream error: $e'),
    );
  }

  Future<String> _saverInfo() async {
    try {
      return 'batterySaver=${await _battery.isInBatterySaveMode}';
    } catch (_) {
      return 'batterySaver=unknown';
    }
  }

  Future<void> _logEnvironment() async {
    try {
      final perm = await Geolocator.checkPermission();
      final svc = await Geolocator.isLocationServiceEnabled();
      _log.log('ENV', 'locationPermission=$perm locationService=$svc ${await _batteryInfo()}');
    } catch (e) {
      _log.log('ENV', 'failed to read environment: $e');
    }
  }

  Future<String> _batteryInfo() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final saver = await _battery.isInBatterySaveMode;
      return 'battery=$level% state=$state saver=$saver';
    } catch (e) {
      return 'battery=unknown($e)';
    }
  }

  // ---------------------------------------------------------------- start / stop

  Future<bool> start({int? resumeSessionId}) async {
    if (recording) return true;
    if (!await Geolocator.isLocationServiceEnabled()) {
      _log.log('START', 'refused: location service disabled');
      return false;
    }
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _log.log('START', 'refused: permission=$perm');
      return false;
    }
    interrupted = null;
    _log.log('START', 'UI requested start resume=${resumeSessionId != null} perm=$perm ${await _batteryInfo()}');

    if (Platform.isAndroid) {
      await _sys.invokeMethod('startTracking', {'session': resumeSessionId ?? 0});
      // Give the service a moment to publish its state.
      for (var i = 0; i < 10 && !recording; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await _refresh();
      }
      return recording;
    }
    return _startDart(resumeSessionId);
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      _log.log('STOP', 'UI requested stop');
      await _sys.invokeMethod('stopTracking');
      for (var i = 0; i < 10 && recording; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await _refresh();
      }
      return;
    }
    await _stopDart();
  }

  // ---------------------------------------------------------------- iOS (Dart) path

  Future<bool> _startDart(int? resumeSessionId) async {
    if (resumeSessionId != null) {
      sessionId = resumeSessionId;
      await TrackDb.instance.reopenSession(resumeSessionId);
      final pts = await TrackDb.instance.points(resumeSessionId);
      pointCount = pts.length;
      distanceM = _distanceOf(pts);
    } else {
      sessionId = await TrackDb.instance.startSession();
      pointCount = 0;
      distanceM = 0;
    }
    _lastStored = null;
    startedAt = DateTime.now();
    _lastFix = DateTime.now();
    recording = true;
    _sub?.cancel();
    _sub = Geolocator.getPositionStream(
      locationSettings: AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.fitness,
        distanceFilter: 3,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      ),
    ).listen(
      _onPosition,
      onError: (Object e, StackTrace s) => _log.log('STREAM', 'ERROR: $e'),
      onDone: () => _log.log('STREAM', 'stream closed by system (onDone)'),
    );
    _timer?.cancel();
    _timer = Timer.periodic(_heartbeat, (_) => _tick());
    notifyListeners();
    return true;
  }

  Future<void> _onPosition(Position p) async {
    _lastFix = DateTime.now();
    lastAccuracy = p.accuracy;
    final ok = p.accuracy <= _maxAccuracyM && !p.isMocked;
    _log.log('FIX',
        '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)} acc=${p.accuracy.toStringAsFixed(1)} ${ok ? 'stored' : 'SKIPPED'}');
    if (!ok || sessionId == null) {
      notifyListeners();
      return;
    }
    if (_lastStored != null) {
      distanceM += Geolocator.distanceBetween(
          _lastStored!.latitude, _lastStored!.longitude, p.latitude, p.longitude);
    }
    _lastStored = p;
    pointCount++;
    await TrackDb.instance.addPoint(
      sessionId!,
      TrackPoint(p.timestamp.millisecondsSinceEpoch, p.latitude, p.longitude, p.accuracy, p.altitude, p.speed),
    );
    notifyListeners();
  }

  Future<void> _tick() async {
    final since = _lastFix == null ? -1 : DateTime.now().difference(_lastFix!).inSeconds;
    _log.log('BEAT', 'ios points=$pointCount dist=${distanceM.toStringAsFixed(0)}m sinceLastFix=${since}s ${await _batteryInfo()}');
    if (_lastFix != null && DateTime.now().difference(_lastFix!) > _watchdog) {
      _log.log('WATCHDOG', 'no fixes for >${_watchdog.inSeconds}s');
      _lastFix = DateTime.now();
    }
  }

  Future<void> _stopDart() async {
    final id = sessionId;
    if (id == null) return;
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    await TrackDb.instance.endSession(id, 'finished');
    _log.log('STOP', 'session=$id points=$pointCount dist=${distanceM.toStringAsFixed(0)}m');
    sessionId = null;
    recording = false;
    notifyListeners();
  }

  double _distanceOf(List<TrackPoint> pts) {
    double d = 0;
    for (var i = 1; i < pts.length; i++) {
      if (pts[i].tsMs - pts[i - 1].tsMs > 30000) continue; // do not bridge gaps
      d += Geolocator.distanceBetween(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    }
    return d;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log.log('LIFECYCLE', '$state recording=$recording');
  }
}
