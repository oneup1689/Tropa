import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class TrackPoint {
  final int tsMs;
  final double lat;
  final double lon;
  final double accuracy;
  final double altitude;
  final double speed;

  TrackPoint(this.tsMs, this.lat, this.lon, this.accuracy, this.altitude, this.speed);
}

class SessionInfo {
  final int id;
  final int startMs;
  final int? endMs;
  final String status; // active | finished | interrupted
  final int pointCount;

  SessionInfo(this.id, this.startMs, this.endMs, this.status, this.pointCount);
}

/// Every GPS fix is written to SQLite immediately, so a killed app loses
/// at most the fix that was in flight.
class TrackDb {
  TrackDb._();
  static final TrackDb instance = TrackDb._();

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'tropa.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE sessions('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, start_ms INTEGER NOT NULL, '
            'end_ms INTEGER, status TEXT NOT NULL)');
        await db.execute('CREATE TABLE points('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, '
            'ts_ms INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, '
            'acc REAL, alt REAL, speed REAL)');
        await db.execute('CREATE INDEX idx_points_session ON points(session_id, ts_ms)');
      },
    );
    return _db!;
  }

  Future<int> startSession() async {
    final db = await _database;
    return db.insert('sessions', {
      'start_ms': DateTime.now().millisecondsSinceEpoch,
      'status': 'active',
    });
  }

  Future<void> reopenSession(int id) async {
    final db = await _database;
    await db.update('sessions', {'status': 'active', 'end_ms': null}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> endSession(int id, String status) async {
    final db = await _database;
    await db.update(
      'sessions',
      {'status': status, 'end_ms': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> addPoint(int sessionId, TrackPoint pt) async {
    final db = await _database;
    await db.insert('points', {
      'session_id': sessionId,
      'ts_ms': pt.tsMs,
      'lat': pt.lat,
      'lon': pt.lon,
      'acc': pt.accuracy,
      'alt': pt.altitude,
      'speed': pt.speed,
    });
  }

  /// A session still marked "active" at app start means the app was killed.
  Future<SessionInfo?> activeSession() async {
    final db = await _database;
    final rows = await db.query('sessions', where: "status = 'active'", orderBy: 'id DESC', limit: 1);
    if (rows.isEmpty) return null;
    return _info(db, rows.first);
  }

  Future<List<SessionInfo>> sessions() async {
    final db = await _database;
    final rows = await db.query('sessions', orderBy: 'id DESC', limit: 50);
    return [for (final r in rows) await _info(db, r)];
  }

  Future<SessionInfo> _info(Database db, Map<String, Object?> r) async {
    final id = r['id'] as int;
    final c = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM points WHERE session_id = ?', [id]));
    return SessionInfo(id, r['start_ms'] as int, r['end_ms'] as int?, r['status'] as String, c ?? 0);
  }

  Future<List<TrackPoint>> points(int sessionId) async {
    final db = await _database;
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
        ),
    ];
  }

  Future<DateTime?> lastPointTime(int sessionId) async {
    final db = await _database;
    final v = Sqflite.firstIntValue(
        await db.rawQuery('SELECT MAX(ts_ms) FROM points WHERE session_id = ?', [sessionId]));
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<void> deleteSession(int id) async {
    final db = await _database;
    await db.delete('points', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }
}
