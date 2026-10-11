import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'heal.dart';
import 'settings.dart';

/// Gap in seconds after which a new track segment starts, so that the line
/// is never drawn straight across a stretch where GPS was lost.
const int gpxGapSeconds = 30;

/// Writes the session as GPX. With [heal], gaps classified as "glue" or "bridge"
/// stay inside one segment; all other gaps still start a new segment.
Future<File> writeGpx(
  int sessionId, {
  bool withTime = true,
  bool withElevation = true,
  bool heal = false,
}) async {
  final pts = await TrackDb.instance.points(sessionId);
  final result = analyzeGaps(pts, settings: AppSettings.instance.healSettings);
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="Tropa" xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('<trk><name>Tropa $sessionId</name>');
  if (heal && result.restoredMeters > 0) {
    b.writeln('<desc>Includes ${result.restoredMeters.round()} m of restored short gaps</desc>');
  }
  var open = false;
  for (var i = 0; i < pts.length; i++) {
    final pt = pts[i];
    var newSeg = i == 0;
    if (!newSeg && pt.tsMs - pts[i - 1].tsMs > gpxGapSeconds * 1000) {
      final kind = result.gapAt(i)?.kind;
      final joined = heal && (kind == GapKind.glueStill || kind == GapKind.bridge);
      newSeg = !joined;
    }
    if (newSeg) {
      if (open) b.writeln('</trkseg>');
      b.writeln('<trkseg>');
      open = true;
    }
    b.write('<trkpt lat="${pt.lat.toStringAsFixed(7)}" lon="${pt.lon.toStringAsFixed(7)}">');
    if (withElevation) b.write('<ele>${pt.altitude.toStringAsFixed(1)}</ele>');
    if (withTime) {
      b.write('<time>${DateTime.fromMillisecondsSinceEpoch(pt.tsMs, isUtc: true).toIso8601String()}</time>');
    }
    b.writeln('</trkpt>');
  }
  if (open) b.writeln('</trkseg>');
  b.writeln('</trk></gpx>');

  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, 'tropa_$sessionId.gpx'));
  return file.writeAsString(b.toString());
}
