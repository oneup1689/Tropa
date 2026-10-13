import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'debug_log.dart';
import 'l10n.dart';
import 'maps.dart';
import 'pmtiles_extract.dart';

// ====================================================================== catalog of regions

/// One downloadable region: a country or a province/oblast with its bounding box.
class CatalogRegion {
  final String ru;
  final String en;
  final GeoBox box;
  final String key; // for file names

  const CatalogRegion(this.ru, this.en, this.box, this.key);

  String get name => L10n.current == AppLang.en ? en : ru;
}

class CatalogCountry {
  final String iso;
  final String ru;
  final String en;
  final GeoBox box;
  final bool whole;
  final List<CatalogRegion> regions;

  const CatalogCountry(this.iso, this.ru, this.en, this.box, this.whole, this.regions);

  String get name => L10n.current == AppLang.en ? en : ru;
}

/// The catalog comes from assets/map/regions.json (made from Natural Earth admin-1 by tools/make_regions.py).
class RegionCatalog {
  RegionCatalog._();

  static List<CatalogCountry>? _cache;

  static GeoBox _box(List<dynamic> b) => GeoBox((b[0] as num).toDouble(), (b[1] as num).toDouble(), (b[2] as num).toDouble(), (b[3] as num).toDouble());

  static String _slug(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  static Future<List<CatalogCountry>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = jsonDecode(await rootBundle.loadString('assets/map/regions.json')) as Map<String, dynamic>;
    final out = <CatalogCountry>[];
    for (final c in raw['countries'] as List<dynamic>) {
      final m = c as Map<String, dynamic>;
      final iso = m['iso'] as String;
      out.add(CatalogCountry(
        iso,
        m['ru'] as String,
        m['en'] as String,
        _box(m['box'] as List<dynamic>),
        m['whole'] as bool? ?? true,
        [
          for (final r in m['regions'] as List<dynamic>)
            CatalogRegion((r as Map<String, dynamic>)['ru'] as String, r['en'] as String, _box(r['box'] as List<dynamic>),
                '${iso}_${_slug(r['en'] as String)}'),
        ],
      ));
    }
    return _cache = out;
  }
}

// ====================================================================== what is stored next to a map

/// Description of a downloaded map, kept in a small file next to it (`<map>.pmtiles.meta.json`).
class RegionMeta {
  final String nameRu;
  final String nameEn;
  final GeoBox box;
  final int maxZoom;

  /// The Protomaps build the map was cut from ("20261012.pmtiles"); its date is the date of the data.
  final String build;
  final int createdMs;
  final bool fragment; // a small piece fetched for a poster, not a region the person chose

  const RegionMeta({
    required this.nameRu,
    required this.nameEn,
    required this.box,
    required this.maxZoom,
    required this.build,
    required this.createdMs,
    this.fragment = false,
  });

  String get name => L10n.current == AppLang.en ? nameEn : nameRu;

  /// Date of the data ("20261012.pmtiles" -> 2026-10-12), or null for an unknown build name.
  DateTime? get buildDate => parseBuildDate(build);

  Map<String, Object?> toJson() => {
        'nameRu': nameRu,
        'nameEn': nameEn,
        'box': [box.minLon, box.minLat, box.maxLon, box.maxLat],
        'maxZoom': maxZoom,
        'build': build,
        'createdMs': createdMs,
        'fragment': fragment,
      };

  factory RegionMeta.fromJson(Map<String, dynamic> m) {
    final b = (m['box'] as List<dynamic>).map((e) => (e as num).toDouble()).toList();
    return RegionMeta(
      nameRu: m['nameRu'] as String,
      nameEn: m['nameEn'] as String,
      box: GeoBox(b[0], b[1], b[2], b[3]),
      maxZoom: (m['maxZoom'] as num).toInt(),
      build: m['build'] as String,
      createdMs: (m['createdMs'] as num).toInt(),
      fragment: m['fragment'] == true,
    );
  }
}

DateTime? parseBuildDate(String build) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(build);
  if (m == null) return null;
  return DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

File metaFileFor(File map) => File('${map.path}.meta.json');

Future<RegionMeta?> readRegionMeta(File map) async {
  try {
    final f = metaFileFor(map);
    if (!await f.exists()) return null;
    return RegionMeta.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

// ====================================================================== the download

enum DownloadState { idle, planning, ready, downloading, failed, done }

/// What the person is shown before a download starts: the exact size.
class DownloadQuote {
  final int downloadBytes;
  final int fileBytes;
  final int tileCount;
  final String build;

  const DownloadQuote(this.downloadBytes, this.fileBytes, this.tileCount, this.build);
}

/// A single map download at a time: planning (reading the directories of the planet build), the quote, then the
/// download itself. An interrupted download is remembered on disk and can be continued.
class MapDownloader extends ChangeNotifier {
  MapDownloader._();
  static final MapDownloader instance = MapDownloader._();

  static const _channel = MethodChannel('tropa/system');

  DownloadState state = DownloadState.idle;
  String title = '';
  String? error;
  int bytesDone = 0;
  int bytesTotal = 0;
  double planProgress = 0;
  DownloadQuote? quote;

  RangeSource? _source;
  ExtractPlan? _plan;
  File? _target;
  Map<String, Object?>? _job; // what is being downloaded, as stored in the state file
  bool _cancel = false;

  double get fraction => bytesTotal == 0 ? 0 : (bytesDone / bytesTotal).clamp(0.0, 1.0);

  bool get busy => state == DownloadState.planning || state == DownloadState.downloading || state == DownloadState.ready;

  Future<File> _stateFile() async => File(p.join((await MapStore.regionsDir()).path, '.download.json'));

  /// An interrupted download that can be continued, if there is one.
  Future<Map<String, Object?>?> pending() async {
    if (busy) return null;
    try {
      final f = await _stateFile();
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, Object?>;
    } catch (_) {
      return null;
    }
  }

  Future<void> discardPending() async {
    final f = await _stateFile();
    if (await f.exists()) await f.delete();
    final dir = await MapStore.regionsDir();
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.part')) await e.delete();
    }
  }

  void _set(DownloadState s, {String? err}) {
    state = s;
    error = err;
    notifyListeners();
  }

  Future<void> _keepAwake(bool on) async {
    try {
      await _channel.invokeMethod('keepScreenOn', {'on': on});
    } catch (_) {}
  }

  /// Reads the directories of the newest build for [box] and returns the exact size. [fileName] is the map's
  /// file in the maps folder; the download continues in [start].
  Future<DownloadQuote?> prepare({
    required String nameRu,
    required String nameEn,
    required GeoBox box,
    required String fileName,
    int maxZoom = 14,
    bool fragment = false,
    String? build,
    int resumeGroup = 0,
  }) async {
    if (busy) return null;
    _cancel = false;
    title = L10n.current == AppLang.en ? nameEn : nameRu;
    bytesDone = 0;
    bytesTotal = 0;
    planProgress = 0;
    quote = null;
    _set(DownloadState.planning);
    try {
      var key = build;
      if (key == null) {
        final latest = await latestProtomapsBuild();
        if (latest == null) throw const HttpException('нет связи со списком сборок карт');
        key = latest.key;
      }
      _source?.close();
      _source = RangeSource(Uri.parse('https://build.protomaps.com/$key'));
      _plan = await planExtract(_source!, box, maxZoom, onProgress: (f, s) {
        planProgress = f;
        notifyListeners();
      });
      final dir = await MapStore.regionsDir();
      _target = File(p.join(dir.path, fileName));
      _job = {
        'nameRu': nameRu,
        'nameEn': nameEn,
        'box': [box.minLon, box.minLat, box.maxLon, box.maxLat],
        'maxZoom': maxZoom,
        'fileName': fileName,
        'build': key,
        'fragment': fragment,
        'groupsDone': resumeGroup,
      };
      bytesTotal = _plan!.downloadBytes;
      quote = DownloadQuote(_plan!.downloadBytes, _plan!.fileBytes, _plan!.tileCount, key);
      _resumeGroup = resumeGroup;
      _set(DownloadState.ready);
      return quote;
    } catch (e) {
      DebugLog.instance.log('MAPDL', 'planning failed: $e');
      _source?.close();
      _source = null;
      _plan = null;
      _set(DownloadState.failed, err: '$e');
      return null;
    }
  }

  int _resumeGroup = 0;

  /// Starts the download that [prepare] planned. It runs in the background; watch this object for progress.
  Future<void> start() async {
    final plan = _plan, source = _source, target = _target, job = _job;
    if (plan == null || source == null || target == null || job == null || state != DownloadState.ready) return;
    _cancel = false;
    _set(DownloadState.downloading);
    await _keepAwake(true);
    final stateFile = await _stateFile();
    try {
      await stateFile.writeAsString(jsonEncode(job));
      await runExtract(
        source,
        plan,
        target,
        resumeGroup: _resumeGroup,
        isCancelled: () => _cancel,
        onBytes: (done, total) {
          bytesDone = done;
          bytesTotal = total;
          notifyListeners();
        },
        onGroupDone: (g) {
          job['groupsDone'] = g;
          // Remembering every group is cheap and lets an interrupted download continue where it stopped.
          if (g % 4 == 0) stateFile.writeAsStringSync(jsonEncode(job));
        },
      );
      final box = job['box'] as List<Object?>;
      final meta = RegionMeta(
        nameRu: job['nameRu'] as String,
        nameEn: job['nameEn'] as String,
        box: GeoBox((box[0] as num).toDouble(), (box[1] as num).toDouble(), (box[2] as num).toDouble(), (box[3] as num).toDouble()),
        maxZoom: job['maxZoom'] as int,
        build: job['build'] as String,
        createdMs: DateTime.now().millisecondsSinceEpoch,
        fragment: job['fragment'] == true,
      );
      await metaFileFor(target).writeAsString(jsonEncode(meta.toJson()));
      if (await stateFile.exists()) await stateFile.delete();
      DebugLog.instance.log('MAPDL', 'done: ${target.path} ${target.lengthSync()} bytes');
      _set(DownloadState.done);
    } on ExtractCancelled {
      // Cancelled by the person: the partial file is useless.
      if (await stateFile.exists()) await stateFile.delete();
      final part = File('${target.path}.part');
      if (await part.exists()) await part.delete();
      _set(DownloadState.idle);
    } catch (e) {
      // Interrupted (network, storage): the state file stays, the download can be continued.
      try {
        await stateFile.writeAsString(jsonEncode(job));
      } catch (_) {}
      DebugLog.instance.log('MAPDL', 'download failed: $e');
      _set(DownloadState.failed, err: '$e');
    } finally {
      await _keepAwake(false);
      source.close();
      if (state != DownloadState.failed) {
        _plan = null;
        _source = null;
      }
    }
  }

  void cancel() {
    if (state == DownloadState.downloading) {
      _cancel = true;
    } else {
      _source?.close();
      _source = null;
      _plan = null;
      _set(DownloadState.idle);
    }
  }

  /// Completes when the running download finishes: true when the map is there, false when it failed or was cancelled.
  Future<bool> whenFinished() {
    final c = Completer<bool>();
    void check() {
      if (state == DownloadState.done) {
        removeListener(check);
        c.complete(true);
      } else if (state == DownloadState.failed || state == DownloadState.idle) {
        removeListener(check);
        c.complete(false);
      }
    }

    addListener(check);
    check();
    return c.future;
  }

  /// Back to idle after the result of a finished or failed download has been shown.
  void acknowledge() {
    if (state == DownloadState.done || state == DownloadState.failed) {
      _source?.close();
      _source = null;
      _plan = null;
      _set(DownloadState.idle);
    }
  }

  /// Continues an interrupted download from the state file (same build, same area).
  Future<DownloadQuote?> prepareResume(Map<String, Object?> saved) {
    final b = saved['box'] as List<Object?>;
    return prepare(
      nameRu: saved['nameRu'] as String,
      nameEn: saved['nameEn'] as String,
      box: GeoBox((b[0] as num).toDouble(), (b[1] as num).toDouble(), (b[2] as num).toDouble(), (b[3] as num).toDouble()),
      fileName: saved['fileName'] as String,
      maxZoom: saved['maxZoom'] as int,
      fragment: saved['fragment'] == true,
      build: saved['build'] as String,
      resumeGroup: (saved['groupsDone'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The newest build available and whether a map made from [meta] is old. Returns null when offline.
Future<({String build, DateTime? date})?> newestBuild() async {
  final latest = await latestProtomapsBuild();
  if (latest == null) return null;
  return (build: latest.key, date: parseBuildDate(latest.key));
}
