import 'modes.dart';

/// Rough time to cover a route: by length at the pace of the travel mode, plus Naismith's rule for climbing
/// (one more hour per 600 m of ascent on foot) when the ascent is known.
Duration estimateRouteTime(double lengthM, {double? ascentM, TravelMode mode = TravelMode.walk}) {
  final bike = mode == TravelMode.bike;
  final car = mode == TravelMode.car;
  final speedKmh = car ? 40.0 : (bike ? 15.0 : 4.5);
  var hours = lengthM / 1000 / speedKmh;
  if (ascentM != null && ascentM > 0 && !car) hours += ascentM / (bike ? 400 : 600);
  return Duration(seconds: (hours * 3600).round());
}
