"""Builds a tropa.db for the emulator from the owner's test GPX (kept outside git).

The schema matches the app (user_version 3). Barometer pressure is synthesised from the GPX heights so the
barometer code path can be exercised; one note is added in the middle of the walk.
"""
import math
import sqlite3
import sys
import xml.etree.ElementTree as ET
from datetime import datetime

gpx, out = sys.argv[1], sys.argv[2]
ns = {"g": "http://www.topografix.com/GPX/1/1"}
root = ET.parse(gpx).getroot()
pts = []
for p in root.iterfind(".//g:trkpt", ns):
    t = datetime.fromisoformat(p.find("g:time", ns).text.replace("Z", "+00:00"))
    pts.append((int(t.timestamp() * 1000), float(p.get("lat")), float(p.get("lon")), float(p.find("g:ele", ns).text)))

db = sqlite3.connect(out)
c = db.cursor()
c.executescript(
    """
CREATE TABLE sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, start_ms INTEGER NOT NULL, end_ms INTEGER,
  status TEXT NOT NULL, mode TEXT NOT NULL DEFAULT 'mixed');
CREATE TABLE points(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL, acc REAL, alt REAL, speed REAL, pressure REAL);
CREATE INDEX idx_points_session ON points(session_id, ts_ms);
CREATE TABLE notes(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL, text TEXT NOT NULL DEFAULT '', media_type TEXT NOT NULL DEFAULT '',
  media_name TEXT NOT NULL DEFAULT '');
CREATE TABLE routes(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_ms INTEGER NOT NULL);
CREATE TABLE route_points(route_id INTEGER NOT NULL, idx INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
  PRIMARY KEY (route_id, idx));
"""
)
c.execute("INSERT INTO sessions(start_ms,end_ms,status,mode) VALUES (?,?,?,?)", (pts[0][0], pts[-1][0], "finished", "walk"))
sid = c.lastrowid
for ts, lat, lon, ele in pts:
    # Pressure follows a slow synthetic profile: real heights are too noisy to look like a barometer.
    prog = (ts - pts[0][0]) / (pts[-1][0] - pts[0][0])
    true_alt = 8 + 12 * math.sin(prog * math.pi * 2)
    hpa = 1013.25 * (1 - (true_alt + 15) / 44330.0) ** 5.255
    c.execute("INSERT INTO points(session_id,ts_ms,lat,lon,acc,alt,speed,pressure) VALUES (?,?,?,?,?,?,?,?)",
              (sid, ts, lat, lon, 6.0, ele, 1.0, hpa))
mid = pts[len(pts) // 2]
c.execute("INSERT INTO notes(session_id,ts_ms,lat,lon,text) VALUES (?,?,?,?,?)", (sid, mid[0], mid[1], mid[2], "Тестовая заметка"))

# The same walk as an imported route (first 400 points, as if somebody else recorded it).
c.execute("INSERT INTO routes(name,created_ms) VALUES (?,?)", ("Тестовый маршрут", pts[0][0]))
rid = c.lastrowid
for i, (ts, lat, lon, ele) in enumerate(pts[:400]):
    c.execute("INSERT INTO route_points VALUES (?,?,?,?)", (rid, i, lat, lon))
c.execute("PRAGMA user_version = 3")
db.commit()
print("points", len(pts), "session", sid, "route", rid)
