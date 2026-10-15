import io
import math
import re
import sys
from datetime import datetime

path = sys.argv[1]
s = io.open(path, encoding="utf-8").read()
pts = []
for m in re.finditer(r'<trkpt lat="([\d.\-]+)" lon="([\d.\-]+)"><ele>([\d.\-]+)</ele><time>([^<]+)</time>', s):
    t = datetime.strptime(m.group(4), "%Y-%m-%dT%H:%M:%S.%fZ")
    pts.append((float(m.group(1)), float(m.group(2)), float(m.group(3)), t))


def hav(a, b):
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


out = []
out.append("points %d  first %s  last %s" % (len(pts), pts[0][3], pts[-1][3]))
total = 0.0
moving = 0.0
maxv = (0, None)
gaps = []
jumps = []
still = 0.0
speeds = []
for i in range(1, len(pts)):
    d = hav(pts[i - 1], pts[i])
    dt = (pts[i][3] - pts[i - 1][3]).total_seconds()
    total += d
    if dt > 0:
        v = d / dt
        speeds.append(v)
        if v > maxv[0]:
            maxv = (v, i)
        if v > 0.5:
            moving += dt
        if d < 2 and dt > 20:
            still += dt
    if dt > 40:
        gaps.append((i, dt, d))
    if d > 60:
        jumps.append((i, d, dt))
dur = (pts[-1][3] - pts[0][3]).total_seconds()
out.append("total %.0f m  duration %.0f min  moving(>0.5 m/s) %.0f min  still %.0f min" % (total, dur / 60, moving / 60, still / 60))
out.append("avg speed %.2f km/h over moving  max %.1f m/s (%.1f km/h) at idx %s" % (total / max(moving, 1) * 3.6, maxv[0], maxv[0] * 3.6, maxv[1]))
out.append("gaps >40 s: %d" % len(gaps))
for g in gaps[:25]:
    i = g[0]
    out.append("  idx %d gap %.0f s moved %.0f m  at %s" % (i, g[1], g[2], pts[i][3]))
out.append("jumps >60 m between points: %d" % len(jumps))
for j in jumps[:15]:
    out.append("  idx %d %.0f m in %.0f s  at %s" % (j[0], j[1], j[2], pts[j[0]][3]))
# first points identical
same = 0
for i in range(1, len(pts)):
    if pts[i][0] == pts[0][0] and pts[i][1] == pts[0][1]:
        same += 1
    else:
        break
out.append("identical points at the start: %d" % same)
els = [p[2] for p in pts]
out.append("elevation min %.1f max %.1f" % (min(els), max(els)))
# speed histogram
bins = [0, 0.3, 0.8, 1.5, 2.5, 4, 8, 100]
h = [0] * (len(bins) - 1)
for v in speeds:
    for k in range(len(bins) - 1):
        if bins[k] <= v < bins[k + 1]:
            h[k] += 1
out.append("speed hist m/s " + str(list(zip(bins[:-1], h))))
# loop closure
out.append("start-end distance %.0f m" % hav(pts[0], pts[-1]))
# local time
out.append("local (UTC+7) start %s" % (pts[0][3].replace(hour=(pts[0][3].hour + 7) % 24)))
io.open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + "\n")
