import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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

/// Debug tool, not a regression test: renders the demo posters of the presentation from tracks made by a script
/// (DEMO_DIR/*.json, photo thumbnails in DEMO_DIR/thumbs) into DEMO_OUT. Skipped when DEMO_DIR is not set.
Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

class _Demo {
  final String title, region;
  final List<TrackPoint> pts;
  final List<Map<String, dynamic>> notes;
  final bool real;
  final int? waterFromMs;

  _Demo(this.title, this.region, this.pts, this.notes, this.real, this.waterFromMs);

  static _Demo load(String path) {
    final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final pts = [
      for (final p in j['points'] as List)
        TrackPoint((p[0] as num).toInt(), (p[1] as num).toDouble(), (p[2] as num).toDouble(), 5, (p[3] as num).toDouble(), 0)
    ];
    return _Demo(j['title'], j['region'], pts, [for (final n in j['notes'] as List) (n as Map).cast<String, dynamic>()], j['real'] == true,
        (j['water_from_ts'] as num?)?.toInt());
  }
}

void main() {
  final dirPath = Platform.environment['DEMO_DIR'];
  final outPath = Platform.environment['DEMO_OUT'];
  testWidgets('render the demo posters of the presentation', (tester) async {
    await tester.runAsync(() async {
      final dir = Directory(dirPath!);
      final out = Directory(outPath!)..createSync(recursive: true);
      // The test engine has no system fonts: emoji and symbols come from Windows fonts, as fallback families.
      await _loadFont('Rubik', 'assets/fonts/Rubik-Variable.ttf');
      await _loadFont('Unbounded', 'assets/fonts/Unbounded-Variable.ttf');
      await _loadFont('EmojiFallback', 'C:/Windows/Fonts/seguiemj.ttf');
      await _loadFont('SymbolFallback', 'C:/Windows/Fonts/seguisym.ttf');
      HttpOverrides.global = null;

      final thumbs = <String, ui.Image>{};
      for (final f in Directory('${dir.path}/thumbs').listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last.replaceAll('.png', '');
        thumbs[name] = (await (await ui.instantiateImageCodec(f.readAsBytesSync())).getNextFrame()).image;
      }

      List<TrackNote> notesOf(_Demo d) => [
            for (var i = 0; i < d.notes.length; i++)
              TrackNote(i, 1, (d.notes[i]['ts'] as num).toInt(), (d.notes[i]['lat'] as num).toDouble(), (d.notes[i]['lon'] as num).toDouble(),
                  d.notes[i]['text'] as String, (d.notes[i]['photo'] as String).isEmpty ? '' : 'photo', d.notes[i]['photo'] as String)
          ];

      Future<List<double>> altOf(_Demo d) async {
        if (!d.real) return fusedAltitude(d.pts, geoid: (a, b) => 0);
        final alt = fusedAltitude(d.pts);
        try {
          final dem = await fetchDem(d.pts);
          if (dem != null) return fuseWithDem(alt, dem);
        } catch (_) {}
        return alt;
      }

      MapCapture? mapOf(String id, String fmt) {
        final cam = File('${dir.path}/maps/${id}_cam.json');
        final png = File('${dir.path}/maps/${id}_$fmt.png');
        if (!cam.existsSync() || !png.existsSync()) return null;
        final c = (jsonDecode(cam.readAsStringSync()) as Map)[fmt] as Map?;
        if (c == null) return null;
        return MapCapture(png.readAsBytesSync(), (c['lat'] as num).toDouble(), (c['lon'] as num).toDouble(), (c['zoom'] as num).toDouble(),
            (c['w'] as num).toInt(), (c['h'] as num).toInt());
      }

      Future<void> write(String name, Future<Uint8List> png) async {
        File('${out.path}/$name.png').writeAsBytesSync(await png);
      }

      Future<void> single(String id, _Demo d, TravelMode mode, LineColoring coloring, WeatherInfo w,
          {List<SegmentOverride> overrides = const [], double? waterTemp, bool hideEnds = false, bool legend = true, bool peaks = true}) async {
        final segs = buildSegments(d.pts, mode, overrides: overrides);
        final alt = await altOf(d);
        final notes = notesOf(d);
        final mv = mapOf(id, 'vertical'), mw = mapOf(id, 'wide');
        PosterOptions opts(PosterFormat fmt) => PosterOptions()
          ..format = fmt
          ..background = (fmt == PosterFormat.vertical ? mv : mw) != null ? PosterBackground.map : PosterBackground.tropa
          ..title = d.title
          ..region = d.region
          ..coloring = coloring
          ..hideEnds = hideEnds
          ..legend = legend
          ..peaks = peaks
          ..waterTempManual = waterTemp;
        final shownMode = overrides.isNotEmpty ? TravelMode.mixed : mode;
        await write('${id}_vertical',
            composePoster(o: opts(PosterFormat.vertical), pts: d.pts, segments: segs, mode: shownMode, weather: w, map: mv, notes: notes, noteThumbs: thumbs, altitude: alt, altitudeFused: d.real, scale: 2));
        await write('${id}_wide',
            composeWidePoster(o: opts(PosterFormat.horizontal), pts: d.pts, segments: segs, mode: shownMode, weather: w, map: mw, notes: notes, noteThumbs: thumbs, altitude: alt, altitudeFused: d.real, scale: 2));
      }

      // 1. The real hike: colour by height.
      bool has(String n) => File('${dir.path}/$n.json').existsSync();
      if (has('p1_hike')) {
      final hike = _Demo.load('${dir.path}/p1_hike.json');
      await single('p1_hike', hike, TravelMode.walk, LineColoring.height,
          const WeatherInfo(tempAvg: 29, tempMin: 24, tempMax: 31, feelsAvg: 33, precipMm: 1.0, windKmh: 8, cloudPct: 60, code: 2, utcOffsetSec: 25200, seaTemp: null), legend: false, peaks: false);

      }
      // 2. The bike ride: colour by speed.
      if (has('p2_bike')) {
      final bike = _Demo.load('${dir.path}/p2_bike.json');
      await single('p2_bike', bike, TravelMode.bike, LineColoring.speed,
          const WeatherInfo(tempAvg: 19, tempMin: 14, tempMax: 23, feelsAvg: 18, precipMm: 0, windKmh: 12, cloudPct: 30, code: 1, utcOffsetSec: 18000, seaTemp: null), legend: false);

      }
      // 3. Car, then a raft: the second part is marked as water by hand, as a person would do in the app.
      if (has('p3_car_raft')) {
      final raft = _Demo.load('${dir.path}/p3_car_raft.json');
      await single('p3_car_raft', raft, TravelMode.mixed, LineColoring.single,
          const WeatherInfo(tempAvg: 18, tempMin: 12, tempMax: 22, feelsAvg: 17, precipMm: 0, windKmh: 9, cloudPct: 40, code: 2, utcOffsetSec: 25200, seaTemp: null),
          overrides: [SegmentOverride(raft.waterFromMs!, raft.pts.last.tsMs, TravelMode.water)], waterTemp: 12);

      }
      // 4. A week of rides on one sheet.
      if (has('p4_week_5')) {
      final routes = <MultiRoute>[];
      for (var i = 1; i <= 5; i++) {
        final d = _Demo.load('${dir.path}/p4_week_$i.json');
        routes.add(MultiRoute(d.title, d.pts, fusedAltitude(d.pts, geoid: (a, b) => 0), false, TravelMode.bike));
      }
      await write(
          'p4_week',
          composeMultiPoster(
              map: mapOf('p4_week', 'wide'),
              o: PosterOptions()
                ..format = PosterFormat.horizontal
                ..background = mapOf('p4_week', 'wide') != null ? PosterBackground.map : PosterBackground.tropa
                ..title = 'Неделя на велосипеде'
                ..region = 'Урал, Россия',
              routes: routes,
              scale: 2));
      }
    });
  }, skip: dirPath == null || outPath == null, timeout: const Timeout(Duration(minutes: 8)));
}
