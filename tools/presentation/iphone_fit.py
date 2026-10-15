"""Fits Android screenshots and 9:16 posters to an iPhone Pro screen (ratio ~2.164): pad, status bar, dynamic island, home indicator."""
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SP = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
OUT = SP + r"\shots_out"
RUBIK = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa\assets\fonts\Rubik-Variable.ttf"
CW, CH = 1080, 2337


def luminance(rgb):
    return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]


def decorate(canvas, ink):
    d = ImageDraw.Draw(canvas)
    # dynamic island
    d.rounded_rectangle((CW // 2 - 168, 34, CW // 2 + 168, 134), radius=50, fill=(0, 0, 0))
    f = ImageFont.truetype(RUBIK, 58)
    f.set_variation_by_axes([600])
    d.text((120, 52), "9:41", font=f, fill=ink)
    # signal bars
    x0 = 760
    for i in range(4):
        h = 18 + i * 10
        d.rounded_rectangle((x0 + i * 20, 106 - h, x0 + i * 20 + 12, 106), radius=3, fill=ink)
    # wifi (three arcs)
    cx, cy = 890, 106
    for r in (30, 20, 10):
        d.arc((cx - r, cy - r, cx + r, cy + r), start=225, end=315, fill=ink, width=6)
    d.ellipse((cx - 4, cy - 4, cx + 4, cy + 4), fill=ink)
    # battery
    d.rounded_rectangle((930, 68, 1008, 106), radius=10, outline=ink, width=4)
    d.rounded_rectangle((938, 76, 992, 98), radius=5, fill=ink)
    d.rounded_rectangle((1012, 80, 1018, 94), radius=3, fill=ink)
    # home indicator
    d.rounded_rectangle((CW // 2 - 190, CH - 34, CW // 2 + 190, CH - 20), radius=7, fill=ink)
    return canvas


def fit_screenshot(src, dst):
    im = Image.open(src).convert("RGB")
    a = np.asarray(im)
    pad = CH - im.size[1]
    pad_top = 127
    pad_bottom = pad - pad_top
    top = a[2:6].mean(axis=0).astype(np.uint8)  # average of the first rows
    bottom = a[-3:-1].mean(axis=0).astype(np.uint8)
    canvas = Image.fromarray(np.vstack([np.repeat(top[None, :, :], pad_top, axis=0), a, np.repeat(bottom[None, :, :], pad_bottom, axis=0)]))
    ink = (20, 20, 20) if luminance(top.mean(axis=0)) > 110 else (255, 255, 255)
    decorate(canvas, ink).save(dst, quality=90)


def fit_poster(src, dst):
    p = Image.open(src).convert("RGB")
    p = p.resize((CW, int(p.size[1] * CW / p.size[0])), Image.LANCZOS)
    bg = p.resize((CW, CH), Image.LANCZOS).filter(ImageFilter.GaussianBlur(60))
    # darken the blurred filler a little so the sharp poster reads as the content
    bg = Image.eval(bg, lambda v: int(v * 0.8))
    y = (CH - p.size[1]) // 2
    bg.paste(p, (0, y))
    decorate(bg, (255, 255, 255)).save(dst, quality=90)


for name, src in [("home", "home.jpg"), ("record", "record_edit.jpg"), ("route", "route.jpg"), ("navscreen", "navscreen.jpg"),
                  ("auto", "auto.jpg"), ("planner", "planner.jpg"), ("poster", "poster.jpg")]:
    fit_screenshot(OUT + "\\" + src, OUT + r"\ip_%s.jpg" % name)
for name, src in [("p1", "demo_jpg3/p1_hike_vertical.jpg"), ("p2", "demo_jpg3/p2_bike_vertical.jpg"), ("p3", "demo_jpg3/p3_car_raft_vertical.jpg")]:
    fit_poster(SP + "\\" + src.replace("/", "\\"), OUT + r"\ip_%s.jpg" % name)
print("done")
