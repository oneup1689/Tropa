import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'maps.dart';
import 'modes.dart';
import 'recorder.dart';
import 'settings.dart';
import 'l10n.dart';

/// Auto-record: recording that starts by itself when the person starts moving (24/7), and the planner: a reminder (and optionally an automatic start of the recording) at a chosen time,
/// plus a readiness checklist so nothing is forgotten before leaving.
class AutoRecordPage extends StatefulWidget {
  const AutoRecordPage({super.key});

  @override
  State<AutoRecordPage> createState() => _AutoRecordPageState();
}

class _PlannedTrip {
  final int id;
  final int atMs;
  final String title;
  final bool autoStart;
  final String mode;

  _PlannedTrip(this.id, this.atMs, this.title, this.autoStart, this.mode);

  Map<String, Object?> toJson() => {'id': id, 'atMs': atMs, 'title': title, 'autoStart': autoStart, 'mode': mode};

  static _PlannedTrip fromJson(Map<String, dynamic> m) => _PlannedTrip(
        m['id'] as int,
        m['atMs'] as int,
        (m['title'] as String?) ?? '',
        m['autoStart'] == true,
        (m['mode'] as String?) ?? 'mixed',
      );
}

class _Check {
  final String label;
  final bool ok;
  final String? hint;
  final Future<void> Function()? fix;

  _Check(this.label, this.ok, {this.hint, this.fix});
}

class _AutoRecordPageState extends State<AutoRecordPage> {
  static const _sys = MethodChannel('tropa/system');
  List<_PlannedTrip> trips = [];
  List<_Check> checks = [];

  @override
  void initState() {
    super.initState();
    _load();
    _runChecks();
  }

  void _load() {
    final raw = AppSettings.instance.raw('trips');
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = <_PlannedTrip>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final trip = _PlannedTrip.fromJson(e);
          if (trip.atMs > now) list.add(trip);
        }
      }
    }
    list.sort((a, b) => a.atMs.compareTo(b.atMs));
    setState(() => trips = list);
  }

  Future<void> _store() => AppSettings.instance.set('trips', [for (final trip in trips) trip.toJson()]);

  Future<void> _runChecks() async {
    final list = <_Check>[];
    final regions = await MapStore.regions();
    list.add(_Check(t('Загружена офлайн-карта'), regions.isNotEmpty,
        hint: regions.isEmpty ? t('Добавьте карту в разделе «Карты»') : t('{p0} шт.', {'p0': regions.length})));

    try {
      final level = await Battery().batteryLevel;
      list.add(_Check(t('Заряд батареи не ниже 50 %'), level >= 50, hint: t('Сейчас {p0} %', {'p0': level})));
    } catch (_) {}

    final gps = await Geolocator.isLocationServiceEnabled();
    list.add(_Check(t('GPS включён'), gps, fix: gps ? null : Geolocator.openLocationSettings));

    final always = await Permission.locationAlways.isGranted;
    list.add(_Check(t('Геолокация «Всегда»'), always,
        hint: always ? null : t('Нужна для записи с погашенным экраном'),
        fix: always ? null : () async => openAppSettings()));

    final notif = await Permission.notification.isGranted;
    list.add(_Check(t('Уведомления разрешены'), notif, fix: notif ? null : () async => Permission.notification.request()));

    if (Platform.isAndroid) {
      final batt = await Permission.ignoreBatteryOptimizations.isGranted;
      list.add(_Check(t('Без ограничений батареи'), batt,
          hint: batt ? null : t('Иначе система может остановить запись'),
          fix: batt ? null : () async => Permission.ignoreBatteryOptimizations.request()));
    }
    if (mounted) setState(() => checks = list);
  }

  Future<void> _add() async {
    final title = TextEditingController(text: t('Прогулка'));
    var mode = AppSettings.instance.travelMode;
    var auto = true;
    var when = DateTime.now().add(const Duration(hours: 1));

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: Text(t('Новая прогулка')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: title, decoration: InputDecoration(labelText: t('Название'))),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text(_fmt(when)),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: c,
                    initialDate: when,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (d == null || !c.mounted) return;
                  final picked = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(when));
                  if (picked == null) return;
                  setS(() => when = DateTime(d.year, d.month, d.day, picked.hour, picked.minute));
                },
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: [
                for (final m in TravelMode.values)
                  ChoiceChip(label: Text(m.label), selected: mode == m, onSelected: (_) => setS(() => mode = m)),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t('Начать запись автоматически')),
                subtitle: Text(t('Если система не разрешит, придёт напоминание')),
                value: auto,
                onChanged: (v) => setS(() => auto = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Отмена'))),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Запланировать'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (when.isBefore(DateTime.now())) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Время уже прошло'))));
      return;
    }
    final id = (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 1000000000;
    final trip = _PlannedTrip(id, when.millisecondsSinceEpoch, title.text.trim(), auto, mode.code);
    await _sys.invokeMethod('scheduleTrip', trip.toJson());
    trips.add(trip);
    trips.sort((a, b) => a.atMs.compareTo(b.atMs));
    await _store();
    if (mounted) setState(() {});
  }

  Future<void> _cancel(_PlannedTrip trip) async {
    await _sys.invokeMethod('cancelTrip', {'id': trip.id});
    trips.removeWhere((x) => x.id == trip.id);
    await _store();
    if (mounted) setState(() {});
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('Автозапись'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_alarm),
        label: Text(t('Запланировать')),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // Two ways to record without pressing the button: when the person starts moving (24/7), and at a set time.
        ListenableBuilder(
          listenable: AppSettings.instance,
          builder: (context, _) => Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.motion_photos_auto_outlined),
              title: Text(t('Писать сам, когда начну двигаться')),
              subtitle: Text(t(
                  'Запись начнётся сама, когда вы пойдёте, и закончится после нескольких минут без движения. В остальное время GPS выключен и батарея почти не тратится.')),
              value: AppSettings.instance.autoMode,
              onChanged: (v) async {
                await AppSettings.instance.set('auto_mode', v);
                await Recorder.instance.applyAutoMode();
              },
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(t('Готовность к прогулке'), style: Theme.of(context).textTheme.titleMedium),
        for (final c in checks)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(c.ok ? Icons.check_circle : Icons.error_outline,
                color: c.ok ? Colors.green : Theme.of(context).colorScheme.error),
            title: Text(c.label),
            subtitle: c.hint == null ? null : Text(c.hint!),
            trailing: c.fix == null
                ? null
                : TextButton(
                    onPressed: () async {
                      await c.fix!();
                      await _runChecks();
                    },
                    child: Text(t('Исправить')),
                  ),
          ),
        const Divider(),
        Text(t('Запланированные прогулки'), style: Theme.of(context).textTheme.titleMedium),
        if (trips.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(t('Пока ничего не запланировано'))),
        for (final trip in trips)
          Card(
            child: ListTile(
              leading: const Icon(Icons.alarm),
              title: Text(trip.title.isEmpty ? t('Прогулка') : trip.title),
              subtitle: Text(
                  '${_fmt(DateTime.fromMillisecondsSinceEpoch(trip.atMs))} · ${t(TravelModeInfo.parse(trip.mode).label)}'
                  '${trip.autoStart ? t(' · автостарт') : ''}'),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => _cancel(trip)),
            ),
          ),
        const SizedBox(height: 72),
      ]),
    );
  }
}
