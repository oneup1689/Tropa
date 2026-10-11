import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Plain-text debug log that survives app kills: every line is flushed to disk.
/// Used to analyse why a recording was interrupted.
class DebugLog {
  DebugLog._();
  static final DebugLog instance = DebugLog._();

  static const int _maxBytes = 5 * 1024 * 1024;
  File? _file;

  String? get path => _file?.path;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'tropa_debug_log.txt'));
    if (await file.exists() && await file.length() > _maxBytes) {
      final old = File(p.join(dir.path, 'tropa_debug_log.old.txt'));
      if (await old.exists()) await old.delete();
      await file.rename(old.path);
    }
    _file = file;
    log('LOG', '---------- log opened ----------');
  }

  void log(String tag, String message) {
    final line = '${DateTime.now().toIso8601String()} [$tag] $message\n';
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync(line, mode: FileMode.append, flush: true);
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
