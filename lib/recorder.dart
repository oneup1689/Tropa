import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import 'db.dart';
import 'debug_log.dart';

/// Records GPS fixes in the background and keeps a detailed debug trail.
class Recorder extends ChangeNotifier with WidgetsBindingObserver {
  Recorder._();
  static final Recorder instance = Recorder._();

  static const double _maxAccuracyM = 50; // fixes worse than this are logged but not stored
  static const Duration _heartbeat = Duration(seconds: 30);
  static const Duration _watchdog = Duration(seconds: 90);

  final _log = DebugLog.instance;
  final _battery = Battery();

  StreamSubscription<Position>? _sub;
  Timer? _timer;
  int? sessionId;
  DateTime? startedAt;
  DateTime? _lastFix;
  Position? _lastStored;
  int pointCount = 0;
  double distanceM = 0;
  double lastAccuracy = 0;
  bool get recording => sessionId != null && _sub != null;

  /// Set at startup when the previous run ended without "stop" (killed by the system).
  SessionInfo? interrupted;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    final prev = await TrackDb.instance.activeSession();
    if (prev != null) {
      final last = await TrackDb.instance.lastPointTime(prev.id);
      _log.log('RECOVERY',
          'previous session ${prev.id} was NOT stopped properly (app killed?). points=${prev.pointCount} lastPoint=$last');
      await TrackDb.instance.endSession(prev.id, 'interrupted');
      interrupted = prev;
    }
    await _logEnvironment();
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

    if (resumeSessionId != null) {
      sessionId = resumeSessionId;
      await TrackDb.instance.reopenSession(resumeSessionId);
      final pts = await TrackDb.instance.points(resumeSessionId);
      pointCount = pts.length;
      distanceM = _distanceOf(pts);
      _lastStored = null;
    } else {
      sessionId = await TrackDb.instance.startSession();
      pointCount = 0;
      distanceM = 0;
      _lastStored = null;
    }
    startedAt = DateTime.now();
    _lastFix = DateTime.now();
    interrupted = null;
    _log.log('START', 'session=$sessionId resume=${resumeSessionId != null} perm=$perm ${await _batteryInfo()}');

    _subscribe();
    _timer?.cancel();
    _timer = Timer.periodic(_heartbeat, (_) => _tick());
    notifyListeners();
    return true;
  }

  void _subscribe() {
    _sub?.cancel();
    final LocationSettings settings;
    if (Platform.isAndroid) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Tropa записывает маршрут',
          notificationText: 'GPS работает в фоне',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    } else {
      settings = AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.fitness,
        distanceFilter: 3,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object e, StackTrace s) => _log.log('STREAM', 'ERROR: $e'),
      onDone: () => _log.log('STREAM', 'stream closed by system (onDone)'),
    );
    _log.log('STREAM', 'subscribed');
  }

  Future<void> _onPosition(Position p) async {
    final now = DateTime.now();
    final gap = _lastFix == null ? 0 : now.difference(_lastFix!).inSeconds;
    _lastFix = now;
    lastAccuracy = p.accuracy;

    if (gap >= 20) _log.log('GAP', 'no fixes for ${gap}s before this one');

    final stored = p.accuracy <= _maxAccuracyM && !p.isMocked;
    _log.log(
      'FIX',
      '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)} '
      'acc=${p.accuracy.toStringAsFixed(1)} alt=${p.altitude.toStringAsFixed(1)} '
      'spd=${p.speed.toStringAsFixed(2)} mock=${p.isMocked} ${stored ? 'stored' : 'SKIPPED'}',
    );
    if (!stored || sessionId == null) {
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
    _log.log('BEAT', 'points=$pointCount dist=${distanceM.toStringAsFixed(0)}m sinceLastFix=${since}s ${await _batteryInfo()}');
    // Watchdog: GPS silently stopped delivering fixes — try to resubscribe.
    if (_lastFix != null && DateTime.now().difference(_lastFix!) > _watchdog) {
      _log.log('WATCHDOG', 'no fixes for >${_watchdog.inSeconds}s, resubscribing');
      _lastFix = DateTime.now();
      _subscribe();
    }
  }

  Future<void> stop() async {
    final id = sessionId;
    if (id == null) return;
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    await TrackDb.instance.endSession(id, 'finished');
    _log.log('STOP', 'session=$id points=$pointCount dist=${distanceM.toStringAsFixed(0)}m ${await _batteryInfo()}');
    sessionId = null;
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
