import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'heal.dart';
import 'settings.dart';
import 'trim.dart';

/// Gap in seconds after which a new track segment starts, so that the line
/// is never drawn straight across a stretch where GPS was lost.
const int gpxGapSeconds = 30;

/// Writes the session as GPX.
///
/// With [heal], gaps classified as "glue" or "bridge" stay inside one segment and
/// bridge gaps get the smooth continuation points; all other gaps still start a
/// new segment. [trimStartM] / [trimEndM] cut the ends of the track (privacy).
Future<File> writeGpx(
  int sessionId, {
  bool withTime = true,
  bool withElevation = true,
  bool heal = false,
  double trimStartM = 0,
  double trimEndM = 0,
}) async {
  final all = await TrackDb.instance.points(sessionId);
  final pts = trimEnds(all, trimStartM, trimEndM);
  final result = analyzeGaps(pts, settings: AppSettings.instance.healSettings);
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="Tropa" xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('<trk><name>Tropa $sessionId</name>');
  if (heal && result.restoredMeters > 0) {
    b.writeln('<desc>Includes ${result.restoredMeters.round()} m of restored short gaps</desc>');
  }

  void writePoint(double lat, double lon, double ele, int tsMs) {
    b.write('<trkpt lat="${lat.toStringAsFixed(7)}" lon="${lon.toStringAsFixed(7)}">');
    if (withElevation) b.write('<ele>${ele.toStringAsFixed(1)}</ele>');
    if (withTime) {
      b.write('<time>${DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true).toIso8601String()}</time>');
    }
    b.writeln('</trkpt>');
  }

  var open = false;
  for (var i = 0; i < pts.length; i++) {
    final pt = pts[i];
    var newSeg = i == 0;
    if (!newSeg && pt.tsMs - pts[i - 1].tsMs > gpxGapSeconds * 1000) {
      final gap = result.gapAt(i);
      final joined = heal && (gap?.kind == GapKind.glueStill || gap?.kind == GapKind.bridge);
      newSeg = !joined;
      if (joined && gap!.kind == GapKind.bridge && gap.curve.isNotEmpty) {
        // Smooth continuation: spread the missing time evenly over the curve points.
        final prev = pts[i - 1];
        final n = gap.curve.length + 1;
        for (var c = 0; c < gap.curve.length; c++) {
          final f = (c + 1) / n;
          writePoint(
            gap.curve[c].lat,
            gap.curve[c].lon,
            prev.altitude + (pt.altitude - prev.altitude) * f,
            (prev.tsMs + (pt.tsMs - prev.tsMs) * f).round(),
          );
        }
      }
    }
    if (newSeg) {
      if (open) b.writeln('</trkseg>');
      b.writeln('<trkseg>');
      open = true;
    }
    writePoint(pt.lat, pt.lon, pt.altitude, pt.tsMs);
  }
  if (open) b.writeln('</trkseg>');
  b.writeln('</trk></gpx>');

  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, 'tropa_$sessionId.gpx'));
  return file.writeAsString(b.toString());
}
