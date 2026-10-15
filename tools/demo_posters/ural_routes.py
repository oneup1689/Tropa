import json, sys
sp = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
sys.path.insert(0, sp)
import mapgen
from routes import *

tiles = mapgen.Tiles(["demo_ural.pmtiles"])
bbox = (56.30, 60.55, 56.64, 61.10)
g = mapgen.road_graph(tiles, bbox, 14, "bike")
comp = main_comp(g)
print("nodes", len(g.adj))

P1 = (56.49, 60.81)   # viewpoint (rounded)
P2 = (56.49, 60.73)   # quarry (rounded)
START = (56.5015, 60.8130)
cands = {
    "a_east": [START, (56.505, 60.90), (56.50, 61.00), (56.46, 61.06), (56.40, 61.02), (56.44, 60.93), START],
    "b_nw": [START, (56.55, 60.72), (56.60, 60.65), (56.56, 60.58), (56.52, 60.66), START],
    "c_pond": [START, P1, (56.47, 60.77), (56.465, 60.72), P2, (56.515, 60.74), START],
    "d_south": [START, (56.45, 60.86), (56.38, 60.88), (56.34, 60.80), (56.40, 60.76), (56.46, 60.80), START],
    "e_ne": [START, (56.56, 60.90), (56.63, 60.96), (56.64, 61.05), (56.57, 61.02), (56.52, 60.95), START],
    "f_far_west": [START, (56.49, 60.68), (56.46, 60.55), (56.40, 60.45), (56.37, 60.55), (56.44, 60.66), START],
}
paths = []
for k, pts in cands.items():
    r = via_path(g, comp, pts)
    if r:
        p = r
        print(k, "km %.1f" % length_km(p))
        paths.append(p)
        json.dump(p, open(sp + r"\routes\ural_%s.json" % k, "w"))
overlay(tiles, "ural_cands2", 56.45, 60.82, 0.62, paths)
