import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'debug_log.dart';
import 'heal.dart' show LatLon;
import 'l10n.dart';
import 'modes.dart';
import 'recorder.dart';
import 'route_nav.dart';
import 'settings.dart';

/// Navigation along a saved route on top of the recording: it listens to the recorder, tells the engine where the
/// person is, and speaks / vibrates before turns. The walk itself is recorded as usual, so at the end the person
/// has a track of their own (named after the route).
class RouteNavigator extends ChangeNotifier {
  RouteNavigator._();
  static final RouteNavigator instance = RouteNavigator._();

  static const MethodChannel _sys = MethodChannel('tropa/system');
  final _log = DebugLog.instance;
  final Recorder _rec = Recorder.instance;

  NavEngine? _engine;
  NavState? state;
  String routeName = '';
  int? routeId;
  bool reverse = false;
  bool active = false;

  /// "ok" / "missing" (no voice for this language) / "none" (no speech engine) / null (unknown yet).
  String? voiceStatus;

  /// The person is farther from the route than allowed.
  bool offRoute = false;
  int _offCount = 0, _onCount = 0;
  int _countedPoints = -1; // number of stored points at the last counted position
  DateTime? _offSince; // when the current stretch away from the route began
  bool _titled = false;
  bool _listening = false;

  bool get voiceOn => AppSettings.instance.getBool('nav_voice');
  bool get vibrateOn => AppSettings.instance.getBool('nav_vibrate');

  /// The service waits for the person at the start of the route; navigation begins when the recording does.
  bool pending = false;
  bool _sawWait = false;

  /// Prepares navigation along [id] for a recording that starts later (the person is not at the start yet).
  Future<void> prepareWait(int id, String name, {bool reverseDir = false}) async {
    routeId = id;
    routeName = name;
    reverse = reverseDir;
    pending = true;
    _sawWait = false;
    if (!_listening) {
      _rec.addListener(_onRecorder);
      _listening = true;
    }
    await _save();
    _log.log('NAV', 'waiting for the start of route=$id reverse=$reverseDir');
    notifyListeners();
  }

  /// Gives up waiting (the service was stopped, or the person cancelled).
  Future<void> cancelPending() async {
    if (!pending) return;
    pending = false;
    if (!active && _listening) {
      _rec.removeListener(_onRecorder);
      _listening = false;
    }
    await _deleteFile();
    _log.log('NAV', 'waiting cancelled');
    notifyListeners();
  }

  /// The person joins the route somewhere else than at its start.
  void skipApproach() {
    _engine?.skipApproach();
    _save();
    notifyListeners();
  }

  /// Prepares navigation along [id]. The recording is started by the caller (with the same route id).
  /// With [approach] the route counts from its start: until the person gets there the screen leads them to it.
  Future<bool> begin(int id, String name, {bool reverseDir = false, bool approach = false}) async {
    final rows = await TrackDb.instance.routePoints(id);
    if (rows.length < 2) return false;
    reverse = reverseDir;
    routeId = id;
    routeName = name;
    pending = false;
    final bike = _rec.activeMode == TravelMode.bike || _rec.activeMode == TravelMode.car;
    _engine = NavEngine(
      RoutePath.build([for (final r in rows) LatLon(r.lat, r.lon)], reverse: reverseDir),
      farM: bike ? 150 : 100,
      nearM: bike ? 50 : 30,
      approach: approach,
    );
    state = null;
    offRoute = false;
    _offCount = _onCount = 0;
    _countedPoints = -1;
    _offSince = null;
    _titled = false;
    active = true;
    if (!_listening) {
      _rec.addListener(_onRecorder);
      _listening = true;
    }
    await _save();
    await _keepScreen(true);
    await checkVoice();
    _log.log('NAV', 'begin route=$id "$name" reverse=$reverseDir turns=${_engine!.path.maneuvers.length} len=${_engine!.path.lengthM.round()}');
    notifyListeners();
    return true;
  }

  /// After the app was restarted in the middle of a walk along a route.
  Future<void> restore() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final id = (m['id'] as num).toInt(), name = (m['name'] as String?) ?? '';
      if (m['pending'] == true) {
        if (_rec.waiting) {
          await prepareWait(id, name, reverseDir: m['reverse'] == true);
        } else if (_rec.recording) {
          await begin(id, name, reverseDir: m['reverse'] == true);
        } else {
          await f.delete();
        }
        return;
      }
      if (!_rec.recording) {
        await f.delete();
        return;
      }
      await begin(id, name, reverseDir: m['reverse'] == true, approach: m['approach'] == true);
    } catch (e) {
      _log.log('NAV', 'restore failed: $e');
    }
  }

  Future<File> _file() async => File(p.join((await getApplicationDocumentsDirectory()).path, 'nav_state.json'));

  Future<void> _save() async {
    try {
      await (await _file()).writeAsString(jsonEncode({
        'id': routeId,
        'name': routeName,
        'reverse': reverse,
        'pending': pending,
        'approach': _engine?.approaching ?? false,
      }));
    } catch (e) {
      _log.log('NAV', 'save failed: $e');
    }
  }

  Future<void> _deleteFile() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (e) {
      _log.log('NAV', 'state file delete failed: $e');
    }
  }

  Future<void> end() async {
    if (!active) return;
    active = false;
    _engine = null;
    state = null;
    offRoute = false;
    if (_listening) {
      _rec.removeListener(_onRecorder);
      _listening = false;
    }
    await _deleteFile();
    await _keepScreen(false);
    if (Platform.isAndroid) _sys.invokeMethod<void>('stopSpeak').catchError((Object _) {});
    _log.log('NAV', 'end');
    notifyListeners();
  }

  Future<void> _keepScreen(bool on) async {
    if (!Platform.isAndroid) return;
    final keep = on && AppSettings.instance.getBool('nav_keep_screen');
    try {
      await _sys.invokeMethod<void>('keepScreenOn', {'on': keep});
    } catch (e) {
      _log.log('NAV', 'keepScreenOn failed: $e');
    }
  }

  Future<void> checkVoice() async {
    if (!Platform.isAndroid) return;
    try {
      voiceStatus = await _sys.invokeMethod<String>('ttsStatus', {'lang': L10n.code});
    } catch (e) {
      voiceStatus = 'none';
    }
  }

  Future<void> installVoice() async {
    if (Platform.isAndroid) await _sys.invokeMethod<void>('ttsInstall');
  }

  // ------------------------------------------------------------------ progress

  void _onRecorder() {
    if (pending) {
      // Waiting at a distance: the service starts the recording when the person reaches the start.
      if (_rec.recording) {
        pending = false;
        begin(routeId!, routeName, reverseDir: reverse);
      } else if (_rec.waiting) {
        _sawWait = true;
      } else if (_sawWait) {
        cancelPending();
      }
      return;
    }
    final eng = _engine;
    if (!active || eng == null) return;
    if (!_rec.recording) {
      // The walk was stopped (button, or the system): navigation ends with it.
      end();
      return;
    }
    if (!_titled && _rec.sessionId != null) {
      _titled = true;
      TrackDb.instance.setSessionMeta(_rec.sessionId!, {'title': routeName, 'route_id': routeId}).catchError((Object e) {
        _log.log('NAV', 'title failed: $e');
      });
    }
    if (_rec.lastLat == 0 && _rec.lastLon == 0) return;
    final s = eng.update(_rec.lastLat, _rec.lastLon, accuracy: _rec.lastAccuracy > 0 ? _rec.lastAccuracy : 10);
    state = s;

    if (s.justReachedStart) {
      _save();
      _say(t('Вы у старта маршрута'), const [0, 300], tone: 'start');
    }
    if (s.toStartM != null) {
      // Still on the way to the start: "off route" does not apply yet.
      notifyListeners();
      return;
    }

    // "Off route" / "back on route" with hysteresis, spoken once per change.
    // The recorder notifies about once a second whatever happens, but a position is new only when a point was stored:
    // count positions, not notifications (the same rule as the native guard: 3 positions over at least 15 s).
    final limit = math.max(AppSettings.instance.offRouteMeters, 2 * _rec.lastAccuracy);
    if (_rec.pointCount != _countedPoints) {
      _countedPoints = _rec.pointCount;
      if (s.offM > limit) {
        if (_offCount == 0) _offSince = DateTime.now();
        _offCount++;
        _onCount = 0;
      } else if (s.offM < 25) {
        _onCount++;
        _offCount = 0;
      }
    }
    final offLongEnough = _offSince != null && DateTime.now().difference(_offSince!).inSeconds >= 15;
    if (!offRoute && _offCount >= 3 && offLongEnough) {
      offRoute = true;
      _say(t('Вы сошли с маршрута'), const [0, 400, 200, 400]);
    } else if (offRoute && _onCount >= 3) {
      offRoute = false;
      _say(t('Вы снова на маршруте'), const [0, 150]);
    }

    final a = s.alert;
    if (a != null && !offRoute) {
      final left = a.maneuver.turn.isLeft;
      final pattern = a.maneuver.turn == Turn.uTurn ? const [0, 300, 120, 300, 120, 300] : (left ? const [0, 250] : const [0, 200, 150, 200]);
      _say(promptText(a.maneuver.turn, a.distM), pattern, tone: left ? 'turn_left' : 'turn_right');
    }
    if (s.justArrived) _say(t('Вы пришли в конечную точку маршрута'), const [0, 500]);
    notifyListeners();
  }

  /// [tone] is the short Tropa sound played before the words (the native service plays "off route" and "back" itself).
  void _say(String text, List<int> pattern, {String? tone}) {
    if (!Platform.isAndroid) return;
    if (tone != null) _sys.invokeMethod<void>('playSound', {'name': tone}).catchError((Object _) {});
    if (voiceOn && voiceStatus == 'ok') {
      _sys.invokeMethod<void>('speak', {'text': text, 'lang': L10n.code}).catchError((Object _) {});
    }
    if (vibrateOn) _sys.invokeMethod<void>('vibratePattern', {'pattern': pattern}).catchError((Object _) {});
    _log.log('NAV', 'say "$text"');
  }

  // ------------------------------------------------------------------ texts

  static String turnWord(Turn turn) => switch (turn) {
        Turn.slightLeft => t('держитесь левее'),
        Turn.left => t('налево'),
        Turn.sharpLeft => t('резко налево'),
        Turn.slightRight => t('держитесь правее'),
        Turn.right => t('направо'),
        Turn.sharpRight => t('резко направо'),
        Turn.uTurn => t('развернитесь'),
      };

  /// "In 100 metres, turn left" — the distance is rounded to 10 m.
  static String promptText(Turn turn, double distM) {
    final d = ((distM / 10).round() * 10).clamp(10, 1000);
    return t('Через {d} метров {turn}', {'d': d, 'turn': turnWord(turn)});
  }
}
