import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'app_hooks.dart';
import 'backup.dart';
import 'debug_log.dart';
import 'l10n.dart';
import 'maps_page.dart';
import 'recorder.dart';
import 'settings.dart';

/// Settings → Data: maps, backup and the debug log (they used to live in the "three dots" menu
/// of the walks screen).
class DataSection extends StatelessWidget {
  const DataSection({super.key});

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _backup(BuildContext context) async {
    _snack(context, t('Готовлю резервную копию…'));
    try {
      final r = await exportBackup();
      await SharePlus.instance.share(ShareParams(files: [XFile(r.file.path)], text: t('Tropa — резервная копия')));
      if (context.mounted) _snack(context, t('Копия: прогулок {n}, точек {p}', {'n': r.sessions, 'p': r.points}));
    } catch (e) {
      DebugLog.instance.log('BACKUP', 'export failed: $e');
      if (context.mounted) _snack(context, t('Не удалось создать копию: {e}', {'e': e}));
    }
  }

  Future<void> _restore(BuildContext context) async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    try {
      final r = await importBackup(File(path));
      if (context.mounted) {
        _snack(context, t('Восстановлено прогулок: {n}, пропущено повторов: {s}, заметок: {m}, маршрутов: {r}',
            {'n': r.sessions, 's': r.skipped, 'm': r.notes, 'r': r.routes}));
      }
      await AppHooks.reloadWalks?.call();
    } catch (e) {
      DebugLog.instance.log('BACKUP', 'import failed: $e');
      if (context.mounted) _snack(context, t('Не удалось восстановить: {e}', {'e': e}));
    }
  }

  /// Quick notes for a test walk: what the person did with the phone and when.
  Future<void> _addMark(BuildContext context) async {
    final presets = [
      t('Режим самолёта ВКЛ'),
      t('Режим самолёта ВЫКЛ'),
      t('Экономия батареи ВКЛ'),
      t('Экономия батареи ВЫКЛ'),
      t('GPS ВКЛ'),
      t('GPS ВЫКЛ'),
      t('Экран погашен'),
      t('Экран включён'),
      t('Телефон в кармане'),
    ];
    final ctl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('Метка в лог')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 6, children: [
              for (final p in presets) ActionChip(label: Text(t(p)), onPressed: () => Navigator.pop(c, p)),
            ]),
            const SizedBox(height: 8),
            TextField(controller: ctl, decoration: InputDecoration(hintText: t('Своя заметка'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Отмена'))),
          TextButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: Text(t('Записать'))),
        ],
      ),
    );
    ctl.dispose();
    if (note != null && note.isNotEmpty) {
      Recorder.instance.mark(note);
      if (context.mounted) _snack(context, t('Метка записана'));
    }
  }

  Future<void> _shareLog() async {
    final path = DebugLog.instance.path;
    if (path == null) return;
    DebugLog.instance.log('LOG', 'shared by user');
    // The log has exact coordinates of the walks in it; the person sends it knowingly (it is a help request).
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: 'Tropa debug log'));
  }

  @override
  Widget build(BuildContext context) {
    final pro = AppSettings.instance.pro;
    Widget tile(IconData icon, String title, String subtitle, VoidCallback onTap) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        );
    return Card(
      child: Column(children: [
        tile(Icons.download_for_offline_outlined, t('Карты'), t('Скачать, обновить или удалить карты регионов'),
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => MapsPage()))),
        tile(Icons.backup_outlined, t('Резервная копия'), t('Сохранить все прогулки и заметки в один файл'), () => _backup(context)),
        tile(Icons.restore, t('Восстановить из копии'), t('Вернуть прогулки из файла копии, без дублей'), () => _restore(context)),
        tile(Icons.bug_report_outlined, t('Отправить лог отладки'), t('Файл для разбора, если запись вела себя странно'), _shareLog),
        if (pro) tile(Icons.bookmark_add_outlined, t('Добавить метку в лог'), t('Пометка о том, что вы сделали с телефоном'), () => _addMark(context)),
        if (pro)
          tile(Icons.delete_sweep_outlined, t('Очистить лог'), t('Удалить записи лога отладки'), () async {
            await DebugLog.instance.clear();
            if (context.mounted) _snack(context, t('Лог очищен'));
          }),
      ]),
    );
  }
}
