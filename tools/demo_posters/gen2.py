"""Demo tracks along real roads/rivers + map snapshots for the posters. Output: demo2/*.json, demo2/maps/*.png, demo2/thumbs/*.png"""
import datetime
import json
import math
import os
import random
import re
import shutil
import sys

sp = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
sys.path.insert(0, sp)
import mapgen

OUT = sp + r"\demo2"
os.makedirs(OUT + r"\maps", exist_ok=True)
if not os.path.exists(OUT + r"\thumbs"):
    shutil.copytree(sp + r"\demo\thumbs", OUT + r"\thumbs")
REAL_GPX = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa\test\tropa_5.gpx"
only = sys.argv[1:]


def want(name):
    return not only or name in only


def ms(y, mo, d, h, mi, tz):
    return int(datetime.datetime(y, mo, d, h, mi, tzinfo=datetime.timezone(datetime.timedelta(hours=tz))).timestamp() * 1000)


def resample_ll(path, step=4.0):
    lat0, lon0 = path[0]
    kx = 111320 * math.cos(math.radians(lat0))
    ky = 110574.0
    xy = [((lo - lon0) * kx, (la - lat0) * ky) for la, lo in path]
    out = [xy[0]]
    acc = 0.0
    for (x0, y0), (x1, y1) in zip(xy, xy[1:]):
        seg = math.hypot(x1 - x0, y1 - y0)
        if seg < 1e-6:
            continue
        pos = step - acc
        while pos <= seg:
            f = pos / seg
            out.append((x0 + (x1 - x0) * f, y0 + (y1 - y0) * f))
            pos += step
        acc = seg - (pos - step)
    # light smoothing (3 passes of a 5-point moving average) to remove the zig-zag of the road data
    for _ in range(3):
        sm = [out[0]]
        for i in range(1, len(out) - 1):
            lo, hi = max(0, i - 2), min(len(out), i + 3)
            sm.append((sum(p[0] for p in out[lo:hi]) / (hi - lo), sum(p[1] for p in out[lo:hi]) / (hi - lo)))
        sm.append(out[-1])
        out = sm
    return out, (lat0, lon0, kx, ky)


def elev_curve(anchors, n, rolling, rng, step=4.0):
    ph, ph2 = rng.uniform(0, 6.28), rng.uniform(0, 6.28)
    res = []
    for i in range(n):
        f = i / max(1, n - 1)
        base = anchors[-1][1]
        for k in range(len(anchors) - 1):
            if anchors[k][0] <= f <= anchors[k + 1][0]:
                a, b = anchors[k], anchors[k + 1]
                u = (f - a[0]) / max(1e-9, b[0] - a[0])
                u = (1 - math.cos(math.pi * u)) / 2
                base = a[1] + (b[1] - a[1]) * u
                break
        d = i * step
        res.append(base + rolling * (math.sin(d / 520 + ph) + 0.12 * math.sin(d / 170 + ph2)))
    return res


class Sim:
    def __init__(self, t0, seed):
        self.t = t0
        self.rng = random.Random(seed)
        self.pts = []
        self.notes = []
        self.nx = self.ny = self.ne = 0.0
        self.v = 0.0

    def emit(self, geo, x, y, e):
        lat0, lon0, kx, ky = geo
        self.nx = 0.85 * self.nx + self.rng.gauss(0, 0.9)
        self.ny = 0.85 * self.ny + self.rng.gauss(0, 0.9)
        self.ne = 0.97 * self.ne + self.rng.gauss(0, 0.5)
        lat = lat0 + (y + self.ny) / ky
        lon = lon0 + (x + self.nx) / kx
        self.pts.append([int(self.t), round(lat, 7), round(lon, 7), round(e + self.ne, 1)])

    def hold(self, geo, x, y, e, secs):
        end = self.t + secs * 1000
        while self.t < end:
            self.emit(geo, x, y, e)
            self.t += 20000
        self.v = 0.0

    def run(self, path_ll, anchors, rolling, kind, stops, dt=2.0):
        path, geo = resample_ll(path_ll)
        step = 4.0
        total = (len(path) - 1) * step
        elev = elev_curve(anchors, len(path), rolling, self.rng)
        curv = []
        for i in range(len(path)):
            a, b, c = path[max(0, i - 6)], path[i], path[min(len(path) - 1, i + 6)]
            h1 = math.atan2(b[1] - a[1], b[0] - a[0])
            h2 = math.atan2(c[1] - b[1], c[0] - b[0])
            curv.append(abs((h2 - h1 + math.pi) % (2 * math.pi) - math.pi) / 24.0)
        curv = [sum(curv[max(0, i - 8):i + 9]) / len(curv[max(0, i - 8):i + 9]) for i in range(len(curv))]
        stops = sorted(stops, key=lambda s: s[0])
        si = 0
        d = 0.0
        ph = self.rng.uniform(0, 6.28)
        while d < total:
            i = min(len(path) - 1, int(d / step))
            if si < len(stops) and d / total >= stops[si][0]:
                _, secs, text, photo = stops[si]
                si += 1
                x, y = path[i]
                self.hold(geo, x, y, elev[i], secs)
                if text or photo:
                    when = self.t - secs * 1000 * 0.6
                    lat = geo[0] + y / geo[3]
                    lon = geo[1] + x / geo[2]
                    self.notes.append({"ts": int(when), "lat": lat, "lon": lon, "text": text or "", "photo": photo or ""})
                continue
            j0, j1 = max(0, i - 8), min(len(path) - 1, i + 8)
            slope = (elev[j1] - elev[j0]) / max(1.0, (j1 - j0) * step)
            noise = 1 + 0.08 * math.sin(d / 170 + ph) + self.rng.gauss(0, 0.03)
            if kind == "bike":
                v = 4.7 * (1 - 7 * slope) if slope > 0 else 4.7 * (1 + 10 * -slope)
                v = max(1.9, min(10.8, v)) * noise
                v = min(v, math.sqrt(3.2 / max(curv[i], 1e-4)))
            elif kind == "car":
                v = 22.5 * noise
                v = max(3.0, min(v, math.sqrt(2.4 / max(curv[i], 1e-4))))
            else:
                v = max(0.9, 2.05 * noise)
            acc = 0.9 * dt if kind != "car" else 1.6 * dt
            self.v += max(-2.2 * dt, min(acc, v - self.v))
            self.v = max(0.6, self.v)
            d += self.v * dt
            i = min(len(path) - 1, int(d / step))
            self.emit(geo, path[i][0], path[i][1], elev[i])
            self.t += dt * 1000
        return geo


def dump(name, title, region, sim, extra):
    data = {"title": title, "region": region, "points": sim.pts, "notes": sorted(sim.notes, key=lambda n: n["ts"])}
    data.update(extra)
    json.dump(data, open(OUT + r"\%s.json" % name, "w", encoding="utf-8"), ensure_ascii=False)
    dist = sum(math.hypot((b[2] - a[2]) * 111320 * math.cos(math.radians(a[1])), (b[1] - a[1]) * 110574) for a, b in zip(sim.pts, sim.pts[1:]))
    tz = extra.get("tz", 0)
    span = (sim.pts[-1][0] - sim.pts[0][0]) / 3.6e6
    print(name, "points", len(sim.pts), "km %.1f" % (dist / 1000), "hours %.2f" % span,
          "from", datetime.datetime.fromtimestamp(sim.pts[0][0] / 1000, datetime.timezone(datetime.timedelta(hours=tz))).strftime("%d.%m %H:%M"))
    return data


# ------------------------------------------------------------------ camera (port of posterCamera)
def camera(pts_ll, area, canvas, widthPx):
    minLat = min(p[0] for p in pts_ll)
    maxLat = max(p[0] for p in pts_ll)
    minLon = min(p[1] for p in pts_ll)
    maxLon = max(p[1] for p in pts_ll)
    aw, ah = area[2], area[3]
    z = 18.0
    while z > 3:
        x0, y0 = mapgen.world_xy(maxLat, minLon, z)
        x1, y1 = mapgen.world_xy(minLat, maxLon, z)
        if abs(x1 - x0) <= aw and abs(y1 - y0) <= ah:
            break
        z -= 0.1
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    shiftY = canvas[1] / 2 - (area[1] + area[3] / 2)
    shiftX = canvas[0] / 2 - (area[0] + area[2] / 2)
    lat, lon = mapgen.world_latlon(cx + shiftX, cy + shiftY, z)
    zoomPx = z + math.log2(widthPx / canvas[0])
    return lat, lon, zoomPx


VERT = ((90, 400, 900, 730), (1080, 1920), 2160, 3840)
WIDE = ((660, 124, 1016, 596), (1800, 1200), 3600, 2400)


def make_maps(name, pts_ll, pm_files, formats=("vertical", "wide")):
    tiles = mapgen.Tiles(pm_files)
    cams = {}
    for fmt in formats:
        area, canvas, W, H = VERT if fmt == "vertical" else WIDE
        lat, lon, zoom = camera(pts_ll, area, canvas, W)
        img = mapgen.render(tiles, lat, lon, zoom, W, H, ss=2)
        img.save(OUT + r"\maps\%s_%s.png" % (name, fmt))
        cams[fmt] = {"lat": lat, "lon": lon, "zoom": zoom, "w": W, "h": H}
        print("  map", name, fmt, "zoom %.2f" % zoom)
    json.dump(cams, open(OUT + r"\maps\%s_cam.json" % name, "w"))


def load_ll(name):
    return [tuple(p) for p in json.load(open(sp + r"\routes\%s.json" % name))]


# ------------------------------------------------------------------ P1: real hike
if want("p1_hike"):
    txt = open(REAL_GPX, encoding="utf-8").read()
    re_pt = re.compile(r'<trkpt lat="([\d.\-]+)" lon="([\d.\-]+)"><ele>([\d.\-]+)</ele><time>([^<]+)</time>')
    pts = []
    for m in re_pt.finditer(txt):
        ts = int(datetime.datetime.fromisoformat(m.group(4).replace("Z", "+00:00")).timestamp() * 1000)
        pts.append([ts, float(m.group(1)), float(m.group(2)), float(m.group(3))])
    pts = pts[328:]  # the walk itself: the first 11 minutes are a taxi ride to the foot of the hill
    top = max(range(len(pts)), key=lambda i: pts[i][3])
    far = lambda i: math.hypot((pts[i][2] - pts[top][2]) * 111320 * math.cos(math.radians(pts[top][1])), (pts[i][1] - pts[top][1]) * 110574)
    lo = top
    while lo > 0 and far(lo - 1) < 650:
        lo -= 1
    hi = top
    while hi < len(pts) - 1 and far(hi + 1) < 650:
        hi += 1
    pts = pts[lo:hi + 1]  # the climb and the descent around the summit
    at = lambda ts: min(pts, key=lambda p: abs(p[0] - ts))
    notes = []

    def add(ts, text, photo=""):
        p = at(ts)
        notes.append({"ts": p[0], "lat": p[1], "lon": p[2], "text": text, "photo": photo})

    add(pts[8][0], "Начало тропы")
    add(ms(2026, 10, 12, 8, 14, 7), "Скалы и джунгли по пути вверх", "hike_rocks")
    add(ms(2026, 10, 12, 8, 42, 7), "Вершина, пагода!", "hike_pagoda")
    add(pts[int(len(pts) * 0.8)][0], "Привал в тени на спуске")
    add(pts[-8][0], "Внизу: холодный лимонад")
    print("hike crop", len(pts), datetime.datetime.fromtimestamp(pts[0][0] / 1000, datetime.timezone(datetime.timedelta(hours=7))).strftime("%H:%M"),
          datetime.datetime.fromtimestamp(pts[-1][0] / 1000, datetime.timezone(datetime.timedelta(hours=7))).strftime("%H:%M"))
    data = {"title": "Хан-Муа: на вершину", "region": "Ниньбинь, Вьетнам", "points": pts, "notes": sorted(notes, key=lambda n: n["ts"]), "real": True, "tz": 7}
    json.dump(data, open(OUT + r"\p1_hike.json", "w", encoding="utf-8"), ensure_ascii=False)
    print("p1_hike points", len(pts))
    make_maps("p1_hike", [(p[1], p[2]) for p in pts], ["demo_hangmua.pmtiles"])

# ------------------------------------------------------------------ P2: bike ride along real roads (Urals)
URAL = ["demo_ural.pmtiles"]
if want("p2_bike"):
    sim = Sim(ms(2024, 5, 21, 10, 40, 5), 21)
    path = load_ll("ural_ride2")
    anch = [(0, 235), (0.2, 262), (0.35, 248), (0.5, 275), (0.7, 258), (0.85, 270), (1, 236)]
    stops = [(0.07, 480, "Кофе у пруда", None), (0.28, 780, "Смотровая площадка", "bike_view"), (0.50, 2100, "Обед на берегу", None),
             (0.70, 1200, "Карьер", "bike_quarry"), (0.88, 420, "Последний подъём", None)]
    sim.run(path, anch, 7.0, "bike", stops)
    dump("p2_bike", "Велопрогулка к карьеру", "Урал, Россия", sim, {"tz": 5})
    make_maps("p2_bike", [(p[1], p[2]) for p in sim.pts], URAL)

# ------------------------------------------------------------------ P3: car + raft (Altai valley)
if want("p3_car_raft"):
    sim = Sim(ms(2021, 8, 6, 9, 40, 7), 6)
    car = load_ll("altai_car")
    raft = load_ll("altai_raft")
    stops = [(0.08, 600, "Заправка и кофе", None), (0.28, 600, "Остановка в долине", "car_valley"), (0.58, 600, "Дорога вдоль реки", "car_road")]
    sim.run(car, [(0, 1010), (0.5, 940), (1, 880)], 6.0, "car", stops, dt=3.0)
    last = sim.pts[-1]
    sim.t = last[0] + 20000
    geo = (last[1], last[2], 111320 * math.cos(math.radians(last[1])), 110574.0)
    sim.hold(geo, 0, 0, last[3], 3000)
    sim.notes.append({"ts": int(sim.t - 1500000), "lat": last[1], "lon": last[2], "text": "Накачиваем лодки", "photo": ""})
    water_from = int(sim.t)
    sim.run(raft, [(0, 880), (1, 850)], 0.6, "raft", [(0.42, 1500, None, None), (0.78, 600, "Свет над рекой", "raft_sun")], dt=4.0)
    lastp = sim.pts[-1]
    dump("p3_car_raft", "Дорога и сплав", "Горный Алтай, Россия", sim, {"tz": 7, "water_from_ts": water_from})
    make_maps("p3_car_raft", [(p[1], p[2]) for p in sim.pts], ["demo_altai.pmtiles"])

# ------------------------------------------------------------------ P4: a week of rides in the same region
if want("p4_week"):
    rides = [("Выезд к озеру", "ural_ride4", 5), ("Лесные тропы", "ural_b_nw", 5), ("Карьер и сосны", "ural_ride3", 5),
             ("Закатная петля", "ural_c_pond", 5), ("Длинный день", "ural_ride2", 5)]
    allpts = []
    for i, (title, route, tz) in enumerate(rides):
        sim = Sim(ms(2024, 5, 20 + i, 9 + (i % 3), 20, tz), 100 + i)
        sim.run(load_ll(route), [(0, 235), (0.3, 262), (0.6, 250), (1, 236)], 7.0, "bike", [(0.3, 600, None, None), (0.62, 900, None, None)])
        dump("p4_week_%d" % (i + 1), title, "Урал, Россия", sim, {"tz": tz})
        allpts += [(p[1], p[2]) for p in sim.pts]
    make_maps("p4_week", allpts, URAL, formats=("wide",))
