import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'modes.dart';
import 'segments.dart';

class TrackPoint {
  final int tsMs;
  final double lat;
  final double lon;
  final double accuracy;
  final double altitude; // raw GPS altitude (WGS84 ellipsoid on most phones)
  final double speed;
  final double pressure; // hPa from the barometer, 0 when unavailable

  TrackPoint(this.tsMs, this.lat, this.lon, this.accuracy, this.altitude, this.speed, {this.pressure = 0});
}

class SessionInfo {
  final int id;
  final int startMs;
  final int? endMs;
  final String status; // active | finished | interrupted
  final int pointCount;
  final String mode; // TravelMode.code

  /// The name the person gave to the walk, empty when none.
  final String title;

  SessionInfo(this.id, this.startMs, this.endMs, this.status, this.pointCount, [this.mode = 'mixed', this.title = '']);
}

/// A note attached to a place and time of a walk. Photos and videos live in the phone gallery;
/// only their names are stored here.
class TrackNote {
  final int id;
  final int sessionId;
  final int tsMs;
  final double lat;
  final double lon;
  final String text;
  final String mediaType; // '', 'photo' or 'video'
  final String mediaName;

  TrackNote(this.id, this.sessionId, this.tsMs, this.lat, this.lon, this.text, this.mediaType, this.mediaName);
}

class RouteInfo {
  final int id;
  final String name;
  final int pointCount;
  final double lengthM;

  RouteInfo(this.id, this.name, this.pointCount, this.lengthM);
}

/// Every GPS fix is written to SQLite immediately, so a killed app loses
/// at most the fix that was in flight. The native service writes points; this class reads
/// them and owns everything else (notes, imported routes).
class TrackDb {
  TrackDb._();
  static final TrackDb instance = TrackDb._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'tropa.db'),
      version: 7,
      onUpgrade: (db, oldVersion, _) async {
        // The native service may already have added some columns; ignore duplicates.
        if (oldVersion < 2) {
          try {
            await db.execute("ALTER TABLE sessions ADD COLUMN mode TEXT NOT NULL DEFAULT 'mixed'");
          } catch (_) {}
        }
        if (oldVersion < 3) {
          try {
            await db.execute('ALTER TABLE points ADD COLUMN pressure REAL');
          } catch (_) {}
          await _createExtraTables(db);
        }
        if (oldVersion < 5) await _createExtraTables(db);
        if (oldVersion < 6) {
          try {
            await db.execute('ALTER TABLE session_meta ADD COLUMN elevation TEXT');
          } catch (_) {}
        }
        if (oldVersion < 7) {
          try {
            await db.execute('ALTER TABLE session_meta ADD COLUMN title TEXT');
          } catch (_) {}
        }
      },
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE IF NOT EXISTS sessions('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, start_ms INTEGER NOT NULL, '
            "end_ms INTEGER, status TEXT NOT NULL, mode TEXT NOT NULL DEFAULT 'mixed')");
        await db.execute('CREATE TABLE IF NOT EXISTS points('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, '
            'ts_ms INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, '
            'acc REAL, alt REAL, speed REAL, pressure REAL)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_points_session ON points(session_id, ts_ms)');
        await _createExtraTables(db);
      },
    );
    return _db!;
  }

  Future<void> _createExtraTables(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS notes('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL, '
        "lat REAL NOT NULL, lon REAL NOT NULL, text TEXT NOT NULL DEFAULT '', "
        "media_type TEXT NOT NULL DEFAULT '', media_name TEXT NOT NULL DEFAULT '')");
    await db.execute('CREATE TABLE IF NOT EXISTS segment_overrides('
        'session_id INTEGER NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, mode TEXT NOT NULL)');
    // Poster data fetched from the internet once and kept: place name, weather (JSON), manual water temperature.
    await db.execute('CREATE TABLE IF NOT EXISTS session_meta('
        'session_id INTEGER PRIMARY KEY, region TEXT, weather TEXT, water_temp REAL, elevation TEXT, title TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS routes('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_ms INTEGER NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS route_points('
        'route_id INTEGER NOT NULL, idx INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, '
        'PRIMARY KEY (route_id, idx))');
  }

  Future<int> startSession({String mode = 'mixed'}) async {
    final db = await database;
    return db.insert('sessions', {
      'start_ms': DateTime.now().millisecondsSinceEpoch,
      'status': 'active',
      'mode': mode,
    });
  }

  Future<String> sessionMode(int id) async {
    final db = await database;
    final rows = await db.query('sessions', columns: ['mode'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? 'mixed' : (rows.first['mode'] as String? ?? 'mixed');
  }

  Future<void> reopenSession(int id) async {
    final db = await database;
    await db.update('sessions', {'status': 'active', 'end_ms': null}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> endSession(int id, String status) async {
    final db = await database;
    await db.update(
      'sessions',
      {'status': status, 'end_ms': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> addPoint(int sessionId, TrackPoint pt) async {
    final db = await database;
    await db.insert('points', {
      'session_id': sessionId,
      'ts_ms': pt.tsMs,
      'lat': pt.lat,
      'lon': pt.lon,
      'acc': pt.accuracy,
      'alt': pt.altitude,
      'speed': pt.speed,
      if (pt.pressure > 0) 'pressure': pt.pressure,
    });
  }

  /// A session still marked "active" at app start means the app was killed.
  Future<SessionInfo?> activeSession() async {
    final db = await database;
    final rows = await db.query('sessions', where: "status = 'active'", orderBy: 'id DESC', limit: 1);
    if (rows.isEmpty) return null;
    return _info(db, rows.first);
  }

  Future<List<SessionInfo>> sessions({int limit = 50}) async {
    final db = await database;
    final rows = await db.query('sessions', orderBy: 'id DESC', limit: limit);
    return [for (final r in rows) await _info(db, r)];
  }

  Future<SessionInfo> _info(Database db, Map<String, Object?> r) async {
    final id = r['id'] as int;
    final c = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM points WHERE session_id = ?', [id]));
    final meta = await db.query('session_meta', columns: ['title'], where: 'session_id = ?', whereArgs: [id]);
    final title = meta.isEmpty ? '' : ((meta.first['title'] as String?) ?? '');
    return SessionInfo(
        id, r['start_ms'] as int, r['end_ms'] as int?, r['status'] as String, c ?? 0, (r['mode'] as String?) ?? 'mixed',
        title);
  }

  /// Changes the travel mode of a finished walk (the segments are then built for the new mode).
  Future<void> setSessionMode(int id, String mode) async {
    final db = await database;
    await db.update('sessions', {'mode': mode}, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<TrackPoint>> points(int sessionId) async {
    final db = await database;
    final rows = await db.query('points', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'ts_ms');
    return [
      for (final r in rows)
        TrackPoint(
          r['ts_ms'] as int,
          r['lat'] as double,
          r['lon'] as double,
          (r['acc'] as num?)?.toDouble() ?? 0,
          (r['alt'] as num?)?.toDouble() ?? 0,
          (r['speed'] as num?)?.toDouble() ?? 0,
          pressure: (r['pressure'] as num?)?.toDouble() ?? 0,
        ),
    ];
  }

  Future<DateTime?> lastPointTime(int sessionId) async {
    final db = await database;
    final v = Sqflite.firstIntValue(
        await db.rawQuery('SELECT MAX(ts_ms) FROM points WHERE session_id = ?', [sessionId]));
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<void> deleteSession(int id) async {
    final db = await database;
    await db.delete('points', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('notes', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('segment_overrides', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('session_meta', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------- notes

  Future<int> addNote({
    required int sessionId,
    required int tsMs,
    required double lat,
    required double lon,
    String text = '',
    String mediaType = '',
    String mediaName = '',
  }) async {
    final db = await database;
    return db.insert('notes', {
      'session_id': sessionId,
      'ts_ms': tsMs,
      'lat': lat,
      'lon': lon,
      'text': text,
      'media_type': mediaType,
      'media_name': mediaName,
    });
  }

  Future<List<TrackNote>> notes(int sessionId) async {
    final db = await database;
    final rows = await db.query('notes', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'ts_ms');
    return [
      for (final r in rows)
        TrackNote(
          r['id'] as int,
          r['session_id'] as int,
          r['ts_ms'] as int,
          (r['lat'] as num).toDouble(),
          (r['lon'] as num).toDouble(),
          (r['text'] as String?) ?? '',
          (r['media_type'] as String?) ?? '',
          (r['media_name'] as String?) ?? '',
        ),
    ];
  }

  Future<void> updateNoteText(int id, String text) async {
    final db = await database;
    await db.update('notes', {'text': text}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateNoteMedia(int id, String type, String name) async {
    final db = await database;
    await db.update('notes', {'media_type': type, 'media_name': name}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteNote(int id) async {
    final db = await database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------- poster metadata

  Future<Map<String, Object?>> sessionMeta(int sessionId) async {
    final db = await database;
    final rows = await db.query('session_meta', where: 'session_id = ?', whereArgs: [sessionId]);
    return rows.isEmpty ? <String, Object?>{} : Map<String, Object?>.of(rows.first);
  }

  /// Updates the given columns (region, weather, water_temp) and keeps the others.
  Future<void> setSessionMeta(int sessionId, Map<String, Object?> values) async {
    final db = await database;
    final existing = await db.query('session_meta', where: 'session_id = ?', whereArgs: [sessionId]);
    if (existing.isEmpty) {
      await db.insert('session_meta', {'session_id': sessionId, ...values});
    } else {
      await db.update('session_meta', values, where: 'session_id = ?', whereArgs: [sessionId]);
    }
  }

  // ---------------------------------------------------------------- manual mode corrections

  Future<List<SegmentOverride>> segmentOverrides(int sessionId) async {
    final db = await database;
    final rows = await db.query('segment_overrides', where: 'session_id = ?', whereArgs: [sessionId]);
    return [
      for (final r in rows)
        SegmentOverride(r['start_ms'] as int, r['end_ms'] as int, TravelModeInfo.parse(r['mode'] as String?)),
    ];
  }

  /// Stores a correction; older corrections that overlap the same time range are replaced.
  Future<void> setSegmentOverride(int sessionId, int startMs, int endMs, TravelMode mode) async {
    final db = await database;
    await db.delete('segment_overrides',
        where: 'session_id = ? AND start_ms < ? AND end_ms > ?', whereArgs: [sessionId, endMs, startMs]);
    await db.insert('segment_overrides',
        {'session_id': sessionId, 'start_ms': startMs, 'end_ms': endMs, 'mode': mode.code});
  }

  // ---------------------------------------------------------------- imported routes

  Future<int> addRoute(String name, List<({double lat, double lon})> pts) async {
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert('routes', {'name': name, 'created_ms': DateTime.now().millisecondsSinceEpoch});
      final batch = txn.batch();
      for (var i = 0; i < pts.length; i++) {
        batch.insert('route_points', {'route_id': id, 'idx': i, 'lat': pts[i].lat, 'lon': pts[i].lon});
      }
      await batch.commit(noResult: true);
      return id;
    });
  }

  Future<List<RouteInfo>> routes() async {
    final db = await database;
    final rows = await db.query('routes', orderBy: 'id DESC');
    final out = <RouteInfo>[];
    for (final r in rows) {
      final id = r['id'] as int;
      final pts = await routePoints(id);
      var len = 0.0;
      for (var i = 1; i < pts.length; i++) {
        len += _hav(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
      }
      out.add(RouteInfo(id, r['name'] as String, pts.length, len));
    }
    return out;
  }

  Future<List<({double lat, double lon})>> routePoints(int routeId) async {
    final db = await database;
    final rows = await db.query('route_points', where: 'route_id = ?', whereArgs: [routeId], orderBy: 'idx');
    return [for (final r in rows) (lat: (r['lat'] as num).toDouble(), lon: (r['lon'] as num).toDouble())];
  }

  Future<void> renameRoute(int id, String name) async {
    final db = await database;
    await db.update('routes', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteRoute(int id) async {
    final db = await database;
    await db.delete('route_points', where: 'route_id = ?', whereArgs: [id]);
    await db.delete('routes', where: 'id = ?', whereArgs: [id]);
  }
}

double _hav(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dp = rad(lat2 - lat1), dl = rad(lon2 - lon1);
  final a = math.pow(math.sin(dp / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}
