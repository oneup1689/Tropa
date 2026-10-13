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
