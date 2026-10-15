import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'debug_log.dart';
import 'note_thumbs.dart';
import 'recorder.dart';
import 'l10n.dart';

/// Photos and videos go to the phone gallery (album "Tropa"), not into the app's own storage,
/// so they do not bloat the app. The database keeps only the text and the file name.
class NoteMedia {
  final String type; // 'photo' | 'video'
  final String name;

  const NoteMedia(this.type, this.name);
}

Future<NoteMedia?> captureMedia({required bool video}) async {
  try {
    final picker = ImagePicker();
    final XFile? shot = video
        ? await picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 2))
        : await picker.pickImage(source: ImageSource.camera, imageQuality: 92);
    if (shot == null) return null;
    if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
    if (video) {
      await Gal.putVideo(shot.path, album: 'Tropa');
    } else {
      await Gal.putImage(shot.path, album: 'Tropa');
    }
    final name = p.basename(shot.path);
    // A small copy stays in the app, so that the poster can show the photo in the marker of the note.
    if (!video) await saveNoteThumb(shot.path, name);
    // The picker's temporary copy is no longer needed once the gallery has the file.
    try {
      await File(shot.path).delete();
    } catch (_) {}
    DebugLog.instance.log('NOTE', '${video ? 'video' : 'photo'} saved to the gallery: $name');
    return NoteMedia(video ? 'video' : 'photo', name);
  } catch (e) {
    DebugLog.instance.log('NOTE', 'media capture failed: $e');
    return null;
  }
}

/// Bottom sheet for a new note: optional text, optional photo or video. Anchored to the current
/// position and time of the recording.
Future<bool> showNoteSheet(BuildContext context) async {
  final rec = Recorder.instance;
  final sessionId = rec.sessionId;
  if (sessionId == null) return false;
  final ctl = TextEditingController();
  NoteMedia? media;

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(c).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('Заметка к этому месту'), style: Theme.of(c).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: ctl,
            maxLines: 3,
            decoration: InputDecoration(hintText: t('Текст (необязательно)'), border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            ActionChip(
              avatar: const Icon(Icons.photo_camera),
              label: Text(t('Фото')),
              onPressed: () async {
                final m = await captureMedia(video: false);
                if (m != null) setS(() => media = m);
              },
            ),
            ActionChip(
              avatar: const Icon(Icons.videocam),
              label: Text(t('Видео')),
              onPressed: () async {
                final m = await captureMedia(video: true);
                if (m != null) setS(() => media = m);
              },
            ),
          ]),
          if (media != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('{k} сохранено в галерею (альбом Tropa)', {'k': media!.type == 'photo' ? t('Фото') : t('Видео')})),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(t('Сохранить заметку')),
          ),
        ]),
      ),
    ),
  );
  if (saved != true) return false;
  final text = ctl.text.trim();
  if (text.isEmpty && media == null) return false;

  await TrackDb.instance.addNote(
    sessionId: sessionId,
    tsMs: DateTime.now().millisecondsSinceEpoch,
    lat: rec.lastLat,
    lon: rec.lastLon,
    text: text,
    mediaType: media?.type ?? '',
    mediaName: media?.name ?? '',
  );
  return true;
}
