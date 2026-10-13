import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'gpx.dart';
import 'modes.dart';
import 'l10n.dart';

/// One archive with everything: a JSON copy of all walks, notes and imported routes (for restoring)
/// plus a GPX file per walk (for opening in any other app). Photos and videos stay in the gallery.
class BackupResult {
  final File file;
  final int sessions;
  final int points;

  BackupResult(this.file, this.sessions, this.points);
}

class RestoreResult {
  final int sessions;
  final int skipped;
  final int notes;
  final int routes;

  RestoreResult(this.sessions, this.skipped, this.notes, this.routes);
}

String _stamp(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}';
}

Future<BackupResult> exportBackup() async {
  final db = TrackDb.instance;
  final sessions = await db.sessions(limit: 100000);
  final data = <String, Object?>{'format': 'tropa-backup', 'version': 1, 'exportedMs': DateTime.now().millisecondsSinceEpoch};
  final archive = Archive();
  var totalPoints = 0;

  final sessionList = <Map<String, Object?>>[];
  for (final s in sessions) {
    final pts = await db.points(s.id);
    final notes = await db.notes(s.id);
    final overrides = await db.segmentOverrides(s.id);
    totalPoints += pts.length;
    sessionList.add({
      'startMs': s.startMs,
      'endMs': s.endMs,
      'status': s.status == 'active' ? 'interrupted' : s.status,
      'mode': s.mode,
      // [ts, lat, lon, accuracy, altitude, speed, pressure]
      'points': [
        for (final t in pts) [t.tsMs, t.lat, t.lon, t.accuracy, t.altitude, t.speed, t.pressure],
      ],
      'segments': [
        for (final o in overrides) {'start': o.startMs, 'end': o.endMs, 'mode': o.mode.code},
      ],
      'notes': [
        for (final n in notes)
          {'ts': n.tsMs, 'lat': n.lat, 'lon': n.lon, 'text': n.text, 'type': n.mediaType, 'name': n.mediaName},
      ],
    });

    if (pts.length >= 2) {
      final gpx = await writeGpx(s.id, heal: false);
      final bytes = await gpx.readAsBytes();
      final started = DateTime.fromMillisecondsSinceEpoch(s.startMs);
      archive.addFile(ArchiveFile.bytes('gpx/${_stamp(started)}_${s.id}.gpx', bytes));
    }
  }
  data['sessions'] = sessionList;

  final routeList = <Map<String, Object?>>[];
  for (final r in await db.routes()) {
    final pts = await db.routePoints(r.id);
    routeList.add({
      'name': r.name,
      'points': [for (final t in pts) [t.lat, t.lon]],
    });
  }
  data['routes'] = routeList;

  archive.addFile(ArchiveFile.bytes('data.json', utf8.encode(jsonEncode(data))));
  final zip = ZipEncoder().encode(archive);

  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, 'tropa_backup_${_stamp(DateTime.now())}.zip'));
  await file.writeAsBytes(zip);
  return BackupResult(file, sessions.length, totalPoints);
}

/// Merges a backup into the current database. Walks that are already present (same start time)
/// are skipped, so restoring twice does not duplicate anything.
Future<RestoreResult> importBackup(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final entry = archive.findFile('data.json');
  if (entry == null) throw FormatException(t('Это не резервная копия Tropa: нет data.json'));
  final data = jsonDecode(utf8.decode(entry.content as List<int>)) as Map<String, dynamic>;
  if (data['format'] != 'tropa-backup') throw FormatException(t('Неизвестный формат файла'));

  final db = await TrackDb.instance.database;
  final existing = <int>{
    for (final s in await TrackDb.instance.sessions(limit: 100000)) s.startMs,
  };

  var added = 0, skipped = 0, noteCount = 0, routeCount = 0;
  for (final s in (data['sessions'] as List<dynamic>)) {
    final m = s as Map<String, dynamic>;
    final startMs = m['startMs'] as int;
    if (existing.contains(startMs)) {
      skipped++;
      continue;
    }
    await db.transaction((txn) async {
      final id = await txn.insert('sessions', {
        'start_ms': startMs,
        'end_ms': m['endMs'],
        'status': m['status'] ?? 'finished',
        'mode': m['mode'] ?? 'mixed',
      });
      final batch = txn.batch();
      for (final raw in (m['points'] as List<dynamic>)) {
        final t = raw as List<dynamic>;
        batch.insert('points', {
          'session_id': id,
          'ts_ms': t[0],
          'lat': t[1],
          'lon': t[2],
          'acc': t[3],
          'alt': t[4],
          'speed': t[5],
          if ((t[6] as num) > 0) 'pressure': t[6],
        });
      }
      for (final n in (m['notes'] as List<dynamic>? ?? const [])) {
        final nm = n as Map<String, dynamic>;
        batch.insert('notes', {
          'session_id': id,
          'ts_ms': nm['ts'],
          'lat': nm['lat'],
          'lon': nm['lon'],
          'text': nm['text'] ?? '',
          'media_type': nm['type'] ?? '',
          'media_name': nm['name'] ?? '',
        });
        noteCount++;
      }
      for (final o in (m['segments'] as List<dynamic>? ?? const [])) {
        final om = o as Map<String, dynamic>;
        batch.insert('segment_overrides',
            {'session_id': id, 'start_ms': om['start'], 'end_ms': om['end'], 'mode': om['mode']});
      }
      await batch.commit(noResult: true);
    });
    existing.add(startMs);
    added++;
  }

  final knownRoutes = {for (final r in await TrackDb.instance.routes()) '${r.name}|${r.pointCount}'};
  for (final r in (data['routes'] as List<dynamic>? ?? const [])) {
    final m = r as Map<String, dynamic>;
    final pts = [
      for (final t in (m['points'] as List<dynamic>)) (lat: (t[0] as num).toDouble(), lon: (t[1] as num).toDouble()),
    ];
    if (knownRoutes.contains('${m['name']}|${pts.length}')) continue;
    await TrackDb.instance.addRoute(m['name'] as String, pts);
    routeCount++;
  }
  return RestoreResult(added, skipped, noteCount, routeCount);
}
