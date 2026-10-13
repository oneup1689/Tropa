import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Cuts a region out of a big remote PMTiles archive (the Protomaps planet build) with HTTP range requests,
/// and writes a small, complete PMTiles file. It does what `pmtiles extract` does, inside the app, without a
/// server of our own: only the directories and the tiles of the region are downloaded.
///
/// PMTiles v3: a 127-byte header, a root directory, JSON metadata, leaf directories and the tile data. Tiles
/// are numbered along a Hilbert curve (tile id); a directory lists (tile id, run length, offset, length), and
/// an entry with run length 0 points to a leaf directory. See https://github.com/protomaps/PMTiles.

class PmHeader {
  final int rootOffset, rootLength, metaOffset, metaLength, leafOffset, leafLength, tileOffset, tileLength;
  final int addressedTiles, tileEntries, tileContents;
  final int clustered, internalCompression, tileCompression, tileType, minZoom, maxZoom;
  final int minLonE7, minLatE7, maxLonE7, maxLatE7, centerZoom, centerLonE7, centerLatE7;

  const PmHeader({
    required this.rootOffset,
    required this.rootLength,
    required this.metaOffset,
    required this.metaLength,
    required this.leafOffset,
    required this.leafLength,
    required this.tileOffset,
    required this.tileLength,
    required this.addressedTiles,
    required this.tileEntries,
    required this.tileContents,
    required this.clustered,
    required this.internalCompression,
    required this.tileCompression,
    required this.tileType,
    required this.minZoom,
    required this.maxZoom,
    required this.minLonE7,
    required this.minLatE7,
    required this.maxLonE7,
    required this.maxLatE7,
    required this.centerZoom,
    required this.centerLonE7,
    required this.centerLatE7,
  });

  static const int size = 127;

  factory PmHeader.parse(Uint8List b) {
    if (b.length < size || String.fromCharCodes(b.sublist(0, 7)) != 'PMTiles' || b[7] != 3) {
      throw const FormatException('Это не архив PMTiles версии 3');
    }
    final d = ByteData.sublistView(b);
    int u64(int o) => d.getUint64(o, Endian.little);
    return PmHeader(
      rootOffset: u64(8),
      rootLength: u64(16),
      metaOffset: u64(24),
      metaLength: u64(32),
      leafOffset: u64(40),
      leafLength: u64(48),
      tileOffset: u64(56),
      tileLength: u64(64),
      addressedTiles: u64(72),
      tileEntries: u64(80),
      tileContents: u64(88),
      clustered: b[96],
      internalCompression: b[97],
      tileCompression: b[98],
      tileType: b[99],
      minZoom: b[100],
      maxZoom: b[101],
      minLonE7: d.getInt32(102, Endian.little),
      minLatE7: d.getInt32(106, Endian.little),
      maxLonE7: d.getInt32(110, Endian.little),
      maxLatE7: d.getInt32(114, Endian.little),
      centerZoom: b[118],
      centerLonE7: d.getInt32(119, Endian.little),
      centerLatE7: d.getInt32(123, Endian.little),
    );
  }

  Uint8List serialize() {
    final b = Uint8List(size);
    final d = ByteData.sublistView(b);
    b.setRange(0, 7, 'PMTiles'.codeUnits);
    b[7] = 3;
    void u64(int o, int v) => d.setUint64(o, v, Endian.little);
    u64(8, rootOffset);
    u64(16, rootLength);
    u64(24, metaOffset);
    u64(32, metaLength);
    u64(40, leafOffset);
    u64(48, leafLength);
    u64(56, tileOffset);
    u64(64, tileLength);
    u64(72, addressedTiles);
    u64(80, tileEntries);
    u64(88, tileContents);
    b[96] = clustered;
    b[97] = internalCompression;
    b[98] = tileCompression;
    b[99] = tileType;
    b[100] = minZoom;
    b[101] = maxZoom;
    d.setInt32(102, minLonE7, Endian.little);
    d.setInt32(106, minLatE7, Endian.little);
    d.setInt32(110, maxLonE7, Endian.little);
    d.setInt32(114, maxLatE7, Endian.little);
    b[118] = centerZoom;
    d.setInt32(119, centerLonE7, Endian.little);
    d.setInt32(123, centerLatE7, Endian.little);
    return b;
  }
}

class DirEntry {
  final int tileId;
  final int offset;
  final int length;
  final int runLength;

  const DirEntry(this.tileId, this.offset, this.length, this.runLength);
}

// ---------------------------------------------------------------------------- varints and directories

List<DirEntry> parseDirectory(Uint8List data) {
  var pos = 0;
  int varint() {
    var result = 0, shift = 0;
    while (true) {
      final b = data[pos++];
      result |= (b & 0x7f) << shift;
      if (b < 0x80) return result;
      shift += 7;
    }
  }

  final n = varint();
  final ids = List<int>.filled(n, 0), runs = List<int>.filled(n, 0), lens = List<int>.filled(n, 0), offs = List<int>.filled(n, 0);
  var last = 0;
  for (var i = 0; i < n; i++) {
    last += varint();
    ids[i] = last;
  }
  for (var i = 0; i < n; i++) {
    runs[i] = varint();
  }
  for (var i = 0; i < n; i++) {
    lens[i] = varint();
  }
  for (var i = 0; i < n; i++) {
    final v = varint();
    offs[i] = (v == 0 && i > 0) ? offs[i - 1] + lens[i - 1] : v - 1;
  }
  return [for (var i = 0; i < n; i++) DirEntry(ids[i], offs[i], lens[i], runs[i])];
}

Uint8List serializeDirectory(List<DirEntry> entries) {
  final out = BytesBuilder();
  void varint(int v) {
    while (v >= 0x80) {
      out.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }

  varint(entries.length);
  var last = 0;
  for (final e in entries) {
    varint(e.tileId - last);
    last = e.tileId;
  }
  for (final e in entries) {
    varint(e.runLength);
  }
  for (final e in entries) {
    varint(e.length);
  }
  for (var i = 0; i < entries.length; i++) {
    if (i > 0 && entries[i].offset == entries[i - 1].offset + entries[i - 1].length) {
      varint(0);
    } else {
      varint(entries[i].offset + 1);
    }
  }
  return out.toBytes();
}

Uint8List _decompress(Uint8List data, int compression) {
  switch (compression) {
    case 1: // none
    case 0:
      return data;
    case 2:
      return Uint8List.fromList(gzip.decode(data));
    default:
      throw FormatException('Неподдерживаемое сжатие архива ($compression)');
  }
}

Uint8List _gzip(Uint8List data) => Uint8List.fromList(gzip.encode(data));

// ---------------------------------------------------------------------------- tile ids

void _rotate(int n, List<int> xy, int rx, int ry) {
  if (ry == 0) {
    if (rx == 1) {
      xy[0] = n - 1 - xy[0];
      xy[1] = n - 1 - xy[1];
    }
    final t = xy[0];
    xy[0] = xy[1];
    xy[1] = t;
  }
}

/// Position of tile z/x/y along the Hilbert curve over all zoom levels (the PMTiles tile id).
int zxyToTileId(int z, int x, int y) {
  final acc = ((1 << (2 * z)) - 1) ~/ 3; // tiles on all lower levels: 1 + 4 + 16 + ...
  final n = 1 << z;
  var d = 0;
  final xy = [x, y];
  for (var s = n ~/ 2; s > 0; s ~/= 2) {
    final rx = (xy[0] & s) > 0 ? 1 : 0;
    final ry = (xy[1] & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    _rotate(s, xy, rx, ry);
  }
  return acc + d;
}

/// Zoom level of a tile id.
int tileIdZoom(int id) {
  var z = 0;
  var acc = 0;
  while (true) {
    final next = acc + (1 << (2 * z));
    if (id < next) return z;
    acc = next;
    z++;
  }
}

class GeoBox {
  final double minLon, minLat, maxLon, maxLat;

  const GeoBox(this.minLon, this.minLat, this.maxLon, this.maxLat);

  @override
  String toString() => '$minLon,$minLat,$maxLon,$maxLat';
}

int _lonToX(double lon, int z) => ((lon + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);

int _latToY(double lat, int z) {
  final l = lat.clamp(-85.0511, 85.0511);
  final s = math.sin(l * math.pi / 180);
  final y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * (1 << z);
  return y.floor().clamp(0, (1 << z) - 1);
}

/// Number of tiles of the box at zoom levels [minZoom]..[maxZoom].
int countTiles(GeoBox box, int minZoom, int maxZoom) {
  var n = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    n += (_lonToX(box.maxLon, z) - _lonToX(box.minLon, z) + 1) * (_latToY(box.minLat, z) - _latToY(box.maxLat, z) + 1);
  }
  return n;
}

/// Sorted ids of every tile of the box at zoom levels [minZoom]..[maxZoom].
Int64List neededTileIds(GeoBox box, int minZoom, int maxZoom) {
  final out = Int64List(countTiles(box, minZoom, maxZoom));
  var k = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final x0 = _lonToX(box.minLon, z), x1 = _lonToX(box.maxLon, z);
    final y0 = _latToY(box.maxLat, z), y1 = _latToY(box.minLat, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        out[k++] = zxyToTileId(z, x, y);
      }
    }
  }
  out.sort();
  return out;
}

// ---------------------------------------------------------------------------- range reading

/// Reads byte ranges of a remote file; retries on network errors.
class RangeSource {
  final Uri url;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  RangeSource(this.url);

  void close() => _client.close(force: true);

  Future<Uint8List> read(int offset, int length, {int attempts = 6}) async {
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final req = await _client.getUrl(url).timeout(const Duration(seconds: 30));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + length - 1}');
        req.headers.set(HttpHeaders.userAgentHeader, 'Tropa/1.0 (offline hiking app)');
        final res = await req.close().timeout(const Duration(seconds: 60));
        if (res.statusCode != 206 && res.statusCode != 200) {
          await res.drain<void>();
          throw HttpException('HTTP ${res.statusCode}');
        }
        final b = BytesBuilder(copy: false);
        await for (final chunk in res.timeout(const Duration(seconds: 60))) {
          b.add(chunk);
        }
        final data = b.takeBytes();
        if (res.statusCode == 200 && data.length > length) {
          // The server ignored the Range header and sent the whole file: refuse instead of eating memory.
          throw const HttpException('сервер не поддерживает частичную загрузку');
        }
        if (data.length != length) throw HttpException('получено ${data.length} байт вместо $length');
        return data;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 500 * (1 << attempt)));
      }
    }
    throw HttpException('Не удалось загрузить часть файла: $lastError');
  }
}

// ---------------------------------------------------------------------------- planning

class _Tile {
  final int id;
  final int offset;
  final int length;

  const _Tile(this.id, this.offset, this.length);
}

class _Block {
  final int srcOffset;
  final int length;
  int destOffset = 0;

  _Block(this.srcOffset, this.length);
}

class _Group {
  final int srcStart;
  final int srcEnd;
  final List<_Block> blocks;

  _Group(this.srcStart, this.srcEnd, this.blocks);
}

/// Everything decided before the first tile is downloaded: how many tiles, how many bytes to fetch, and the
/// finished head of the new file (header, directories, metadata).
class ExtractPlan {
  final PmHeader sourceHeader;
  final Uint8List head;
  final int tileCount;
  final int downloadBytes; // bytes that will be fetched (a little more than the tile data: gaps between tiles)
  final int fileBytes; // size of the new file
  final List<_Group> _groups;
  final int _tileDataStart;

  ExtractPlan._(this.sourceHeader, this.head, this.tileCount, this.downloadBytes, this.fileBytes, this._groups, this._tileDataStart);

  int get groupCount => _groups.length;
}

typedef ProgressCallback = void Function(double fraction, String stage);

/// Reads the directories of the source and decides what to download for [box] at zoom levels 0..[maxZoom].
Future<ExtractPlan> planExtract(
  RangeSource source,
  GeoBox box,
  int maxZoom, {
  ProgressCallback? onProgress,
  int concurrency = 8,
  int gapLimit = 262144,
  int maxGroup = 16 * 1024 * 1024,
}) async {
  onProgress?.call(0, 'header');
  final header = PmHeader.parse(await source.read(0, PmHeader.size));
  final minZ = header.minZoom;
  final maxZ = math.min(maxZoom, header.maxZoom);
  final ids = neededTileIds(box, minZ, maxZ);
  if (ids.isEmpty) throw const FormatException('В выбранной области нет тайлов');

  // First needed id >= v.
  int lower(int v) {
    var lo = 0, hi = ids.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ids[mid] < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  final tiles = <_Tile>[];
  final rootBytes = await source.read(header.rootOffset, header.rootLength);
  var level = <List<DirEntry>>[parseDirectory(_decompress(rootBytes, header.internalCompression))];

  var dirsFetched = 0;
  while (level.isNotEmpty) {
    final leaves = <(int, int)>[]; // (offset, length) of leaf directories to read next
    for (final entries in level) {
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (e.runLength > 0) {
          final end = e.tileId + e.runLength;
          for (var k = lower(e.tileId); k < ids.length && ids[k] < end; k++) {
            tiles.add(_Tile(ids[k], e.offset, e.length));
          }
        } else {
          // A leaf directory covers the ids up to the next entry of this directory (or to the end).
          final next = i + 1 < entries.length ? entries[i + 1].tileId : (1 << 62);
          final k = lower(e.tileId);
          if (k < ids.length && ids[k] < next) leaves.add((header.leafOffset + e.offset, e.length));
        }
      }
    }
    final nextLevel = <List<DirEntry>>[];
    for (var from = 0; from < leaves.length; from += concurrency) {
      final batch = leaves.sublist(from, math.min(from + concurrency, leaves.length));
      final got = await Future.wait([for (final l in batch) source.read(l.$1, l.$2)]);
      for (final b in got) {
        nextLevel.add(parseDirectory(_decompress(b, header.internalCompression)));
      }
      dirsFetched += batch.length;
      onProgress?.call(math.min(0.95, dirsFetched / math.max(dirsFetched + 1, leaves.length + dirsFetched)), 'directories');
    }
    level = nextLevel;
  }
  if (tiles.isEmpty) throw const FormatException('В выбранной области нет тайлов');
  tiles.sort((a, b) => a.id.compareTo(b.id));

  // Unique blocks of tile data (identical tiles are stored once), laid out in the order of the source file.
  final bySrc = <int, _Block>{};
  for (final t in tiles) {
    bySrc.putIfAbsent(t.offset, () => _Block(t.offset, t.length));
  }
  final blocks = bySrc.values.toList()..sort((a, b) => a.srcOffset.compareTo(b.srcOffset));
  var dest = 0;
  for (final b in blocks) {
    b.destOffset = dest;
    dest += b.length;
  }
  final tileDataLength = dest;

  // New directory entries: consecutive tile ids that share one block become one run.
  final entries = <DirEntry>[];
  for (final t in tiles) {
    final d = bySrc[t.offset]!.destOffset;
    if (entries.isNotEmpty) {
      final last = entries.last;
      if (last.offset == d && last.length == t.length && last.tileId + last.runLength == t.id) {
        entries[entries.length - 1] = DirEntry(last.tileId, last.offset, last.length, last.runLength + 1);
        continue;
      }
    }
    entries.add(DirEntry(t.id, d, t.length, 1));
  }

  // Metadata of the source, copied (recompressed with gzip).
  final metaRaw = _decompress(await source.read(header.metaOffset, header.metaLength), header.internalCompression);
  final metaGz = _gzip(metaRaw);

  // Directories: everything in the root when it fits in 16 KB, else leaf directories of growing size.
  Uint8List rootGz;
  var leafGz = Uint8List(0);
  var leafSize = 4096;
  while (true) {
    if (entries.length <= leafSize) {
      final r = _gzip(serializeDirectory(entries));
      if (r.length <= 16384 - PmHeader.size) {
        rootGz = r;
        leafGz = Uint8List(0);
        break;
      }
    }
    final leafBytes = BytesBuilder();
    final rootEntries = <DirEntry>[];
    for (var i = 0; i < entries.length; i += leafSize) {
      final part = _gzip(serializeDirectory(entries.sublist(i, math.min(i + leafSize, entries.length))));
      rootEntries.add(DirEntry(entries[i].tileId, leafBytes.length, part.length, 0));
      leafBytes.add(part);
    }
    final r = _gzip(serializeDirectory(rootEntries));
    if (r.length <= 16384 - PmHeader.size) {
      rootGz = r;
      leafGz = leafBytes.takeBytes();
      break;
    }
    leafSize = (leafSize * 1.3).ceil();
  }

  final rootOffset = PmHeader.size;
  final metaOffset = rootOffset + rootGz.length;
  final leafOffset = metaOffset + metaGz.length;
  final tileOffset = leafOffset + leafGz.length;
  final bounds = (
    minLon: (box.minLon * 1e7).round(),
    minLat: (box.minLat * 1e7).round(),
    maxLon: (box.maxLon * 1e7).round(),
    maxLat: (box.maxLat * 1e7).round()
  );
  var minTileZoom = 99, maxTileZoom = 0;
  for (final t in tiles) {
    final z = tileIdZoom(t.id);
    minTileZoom = math.min(minTileZoom, z);
    maxTileZoom = math.max(maxTileZoom, z);
  }
  var ascending = true;
  for (var i = 1; i < entries.length; i++) {
    if (entries[i].offset < entries[i - 1].offset) ascending = false;
  }
  final out = PmHeader(
    rootOffset: rootOffset,
    rootLength: rootGz.length,
    metaOffset: metaOffset,
    metaLength: metaGz.length,
    leafOffset: leafOffset,
    leafLength: leafGz.length,
    tileOffset: tileOffset,
    tileLength: tileDataLength,
    addressedTiles: tiles.length,
    tileEntries: entries.length,
    tileContents: blocks.length,
    clustered: ascending ? 1 : 0,
    internalCompression: 2,
    tileCompression: header.tileCompression,
    tileType: header.tileType,
    minZoom: minTileZoom,
    maxZoom: maxTileZoom,
    minLonE7: bounds.minLon,
    minLatE7: bounds.minLat,
    maxLonE7: bounds.maxLon,
    maxLatE7: bounds.maxLat,
    centerZoom: math.min(maxTileZoom, (minTileZoom + maxTileZoom) ~/ 2 + 2),
    centerLonE7: ((bounds.minLon + bounds.maxLon) / 2).round(),
    centerLatE7: ((bounds.minLat + bounds.maxLat) / 2).round(),
  );
  final head = BytesBuilder()
    ..add(out.serialize())
    ..add(rootGz)
    ..add(metaGz)
    ..add(leafGz);

  // Download groups: neighbouring blocks are fetched together when the gap between them is small.
  final groups = <_Group>[];
  var start = 0;
  while (start < blocks.length) {
    var end = start;
    var spanStart = blocks[start].srcOffset;
    var spanEnd = spanStart + blocks[start].length;
    while (end + 1 < blocks.length) {
      final nb = blocks[end + 1];
      if (nb.srcOffset - spanEnd > gapLimit || nb.srcOffset + nb.length - spanStart > maxGroup) break;
      spanEnd = nb.srcOffset + nb.length;
      end++;
    }
    groups.add(_Group(spanStart, spanEnd, blocks.sublist(start, end + 1)));
    start = end + 1;
  }
  final download = groups.fold<int>(0, (a, g) => a + (g.srcEnd - g.srcStart));
  onProgress?.call(1, 'planned');
  return ExtractPlan._(header, head.takeBytes(), tiles.length, download, tileOffset + tileDataLength, groups, tileOffset);
}

// ---------------------------------------------------------------------------- download

class ExtractCancelled implements Exception {
  const ExtractCancelled();
}

/// Downloads the tiles of [plan] and writes the finished archive to [target] (a `.part` file is used until it is
/// complete). With [resumeGroup] > 0 the file that is already there is continued from that download group. The
/// number of finished groups is reported through [onGroupDone], so that an interrupted download can be resumed.
Future<void> runExtract(
  RangeSource source,
  ExtractPlan plan,
  File target, {
  int resumeGroup = 0,
  int parallel = 4,
  void Function(int bytesDone, int bytesTotal)? onBytes,
  void Function(int groupsDone)? onGroupDone,
  bool Function()? isCancelled,
}) async {
  final part = File('${target.path}.part');
  final raf = await part.open(mode: resumeGroup > 0 ? FileMode.append : FileMode.write);
  try {
    if (resumeGroup == 0) {
      await raf.writeFrom(plan.head);
    } else {
      // Continue after the data of the finished groups: cut off anything half written.
      final lastBlock = plan._groups[resumeGroup - 1].blocks.last;
      final expected = plan._tileDataStart + lastBlock.destOffset + lastBlock.length;
      await raf.truncate(expected);
      await raf.setPosition(expected);
    }
    var doneBytes = 0;
    for (var g = 0; g < resumeGroup; g++) {
      doneBytes += plan._groups[g].srcEnd - plan._groups[g].srcStart;
    }
    // Sliding window: up to [parallel] groups are being fetched, results are written in order.
    final pending = <int, Future<Uint8List>>{};
    var nextToStart = resumeGroup;
    // Offsets in the directories are relative to the start of the tile data of the source archive.
    Future<Uint8List> fetch(int g) =>
        source.read(plan.sourceHeader.tileOffset + plan._groups[g].srcStart, plan._groups[g].srcEnd - plan._groups[g].srcStart);
    for (var g = resumeGroup; g < plan._groups.length; g++) {
      while (nextToStart < plan._groups.length && nextToStart < g + parallel) {
        pending[nextToStart] = fetch(nextToStart);
        nextToStart++;
      }
      final data = await pending.remove(g)!;
      if (isCancelled?.call() == true) throw const ExtractCancelled();
      final group = plan._groups[g];
      for (final b in group.blocks) {
        final from = b.srcOffset - group.srcStart;
        await raf.writeFrom(data, from, from + b.length);
      }
      doneBytes += group.srcEnd - group.srcStart;
      onBytes?.call(doneBytes, plan.downloadBytes);
      onGroupDone?.call(g + 1);
    }
    await raf.flush();
  } finally {
    await raf.close();
  }
  if (await target.exists()) await target.delete();
  await part.rename(target.path);
}

/// Name of the newest Protomaps build ("20261012.pmtiles") from the public list of builds.
Future<({String key, int size})?> latestProtomapsBuild() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse('https://build-metadata.protomaps.dev/builds.json'));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    final list = jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
    if (list.isEmpty) return null;
    list.sort((a, b) => (a['key'] as String).compareTo(b['key'] as String));
    final last = list.last as Map<String, dynamic>;
    return (key: last['key'] as String, size: (last['size'] as num).toInt());
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
