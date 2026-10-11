import 'db.dart';
import 'heal.dart';

/// Cuts [startMeters] off the beginning and [endMeters] off the end of the track
/// (measured along the recorded path). It only removes points: it never moves,
/// extends or reorders anything, so the remaining route is exactly as recorded.
/// Returns an empty list when nothing would be left.
List<TrackPoint> trimEnds(List<TrackPoint> pts, double startMeters, double endMeters) {
  if (pts.length < 2 || (startMeters <= 0 && endMeters <= 0)) return pts;

  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
  }
  if (startMeters + endMeters >= total) return const [];

  var from = 0;
  var walked = 0.0;
  while (from < pts.length - 1 && walked < startMeters) {
    walked += haversine(pts[from].lat, pts[from].lon, pts[from + 1].lat, pts[from + 1].lon);
    from++;
  }

  var to = pts.length - 1;
  walked = 0.0;
  while (to > from && walked < endMeters) {
    walked += haversine(pts[to].lat, pts[to].lon, pts[to - 1].lat, pts[to - 1].lon);
    to--;
  }
  return pts.sublist(from, to + 1);
}
