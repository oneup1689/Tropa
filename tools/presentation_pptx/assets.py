"""Pictures for the .pptx: phone frames (PNG with alpha), gradient backgrounds, the wordmark logo."""
import math
import os

from PIL import Image, ImageDraw

SP = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
OUT = SP + r"\pptxbuild\img"
os.makedirs(OUT, exist_ok=True)


def gradient(w, h, c1, c2, diag=True):
    """Linear gradient from top-left to bottom-right."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x / w + y / h) / 2 if diag else y / h
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return img


def phone(src, dst, W=768):
    """iPhone Pro frame: titanium rim, thin black bezel, screen with rounded corners."""
    s = W / 384.0
    H = round(W * 2.092)
    rim, bez = round(3 * s), round(9 * s)
    r_out, r_in, r_img = round(58 * s), round(55 * s), round(46 * s)
    S = 2  # supersample for smooth corners
    canvas = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    # titanium gradient clipped to the rounded body
    grad = gradient(W * S // 4, H * S // 4, (0x8E, 0x8E, 0x93), (0x2B, 0x2B, 0x2E)).resize((W * S, H * S), Image.BILINEAR)
    mask = Image.new("L", (W * S, H * S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, W * S - 1, H * S - 1), radius=r_out * S, fill=255)
    canvas.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((rim * S, rim * S, (W - rim) * S - 1, (H - rim) * S - 1), radius=r_in * S, fill=(5, 5, 5, 255))
    iw, ih = W - 2 * rim - 2 * bez, H - 2 * rim - 2 * bez
    scr = Image.open(src).convert("RGB")
    # object-fit: cover
    k = max(iw / scr.size[0], ih / scr.size[1])
    scr = scr.resize((round(scr.size[0] * k), round(scr.size[1] * k)), Image.LANCZOS)
    left, top = (scr.size[0] - iw) // 2, (scr.size[1] - ih) // 2
    scr = scr.crop((left, top, left + iw, top + ih)).resize((iw * S, ih * S), Image.LANCZOS)
    m2 = Image.new("L", scr.size, 0)
    ImageDraw.Draw(m2).rounded_rectangle((0, 0, scr.size[0] - 1, scr.size[1] - 1), radius=r_img * S, fill=255)
    canvas.paste(scr, ((rim + bez) * S, (rim + bez) * S), m2)
    canvas.resize((W, H), Image.LANCZOS).save(dst, optimize=True)


def bezier(p0, p1, p2, p3, n=40):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return pts


def arc(cx, cy, r, a0, a1, n=30):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def wordmark(dst, color=(0xF2, 0xE8, 0xCF), dot=(0xFF, 0x70, 0x43), k=6):
    """The tropa wordmark (viewBox 14 2 390 120), transparent PNG."""
    W, H = 390 * k, 120 * k
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    sw = 10.5 * k

    def line(pts):
        pts = [((x - 14) * k, (y - 2) * k) for x, y in pts]
        r = sw / 2
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            n = max(1, int(math.hypot(x1 - x0, y1 - y0) / 1.5))
            for i in range(n + 1):
                x, y = x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n
                d.ellipse((x - r, y - r, x + r, y + r), fill=color)

    line([(50, 16), (50, 60)] + arc(70, 60, 20, 180, 90)[1:])  # t stem and foot
    line([(34, 40), (68, 40)])  # t bar
    line([(95, 40), (95, 80)])  # r stem
    line(arc(115, 60, 20, 180, 270))  # r shoulder
    for cx in (160, 225, 280):
        line(arc(cx, 60, 20.5, 0, 360, 80))
    line([(205, 40), (205, 112)])  # p stem
    line([(300, 40), (300, 60)] + arc(320, 60, 20, 180, 90)[1:] + bezier((320, 80), (342, 80), (342, 56), (364, 56))[1:])
    x, y, r = (373.5 - 14) * k, (56 - 2) * k, 8.5 * k
    d.ellipse((x - r, y - r, x + r, y + r), fill=dot)
    img.resize((W // 2, H // 2), Image.LANCZOS).save(dst, optimize=True)


def contours_bg(dst):
    bg = gradient(1920, 1080, (0x0E, 0x4D, 0x3A), (0x07, 0x1C, 0x2E))
    over = Image.new("RGBA", (1920 * 2, 1080 * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    paths = [
        [(1180, 520), (1180, 300), (1500, 220), (1700, 300), (1900, 380), (1900, 700), (1720, 800), (1540, 900), (1180, 820), (1180, 520)],
        [(1260, 520), (1260, 360), (1500, 300), (1650, 360), (1800, 420), (1810, 660), (1680, 740), (1540, 820), (1260, 760), (1260, 520)],
        [(1340, 520), (1340, 420), (1500, 380), (1600, 420), (1710, 470), (1720, 620), (1640, 680), (1540, 740), (1340, 690), (1340, 520)],
    ]
    for p in paths:
        pts = [(x * 2, y * 2) for x, y in p]
        # smooth closed curve through the points (Chaikin)
        pts = pts[:-1]
        for _ in range(4):
            nxt = []
            for a, b in zip(pts, pts[1:] + pts[:1]):
                nxt += [(a[0] * 0.75 + b[0] * 0.25, a[1] * 0.75 + b[1] * 0.25), (a[0] * 0.25 + b[0] * 0.75, a[1] * 0.25 + b[1] * 0.75)]
            pts = nxt
        pts = pts + pts[:1]
        d.line(pts, fill=(0x2A, 0x6B, 0x58, 190), width=6, joint="curve")
    over = over.resize((1920, 1080), Image.LANCZOS)
    bg = bg.convert("RGBA")
    bg.alpha_composite(over)
    bg.convert("RGB").save(dst, quality=92)


SH = SP + r"\shots_out"
for key in ("home", "record", "route", "navscreen", "auto", "planner", "poster", "p1", "p2", "p3"):
    phone(SH + r"\ip_%s.jpg" % key, OUT + r"\phone_%s.png" % key)
wordmark(OUT + r"\logo_light.png")
contours_bg(OUT + r"\bg_cover.jpg")
gradient(1920, 1080, (0x0E, 0x4D, 0x3A), (0x07, 0x1C, 0x2E)).save(OUT + r"\bg_finale.jpg", quality=92)
Image.open(SP + r"\demo_jpg2\p2_bike_wide.jpg").save(OUT + r"\wide_pro.jpg", quality=90)
Image.open(SP + r"\demo_jpg2\p4_week.jpg").save(OUT + r"\wide_week.jpg", quality=90)
for f in sorted(os.listdir(OUT)):
    print(f, os.path.getsize(os.path.join(OUT, f)) // 1024, "KB")
