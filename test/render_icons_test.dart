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
      // Old launchers (before Android 8): the rounded square of the poster gradient with the t mark.
      for (final (d, px) in const [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]) {
        await _png('$res/mipmap-$d/ic_launcher.png', px, (c, s) => drawTropaLogo(c, Offset(s * 0.03, s * 0.03), s * 0.94));
      }
      // Adaptive icon (Android 8+): the foreground is the t mark inside the safe zone (central 66 %); the
      // background is the poster gradient (res/drawable/ic_launcher_background.xml).
      for (final (d, px) in const [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216), ('xxhdpi', 324), ('xxxhdpi', 432)]) {
        await _png('$res/mipmap-$d/ic_launcher_foreground.png', px, (c, s) => drawTropaLogo(c, Offset.zero, s, badge: false, fill: 0.58));
        // Android 13 themed icon: one-colour layer, tinted by the system.
        await _png('$res/mipmap-$d/ic_launcher_monochrome.png', px, (c, s) => drawTropaLogo(c, Offset.zero, s, badge: false, mono: const Color(0xFF000000), fill: 0.58));
      }
      // Status bar icon of the notifications: one colour (white) silhouette.
      for (final (d, px) in const [('mdpi', 24), ('hdpi', 36), ('xhdpi', 48), ('xxhdpi', 72), ('xxxhdpi', 96)]) {
        await _png('$res/drawable-$d/ic_stat_tropa.png', px, (c, s) => drawTropaLogo(c, Offset.zero, s, badge: false, mono: const Color(0xFFFFFFFF), fill: 0.92));
      }
      // iOS: a full-bleed square (the system rounds the corners itself): poster gradient + the t mark.
      const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final name = RegExp(r'^Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$');
      for (final f in Directory(ios).listSync().whereType<File>()) {
        final m = name.firstMatch(f.uri.pathSegments.last);
        if (m == null) continue;
        final px = (double.parse(m.group(1)!) * int.parse(m.group(2)!)).round();
        await _png(f.path, px, (c, s) {
          c.drawRect(Rect.fromLTWH(0, 0, s, s), Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(s, s), const [brandGreen, brandNight]));
          drawTropaLogo(c, Offset.zero, s, badge: false, fill: 0.62);
        });
      }
    });
  }, skip: Platform.environment['RENDER_ICONS'] == null);
}
