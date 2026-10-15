"""Tiny PMTiles v3 reader + Mapbox Vector Tile decoder (no third-party packages)."""
import gzip
import struct


def _varint(buf, pos):
    r = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        r |= (b & 0x7F) << shift
        if not b & 0x80:
            return r, pos
        shift += 7


def zxy_to_tileid(z, x, y):
    acc = 0
    for t in range(z):
        acc += (1 << t) * (1 << t)
    n = 1 << z
    d = 0
    s = n // 2
    tx, ty = x, y
    while s > 0:
        rx = 1 if (tx & s) > 0 else 0
        ry = 1 if (ty & s) > 0 else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                tx = s - 1 - tx
                ty = s - 1 - ty
            tx, ty = ty, tx
        s //= 2
    return acc + d


class PMTiles:
    def __init__(self, path):
        self.f = open(path, "rb")
        h = self.f.read(127)
        assert h[:7] == b"PMTiles", "not a pmtiles file"
        (self.root_off, self.root_len, self.meta_off, self.meta_len, self.leaf_off, self.leaf_len, self.data_off, self.data_len) = struct.unpack("<8Q", h[8:72])
        self.internal_comp = h[97]
        self.tile_comp = h[98]
        self.min_zoom, self.max_zoom = h[100], h[101]
        self._dirs = {}

    def _read(self, off, ln):
        self.f.seek(off)
        return self.f.read(ln)

    def _dir(self, off, ln):
        key = (off, ln)
        if key in self._dirs:
            return self._dirs[key]
        raw = self._read(off, ln)
        if self.internal_comp == 2:
            raw = gzip.decompress(raw)
        pos = 0
        n, pos = _varint(raw, pos)
        ids, runs, lens, offs = [], [], [], []
        last = 0
        for _ in range(n):
            v, pos = _varint(raw, pos)
            last += v
            ids.append(last)
        for _ in range(n):
            v, pos = _varint(raw, pos)
            runs.append(v)
        for _ in range(n):
            v, pos = _varint(raw, pos)
            lens.append(v)
        for i in range(n):
            v, pos = _varint(raw, pos)
            if v == 0 and i > 0:
                offs.append(offs[i - 1] + lens[i - 1])
            else:
                offs.append(v - 1)
        res = list(zip(ids, runs, lens, offs))
        self._dirs[key] = res
        return res

    def get(self, z, x, y):
        tid = zxy_to_tileid(z, x, y)
        off, ln = self.root_off, self.root_len
        for _ in range(4):
            entries = self._dir(off, ln)
            lo, hi = 0, len(entries) - 1
            found = None
            while lo <= hi:
                mid = (lo + hi) // 2
                if entries[mid][0] <= tid:
                    found = mid
                    lo = mid + 1
                else:
                    hi = mid - 1
            if found is None:
                return None
            eid, run, ln2, off2 = entries[found]
            if run > 0:
                if tid < eid + run:
                    data = self._read(self.data_off + off2, ln2)
                    return gzip.decompress(data) if self.tile_comp == 2 else data
                return None
            off, ln = self.leaf_off + off2, ln2
        return None


# ---------------------------------------------------------------- MVT
def _zz(n):
    return (n >> 1) ^ -(n & 1)


def _fields(buf):
    pos = 0
    n = len(buf)
    while pos < n:
        key, pos = _varint(buf, pos)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, pos = _varint(buf, pos)
        elif wt == 2:
            ln, pos = _varint(buf, pos)
            v = buf[pos:pos + ln]
            pos += ln
        elif wt == 1:
            v = buf[pos:pos + 8]
            pos += 8
        elif wt == 5:
            v = buf[pos:pos + 4]
            pos += 4
        else:
            raise ValueError("bad wire type")
        yield f, wt, v


def _packed(buf):
    pos = 0
    out = []
    while pos < len(buf):
        v, pos = _varint(buf, pos)
        out.append(v)
    return out


def _value(buf):
    for f, wt, v in _fields(buf):
        if f == 1:
            return v.decode("utf-8", "replace")
        if f == 2:
            return struct.unpack("<f", v)[0]
        if f == 3:
            return struct.unpack("<d", v)[0]
        if f == 4:
            return v if v < (1 << 63) else v - (1 << 64)
        if f == 5:
            return v
        if f == 6:
            return _zz(v)
        if f == 7:
            return bool(v)
    return None


def decode_mvt(buf):
    """-> {layer name: (extent, [ (type, props, geometry) ])}; geometry is a list of rings/lines (lists of (x, y))."""
    layers = {}
    for f, wt, lv in _fields(buf):
        if f != 3:
            continue
        name = ""
        extent = 4096
        keys, vals, feats = [], [], []
        for lf, lwt, v in _fields(lv):
            if lf == 1:
                name = v.decode()
            elif lf == 2:
                feats.append(v)
            elif lf == 3:
                keys.append(v.decode())
            elif lf == 4:
                vals.append(_value(v))
            elif lf == 5:
                extent = v
        out = []
        for fb in feats:
            gtype = 0
            tags = []
            geom = []
            for ff, fwt, v in _fields(fb):
                if ff == 2:
                    tags = _packed(v)
                elif ff == 3:
                    gtype = v
                elif ff == 4:
                    geom = _packed(v)
            props = {keys[tags[i]]: vals[tags[i + 1]] for i in range(0, len(tags) - 1, 2) if tags[i] < len(keys) and tags[i + 1] < len(vals)}
            parts = []
            cur = []
            x = y = 0
            i = 0
            while i < len(geom):
                cmd = geom[i] & 7
                cnt = geom[i] >> 3
                i += 1
                if cmd == 1:
                    for _ in range(cnt):
                        x += _zz(geom[i])
                        y += _zz(geom[i + 1])
                        i += 2
                        if cur:
                            parts.append(cur)
                        cur = [(x, y)]
                elif cmd == 2:
                    for _ in range(cnt):
                        x += _zz(geom[i])
                        y += _zz(geom[i + 1])
                        i += 2
                        cur.append((x, y))
                elif cmd == 7:
                    if cur:
                        cur.append(cur[0])
            if cur:
                parts.append(cur)
            out.append((gtype, props, parts))
        layers[name] = (extent, out)
    return layers
