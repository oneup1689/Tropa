"""Adds a straight 60-point test route (about 280 m, heading north-east) to a pulled tropa.db.

Used by emu_check.ps1; the emulator walk follows the same line, then leaves it.
Usage: python -I emu_add_route.py path\to\tropa.db
"""
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
cur = con.cursor()
cur.execute("INSERT INTO routes(name, created_ms) VALUES('emu-test', 0)")
rid = cur.lastrowid
lat, lon = 21.0300, 105.8560
for i in range(60):
    cur.execute("INSERT INTO route_points(route_id, idx, lat, lon) VALUES(?,?,?,?)", (rid, i, lat, lon))
    lat += 0.00002
    lon += 0.00004
con.commit()
print("route id", rid)
