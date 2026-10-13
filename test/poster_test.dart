import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/poster.dart';
import 'package:tropa/weather.dart';

void main() {
  // Open-Meteo answers with LOCAL times and utc_offset_seconds; the walk is stored in UTC.
  final response = {
    'utc_offset_seconds': 25200,
    'hourly': {
      'time': [for (var h = 0; h < 24; h++) '2026-10-12T${h.toString().padLeft(2, '0')}:00'],
      'temperature_2m': [for (var h = 0; h < 24; h++) 20.0 + h], // 20 at 00:00 local, 27 at 07:00 local
      'apparent_temperature': [for (var h = 0; h < 24; h++) 25.0 + h],
      'precipitation': [for (var h = 0; h < 24; h++) h == 10 ? 0.6 : 0.0],
      'weather_code': [for (var h = 0; h < 24; h++) h >= 10 && h <= 13 ? 51 : 0],
      'wind_speed_10m': [for (var h = 0; h < 24; h++) 10.0],
      'cloud_cover': [for (var h = 0; h < 24; h++) 50],
    },
  };

  test('weather hours are matched in UTC, whatever the phone time zone is', () {
    // 2026-10-12 00:23 UTC .. 07:44 UTC is 07:23 .. 14:44 local (UTC+7): local hours 07..14.
    final start = DateTime.utc(2026, 10, 12, 0, 23).millisecondsSinceEpoch;
    final end = DateTime.utc(2026, 10, 12, 7, 44).millisecondsSinceEpoch;
    final w = summarizeWeather(response, start, end)!;
    expect(w.utcOffsetSec, 25200);
    expect(w.tempMin, 27); // 07:00 local, not 00:00 (20): the offset was applied
    expect(w.tempMax, 34); // 14:00 local
    expect(w.tempAvg, closeTo(30.5, 0.01));
    expect(w.precipMm, closeTo(0.6, 0.001));
    expect(w.code, 0); // clear in 4 of 8 hours and drizzle in 4: the first most frequent wins
  });

  test('a walk after the data returns nothing', () {
    final start = DateTime.utc(2026, 10, 20).millisecondsSinceEpoch;
    expect(summarizeWeather(response, start, start + 3600000), isNull);
  });

  test('sea temperature comes from the marine response', () {
    final marine = {
      'utc_offset_seconds': 25200,
      'hourly': {
        'time': [for (var h = 0; h < 24; h++) '2026-10-12T${h.toString().padLeft(2, '0')}:00'],
        'sea_surface_temperature': [for (var h = 0; h < 24; h++) 26.0],
      },
    };
    final start = DateTime.utc(2026, 10, 12, 1).millisecondsSinceEpoch;
    final w = summarizeWeather(response, start, start + 3600000, marine: marine)!;
    expect(w.seaTemp, 26);
  });

  test('weather survives storing as JSON', () {
    final start = DateTime.utc(2026, 10, 12, 1).millisecondsSinceEpoch;
    final w = summarizeWeather(response, start, start + 3600000)!;
    final back = WeatherInfo.fromJson(w.toJson());
    expect(back.tempAvg, w.tempAvg);
    expect(back.utcOffsetSec, 25200);
    expect(back.seaTemp, isNull);
  });

  test('start and end are printed in the time of the place', () {
    final start = DateTime.utc(2026, 10, 12, 0, 23).millisecondsSinceEpoch;
    final end = DateTime.utc(2026, 10, 12, 7, 44).millisecondsSinceEpoch;
    expect(posterDateLine(start, end, 25200), '12 октября 2026 · 07:23–14:44');
    // The same walk seen from Moscow (UTC+3) would read differently: the place's zone is what counts.
    expect(posterDateLine(start, end, 10800), '12 октября 2026 · 03:23–10:44');
    // Crossing midnight shows both dates.
    final late = DateTime.utc(2026, 10, 12, 15, 0).millisecondsSinceEpoch;
    final next = DateTime.utc(2026, 10, 12, 20, 30).millisecondsSinceEpoch;
    expect(posterDateLine(late, next, 25200), '12 октября 22:00 – 13 октября 03:30');
  });

  test('weather codes have an emoji and a Russian description', () {
    expect(describeWeatherCode(0).$2, 'ясно');
    expect(describeWeatherCode(61).$2, 'дождь');
    expect(describeWeatherCode(95).$2, 'гроза');
  });
}
