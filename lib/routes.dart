import 'dart:math' as math;

import 'debug_log.dart';
import 'package:xml/xml.dart';

/// A route read from a GPX file: the name and the track/route points in order.
class ParsedRoute {
  final String name;
  final List<({double lat, double lon})> points;

  const ParsedRoute(this.name, this.points);
}

/// Reads a GPX document. Track points (`trkpt`) are preferred; if there are none the route
/// points (`rtept`) are used. Waypoints are ignored.
ParsedRoute? parseGpx(String xml, {String fallbackName = 'Маршрут'}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (e) {
    DebugLog.instance.log('ROUTE', 'GPX is not valid XML: $e');
    return null;
  }

  Iterable<XmlElement> byName(String name) => doc.findAllElements(name);

  var elements = byName('trkpt').toList();
  if (elements.isEmpty) elements = byName('rtept').toList();
  final pts = <({double lat, double lon})>[];
  for (final e in elements) {
    final lat = double.tryParse(e.getAttribute('lat') ?? '');
    final lon = double.tryParse(e.getAttribute('lon') ?? '');
    if (lat == null || lon == null) continue;
    if (lat.abs() > 90 || lon.abs() > 180) continue;
    pts.add((lat: lat, lon: lon));
  }
  if (pts.length < 2) return null;

  String? name;
  for (final tag in ['trk', 'rte', 'metadata']) {
    final nameEl = byName(tag).expand((t) => t.findElements('name')).firstOrNull;
    final text = nameEl?.innerText.trim();
    if (text != null && text.isNotEmpty) {
      name = text;
      break;
    }
  }
  return ParsedRoute(name ?? fallbackName, pts);
}

/// A route as a GPX document (a single track, no times): what "Share GPX" of a saved route sends.
String routeToGpx(String name, List<({double lat, double lon})> points) {
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="Tropa" xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('<trk><name>${esc(name)}</name><trkseg>');
  for (final p in points) {
    b.writeln('<trkpt lat="${p.lat.toStringAsFixed(7)}" lon="${p.lon.toStringAsFixed(7)}"></trkpt>');
  }
  b
    ..writeln('</trkseg></trk>')
    ..writeln('</gpx>');
  return b.toString();
}

/// Thins a recorded track to a route: points about [stepM] metres apart (always keeping the first and the last), so
/// a saved route is light and its navigation is not confused by GPS jitter.
List<({double lat, double lon})> thinToRoute(List<({double lat, double lon})> pts, {double stepM = 10}) {
  if (pts.length < 3) return pts;
  final out = [pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    final a = out.last, b = pts[i];
    final dy = (b.lat - a.lat) * 111320;
    final dx = (b.lon - a.lon) * 111320 * math.cos(a.lat * math.pi / 180); // a degree of longitude shrinks with latitude
    if (dx * dx + dy * dy >= stepM * stepM) out.add(b);
  }
  out.add(pts.last);
  return out;
}
