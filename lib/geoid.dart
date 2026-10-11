import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// EGM96 geoid undulation N (metres): height of mean sea level above the WGS84 ellipsoid.
/// Phones report GPS altitude above the ellipsoid, so sea-level altitude is `altitude - N`.
/// (In Vietnam N is about -25 m, which is why raw altitudes looked negative.)
///
/// The grid is a 0.5 degree int16 table in centimetres, converted from the public EGM96 data.
class Geoid {
  Geoid._();
  static final Geoid instance = Geoid._();

  Int16List? _grid;
  double _latTop = 90;
  double _lonLeft = -180;
  double _step = 0.5;
  int _rows = 0;
  int _cols = 0;

  bool get loaded => _grid != null;

  Future<void> load() async {
    try {
      loadFromBytes(await rootBundle.load('assets/geoid/egm96_half_deg.bin'));
    } catch (_) {
      // Without the table the undulation is treated as 0 (altitude stays ellipsoidal).
    }
  }

  void loadFromBytes(ByteData data) {
    final header = Float32List.view(data.buffer, data.offsetInBytes, 4);
    _latTop = header[0];
    _lonLeft = header[1];
    _step = header[2];
    _cols = (360 / _step).round();
    final count = (data.lengthInBytes - 16) ~/ 2;
    _rows = count ~/ _cols;
    final bytes = data.buffer.asUint8List(data.offsetInBytes + 16, count * 2);
    // Copy to guarantee alignment for the Int16 view.
    _grid = Uint8List.fromList(bytes).buffer.asInt16List();
  }

  /// Bilinear interpolation; 0 when the table is not loaded.
  double undulation(double lat, double lon) {
    final g = _grid;
    if (g == null) return 0;
    final r = (_latTop - lat) / _step;
    final c = (((lon - _lonLeft) % 360) + 360) % 360 / _step;
    final r0 = r.floor().clamp(0, _rows - 1);
    final c0 = c.floor() % _cols;
    final dr = (r - r0).clamp(0.0, 1.0), dc = c - c.floor();
    final r1 = math.min(r0 + 1, _rows - 1);
    final c1 = (c0 + 1) % _cols;
    double at(int rr, int cc) => g[rr * _cols + cc] / 100.0;
    return at(r0, c0) * (1 - dr) * (1 - dc) +
        at(r0, c1) * (1 - dr) * dc +
        at(r1, c0) * dr * (1 - dc) +
        at(r1, c1) * dr * dc;
  }
}
