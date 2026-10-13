import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_log.dart';
import 'map_downloads.dart';
import 'l10n.dart';

/// Geographic bounds stored in the header of a .pmtiles file.
class RegionBounds {
  final double minLon, minLat, maxLon, maxLat;

  const RegionBounds(this.minLon, this.minLat, this.maxLon, this.maxLat);

  bool contains(double lat, double lon) => lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;
}

class MapRegion {
  final File file;
  final RegionBounds? bounds;

  /// Present for maps downloaded in the app (name, area, date of the data); null for files copied by hand.
  final RegionMeta? meta;

  const MapRegion(this.file, this.bounds, [this.meta]);

  String get name => meta?.name ?? p.basenameWithoutExtension(file.path);
  int get sizeBytes => file.lengthSync();
}

/// Offline map files (.pmtiles) and the assets needed to draw them (style, fonts).
///
/// Region files live in the phone's shared app folder (Android/data/app.tropa.tropa/files/maps), so
/// they can be copied there from a computer with a cable, or added with "Добавить карту".
class MapStore {
  MapStore._();

  /// Set when the last listing of the regions folder failed; the maps screen shows it.
  static String? lastListError;

  static Future<Directory> regionsDir() async {
    Directory base;
    try {
      base = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'maps'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<List<MapRegion>> regions() async {
    final dir = await regionsDir();
    final out = <MapRegion>[];
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.pmtiles')) out.add(MapRegion(e, await readBounds(e), await readRegionMeta(e)));
      }
    } on FileSystemException catch (e) {
      // The folder exists but cannot be read (e.g. created by another user): report instead of crashing.
      DebugLog.instance.log('MAP', 'cannot list ${dir.path}: $e');
      lastListError = t('Нет доступа к папке с картами: {p0}', {'p0': e.osError?.message ?? e.message});
      return out;
    }
    lastListError = null;
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// PMTiles v3 header: bounds are four int32 values (x1e7) at offset 102.
  static Future<RegionBounds?> readBounds(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      final head = await raf.read(127);
      if (head.length < 127 || String.fromCharCodes(head.sublist(0, 7)) != 'PMTiles') return null;
      final bd = ByteData.sublistView(Uint8List.fromList(head));
      double v(int off) => bd.getInt32(off, Endian.little) / 1e7;
      return RegionBounds(v(102), v(106), v(110), v(114));
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// The installed region that covers the point, if any.
  static Future<MapRegion?> regionFor(double lat, double lon) async {
    for (final r in await regions()) {
      if (r.bounds?.contains(lat, lon) ?? false) return r;
    }
    return null;
  }

  /// Moves a picked file into the regions folder (a move is instant; a copy is the fallback).
  static Future<MapRegion?> importRegion(File picked, {String? name}) async {
    final dir = await regionsDir();
    final target = File(p.join(dir.path, name ?? p.basename(picked.path)));
    if (await target.exists()) await target.delete();
    try {
      await picked.rename(target.path);
    } on FileSystemException {
      await picked.copy(target.path);
      try {
        await picked.delete();
      } catch (_) {}
    }
    return MapRegion(target, await readBounds(target));
  }

  static Future<void> deleteRegion(MapRegion r) async {
    await r.file.delete();
    final meta = metaFileFor(r.file);
    if (await meta.exists()) await meta.delete();
  }

  // ------------------------------------------------------------ style and fonts

  static Future<Directory> _assetDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'map'));
  }

  /// Copies the bundled glyph (font) files to the file system once; MapLibre reads them from there.
  static Future<void> prepareFonts() async {
    final root = await _assetDir();
    final stamp = File(p.join(root.path, 'fonts_v2.ok'));
    if (await stamp.exists()) return;
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final fonts = manifest.listAssets().where((a) => a.startsWith('assets/map/fonts/') && a.endsWith('.pbf'));
    var n = 0;
    for (final asset in fonts) {
      final rel = asset.substring('assets/map/'.length);
      final out = File(p.join(root.path, rel));
      await out.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      await out.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      n++;
    }

    // MapLibre waits for every glyph range a label needs. Labels in scripts we did not bundle (Chinese,
    // Thai, ...) would otherwise never finish and the whole tile would show no text at all, so every
    // missing range gets an empty (but valid) glyph file: those characters are simply skipped.
    var stubs = 0;
    final fontsDir = Directory(p.join(root.path, 'fonts'));
    if (await fontsDir.exists()) {
      await for (final fontDir in fontsDir.list()) {
        if (fontDir is! Directory) continue;
        final fontName = p.basename(fontDir.path);
        for (var start = 0; start < 65536; start += 256) {
          final range = '$start-${start + 255}';
          final f = File(p.join(fontDir.path, '$range.pbf'));
          if (await f.exists()) continue;
          await f.writeAsBytes(_emptyGlyphRange(fontName, range));
          stubs++;
        }
      }
    }
    await root.create(recursive: true);
    await stamp.writeAsString('$n+$stubs');
    DebugLog.instance.log('MAP', 'map fonts prepared: $n files, $stubs empty ranges');
  }

  /// A valid glyph PBF with a font stack header and no glyphs.
  static List<int> _emptyGlyphRange(String fontName, String range) {
    final name = utf8.encode(fontName), rng = utf8.encode(range);
    final stack = [0x0a, name.length, ...name, 0x12, rng.length, ...rng];
    return [0x0a, stack.length, ...stack];
  }

  /// Complete style JSON for the region, with the local file paths filled in.
  static Future<String> styleFor(MapRegion region, {required bool dark}) async {
    await prepareFonts();
    final root = await _assetDir();
    final template = await rootBundle.loadString('assets/map/style_${dark ? 'dark' : 'light'}.json');
    final fontsUrl = 'file://${p.join(root.path, 'fonts').replaceAll(r'\', '/')}';
    final tilesUrl = 'file://${region.file.path.replaceAll(r'\', '/')}';
    return template.replaceAll('{{PMTILES}}', tilesUrl).replaceAll('{{FONTS}}', fontsUrl);
  }

  /// Style of the region plus extra GeoJSON sources and layers (the track, notes, ...), written to a file.
  /// The map must be given the *file path*: the share picture is rendered by the plugin's snapshotter,
  /// which re-reads the style from that path, so everything drawn has to live inside the style itself.
  static Future<String> writeStyleWithOverlay(
    MapRegion region, {
    required bool dark,
    required Map<String, Object?> sources,
    required List<Map<String, Object?>> layers,
  }) async {
    final style = jsonDecode(await styleFor(region, dark: dark)) as Map<String, dynamic>;
    (style['sources'] as Map<String, dynamic>).addAll(sources.map((k, v) => MapEntry(k, v)));
    (style['layers'] as List<dynamic>).addAll(layers);
    final root = await _assetDir();
    await root.create(recursive: true);
    final file = File(p.join(root.path, 'style_active.json'));
    await file.writeAsString(jsonEncode(style));
    return file.path;
  }
}
