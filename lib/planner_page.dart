import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'maps.dart';
import 'modes.dart';
import 'settings.dart';

/// Trip planner: a reminder (and optionally an automatic start of the recording) at a chosen time,
/// plus a readiness checklist so nothing is forgotten before leaving.
class PlannerPage extends StatefulWidget {
  const PlannerPage({super.key});

  @override
  State<PlannerPage> createState() => _PlannerPageState();
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

class _PlannerPageState extends State<PlannerPage> {
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
          final t = _PlannedTrip.fromJson(e);
          if (t.atMs > now) list.add(t);
        }
      }
    }
    list.sort((a, b) => a.atMs.compareTo(b.atMs));
    setState(() => trips = list);
  }

  Future<void> _store() => AppSettings.instance.set('trips', [for (final t in trips) t.toJson()]);

  Future<void> _runChecks() async {
    final list = <_Check>[];
    final regions = await MapStore.regions();
    list.add(_Check('Загружена офлайн-карта', regions.isNotEmpty,
        hint: regions.isEmpty ? 'Добавьте карту в разделе «Карты»' : '${regions.length} шт.'));

    try {
      final level = await Battery().batteryLevel;
      list.add(_Check('Заряд батареи не ниже 50 %', level >= 50, hint: 'Сейчас $level %'));
    } catch (_) {}

    final gps = await Geolocator.isLocationServiceEnabled();
    list.add(_Check('GPS включён', gps, fix: gps ? null : Geolocator.openLocationSettings));

    final always = await Permission.locationAlways.isGranted;
    list.add(_Check('Геолокация «Всегда»', always,
        hint: always ? null : 'Нужна для записи с погашенным экраном',
        fix: always ? null : () async => openAppSettings()));

    final notif = await Permission.notification.isGranted;
    list.add(_Check('Уведомления разрешены', notif, fix: notif ? null : () async => Permission.notification.request()));

    if (Platform.isAndroid) {
      final batt = await Permission.ignoreBatteryOptimizations.isGranted;
      list.add(_Check('Без ограничений батареи', batt,
          hint: batt ? null : 'Иначе система может остановить запись',
          fix: batt ? null : () async => Permission.ignoreBatteryOptimizations.request()));
    }
    if (mounted) setState(() => checks = list);
  }

  Future<void> _add() async {
    final title = TextEditingController(text: 'Прогулка');
    var mode = AppSettings.instance.travelMode;
    var auto = true;
    var when = DateTime.now().add(const Duration(hours: 1));

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: const Text('Новая прогулка'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Название')),
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
                  final t = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(when));
                  if (t == null) return;
                  setS(() => when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
                },
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: [
                for (final m in TravelMode.values)
                  ChoiceChip(label: Text(m.label), selected: mode == m, onSelected: (_) => setS(() => mode = m)),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Начать запись автоматически'),
                subtitle: const Text('Если система не разрешит, придёт напоминание'),
                value: auto,
                onChanged: (v) => setS(() => auto = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Запланировать')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (when.isBefore(DateTime.now())) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Время уже прошло')));
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

  Future<void> _cancel(_PlannedTrip t) async {
    await _sys.invokeMethod('cancelTrip', {'id': t.id});
    trips.removeWhere((x) => x.id == t.id);
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
      appBar: AppBar(title: const Text('Планировщик')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_alarm),
        label: const Text('Запланировать'),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Готовность к прогулке', style: Theme.of(context).textTheme.titleMedium),
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
                    child: const Text('Исправить'),
                  ),
          ),
        const Divider(),
        Text('Запланированные прогулки', style: Theme.of(context).textTheme.titleMedium),
        if (trips.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Пока ничего не запланировано')),
        for (final t in trips)
          Card(
            child: ListTile(
              leading: const Icon(Icons.alarm),
              title: Text(t.title.isEmpty ? 'Прогулка' : t.title),
              subtitle: Text(
                  '${_fmt(DateTime.fromMillisecondsSinceEpoch(t.atMs))} · ${TravelModeInfo.parse(t.mode).label}'
                  '${t.autoStart ? ' · автостарт' : ''}'),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => _cancel(t)),
            ),
          ),
        const SizedBox(height: 72),
      ]),
    );
  }
}
