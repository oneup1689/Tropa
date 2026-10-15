import json, math, os, sys
sp = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
sys.path.insert(0, sp)
import mapgen
from PIL import ImageDraw

os.makedirs(sp + r"\routes", exist_ok=True)


def via_path(g, comp, points, max_snap=600):
    """Shortest path through the via points (snapped to through-nodes of the main component); out-and-back spurs are removed."""
    keys = []
    for lat, lon in points:
        best, bd = None, 1e18
        for k, v in g.adj.items():
            if comp[k] != comp["main"] or len(v["nb"]) < 2:
                continue
            d = mapgen._hav(v["ll"], (lat, lon))
            if d < bd:
                best, bd = k, d
        if bd > max_snap:
            print("  via point far from a road:", (lat, lon), int(bd))
        keys.append(best)
    seq = []
    for a, b in zip(keys, keys[1:]):
        seg = g.route_keys(a, b)
        if seg is None:
            print("no route between", a, b)
            return None
        seq.extend(seg if not seq else seg[1:])
    out = []
    for k in seq:  # erase backtracking (a, b, ..., b, a)
        if len(out) >= 2 and out[-2] == k:
            out.pop()
        else:
            out.append(k)
    return [g.adj[k]["ll"] for k in out]


def main_comp(g):
    comp = g.components()
    cnt = {}
    for c in comp.values():
        cnt[c] = cnt.get(c, 0) + 1
    comp["main"] = max(cnt, key=cnt.get)
    return comp


def length_km(path):
    return sum(mapgen._hav(a, b) for a, b in zip(path, path[1:])) / 1000


def overlay(tiles, name, lat, lon, dlon, paths, size=1400):
    zoom = math.log2(size / (512 * dlon / 360))
    img = mapgen.render(tiles, lat, lon, zoom, size, size, ss=1)
    img = img.point(lambda v: min(255, int(v * 1.55 + 18)))
    d = ImageDraw.Draw(img)
    cx, cy = mapgen.world_xy(lat, lon, zoom)
    cols = [(255, 112, 67), (64, 196, 255), (105, 240, 174), (255, 213, 79), (224, 64, 251)]
    for i, p in enumerate(paths):
        pts = []
        for la, lo in p:
            x, y = mapgen.world_xy(la, lo, zoom)
            pts.append((x - cx + size / 2, y - cy + size / 2))
        d.line(pts, fill=cols[i % len(cols)], width=4)
    img.save(sp + r"\routes\%s.png" % name)
