"""Adds two Z-shaped test routes: one inside the testwalk map region, one outside of it."""
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
cur = con.cursor()


def add(name, lat, lon):
    cur.execute("INSERT INTO routes(name, created_ms) VALUES(?, 0)", (name,))
    rid = cur.lastrowid
    pts = [(lat, lon)]
    for _ in range(40):
        lat += 0.00009
        pts.append((lat, lon))
    for _ in range(40):
        lon += 0.0000962
        pts.append((lat, lon))
    for _ in range(40):
        lat += 0.00009
        pts.append((lat, lon))
    for _ in range(40):
        lon -= 0.0000962
        pts.append((lat, lon))
    for i, (a, b) in enumerate(pts):
        cur.execute("INSERT INTO route_points(route_id, idx, lat, lon) VALUES(?,?,?,?)", (rid, i, a, b))
    print(name, rid, len(pts))


add("In-map", 20.2500, 106.0000)
add("No-map", 21.0300, 105.8560)
con.commit()
