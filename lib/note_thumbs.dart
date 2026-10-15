import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'debug_log.dart';

/// Small copies of the photos of the notes, kept in the app's own folder for the posters (the photos themselves
/// live in the phone gallery, where the app cannot read them without extra permissions). Keyed by the media name
/// of the note.
const thumbWidth = 360;

/// A photo shrunk to [thumbWidth] pixels wide (the height follows), as PNG bytes. Null when it cannot be decoded.
Future<Uint8List?> encodeThumbnail(Uint8List photo) async {
  try {
    final codec = await ui.instantiateImageCodec(photo, targetWidth: thumbWidth);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } catch (e) {
    DebugLog.instance.log('NOTE', 'thumbnail encode failed: $e');
    return null;
  }
}

Future<File> _thumbFile(String mediaName) async {
  final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'note_thumbs'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return File(p.join(dir.path, '${p.basenameWithoutExtension(mediaName)}.png'));
}

/// Makes and keeps the thumbnail of the photo at [sourcePath] for the note media [mediaName]. Returns whether it worked.
Future<bool> saveNoteThumb(String sourcePath, String mediaName) async {
  try {
    final png = await encodeThumbnail(await File(sourcePath).readAsBytes());
    if (png == null) return false;
    await (await _thumbFile(mediaName)).writeAsBytes(png);
    return true;
  } catch (e) {
    DebugLog.instance.log('NOTE', 'thumbnail save failed: $e');
    return false;
  }
}

Future<bool> hasNoteThumb(String mediaName) async => mediaName.isNotEmpty && await (await _thumbFile(mediaName)).exists();

Future<void> deleteNoteThumb(String mediaName) async {
  if (mediaName.isEmpty) return;
  try {
    final f = await _thumbFile(mediaName);
    if (await f.exists()) await f.delete();
  } catch (e) {
    DebugLog.instance.log('NOTE', 'thumbnail delete failed: $e');
  }
}

/// The decoded thumbnails of the photo notes that have one, by media name (for drawing on a poster).
Future<Map<String, ui.Image>> loadNoteThumbs(List<TrackNote> notes) async {
  final out = <String, ui.Image>{};
  for (final n in notes) {
    if (n.mediaType != 'photo' || n.mediaName.isEmpty || out.containsKey(n.mediaName)) continue;
    try {
      final f = await _thumbFile(n.mediaName);
      if (!await f.exists()) continue;
      final codec = await ui.instantiateImageCodec(await f.readAsBytes());
      out[n.mediaName] = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (e) {
      DebugLog.instance.log('NOTE', 'thumbnail load failed: $e');
    }
  }
  return out;
}
