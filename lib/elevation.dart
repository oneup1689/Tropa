import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'altitude.dart';
import 'db.dart';
import 'debug_log.dart';
import 'heal.dart';

/// Heights of the terrain under the track, taken from a digital elevation model (DEM) for points
/// spaced along the walk. [idx] are indexes into the track's points, [elev] the heights in metres.
class DemSamples {
  final List<int> idx;
  final List<double> elev;
  final String source;

  const DemSamples(this.idx, this.elev, this.source);

  Map<String, Object?> toJson() => {'idx': idx, 'elev': elev, 'source': source};

  factory DemSamples.fromJson(Map<String, dynamic> m) => DemSamples(
        (m['idx'] as List<dynamic>).map((e) => (e as num).toInt()).toList(),
        (m['elev'] as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
        (m['source'] as String?) ?? 'dem',
      );
}

/// Track points about every [spacingM] along the path (first and last included), at most [maxSamples].
List<int> demSampleIndexes(List<TrackPoint> pts, {double spacingM = 40, int maxSamples = 500}) {
  if (pts.isEmpty) return const [];
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
  }
  final step = math.max(spacingM, total / maxSamples);
  final out = <int>[0];
  var since = 0.0;
  for (var i = 1; i < pts.length; i++) {
    since += haversine(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    if (since >= step) {
      out.add(i);
      since = 0;
    }
  }
  if (out.last != pts.length - 1) out.add(pts.length - 1);
  return out;
}

Future<dynamic> _getJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 15));
    req.headers.set('User-Agent', 'Tropa/1.0 (personal hiking app)');
    final res = await req.close().timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      DebugLog.instance.log('DEM', 'HTTP ${res.statusCode} from ${uri.host}');
      return null;
    }
    return jsonDecode(await res.transform(utf8.decoder).join());
  } catch (e) {
    DebugLog.instance.log('DEM', 'request to ${uri.host} failed: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Heights for [pts] from the elevation services. SRTM 30 m (OpenTopoData) first; places it does not cover
/// (north of 60 degrees, water) and failures fall back to Copernicus 90 m (Open-Meteo). Needs internet;
/// returns null when no service answered.
Future<DemSamples?> fetchDem(List<TrackPoint> pts) async {
  final idx = demSampleIndexes(pts);
  if (idx.length < 2) return null;
  final elev = List<double?>.filled(idx.length, null);
  var usedSrtm = 0, usedCop = 0;

  const batch = 100;
  for (var from = 0; from < idx.length; from += batch) {
    final to = math.min(from + batch, idx.length);
    final loc = [for (var k = from; k < to; k++) '${pts[idx[k]].lat.toStringAsFixed(5)},${pts[idx[k]].lon.toStringAsFixed(5)}'].join('|');
    final r = await _getJson(Uri.parse('https://api.opentopodata.org/v1/srtm30m?locations=$loc'));
    final results = r is Map ? r['results'] : null;
    if (results is List && results.length == to - from) {
      for (var k = from; k < to; k++) {
        final e = (results[k - from] as Map)['elevation'];
        if (e is num) {
          elev[k] = e.toDouble();
          usedSrtm++;
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // the public service allows 1 request a second
  }

  // Whatever SRTM did not give: Copernicus 90 m.
  final missing = [for (var k = 0; k < elev.length; k++) if (elev[k] == null) k];
  for (var from = 0; from < missing.length; from += batch) {
    final part = missing.sublist(from, math.min(from + batch, missing.length));
    final lat = [for (final k in part) pts[idx[k]].lat.toStringAsFixed(5)].join(',');
    final lon = [for (final k in part) pts[idx[k]].lon.toStringAsFixed(5)].join(',');
    final r = await _getJson(Uri.parse('https://api.open-meteo.com/v1/elevation?latitude=$lat&longitude=$lon'));
    final list = r is Map ? r['elevation'] : null;
    if (list is List && list.length == part.length) {
      for (var m = 0; m < part.length; m++) {
        final e = list[m];
        if (e is num) {
          elev[part[m]] = e.toDouble();
          usedCop++;
        }
      }
    }
  }
  if (elev.any((e) => e == null)) {
    // A hole (a service was down): fill it from the neighbours rather than throw everything away.
    final known = elev.whereType<double>().length;
    if (known < idx.length * 0.8) {
      DebugLog.instance.log('DEM', 'not enough data: $known of ${idx.length}');
      return null;
    }
    for (var k = 0; k < elev.length; k++) {
      if (elev[k] != null) continue;
      var a = k - 1, b = k + 1;
      while (a >= 0 && elev[a] == null) {
        a--;
      }
      while (b < elev.length && elev[b] == null) {
        b++;
      }
      elev[k] = a >= 0 && b < elev.length ? (elev[a]! + elev[b]!) / 2 : (a >= 0 ? elev[a] : elev[b]);
    }
  }
  final source = usedCop == 0 ? 'srtm30' : (usedSrtm == 0 ? 'copernicus90' : 'srtm30+copernicus90');
  DebugLog.instance.log('DEM', '${idx.length} samples ($source)');
  return DemSamples(idx, [for (final e in elev) e!], source);
}

/// Height of the walk from GPS [gps] (already corrected for the geoid, see [fusedAltitude]) and the
/// terrain model [dem].
///
/// Both are wrong in different ways. GPS height wanders by 10-20 m but follows the real shape; a DEM is
/// stable but smooths narrow peaks (a 30-90 m grid cannot see a rock needle) and shows the tree canopy.
/// So: (1) the slow drift of GPS is removed using flat stretches, where the DEM is reliable (median of
/// DEM minus GPS); (2) each point is a weighted mean of the two, weights 1/sigma^2. GPS sigma is 12 m; the DEM
/// sigma is 6 m plus a quarter of the local relief, because steep, rough ground is where the DEM errs most.
List<double> fuseWithDem(List<double> gps, DemSamples dem) {
  final n = gps.length;
  if (n == 0 || dem.idx.length < 2) return gps;
  // DEM at every point by linear interpolation between the samples.
  final d = List<double>.filled(n, dem.elev.first);
  for (var s = 0; s + 1 < dem.idx.length; s++) {
    final a = dem.idx[s], b = dem.idx[s + 1];
    for (var i = a; i <= b && i < n; i++) {
      final t = b == a ? 0.0 : (i - a) / (b - a);
      d[i] = dem.elev[s] + (dem.elev[s + 1] - dem.elev[s]) * t;
    }
  }
  for (var i = dem.idx.last; i < n; i++) {
    d[i] = dem.elev.last;
  }
  // Local relief of the DEM around every sample: +-4 samples (about +-160 m of path).
  final relief = List<double>.filled(dem.idx.length, 0);
  for (var s = 0; s < dem.idx.length; s++) {
    var lo = dem.elev[s], hi = dem.elev[s];
    for (var m = math.max(0, s - 4); m <= math.min(dem.idx.length - 1, s + 4); m++) {
      lo = math.min(lo, dem.elev[m]);
      hi = math.max(hi, dem.elev[m]);
    }
    relief[s] = hi - lo;
  }
  // Drift of GPS: median of (DEM - GPS) on flat ground.
  final diffs = <double>[];
  for (var s = 0; s < dem.idx.length; s++) {
    if (relief[s] < 6 && dem.idx[s] < n) diffs.add(dem.elev[s] - gps[dem.idx[s]]);
  }
  var bias = 0.0;
  if (diffs.length >= 10) {
    diffs.sort();
    bias = diffs[diffs.length ~/ 2].clamp(-30.0, 30.0);
  }
  final out = List<double>.filled(n, 0);
  var s = 0;
  for (var i = 0; i < n; i++) {
    while (s + 1 < dem.idx.length && dem.idx[s + 1] <= i) {
      s++;
    }
    final sigmaD = 6 + 0.25 * relief[s];
    const sigmaG = 12.0;
    final wd = 1 / (sigmaD * sigmaD), wg = 1 / (sigmaG * sigmaG);
    out[i] = ((gps[i] + bias) * wg + d[i] * wd) / (wg + wd);
  }
  // Light smoothing: the interpolated DEM has corners at the samples.
  const half = 3;
  return List<double>.generate(n, (i) {
    var sum = 0.0;
    var cnt = 0;
    for (var m = math.max(0, i - half); m <= math.min(n - 1, i + half); m++) {
      sum += out[m];
      cnt++;
    }
    return sum / cnt;
  });
}

/// Height profile of a stored walk: GPS height, refined by the terrain model when it was fetched.
Future<List<double>> sessionAltitude(int sessionId, List<TrackPoint> pts) async {
  final gps = fusedAltitude(pts);
  try {
    final raw = (await TrackDb.instance.sessionMeta(sessionId))['elevation'] as String?;
    if (raw != null) {
      return fuseWithDem(gps, DemSamples.fromJson(jsonDecode(raw) as Map<String, dynamic>));
    }
  } catch (e) {
    DebugLog.instance.log('DEM', 'stored elevation unreadable: $e');
  }
  return gps;
}

/// Climb and descent for a profile that went through [fuseWithDem] (smoother than raw GPS: 6 m).
ElevationStats elevationOfFused(List<double> alt) => elevationStats(alt, threshold: 6);
