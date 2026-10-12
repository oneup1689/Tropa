"""Converts the PROJ EGM96 15' GeoTIFF into a compact int16 grid for the app.

Output (little endian): header = 4 x float32 (lat_top, lon_left, step_deg, reserved)
followed by rows x cols int16 values in centimetres. Rows go north to south, columns west to east.
The grid is subsampled to 0.5 degree to keep the asset small; error stays well under a metre.
"""
import struct
import sys

import numpy as np
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src)
print("size", img.size, "mode", img.mode)
tags = img.tag_v2
scale = tags.get(33550)  # ModelPixelScale
tie = tags.get(33922)    # ModelTiepoint
print("scale", scale, "tiepoint", tie)

arr = np.array(img, dtype=np.float32)
print("shape", arr.shape, "min", float(arr.min()), "max", float(arr.max()))

lon_left = float(tie[3])
lat_top = float(tie[4])
step = float(scale[0])
print("lat_top", lat_top, "lon_left", lon_left, "step", step)

# Subsample to 0.5 degree: keep every k-th row/column.
k = int(round(0.5 / step))
sub = arr[::k, ::k]
out_step = step * k
cm = np.clip(np.round(sub * 100.0), -32768, 32767).astype("<i2")
with open(dst, "wb") as f:
    f.write(struct.pack("<4f", lat_top, lon_left, out_step, 0.0))
    f.write(cm.tobytes())
print("wrote", dst, cm.shape, "bytes", 16 + cm.nbytes)

# Sanity checks against well known EGM96 values: Hanoi ~ -23 m ... Berlin ~ +46 m.
def lookup(lat, lon):
    r = (lat_top - lat) / out_step
    c = ((lon - lon_left) % 360.0) / out_step
    r0, c0 = int(np.floor(r)), int(np.floor(c))
    dr, dc = r - r0, c - c0
    r1 = min(r0 + 1, cm.shape[0] - 1)
    c1 = (c0 + 1) % cm.shape[1]
    v = (cm[r0, c0] * (1 - dr) * (1 - dc) + cm[r0, c1] * (1 - dr) * dc
         + cm[r1, c0] * dr * (1 - dc) + cm[r1, c1] * dr * dc)
    return v / 100.0

for name, lat, lon in [("Hanoi", 21.03, 105.85), ("Ho Chi Minh", 10.78, 106.7),
                       ("Berlin", 52.52, 13.4), ("Moscow", 55.75, 37.62), ("our test walk", 20.24, 105.98)]:
    print(name, round(lookup(lat, lon), 2), "m")
