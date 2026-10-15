"""Adds a Z-shaped test route (north 300 m, east 300 m, north 300 m) to a pulled tropa.db.

Usage: python -I emu_add_zroute.py <path to tropa.db>
"""
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
cur = con.cursor()
cur.execute("INSERT INTO routes(name, created_ms) VALUES('L-test', 0)")
rid = cur.lastrowid
lat, lon = 21.0300, 105.8560
pts = [(lat, lon)]
for _ in range(30):
    lat += 0.00009
    pts.append((lat, lon))
for _ in range(30):
    lon += 0.0000962
    pts.append((lat, lon))
for _ in range(30):
    lat += 0.00009
    pts.append((lat, lon))
for i, (a, b) in enumerate(pts):
    cur.execute("INSERT INTO route_points(route_id, idx, lat, lon) VALUES(?,?,?,?)", (rid, i, a, b))
con.commit()
print("route id", rid, "points", len(pts))
