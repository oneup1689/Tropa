import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'l10n.dart';

/// "Is the phone ready to record?" The indicator on the start card shows the answer, the sheet behind it shows
/// what is wrong and fixes it in one tap. The decision itself ([evaluateReadiness]) is plain code on a snapshot of the
/// phone state, so it can be tested without a phone.
enum ReadyLevel { ready, warning, blocked }

enum LocationAccess { none, whileInUse, always }

/// What the phone says right now. Fields that do not exist on a platform are null.
class ReadinessSnapshot {
  final bool gpsOn;
  final LocationAccess location;
  final bool? notifications; // Android 13+: the notification permission
  final bool? batteryUnrestricted; // Android: the app is exempt from battery optimisation
  final int? batteryPercent;
  final bool? batterySaver;

  const ReadinessSnapshot({
    required this.gpsOn,
    required this.location,
    this.notifications,
    this.batteryUnrestricted,
    this.batteryPercent,
    this.batterySaver,
  });
}

/// One line of the check: what it is about, whether it is fine, and (if not) what to do.
class ReadinessItem {
  final String id;
  final bool ok;
  final bool blocker; // true: a recording cannot start (or will not record anything) until it is fixed
  final String title;
  final String detail;
  final String shortLabel; // for the pill, capitals
  final String? fixLabel;

  const ReadinessItem({
    required this.id,
    required this.ok,
    required this.blocker,
    required this.title,
    required this.detail,
    required this.shortLabel,
    this.fixLabel,
  });
}

class ReadinessResult {
  final ReadyLevel level;
  final List<ReadinessItem> items;

  const ReadinessResult(this.level, this.items);

  List<ReadinessItem> get problems => [for (final i in items) if (!i.ok) i];

  /// The text of the pill on the start card.
  String get label {
    switch (level) {
      case ReadyLevel.ready:
        return t('ГОТОВ К ПРОГУЛКЕ');
      case ReadyLevel.blocked:
        return problems.firstWhere((i) => i.blocker).shortLabel;
      case ReadyLevel.warning:
        return t('ЕСТЬ ЗАМЕЧАНИЯ: {n}', {'n': problems.length});
    }
  }
}

/// Turns the snapshot into the list of checks, most important first, and the overall level.
ReadinessResult evaluateReadiness(ReadinessSnapshot s) {
  final items = <ReadinessItem>[];

  items.add(s.gpsOn
      ? ReadinessItem(id: 'gps', ok: true, blocker: true, title: t('GPS включён'), detail: '', shortLabel: '')
      : ReadinessItem(
          id: 'gps',
          ok: false,
          blocker: true,
          title: t('GPS выключен'),
          detail: t('Без GPS маршрут не запишется. Включите геолокацию в настройках телефона.'),
          shortLabel: t('GPS ВЫКЛЮЧЕН'),
          fixLabel: t('Включить'),
        ));

  switch (s.location) {
    case LocationAccess.none:
      items.add(ReadinessItem(
        id: 'location',
        ok: false,
        blocker: true,
        title: t('Нет доступа к геолокации'),
        detail: t('Разрешите Tropa определять местоположение, иначе запись не начнётся.'),
        shortLabel: t('НЕТ ДОСТУПА К GPS'),
        fixLabel: t('Разрешить'),
      ));
    case LocationAccess.whileInUse:
      items.add(ReadinessItem(
        id: 'location',
        ok: false,
        blocker: false,
        title: t('Геолокация только при открытом приложении'),
        detail: t('Выберите «Разрешить всегда»: иначе запись может оборваться, когда экран погаснет.'),
        shortLabel: '',
        fixLabel: t('Открыть настройки'),
      ));
    case LocationAccess.always:
      items.add(ReadinessItem(id: 'location', ok: true, blocker: false, title: t('Геолокация «Всегда»'), detail: '', shortLabel: ''));
  }

  if (s.notifications != null) {
    items.add(s.notifications!
        ? ReadinessItem(id: 'notifications', ok: true, blocker: false, title: t('Уведомления разрешены'), detail: '', shortLabel: '')
        : ReadinessItem(
            id: 'notifications',
            ok: false,
            blocker: false,
            title: t('Уведомления выключены'),
            detail: t('Во время записи Tropa показывает уведомление. Без него вы не увидите статус, а система охотнее остановит запись.'),
            shortLabel: '',
            fixLabel: t('Разрешить'),
          ));
  }

  if (s.batteryUnrestricted != null) {
    items.add(s.batteryUnrestricted!
        ? ReadinessItem(id: 'battery_opt', ok: true, blocker: false, title: t('Без ограничений батареи'), detail: '', shortLabel: '')
        : ReadinessItem(
            id: 'battery_opt',
            ok: false,
            blocker: false,
            title: t('Включена экономия батареи для Tropa'),
            detail: t('Система может остановить запись при погашенном экране. Разрешите работу без ограничений.'),
            shortLabel: '',
            fixLabel: t('Разрешить'),
          ));
  }

  if (s.batterySaver == true) {
    items.add(ReadinessItem(
      id: 'saver',
      ok: false,
      blocker: false,
      title: t('Включён режим энергосбережения'),
      detail: t('Он может ограничивать GPS и работу в фоне. На время прогулки лучше его выключить.'),
      shortLabel: '',
    ));
  }

  final pct = s.batteryPercent;
  if (pct != null && pct < 15) {
    items.add(ReadinessItem(
      id: 'charge',
      ok: false,
      blocker: false,
      title: t('Низкий заряд батареи: {p} %', {'p': pct}),
      detail: t('GPS быстро разряжает телефон. Зарядите его или возьмите павербанк.'),
      shortLabel: '',
    ));
  }

  final level = items.any((i) => !i.ok && i.blocker)
      ? ReadyLevel.blocked
      : items.any((i) => !i.ok)
          ? ReadyLevel.warning
          : ReadyLevel.ready;
  return ReadinessResult(level, items);
}

/// Asks the phone. Never throws: what cannot be read is left out of the snapshot.
Future<ReadinessSnapshot> loadReadinessSnapshot() async {
  final gpsOn = await Geolocator.isLocationServiceEnabled();
  final perm = await Geolocator.checkPermission();
  final location = switch (perm) {
    LocationPermission.always => LocationAccess.always,
    LocationPermission.whileInUse => LocationAccess.whileInUse,
    _ => LocationAccess.none,
  };
  bool? notifications, batteryUnrestricted;
  if (Platform.isAndroid) {
    try {
      notifications = await Permission.notification.isGranted;
      batteryUnrestricted = await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {}
  }
  int? percent;
  bool? saver;
  try {
    final b = Battery();
    percent = await b.batteryLevel;
    saver = await b.isInBatterySaveMode;
    // A phone that is charging is fine even when low.
    if ((await b.batteryState) == BatteryState.charging) percent = null;
  } catch (_) {}
  return ReadinessSnapshot(
    gpsOn: gpsOn,
    location: location,
    notifications: notifications,
    batteryUnrestricted: batteryUnrestricted,
    batteryPercent: percent,
    batterySaver: saver,
  );
}

Future<ReadinessResult> checkReadiness() async => evaluateReadiness(await loadReadinessSnapshot());

/// The fix behind the button of one item.
Future<void> fixReadinessItem(String id) async {
  switch (id) {
    case 'gps':
      await Geolocator.openLocationSettings();
    case 'location':
      final cur = await Geolocator.checkPermission();
      if (cur == LocationPermission.whileInUse) {
        // Android 11+ grants "Always" only from the settings screen.
        final r = await Permission.locationAlways.request();
        if (!r.isGranted) await openAppSettings();
      } else {
        final r = await Permission.locationWhenInUse.request();
        if (r.isPermanentlyDenied) await openAppSettings();
      }
    case 'notifications':
      final r = await Permission.notification.request();
      if (r.isPermanentlyDenied) await openAppSettings();
    case 'battery_opt':
      await Permission.ignoreBatteryOptimizations.request();
  }
}

Color readinessColor(ReadyLevel l) => switch (l) {
      ReadyLevel.ready => const Color(0xFF69F0AE),
      ReadyLevel.warning => Colors.amber,
      ReadyLevel.blocked => const Color(0xFFFF5252),
    };

/// The sheet behind the indicator: the verdict, the problems with their fix buttons, then what is fine.
class ReadinessSheet extends StatefulWidget {
  final ReadinessResult initial;
  final ValueChanged<ReadinessResult> onChanged;

  const ReadinessSheet({super.key, required this.initial, required this.onChanged});

  @override
  State<ReadinessSheet> createState() => _ReadinessSheetState();
}

class _ReadinessSheetState extends State<ReadinessSheet> with WidgetsBindingObserver {
  late ReadinessResult result = widget.initial;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // came back from the system settings
  }

  Future<void> _refresh() async {
    final r = await checkReadiness();
    if (!mounted) return;
    setState(() => result = r);
    widget.onChanged(r);
  }

  Future<void> _fix(ReadinessItem i) async {
    await fixReadinessItem(i.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final title = switch (result.level) {
      ReadyLevel.ready => t('Всё готово к прогулке'),
      ReadyLevel.warning => t('Можно идти, но есть замечания'),
      ReadyLevel.blocked => t('Запись не начнётся'),
    };
    final color = readinessColor(result.level);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(result.level == ReadyLevel.ready ? Icons.check_circle : (result.level == ReadyLevel.warning ? Icons.warning_amber_rounded : Icons.error),
                color: color, size: 30),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: tt.titleLarge)),
          ]),
          const SizedBox(height: 14),
          for (final i in result.problems)
            Card(
              color: i.blocker ? cs.errorContainer : cs.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(i.blocker ? Icons.error_outline : Icons.warning_amber_rounded, size: 20, color: i.blocker ? cs.error : Colors.amber.shade800),
                    const SizedBox(width: 8),
                    Expanded(child: Text(i.title, style: tt.titleSmall)),
                  ]),
                  const SizedBox(height: 4),
                  Text(i.detail, style: tt.bodySmall),
                  if (i.fixLabel != null) ...[
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: FilledButton.tonal(onPressed: () => _fix(i), child: Text(i.fixLabel!))),
                  ],
                ]),
              ),
            ),
          if (result.items.any((i) => i.ok)) ...[
            const SizedBox(height: 6),
            for (final i in result.items.where((i) => i.ok))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  const Icon(Icons.check_circle, size: 20, color: Color(0xFF2E9E6B)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(i.title, style: tt.bodyMedium)),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}
