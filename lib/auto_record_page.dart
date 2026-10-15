import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'modes.dart';
import 'readiness.dart';
import 'recorder.dart';
import 'settings.dart';

/// Auto-record: recording that starts by itself when the person starts moving, the readiness of the phone for it,
/// and the planner (a reminder, and optionally an automatic start, at a chosen time).
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

class _AutoRecordPageState extends State<AutoRecordPage> with WidgetsBindingObserver {
  static const _sys = MethodChannel('tropa/system');
  List<_PlannedTrip> trips = [];
  ReadinessResult? ready;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _runChecks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _runChecks(); // came back from the system settings
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
    final r = await checkReadiness();
    if (mounted) setState(() => ready = r);
  }

  Future<void> _fix(ReadinessItem i) async {
    await fixReadinessItem(i.id);
    await _runChecks();
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

  /// The switch and what it means, in two lines.
  Widget _statusCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        final on = AppSettings.instance.autoMode;
        return Card(
          color: on ? cs.primaryContainer : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.motion_photos_auto_outlined, color: on ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(t('Начинать запись автоматически'),
                      style: text.titleMedium?.copyWith(color: on ? cs.onPrimaryContainer : null)),
                ),
                Switch(
                  value: on,
                  onChanged: (v) async {
                    await AppSettings.instance.set('auto_mode', v);
                    await Recorder.instance.applyAutoMode();
                  },
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 36, right: 8),
                child: Text(
                  on
                      ? t('Включена. Запись начнётся сама, когда вы пойдёте, и закончится через {n} мин без движения. В остальное время GPS выключен.',
                          {'n': AppSettings.instance.idleMinutes})
                      : t('Выключена. Включите, и запись будет начинаться сама, когда вы пойдёте: нажимать кнопку не придётся.'),
                  style: text.bodySmall?.copyWith(color: on ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  /// "Everything is ready" in one green line, or what to fix (opened by default).
  Widget _readinessCard(BuildContext context) {
    final r = ready;
    final text = Theme.of(context).textTheme;
    if (r == null) return const SizedBox(height: 56, child: Center(child: CircularProgressIndicator()));
    final problems = r.problems.length;
    final title = r.level == ReadyLevel.ready
        ? t('Телефон готов к записи')
        : (r.level == ReadyLevel.blocked ? t('Запись не начнётся: нужно поправить') : t('Можно идти, есть замечания: {n}', {'n': problems}));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey('ready-${r.level.name}-$problems'),
        initiallyExpanded: r.level != ReadyLevel.ready,
        leading: Icon(
          r.level == ReadyLevel.ready ? Icons.check_circle : (r.level == ReadyLevel.warning ? Icons.warning_amber_rounded : Icons.error),
          color: readinessColor(r.level),
        ),
        title: Text(title, style: text.titleSmall),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [ReadinessBody(result: r, onFix: _fix)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('Автозапись'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_alarm),
        label: Text(t('Запланировать')),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _statusCard(context),
        const SizedBox(height: 18),
        Text(t('Готовность'), style: text.titleMedium),
        const SizedBox(height: 6),
        _readinessCard(context),
        const SizedBox(height: 18),
        Text(t('Запланированные прогулки'), style: text.titleMedium),
        const SizedBox(height: 6),
        if (trips.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(t('Пока ничего не запланировано. Запись по расписанию: напоминание или автостарт в нужное время.'),
                style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
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
