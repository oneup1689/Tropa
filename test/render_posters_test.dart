import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/altitude.dart';
import 'package:tropa/db.dart';
import 'package:tropa/elevation.dart';
import 'package:tropa/modes.dart';
import 'package:tropa/poster.dart';
import 'package:tropa/poster_multi.dart';
import 'package:tropa/poster_wide.dart';
import 'package:tropa/segments.dart';
import 'package:tropa/weather.dart';

/// Debug tool, not a regression test: renders posters from a real recorded walk (test/tropa_5.gpx, which is
/// not in git) into dist/posters/ so they can be looked at. Skipped when the file is missing.
Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

void main() {
  final gpx = File('test/tropa_5.gpx');
  testWidgets('render posters from a real walk', (tester) async {
    await tester.runAsync(() async {
      await _loadFont('Rubik', 'assets/fonts/Rubik-Variable.ttf');
      await _loadFont('Unbounded', 'assets/fonts/Unbounded-Variable.ttf');
      final re = RegExp(r'<trkpt lat="([\d.\-]+)" lon="([\d.\-]+)"><ele>([\d.\-]+)</ele><time>([^<]+)</time>');
      final pts = [
        for (final m in re.allMatches(gpx.readAsStringSync()))
          TrackPoint(DateTime.parse(m.group(4)!).millisecondsSinceEpoch, double.parse(m.group(1)!), double.parse(m.group(2)!), 5,
              double.parse(m.group(3)!), 0)
      ];
      const weather = WeatherInfo(
          tempAvg: 29, tempMin: 24, tempMax: 31, feelsAvg: 34, precipMm: 1.0, windKmh: 8, cloudPct: 60, code: 2, utcOffsetSec: 25200, seaTemp: 26.4);

      // Notes: a text one at the start, a photo at the top, a video, a long one, one at the end.
      var top = 0;
      final alt = fusedAltitude(pts);
      for (var i = 0; i < pts.length; i++) {
        if (alt[i] > alt[top]) top = i;
      }
      TrackNote note(int i, String text, [String type = '']) =>
          TrackNote(i, 1, pts[i].tsMs, pts[i].lat, pts[i].lon, text, type, type.isEmpty ? '' : 'IMG_$i');
      final notes = [
        note(5, 'Старт: кофе у рынка'),
        note(pts.length ~/ 8, 'Отсюда дальше пешком'),
        note(top, 'Вершина! Вид на всю долину', 'photo'),
        note(pts.length * 6 ~/ 10, 'Обед в деревне, очень вкусно', 'video'),
        note(pts.length - 20, 'Финиш и холодный лимонад'),
      ];

      HttpOverrides.global = null; // testWidgets blocks real HTTP by default
      // Heights from the terrain model when there is internet (the same call the app makes).
      List<double>? fusedAlt;
      try {
        final dem = await fetchDem(pts);
        if (dem != null) fusedAlt = fuseWithDem(alt, dem);
      } catch (_) {
        fusedAlt = null; // offline: GPS heights
      }

      Directory('dist/posters').createSync(recursive: true);
      Future<void> write(String name, Future<Uint8List> png) async {
        final bytes = await png;
        try {
          File('dist/posters/$name.png').writeAsBytesSync(bytes);
        } on FileSystemException {
          // The old picture is open in a viewer (locked on Windows): write next to it.
          File('dist/posters/${name}_new.png').writeAsBytesSync(bytes);
        }
      }

      final mixed = buildSegments(pts, TravelMode.mixed);
      final base = PosterOptions()
        ..title = 'Хан-Муа и обратно'
        ..region = 'Ниньбинь, Вьетнам';

      await write('1_vertical_modes', composePoster(o: base, pts: pts, segments: mixed, mode: TravelMode.mixed, weather: weather, notes: notes, altitude: fusedAlt, altitudeFused: fusedAlt != null, scale: 1));
      final speed = PosterOptions()
        ..title = 'Хан-Муа и обратно'
        ..region = 'Ниньбинь, Вьетнам'
        ..coloring = LineColoring.speed
        ..hideEnds = true;
      await write('2_vertical_speed_hidden_ends', composePoster(o: speed, pts: pts, segments: mixed, mode: TravelMode.mixed, weather: weather, notes: notes, altitude: fusedAlt, altitudeFused: fusedAlt != null, scale: 1));
      final water = PosterOptions()
        ..title = 'Сплав по реке Ня Лонг'
        ..region = 'Ниньбинь, Вьетнам'
        ..coloring = LineColoring.single
        ..waterTempManual = 24.5;
      await write('3_vertical_water', composePoster(o: water, pts: pts, segments: buildSegments(pts, TravelMode.water), mode: TravelMode.water, weather: weather, notes: notes, altitude: fusedAlt, altitudeFused: fusedAlt != null, scale: 1));

      final wide = PosterOptions()
        ..format = PosterFormat.horizontal
        ..title = 'Хан-Муа и обратно'
        ..region = 'Ниньбинь, Вьетнам';
      await write('4_wide_modes', composeWidePoster(o: wide, pts: pts, segments: mixed, mode: TravelMode.mixed, weather: weather, notes: notes, altitude: fusedAlt, altitudeFused: fusedAlt != null, scale: 1));
      final wideH = PosterOptions()
        ..format = PosterFormat.horizontal
        ..title = 'Хан-Муа и обратно'
        ..region = 'Ниньбинь, Вьетнам'
        ..coloring = LineColoring.height;
      await write('5_wide_height', composeWidePoster(o: wideH, pts: pts, segments: mixed, mode: TravelMode.mixed, weather: weather, notes: notes, altitude: fusedAlt, altitudeFused: fusedAlt != null, scale: 1));

      final wideSpeed = PosterOptions()
        ..format = PosterFormat.horizontal
        ..title = 'Хан-Муа и обратно'
        ..region = 'Ниньбинь, Вьетнам'
        ..coloring = LineColoring.speed;
      await write('5b_wide_speed', composeWidePoster(o: wideSpeed, pts: pts, segments: mixed, mode: TravelMode.mixed, weather: weather, notes: notes, altitude: fusedAlt, altitudeFused: fusedAlt != null, scale: 1));

      // Several walks on one poster: the real ones plus shifted copies to fill the legend.
      List<TrackPoint> load(String path, {double dLat = 0, double dLon = 0}) => [
            for (final m in re.allMatches(File(path).readAsStringSync()))
              TrackPoint(DateTime.parse(m.group(4)!).millisecondsSinceEpoch, double.parse(m.group(1)!) + dLat,
                  double.parse(m.group(2)!) + dLon, 5, double.parse(m.group(3)!), 0)
          ];
      MultiRoute route(String name, List<TrackPoint> p, TravelMode mode) => MultiRoute(name, p, fusedAltitude(p), false, mode);
      final multi = [
        route('Хан-Муа и обратно', pts, TravelMode.mixed),
        route('Тест автозапуска', load('test/tropa_6.gpx'), TravelMode.walk),
        route('Прогулка 11 окт', load('test/tropa_1.gpx'), TravelMode.walk),
        route('Велопрогулка к озеру', load('test/tropa_5.gpx', dLat: 0.012, dLon: -0.02), TravelMode.bike),
        route('Вечерний сплав по реке', load('test/tropa_1.gpx', dLat: -0.01, dLon: 0.015), TravelMode.water),
        route('Утренняя пробежка', load('test/tropa_6.gpx', dLat: 0.004, dLon: -0.006), TravelMode.walk),
      ];
      await write('8_multi', composeMultiPoster(o: PosterOptions()..format = PosterFormat.horizontal..title = 'Ниньбинь: неделя в движении'..region = 'Ниньбинь, Вьетнам', routes: multi, scale: 1));
    });
  }, skip: !gpx.existsSync());
}
