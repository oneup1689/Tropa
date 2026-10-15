import numpy as np
from PIL import Image, ImageDraw, ImageFont

SP = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad\shots_out"
FONT = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa\assets\fonts\Unbounded-Variable.ttf"
RUBIK = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa\assets\fonts\Rubik-Variable.ttf"

im = Image.open(SP + r"\record.jpg").convert("RGB")
a = np.asarray(im).copy()


def bright_bbox(box, thr=215):
    x0, y0, x1, y1 = box
    sub = a[y0:y1, x0:x1]
    mask = (sub.min(axis=2) > thr)
    ys, xs = np.where(mask)
    return (x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1)


def erase(box, pad=3):
    x0, y0, x1, y1 = box
    x0 -= pad; y0 -= pad; x1 += pad; y1 += pad
    top = a[y0 - 6, x0:x1].astype(float)
    bot = a[y1 + 6, x0:x1].astype(float)
    for y in range(y0, y1):
        t = (y - y0) / max(1, (y1 - y0))
        a[y, x0:x1] = (top * (1 - t) + bot * t).astype(np.uint8)


def fit_font(text, width, height, path=FONT):
    """Finds size/weight so that the text bbox matches the old one."""
    best = None
    for wght in (600, 700, 800):
        for size in range(20, 140):
            f = ImageFont.truetype(path, size)
            f.set_variation_by_axes([wght])
            bb = f.getbbox(text)
            w, h = bb[2] - bb[0], bb[3] - bb[1]
            err = abs(w - width) / width + abs(h - height) / height
            if best is None or err < best[0]:
                best = (err, size, wght, bb)
    return best


def redraw(box_search, old_text, new_text, align="left", fill=(255, 255, 255)):
    global im, a
    bb = bright_bbox(box_search)
    w, h = bb[2] - bb[0], bb[3] - bb[1]
    err, size, wght, fb = fit_font(old_text, w, h)
    print(old_text, "->", new_text, "bbox", bb, "size", size, "wght", wght, "err %.3f" % err)
    erase(bb)
    img = Image.fromarray(a)
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_axes([wght])
    nb = f.getbbox(new_text)
    nw = nb[2] - nb[0]
    x = bb[0] - nb[0] if align == "left" else bb[2] - nw - nb[0]
    y = bb[1] - nb[1]
    d.text((x, y), new_text, font=f, fill=fill)
    a = np.asarray(img).copy()


redraw((540, 215, 1000, 300), "00:00:13", "00:42:18", align="right")
redraw((95, 610, 410, 680), "0.00 км", "3.27 км", align="left")
redraw((435, 620, 700, 672), "00:00:00", "00:41:05", align="left")
redraw((705, 610, 860, 680), "0 м", "4 м", align="left")
Image.fromarray(a).save(SP + r"\record_edit.jpg", quality=90)
Image.fromarray(a).crop((0, 0, 1080, 1260)).save(SP + r"\rec_top2.png")

# --- the list row under the card: "0.0 км • 1 мин" -> "3.3 км • 42 мин"
def redraw_dark(box, old_text, new_text):
    global a
    x0, y0, x1, y1 = box
    sub = a[y0:y1, x0:x1]
    mask = sub.max(axis=2) < 170
    ys, xs = np.where(mask)
    bb = (x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1)
    col = tuple(int(v) for v in a[bb[1] + (bb[3] - bb[1]) // 2, bb[0]:bb[2]].min(axis=0))
    bgc = tuple(int(v) for v in a[y0 - 2, x0 + 5])
    best = None
    for wght in (400, 500):
        for size in range(20, 80):
            f = ImageFont.truetype(RUBIK, size)
            f.set_variation_by_axes([wght])
            b = f.getbbox(old_text)
            err = abs((b[2] - b[0]) - (bb[2] - bb[0])) / (bb[2] - bb[0]) + abs((b[3] - b[1]) - (bb[3] - bb[1])) / (bb[3] - bb[1])
            if best is None or err < best[0]:
                best = (err, size, wght)
    print("row", bb, best, col, bgc)
    a[bb[1] - 4:bb[3] + 4, bb[0] - 4:bb[2] + 4] = bgc
    img = Image.fromarray(a)
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(RUBIK, best[1])
    f.set_variation_by_axes([best[2]])
    nb = f.getbbox(new_text)
    d.text((bb[0] - nb[0], bb[1] - nb[1]), new_text, font=f, fill=(68, 72, 70))
    a = np.asarray(img).copy()


redraw_dark((380, 1528, 700, 1580), "0.0 км • 1 мин", "3.3 км • 42 мин")
Image.fromarray(a).save(SP + r"\record_edit.jpg", quality=90)
Image.fromarray(a).crop((0, 1230, 1080, 1750)).save(SP + r"\rec_mid2.png")
