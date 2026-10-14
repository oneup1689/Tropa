import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tropa/debug_log.dart';

void main() {
  test('trim keeps the newest lines, starts on a whole line and ends under the limit', () async {
    final dir = await Directory.systemTemp.createTemp('tropa_log_test');
    try {
      final file = File('${dir.path}/log.txt');
      final sb = StringBuffer();
      for (var i = 0; i < 2000; i++) {
        sb.writeln('2026-10-14T12:00:00.000 [FIX] line $i ${'x' * 40}');
      }
      await file.writeAsString(sb.toString());
      final before = await file.length();
      await DebugLog.trim(file, max: 60000, keep: 40000);
      final after = await file.length();
      expect(before, greaterThan(60000));
      expect(after, lessThanOrEqualTo(40000));
      final lines = await file.readAsLines();
      expect(lines.first.startsWith('2026-10-14'), true, reason: 'the cut must not leave half a line at the start');
      expect(lines.last.contains('line 1999'), true, reason: 'the newest line stays');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a small log is left alone', () async {
    final dir = await Directory.systemTemp.createTemp('tropa_log_test');
    try {
      final file = File('${dir.path}/log.txt');
      await file.writeAsString('a\nb\n');
      await DebugLog.trim(file, max: 1000, keep: 500);
      expect(await file.readAsString(), 'a\nb\n');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
