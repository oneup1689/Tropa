import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/brand.dart';

/// Dev tool: draws the app icon from the logo into the Android resource folders.
/// Run with: RENDER_ICONS=1 flutter test test/render_icons_test.dart
Future<void> _png(String path, int px, void Function(Canvas c, double s) draw) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  draw(c, px.toDouble());
  final img = await rec.endRecording().toImage(px, px);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  testWidgets('render the app icon', (tester) async {
    await tester.runAsync(() async {
      const res = 'android/app/src/main/res';
      // Old launchers (before Android 8): the round badge on a transparent square.
      for (final (d, px) in const [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]) {
        await _png('$res/mipmap-$d/ic_launcher.png', px, (c, s) => drawTropaLogo(c, Offset(s * 0.03, s * 0.03), s * 0.94));
      }
      // Adaptive icon (Android 8+): the foreground is the peak, the trail and the flag in the safe zone; the
      // background is the green gradient of the badge (res/drawable/ic_launcher_background.xml).
      for (final (d, px) in const [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216), ('xxhdpi', 324), ('xxxhdpi', 432)]) {
        await _png('$res/mipmap-$d/ic_launcher_foreground.png', px, (c, s) => drawTropaLogo(c, Offset(s * 0.18, s * 0.17), s * 0.64, badge: false));
      }
      // Status bar icon of the notifications: one colour (white) silhouette.
      for (final (d, px) in const [('mdpi', 24), ('hdpi', 36), ('xhdpi', 48), ('xxhdpi', 72), ('xxxhdpi', 96)]) {
        await _png('$res/drawable-$d/ic_stat_tropa.png', px, (c, s) => drawTropaLogo(c, Offset(s * 0.04, s * 0.04), s * 0.92, badge: false, mono: const Color(0xFFFFFFFF)));
      }
    });
  }, skip: Platform.environment['RENDER_ICONS'] == null);
}
