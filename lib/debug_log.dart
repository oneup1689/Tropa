import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Plain-text debug log that survives app kills: every line is flushed to disk.
/// Used to analyse why a recording was interrupted.
///
/// One file only: when it passes [maxBytes] the oldest lines are cut off and the newest [keepBytes]
/// stay, like a dashcam overwriting its oldest footage. The native recording service writes to the same
/// file (see TrackingDb.kt) and follows the same rule.
class DebugLog {
  DebugLog._();
  static final DebugLog instance = DebugLog._();

  static const int maxBytes = 4 * 1024 * 1024;
  static const int keepBytes = 3 * 1024 * 1024;
  static const int _checkEvery = 200; // writes between two size checks
  File? _file;
  int _writes = 0;

  String? get path => _file?.path;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'tropa_debug_log.txt'));
    // Older builds kept a second file for the previous log: it is not needed any more.
    final old = File(p.join(dir.path, 'tropa_debug_log.old.txt'));
    if (await old.exists()) await old.delete();
    _file = file;
    if (await file.exists()) await trim(file);
    log('LOG', '---------- log opened ----------');
  }

  /// Cuts [file] down to its newest [keepBytes] (starting on a whole line) when it is over [maxBytes].
  static Future<void> trim(File file, {int max = maxBytes, int keep = keepBytes}) async {
    try {
      final length = await file.length();
      if (length <= max) return;
      final raf = await file.open();
      final List<int> tail;
      try {
        await raf.setPosition(length - keep);
        tail = await raf.read(keep);
      } finally {
        await raf.close(); // Windows cannot replace a file that is still open
      }
      final nl = tail.indexOf(10);
      final start = nl < 0 ? 0 : nl + 1;
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(tail.sublist(start), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Trimming must never break the app.
    }
  }

  void log(String tag, String message) {
    final line = '${DateTime.now().toIso8601String()} [$tag] $message\n';
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync(line, mode: FileMode.append, flush: true);
      if (++_writes % _checkEvery == 0 && f.lengthSync() > maxBytes) {
        // Rare and short: done synchronously so that no line is written while the file is being replaced.
        final bytes = f.readAsBytesSync();
        final tail = bytes.sublist(bytes.length - keepBytes);
        final nl = tail.indexOf(10);
        f.writeAsBytesSync(nl < 0 ? tail : tail.sublist(nl + 1), flush: true);
      }
    } catch (_) {
      // Logging must never break recording.
    }
  }

  Future<void> clear() async {
    final f = _file;
    if (f == null) return;
    await f.writeAsString('');
    log('LOG', 'log cleared by user');
  }
}
