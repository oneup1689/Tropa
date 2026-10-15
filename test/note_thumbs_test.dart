import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/db.dart';
import 'package:tropa/note_thumbs.dart';
import 'package:tropa/poster.dart';

Future<Uint8List> _photo(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF3366CC));
  c.drawCircle(Offset(w / 2, h / 2), h / 4, Paint()..color = const Color(0xFFFFCC00));
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  testWidgets('a photo is shrunk to the thumbnail width, keeping its proportions', (tester) async {
    await tester.runAsync(() async {
      final png = await encodeThumbnail(await _photo(1200, 900));
      expect(png, isNotNull);
      final codec = await ui.instantiateImageCodec(png!);
      final img = (await codec.getNextFrame()).image;
      expect(img.width, thumbWidth);
      expect(img.height, closeTo(thumbWidth * 900 / 1200, 2));
    });
  });

  testWidgets('garbage is not a photo', (tester) async {
    await tester.runAsync(() async {
      expect(await encodeThumbnail(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });

  testWidgets('a note marker with a photo draws without trouble (photo and plain markers together)', (tester) async {
    await tester.runAsync(() async {
      final png = await encodeThumbnail(await _photo(800, 600));
      final photo = (await (await ui.instantiateImageCodec(png!)).getNextFrame()).image;
      final notes = [
        TrackNote(1, 1, 0, 10.0, 106.0, 'with photo', 'photo', 'a.jpg'),
        TrackNote(2, 1, 0, 10.001, 106.001, 'plain', '', ''),
      ];
      final rec = ui.PictureRecorder();
      final c = Canvas(rec, const Rect.fromLTWH(0, 0, 1080, 1920));
      drawNoteMarkers(c, notes, (lat, lon) => Offset((lon - 106.0) * 400000 + 300, 900 - (lat - 10.0) * 400000),
          labels: true, bounds: const Rect.fromLTWH(24, 100, 1032, 1600), thumbs: {'a.jpg': photo});
      final img = await rec.endRecording().toImage(1080, 1920);
      expect(img.width, 1080);
      // For looking at the result by eye: RENDER_NOTE_PNG=<path> flutter test test/note_thumbs_test.dart
      final out = Platform.environment['RENDER_NOTE_PNG'];
      if (out != null) await File(out).writeAsBytes((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  });
}
