"""Dark Tropa-style map renderer and road/river router on top of mapkit (PMTiles + MVT).

render(...) makes the same kind of bare snapshot the app takes with MapLibre: Web Mercator, 512-px world.
"""
import heapq
import math
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad")
from mapkit import PMTiles, decode_mvt

D = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa\data\maps"


def world_xy(lat, lon, zoom):
    w = 512 * 2 ** zoom
    x = (lon + 180) / 360 * w
    s = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * w
    return x, y


def world_latlon(x, y, zoom):
    w = 512 * 2 ** zoom
    lon = x / w * 360 - 180
    n = math.pi - 2 * math.pi * y / w
    lat = math.degrees(math.atan(0.5 * (math.exp(n) - math.exp(-n))))
    return lat, lon


def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# ------------------------------------------------------------------ style
def interp(stops, z, base=1.6):
    if z <= stops[0][0]:
        return stops[0][1]
    for (z0, v0), (z1, v1) in zip(stops, stops[1:]):
        if z <= z1:
            if base == 1:
                t = (z - z0) / (z1 - z0)
            else:
                t = (base ** (z - z0) - 1) / (base ** (z1 - z0) - 1)
            return v0 + (v1 - v0) * t
    return stops[-1][1]


W_MINOR = [(11, 0), (12.5, 0.5), (15, 2), (18, 11)]
W_MAJOR = [(6, 0), (12, 1.6), (15, 3), (18, 13)]
W_HIGHWAY = [(3, 0), (6, 1.1), (12, 1.6), (15, 5), (18, 15)]
W_OTHER = [(14, 0.5), (20, 12)]
W_RIVER = [(9, 0), (9.5, 1), (18, 12)]

LAND = {
    "wood": "#1b2a21", "forest": "#1b2a21", "grassland": "#1e291f", "grass": "#1e291f", "scrub": "#222a22", "farmland": "#202619",
    "wetland": "#1c2a2a", "bare_rock": "#262624", "barren": "#262624", "glacier": "#33383c", "park": "#1b2a21", "nature_reserve": "#1b2a21",
    "national_park": "#1b2a21", "protected_area": "#1b2a21", "allotments": "#192a24", "village_green": "#192a24", "meadow": "#1e291f",
    "residential": "#1c1c1c", "industrial": "#222222", "cemetery": "#1b2a21", "recreation_ground": "#1e2a20", "pitch": "#1e2a20",
}


class Tiles:
    def __init__(self, files):
        self.pms = [PMTiles(D + "\\" + f) for f in files]
        self.cache = {}

    def get(self, z, x, y):
        key = (z, x, y)
        if key in self.cache:
            return self.cache[key]
        res = None
        for pm in self.pms:
            raw = pm.get(z, x, y)
            if raw:
                res = decode_mvt(raw)
                break
        self.cache[key] = res
        return res


def tile_range(lat0, lon0, lat1, lon1, Z):
    n = 2 ** Z

    def tx(lon):
        return (lon + 180) / 360 * n

    def ty(lat):
        s = math.sin(math.radians(lat))
        return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n

    return int(tx(lon0)), int(tx(lon1)), int(ty(lat1)), int(ty(lat0))


def render(tiles, lat, lon, zoom, W, H, ss=2, labels=False):
    """zoom: 512-world zoom at the picture's own pixel size (as in MapCapture)."""
    ratio = W / 1080.0
    cx, cy = world_xy(lat, lon, zoom)
    ox, oy = cx - W / 2, cy - H / 2
    Z = max(0, min(14, int(math.ceil(zoom + 0.6))))
    tilesize = 512 * 2 ** zoom / 2 ** Z
    x0, x1 = int(ox // tilesize), int((ox + W) // tilesize)
    y0, y1 = int(oy // tilesize), int((oy + H) // tilesize)
    zs = zoom - math.log2(ratio)  # style zoom (logical px)

    S = ss
    img = Image.new("RGB", (W * S, H * S), hexc("#34373d"))
    dr = ImageDraw.Draw(img)

    def proj(tx_, ty_, ext, pts):
        k = tilesize / ext * S
        bx = (tx_ * tilesize - ox) * S
        by = (ty_ * tilesize - oy) * S
        return [(bx + p[0] * k, by + p[1] * k) for p in pts]

    data = []
    for ty_ in range(y0, y1 + 1):
        for tx_ in range(x0, x1 + 1):
            if not (0 <= tx_ < 2 ** Z and 0 <= ty_ < 2 ** Z):
                continue
            t = tiles.get(Z, tx_, ty_)
            if t:
                data.append((tx_, ty_, t))

    def polys(layer_names, colorfn):
        # group by colour; draw exteriors then holes through a mask
        groups = {}
        for tx_, ty_, t in data:
            for ln in layer_names:
                if ln not in t:
                    continue
                ext, feats = t[ln]
                for gt, props, parts in feats:
                    if gt != 3:
                        continue
                    col = colorfn(props)
                    if col is None:
                        continue
                    groups.setdefault(col, []).append(proj(tx_, ty_, ext, parts[0]) if False else [proj(tx_, ty_, ext, r) for r in parts])
        for col, items in groups.items():
            mask = Image.new("L", img.size, 0)
            md = ImageDraw.Draw(mask)
            for rings in items:
                for r in rings:
                    if len(r) < 3:
                        continue
                    area = sum(r[i][0] * r[i + 1][1] - r[i + 1][0] * r[i][1] for i in range(len(r) - 1))
                    md.polygon(r, fill=255 if area > 0 else 0)
            img.paste(col, (0, 0), mask)

    # earth
    polys(["earth"], lambda p: hexc("#1f1f1f"))
    polys(["landcover", "natural"], lambda p: hexc(LAND.get(p.get("kind"), "#1f1f1f")))
    polys(["landuse"], lambda p: hexc(LAND[p["kind"]]) if p.get("kind") in LAND else None)
    polys(["water"], lambda p: hexc("#31353f"))

    def lines(layer, cond, colorfn, widthfn, sortkey=None):
        items = []
        for tx_, ty_, t in data:
            if layer not in t:
                continue
            ext, feats = t[layer]
            for gt, props, parts in feats:
                if gt != 2 or not cond(props):
                    continue
                for part in parts:
                    items.append((sortkey(props) if sortkey else 0, props, proj(tx_, ty_, ext, part)))
        items.sort(key=lambda i: i[0])
        for _, props, pts in items:
            w = widthfn(props)
            if w <= 0:
                continue
            col = colorfn(props)
            dr.line(pts, fill=col, width=max(1, int(round(w * ratio * S))), joint="curve")

    lines("water", lambda p: p.get("kind") == "stream", lambda p: hexc("#31353f"), lambda p: 0.5)
    lines("water", lambda p: p.get("kind") in ("river", "canal"), lambda p: hexc("#31353f"), lambda p: interp(W_RIVER, zs))

    order = {"other": 0, "path": 0, "minor_road": 1, "major_road": 2, "highway": 3, "rail": 4}

    def kind_w(p):
        k = p.get("kind")
        if k in ("path", "other"):
            return interp(W_OTHER, zs)
        if k == "minor_road":
            return interp(W_MINOR, zs) * (0.7 if p.get("kind_detail") == "service" else 1)
        if k == "major_road":
            return interp(W_MAJOR, zs)
        if k == "highway":
            return interp(W_HIGHWAY, zs)
        if k == "rail":
            return interp([(3, 0), (6, 0.15), (18, 9)], zs)
        return 0

    def kind_c(p):
        k = p.get("kind")
        return {"highway": hexc("#474747"), "major_road": hexc("#3d3d3d"), "minor_road": hexc("#363636"), "rail": hexc("#0a0a0a")}.get(k, hexc("#333333"))

    # buildings first (under roads)
    polys(["buildings"], lambda p: hexc("#111111"))
    # casings then fills
    lines("roads", lambda p: p.get("kind") in ("minor_road", "major_road", "highway"), lambda p: hexc("#1b1b1b"), lambda p: kind_w(p) + 1.0 if kind_w(p) > 0.6 else 0,
          lambda p: order.get(p.get("kind"), 0))
    lines("roads", lambda p: True, kind_c, kind_w, lambda p: order.get(p.get("kind"), 0))

    if S > 1:
        img = img.resize((W, H), Image.LANCZOS)
    return img


# ------------------------------------------------------------------ routing
def _hav(a, b):
    dy = (b[0] - a[0]) * 110574.0
    dx = (b[1] - a[1]) * 111320.0 * math.cos(math.radians((a[0] + b[0]) / 2))
    return math.hypot(dx, dy)


class Graph:
    def __init__(self):
        self.adj = {}

    @staticmethod
    def key(lat, lon):
        return (round(lat / 1.5e-5), round(lon / 1.5e-5))

    def add_line(self, pts, weight_mult=1.0, oneway=False):
        prev = None
        for lat, lon in pts:
            k = self.key(lat, lon)
            self.adj.setdefault(k, {"ll": (lat, lon), "nb": {}})
            if prev is not None and prev != k:
                d = _hav(self.adj[prev]["ll"], (lat, lon))
                w = d * weight_mult
                cur = self.adj[prev]["nb"].get(k)
                if cur is None or w < cur:
                    self.adj[prev]["nb"][k] = w
                if not oneway:
                    cur2 = self.adj[k]["nb"].get(prev)
                    if cur2 is None or w < cur2:
                        self.adj[k]["nb"][prev] = w
            prev = k

    def heal(self, tol_m=4.0):
        """Joins nodes that are within tol_m (tile edges, T-junction slop)."""
        cell = {}
        for k, v in self.adj.items():
            cell.setdefault((int(v["ll"][0] / 5e-5), int(v["ll"][1] / 5e-5)), []).append(k)
        for k, v in list(self.adj.items()):
            la, lo = v["ll"]
            ci, cj = int(la / 5e-5), int(lo / 5e-5)
            for di in (-1, 0, 1):
                for dj in (-1, 0, 1):
                    for k2 in cell.get((ci + di, cj + dj), []):
                        if k2 != k and k2 not in v["nb"]:
                            d = _hav(v["ll"], self.adj[k2]["ll"])
                            if d < tol_m:
                                v["nb"][k2] = d + 0.1
                                self.adj[k2]["nb"][k] = d + 0.1

    def nearest(self, lat, lon):
        best, bd = None, 1e18
        for k, v in self.adj.items():
            d = _hav(v["ll"], (lat, lon))
            if d < bd:
                best, bd = k, d
        return best, bd

    def route(self, a, b):
        ks = self.route_keys(a, b)
        return None if ks is None else [self.adj[k]["ll"] for k in ks]

    def route_keys(self, a, b):
        dist = {a: 0.0}
        prev = {}
        pq = [(0.0, a)]
        while pq:
            d, u = heapq.heappop(pq)
            if u == b:
                break
            if d > dist.get(u, 1e18):
                continue
            for v, w in self.adj[u]["nb"].items():
                nd = d + w
                if nd < dist.get(v, 1e18):
                    dist[v] = nd
                    prev[v] = u
                    heapq.heappush(pq, (nd, v))
        if b not in prev and a != b:
            return None
        path = [b]
        while path[-1] != a:
            path.append(prev[path[-1]])
        path.reverse()
        return path

    def components(self):
        seen = {}
        cid = 0
        for s in self.adj:
            if s in seen:
                continue
            stack = [s]
            seen[s] = cid
            while stack:
                u = stack.pop()
                for v in self.adj[u]["nb"]:
                    if v not in seen:
                        seen[v] = cid
                        stack.append(v)
            cid += 1
        return seen


def clip_line(pts, ext):
    """Clips a polyline to the tile square [0, ext]; returns the pieces (tiles carry a buffer outside it)."""
    pieces, cur = [], []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        dx, dy = x1 - x0, y1 - y0
        t0, t1 = 0.0, 1.0
        ok = True
        for p_, q_ in ((-dx, x0), (dx, ext - x0), (-dy, y0), (dy, ext - y0)):
            if p_ == 0:
                if q_ < 0:
                    ok = False
                    break
            else:
                r = q_ / p_
                if p_ < 0:
                    t0 = max(t0, r)
                else:
                    t1 = min(t1, r)
        if not ok or t0 > t1:
            if len(cur) > 1:
                pieces.append(cur)
            cur = []
            continue
        a = (x0 + t0 * dx, y0 + t0 * dy)
        b = (x0 + t1 * dx, y0 + t1 * dy)
        if not cur or (abs(cur[-1][0] - a[0]) > 1e-6 or abs(cur[-1][1] - a[1]) > 1e-6):
            if len(cur) > 1:
                pieces.append(cur)
            cur = [a]
        cur.append(b)
    if len(cur) > 1:
        pieces.append(cur)
    return pieces


def read_lines(tiles, bbox, Z, layer, cond):
    """bbox = (lat0, lon0, lat1, lon1). Returns [(props, [(lat, lon)...])]"""
    x0, x1, y0, y1 = tile_range(*bbox, Z)
    out = []
    n = 2 ** Z
    for ty in range(y0, y1 + 1):
        for tx in range(x0, x1 + 1):
            t = tiles.get(Z, tx, ty)
            if not t or layer not in t:
                continue
            ext, feats = t[layer]
            for gt, props, parts in feats:
                if gt != 2 or not cond(props):
                    continue
                for part0 in parts:
                  for part in clip_line(part0, ext):
                    pts = []
                    for px, py in part:
                        lon = (tx + px / ext) / n * 360 - 180
                        lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (ty + py / ext) / n))))
                        pts.append((lat, lon))
                    out.append((props, pts))
    return out


def road_graph(tiles, bbox, Z, mode):
    g = Graph()
    for props, pts in read_lines(tiles, bbox, Z, "roads", lambda p: p.get("kind") != "rail"):
        k = props.get("kind")
        if mode == "bike":
            mult = {"highway": 4.0, "major_road": 1.6, "minor_road": 1.0, "path": 0.8, "other": 1.0}.get(k, 1.0)
            if props.get("kind_detail") in ("motorway", "trunk"):
                mult = 6.0
        elif mode == "car":
            mult = {"highway": 0.8, "major_road": 0.9, "minor_road": 1.4, "path": 4.0, "other": 3.0}.get(k, 1.0)
        else:  # walk
            mult = {"highway": 5.0, "major_road": 1.5, "minor_road": 1.0, "path": 0.7, "other": 0.9}.get(k, 1.0)
        g.add_line(pts, mult)
    g.heal()
    return g


def river_graph(tiles, bbox, Z):
    g = Graph()
    for props, pts in read_lines(tiles, bbox, Z, "water", lambda p: p.get("kind") in ("river", "canal")):
        g.add_line(pts, 1.0)
    g.heal(6.0)
    return g
