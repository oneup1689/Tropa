import json, sys
sp = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
sys.path.insert(0, sp)
import mapgen
from routes import *

tiles = mapgen.Tiles(["demo_altai.pmtiles"])
bbox = (50.15, 86.95, 50.50, 87.90)
for Z in (12, 13):
    g = mapgen.road_graph(tiles, bbox, Z, "car")
    comp = main_comp(g)
    print("Z", Z, "nodes", len(g.adj))
    car = via_path(g, comp, [(50.315, 87.58), (50.345, 87.30), (50.385, 87.12)], max_snap=2000)
    print(" car km", length_km(car) if car else None)
rg = mapgen.river_graph(tiles, bbox, 12)
rc = main_comp(rg)
print("river nodes", len(rg.adj))
raft = via_path(rg, rc, [car[-1], (50.43, 86.85)], max_snap=9000)
print("car end", car[-1], "raft", raft[0], raft[-1])
print(" raft km", length_km(raft) if raft else None)
json.dump(car, open(sp + r"\routes\altai_car.json", "w"))
json.dump(raft, open(sp + r"\routes\altai_raft.json", "w"))
overlay(tiles, "altai_cands", 50.38, 87.10, 0.9, [car, raft])
