import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'brand.dart';

/// Small helpers shared by the maps: GeoJSON pieces for the style overlay, and the marker pictures.

Map<String, Object?> geoFc(List<Map<String, Object?>> features) => {'type': 'FeatureCollection', 'features': features};

Map<String, Object?> geoLine(List<LatLng> pts) => {
      'type': 'Feature',
      'properties': <String, Object?>{},
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (final p in pts) [p.longitude, p.latitude],
        ],
      },
    };

Map<String, Object?> geoPoint(LatLng p, {String color = '#E53935', double radius = 8, String label = ''}) => {
      'type': 'Feature',
      'properties': {'color': color, 'r': radius, 'label': label},
      'geometry': {
        'type': 'Point',
        'coordinates': [p.longitude, p.latitude],
      },
    };

/// The marker pictures in the colours of the app: an orange arrow with a sand outline and a soft shadow (when the
/// direction is known), or an orange dot with a sand ring.
Future<Uint8List> locatorMarkerPng({required bool arrow}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  const mid = Offset(48, 48);
  if (arrow) {
    final shape = Path()
      ..moveTo(48, 12)
      ..lineTo(70, 78)
      ..lineTo(48, 64)
      ..lineTo(26, 78)
      ..close();
    c.drawPath(shape.shift(const Offset(0, 3)), Paint()..color = const Color(0x40000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    c.drawPath(
      shape,
      Paint()
        ..color = brandSand
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeJoin = StrokeJoin.round,
    );
    c.drawPath(shape, Paint()..color = brandAccent);
  } else {
    c.drawCircle(mid + const Offset(0, 2.5), 22, Paint()..color = const Color(0x40000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    c.drawCircle(mid, 22, Paint()..color = brandSand);
    c.drawCircle(mid, 14, Paint()..color = brandAccent);
  }
  final img = await rec.endRecording().toImage(96, 96);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}
