import 'l10n.dart';
/// How the person travels. Drives filters, GPS rate, gap-healing limits and statistics.
/// [car] means any motor transport (car, scooter); [water] is rafting, kayaking and boats.
enum TravelMode { walk, bike, car, water, mixed }

extension TravelModeInfo on TravelMode {
  String get label => switch (this) {
        TravelMode.walk => t('Пешком'),
        TravelMode.bike => t('Велосипед'),
        TravelMode.car => t('Транспорт'),
        TravelMode.water => t('Сплав / вода'),
        TravelMode.mixed => t('Смешанный'),
      };

  /// Value stored in the database.
  String get code => name;

  static TravelMode parse(String? code) =>
      TravelMode.values.firstWhere((m) => m.name == code, orElse: () => TravelMode.mixed);
}

/// Recording parameters derived from the travel mode.
class ModeProfile {
  /// GPS request interval while moving, in milliseconds.
  final int intervalMs;

  /// A jump faster than this (m/s) with poor accuracy is treated as a GPS glitch.
  final double jumpSpeedMs;

  /// Below this speed (m/s) the person counts as standing (pause).
  final double movingSpeedMs;

  const ModeProfile(this.intervalMs, this.jumpSpeedMs, this.movingSpeedMs);
}

ModeProfile profileOf(TravelMode m) => switch (m) {
      TravelMode.walk => const ModeProfile(2000, 10, 0.4),
      TravelMode.bike => const ModeProfile(2000, 25, 0.8),
      TravelMode.car => const ModeProfile(1000, 70, 2.0),
      TravelMode.water => const ModeProfile(2000, 15, 0.3),
      TravelMode.mixed => const ModeProfile(2000, 70, 0.5),
    };
