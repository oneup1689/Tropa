import 'l10n.dart';

enum UnitSystem { metric, imperial }

/// Distances, speeds, paces and heights in kilometres or miles. Everything is stored and calculated in metres and
/// seconds; only the display is converted here.
class Units {
  Units._();

  static UnitSystem system = UnitSystem.metric;

  static bool get imperial => system == UnitSystem.imperial;

  static const double _mile = 1609.344;
  static const double _foot = 0.3048;

  /// Imperial units exist only in the English interface (the Russian one is always metric), so they are English.
  static String get kmUnit => imperial ? 'mi' : t('км');

  static String get shortDistUnit => imperial ? 'ft' : t('м');

  static String get speedUnit => imperial ? 'mph' : t('км/ч');

  static String get paceUnit => imperial ? 'min/mi' : t('мин/км');

  static double toLong(double meters) => imperial ? meters / _mile : meters / 1000;

  /// "12.34 км" / "7.67 mi".
  static String dist(double meters, {int digits = 2}) => '${toLong(meters).toStringAsFixed(digits)} $kmUnit';

  /// A round figure for goals: "5 км", "2.5 км", "3 mi".
  static String distTrim(double meters) {
    final v = toLong(meters);
    return '${v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1)} $kmUnit';
  }

  /// Short distances: "150 м" / "492 ft".
  static String shortDist(double meters) => '${(imperial ? meters / _foot : meters).round()} $shortDistUnit';

  /// Height above sea level or climb: "126 м" / "413 ft".
  static String height(double meters) => shortDist(meters);

  static String heightSigned(double meters) => '${meters >= 0 ? '+' : '-'}${shortDist(meters.abs())}';

  /// Speed from metres per second: "30.0 км/ч" / "18.6 mph".
  static String speed(double metersPerSecond, {int digits = 1}) =>
      '${(imperial ? metersPerSecond * 2.2369363 : metersPerSecond * 3.6).toStringAsFixed(digits)} $speedUnit';

  static double speedValue(double metersPerSecond) => imperial ? metersPerSecond * 2.2369363 : metersPerSecond * 3.6;

  /// Pace as "15:08 мин/км" / "24:21 min/mi", from the pace in minutes per kilometre.
  static String pace(double minPerKm) {
    final v = imperial ? minPerKm * 1.609344 : minPerKm;
    final m = v.floor();
    final s = ((v - m) * 60).round();
    final carry = s == 60;
    return '${carry ? m + 1 : m}:${(carry ? 0 : s).toString().padLeft(2, '0')} $paceUnit';
  }

  /// Pro setting: temperature unit chosen separately from miles (null = follows the distance units).
  static bool? fahrenheitOverride;

  static bool get fahrenheit => fahrenheitOverride ?? imperial;

  /// Temperature: "29°" or "84°F".
  static String temp(double celsius, {int digits = 0}) =>
      fahrenheit ? '${(celsius * 9 / 5 + 32).toStringAsFixed(digits)}°F' : '${celsius.toStringAsFixed(digits)}°'; // °F is the same in both languages

  /// Precipitation from millimetres: "1.2 мм" / "0.05 in".
  static String precip(double mm) => imperial
      ? '${(mm / 25.4).toStringAsFixed(2)} in'
      : '${mm.toStringAsFixed(1)} ${t('мм')}';

  /// The pace without the unit ("15:08").
  static String paceValue(double minPerKm) => pace(minPerKm).split(' ').first;
}
