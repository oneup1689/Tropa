import 'dart:convert';
import 'dart:io';

import 'debug_log.dart';
import 'l10n.dart';

/// Weather during a walk, not "now": the hours between the first and the last point of the track,
/// at the place of the walk. Data comes from Open-Meteo (model/reanalysis, grid of about 10 km), so
/// it is "what the weather was like there", not a reading of a nearby station.
class WeatherInfo {
  final double tempAvg;
  final double tempMin;
  final double tempMax;
  final double feelsAvg;
  final double precipMm;
  final double windKmh;
  final double cloudPct;

  /// WMO weather code of the most frequent condition during the walk.
  final int code;

  /// Time zone of the PLACE (seconds east of UTC). Used to print start/end times as the people
  /// there saw them on the clock, whatever time zone the phone is in.
  final int utcOffsetSec;

  /// Sea surface temperature during the walk; null for rivers, lakes and inland places.
  final double? seaTemp;

  const WeatherInfo({
    required this.tempAvg,
    required this.tempMin,
    required this.tempMax,
    required this.feelsAvg,
    required this.precipMm,
    required this.windKmh,
    required this.cloudPct,
    required this.code,
    required this.utcOffsetSec,
    this.seaTemp,
  });

  Map<String, Object?> toJson() => {
        'tempAvg': tempAvg,
        'tempMin': tempMin,
        'tempMax': tempMax,
        'feelsAvg': feelsAvg,
        'precipMm': precipMm,
        'windKmh': windKmh,
        'cloudPct': cloudPct,
        'code': code,
        'utcOffsetSec': utcOffsetSec,
        'seaTemp': seaTemp,
      };

  factory WeatherInfo.fromJson(Map<String, dynamic> m) => WeatherInfo(
        tempAvg: (m['tempAvg'] as num).toDouble(),
        tempMin: (m['tempMin'] as num).toDouble(),
        tempMax: (m['tempMax'] as num).toDouble(),
        feelsAvg: (m['feelsAvg'] as num).toDouble(),
        precipMm: (m['precipMm'] as num).toDouble(),
        windKmh: (m['windKmh'] as num).toDouble(),
        cloudPct: (m['cloudPct'] as num).toDouble(),
        code: (m['code'] as num).toInt(),
        utcOffsetSec: (m['utcOffsetSec'] as num).toInt(),
        seaTemp: (m['seaTemp'] as num?)?.toDouble(),
      );

  /// Emoji and a short Russian description for the WMO code.
  (String, String) get condition => describeWeatherCode(code);
}

(String, String) describeWeatherCode(int code) {
  if (code == 0) return ('☀️', t('ясно'));
  if (code == 1) return ('🌤️', t('малооблачно'));
  if (code == 2) return ('⛅', t('облачно'));
  if (code == 3) return ('☁️', t('пасмурно'));
  if (code == 45 || code == 48) return ('🌫️', t('туман'));
  if (code >= 51 && code <= 57) return ('🌦️', t('морось'));
  if ((code >= 61 && code <= 65) || code == 80 || code == 81) return ('🌧️', t('дождь'));
  if (code == 66 || code == 67) return ('🌧️', t('ледяной дождь'));
  if (code == 82) return ('🌧️', t('сильный ливень'));
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) return ('❄️', t('снег'));
  if (code >= 95) return ('⛈️', t('гроза'));
  return ('🌡️', t('переменная погода'));
}

/// Hourly values of one Open-Meteo response, with the time zone of the place.
class _Hourly {
  final List<int> utcMs; // start of every hour, in UTC milliseconds
  final Map<String, List<dynamic>> values;
  final int offsetSec;

  _Hourly(this.utcMs, this.values, this.offsetSec);

  /// The API answers with LOCAL times ("2026-10-12T07:00") plus utc_offset_seconds. Local minus offset is UTC:
  /// the comparison with the track (stored in UTC) never depends on the phone's own time zone.
  factory _Hourly.parse(Map<String, dynamic> json) {
    final offset = (json['utc_offset_seconds'] as num?)?.toInt() ?? 0;
    final hourly = json['hourly'] as Map<String, dynamic>;
    final times = (hourly['time'] as List<dynamic>).cast<String>();
    final utc = [for (final t in times) DateTime.parse('${t}Z').millisecondsSinceEpoch - offset * 1000];
    final values = <String, List<dynamic>>{
      for (final e in hourly.entries)
        if (e.key != 'time') e.key: e.value as List<dynamic>,
    };
    return _Hourly(utc, values, offset);
  }

  /// Indexes of the hours that overlap [startMs]..[endMs].
  List<int> hoursBetween(int startMs, int endMs) {
    const hour = 3600000;
    final first = startMs - startMs % hour;
    return [
      for (var i = 0; i < utcMs.length; i++)
        if (utcMs[i] >= first && utcMs[i] <= endMs) i,
    ];
  }
}

double? _avg(Iterable<num?> v) {
  final list = [for (final x in v) if (x != null) x.toDouble()];
  return list.isEmpty ? null : list.reduce((a, b) => a + b) / list.length;
}

/// Summary for the walk from the forecast/archive response ([weather]) and, optionally, the marine response.
/// Returns null when the response has no hours for the walk.
WeatherInfo? summarizeWeather(Map<String, dynamic> weather, int startMs, int endMs, {Map<String, dynamic>? marine}) {
  final h = _Hourly.parse(weather);
  final idx = h.hoursBetween(startMs, endMs);
  if (idx.isEmpty) return null;
  List<num?> pick(String key) => [for (final i in idx) (h.values[key]?[i] as num?)];
  final temps = pick('temperature_2m').whereType<num>().toList();
  if (temps.isEmpty) return null;

  final codes = <int, int>{};
  for (final c in pick('weather_code').whereType<num>()) {
    codes[c.toInt()] = (codes[c.toInt()] ?? 0) + 1;
  }
  var code = 0, best = 0;
  codes.forEach((k, v) {
    if (v > best) {
      best = v;
      code = k;
    }
  });

  double? sea;
  if (marine != null) {
    try {
      final m = _Hourly.parse(marine);
      final mi = m.hoursBetween(startMs, endMs);
      sea = _avg([for (final i in mi) (m.values['sea_surface_temperature']?[i] as num?)]);
    } catch (_) {
      sea = null;
    }
  }

  return WeatherInfo(
    tempAvg: temps.reduce((a, b) => a + b) / temps.length,
    tempMin: temps.map((e) => e.toDouble()).reduce((a, b) => a < b ? a : b),
    tempMax: temps.map((e) => e.toDouble()).reduce((a, b) => a > b ? a : b),
    feelsAvg: _avg(pick('apparent_temperature')) ?? temps.reduce((a, b) => a + b) / temps.length,
    precipMm: pick('precipitation').whereType<num>().fold(0.0, (a, b) => a + b),
    windKmh: _avg(pick('wind_speed_10m')) ?? 0,
    cloudPct: _avg(pick('cloud_cover')) ?? 0,
    code: code,
    utcOffsetSec: h.offsetSec,
    seaTemp: sea,
  );
}

Future<Map<String, dynamic>?> _getJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 12));
    req.headers.set('User-Agent', 'Tropa/1.0 (personal hiking app)');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      DebugLog.instance.log('WEATHER', 'HTTP ${res.statusCode} from ${uri.host}');
      return null;
    }
    final body = await res.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (e) {
    DebugLog.instance.log('WEATHER', 'request to ${uri.host} failed: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

String _date(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Fetches the weather of the walk (needs internet). Recent walks use the forecast service with its
/// "past days" window, older ones the archive. Returns null when there is no internet or no data.
Future<WeatherInfo?> fetchWeather(double lat, double lon, int startMs, int endMs) async {
  const hourly = 'temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,cloud_cover';
  final now = DateTime.now().millisecondsSinceEpoch;
  final ageDays = (now - endMs) / 86400000;
  final latS = lat.toStringAsFixed(3), lonS = lon.toStringAsFixed(3);
  // Dates are UTC with a day of margin on both sides: the API cuts days in the LOCAL time of the place.
  final from = _date(startMs - 86400000), to = _date(endMs + 86400000);
  final Uri wUri, mUri;
  if (ageDays <= 80) {
    final past = (ageDays + 3).ceil().clamp(1, 92);
    wUri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latS, 'longitude': lonS, 'hourly': hourly, 'past_days': '$past', 'forecast_days': '1',
      'timezone': 'auto', 'wind_speed_unit': 'kmh',
    });
    mUri = Uri.https('marine-api.open-meteo.com', '/v1/marine', {
      'latitude': latS, 'longitude': lonS, 'hourly': 'sea_surface_temperature', 'past_days': '$past',
      'forecast_days': '1', 'timezone': 'auto',
    });
  } else {
    wUri = Uri.https('archive-api.open-meteo.com', '/v1/archive', {
      'latitude': latS, 'longitude': lonS, 'hourly': hourly, 'start_date': from, 'end_date': to,
      'timezone': 'auto', 'wind_speed_unit': 'kmh',
    });
    mUri = Uri.https('marine-api.open-meteo.com', '/v1/marine', {
      'latitude': latS, 'longitude': lonS, 'hourly': 'sea_surface_temperature', 'start_date': from,
      'end_date': to, 'timezone': 'auto',
    });
  }
  final w = await _getJson(wUri);
  if (w == null || w['hourly'] == null) return null;
  final m = await _getJson(mUri); // inland: the service answers with an error or nulls, which is fine
  try {
    final info = summarizeWeather(w, startMs, endMs, marine: m != null && m['hourly'] != null ? m : null);
    DebugLog.instance.log('WEATHER', info == null ? 'no hours for the walk' : 'ok ${info.tempAvg.toStringAsFixed(1)}C code=${info.code}');
    return info;
  } catch (e) {
    DebugLog.instance.log('WEATHER', 'parse failed: $e');
    return null;
  }
}

/// Place name for the poster ("Ниньбинь, Вьетнам"); null without internet. BigDataCloud's free client
/// endpoint first (no key, province + country in Russian), OpenStreetMap's Nominatim as a fallback.
Future<String?> fetchPlaceName(double lat, double lon) async {
  final b = await _getJson(Uri.https('api.bigdatacloud.net', '/data/reverse-geocode-client', {
    'latitude': lat.toStringAsFixed(5), 'longitude': lon.toStringAsFixed(5), 'localityLanguage': 'ru',
  }));
  if (b != null) {
    final region = (b['principalSubdivision'] as String?)?.trim() ?? '';
    final country = (b['countryName'] as String?)?.trim() ?? '';
    final name = [if (region.isNotEmpty) region, if (country.isNotEmpty) country].join(', ');
    if (name.isNotEmpty) return name;
  }
  final j = await _getJson(Uri.https('nominatim.openstreetmap.org', '/reverse', {
    'format': 'jsonv2', 'lat': lat.toStringAsFixed(5), 'lon': lon.toStringAsFixed(5), 'zoom': '10',
    'accept-language': 'ru',
  }));
  final a = j?['address'];
  if (a is! Map) return null;
  final parts = <String>[];
  for (final k in ['state', 'city', 'town', 'municipality', 'county', 'state_district', 'village']) {
    final v = a[k];
    if (v is String && v.isNotEmpty && !parts.contains(v)) {
      parts.add(v);
      break;
    }
  }
  final country = a['country'];
  if (country is String && country.isNotEmpty) parts.add(country);
  return parts.isEmpty ? null : parts.join(', ');
}
