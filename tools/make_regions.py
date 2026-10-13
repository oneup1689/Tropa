"""Builds assets/maps/regions.json (the catalog of downloadable map regions) from Natural Earth admin-1.

Input: the unpacked ne_10m_admin_1_states_provinces.* files (public domain, naturalearthdata.com).
Output: countries with their provinces/oblasts: names in Russian and English, bounding box.
Only bounding boxes are kept: a map region is the rectangle around the province (maps overlap a little at the borders, which is
harmless and is how most offline-map apps cut regions).

Usage: python -I tools/make_regions.py <folder with ne_10m_admin_1_states_provinces.shp/.dbf> <out.json>
"""
import json
import struct
import sys
from pathlib import Path

folder, out = Path(sys.argv[1]), Path(sys.argv[2])
base = folder / "ne_10m_admin_1_states_provinces"


def read_dbf(path):
    data = path.read_bytes()
    n_records, header_len, rec_len = struct.unpack("<IHH", data[4:12])
    fields = []
    pos = 32
    while data[pos] != 0x0D:
        name = data[pos:pos + 11].split(b"\0")[0].decode("ascii")
        length = data[pos + 16]
        fields.append((name, length))
        pos += 32
    rows = []
    for i in range(n_records):
        rec = data[header_len + i * rec_len: header_len + (i + 1) * rec_len]
        off = 1
        row = {}
        for name, length in fields:
            row[name] = rec[off:off + length].decode("utf-8", "replace").strip(chr(0) + " ")
            off += length
        rows.append(row)
    return rows


def read_shp_bboxes(path):
    data = path.read_bytes()
    pos = 100
    boxes = []
    while pos + 8 <= len(data):
        _, content_len = struct.unpack(">ii", data[pos:pos + 8])
        content = data[pos + 8: pos + 8 + content_len * 2]
        shape_type = struct.unpack("<i", content[:4])[0]
        if shape_type in (5, 15, 25):  # polygon types
            boxes.append(struct.unpack("<4d", content[4:36]))  # minX minY maxX maxY
        else:
            boxes.append(None)
        pos += 8 + content_len * 2
    return boxes


rows = read_dbf(base.with_suffix(".dbf"))
boxes = read_shp_bboxes(base.with_suffix(".shp"))
assert len(rows) == len(boxes), (len(rows), len(boxes))

countries = {}
for row, box in zip(rows, boxes):
    if box is None:
        continue
    iso = row.get("adm0_a3", "")
    admin_en = row.get("admin", "")
    name_en = row.get("name_en") or row.get("name") or ""
    name_ru = row.get("name_ru") or name_en
    if not name_en:
        continue
    c = countries.setdefault(iso + "|" + admin_en, {"iso": iso, "en": admin_en, "ru": admin_en, "box": [180, 90, -180, -90], "regions": []})
    c["box"] = [min(c["box"][0], box[0]), min(c["box"][1], box[1]), max(c["box"][2], box[2]), max(c["box"][3], box[3])]
    c["regions"].append({"en": name_en, "ru": name_ru, "box": [round(v, 3) for v in box]})

# Russian names of the countries: tools/countries_ru.json (by the English name used in the data).
ru_names = json.loads((Path(__file__).parent / "countries_ru.json").read_text(encoding="utf-8"))

result = []
for c in sorted(countries.values(), key=lambda c: c["en"]):
    c["box"] = [round(v, 3) for v in c["box"]]
    c["ru"] = ru_names.get(c["en"], c["en"])
    c["regions"].sort(key=lambda r: r["en"])
    # A rectangle cannot cross the antimeridian: such regions (Chukotka, the Aleutians...) are left out, and
    # "the whole country" is not offered for countries that span more than 180 degrees of longitude.
    c["whole"] = (c["box"][2] - c["box"][0]) <= 180
    c["regions"] = [r for r in c["regions"] if (r["box"][2] - r["box"][0]) <= 180]
    if c["regions"] or c["whole"]:
        result.append(c)

out.write_text(json.dumps({"source": "Natural Earth admin-1 (public domain)", "countries": result}, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
print(len(result), "countries,", sum(len(c["regions"]) for c in result), "regions ->", out, out.stat().st_size, "bytes")
