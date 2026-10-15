"""One HTML page per slide (1920x1080) from docs/presentation/slides, for Edge headless print-to-pdf."""
import json
import os
import re
import shutil

SP = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
SRC = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa\docs\presentation"
OUT = SP + r"\pptxbuild\pdfsrc"
os.makedirs(OUT + r"\img", exist_ok=True)
ids = {
    "2df8e1ed1f0b7aa218a648762472fd48": ("shots_out", "ip_home.jpg"), "71b315bd9325bd45e8c15a3678413186": ("shots_out", "ip_record.jpg"),
    "b8b193727da15a5fc2471537327c75fa": ("shots_out", "ip_route.jpg"), "1d2e37211ea10624cec0cab7e1164cb9": ("shots_out", "ip_navscreen.jpg"),
    "39f0ec08ff0677be890e92fe28396c8c": ("shots_out", "ip_auto.jpg"), "f4b710bc2449b5c761c611fc5e666542": ("shots_out", "ip_planner.jpg"),
    "712db5545056f8ec56521b81a4b1428f": ("shots_out", "ip_poster.jpg"), "ff7b80f906ccbfd006558b12aef71ba6": ("shots_out", "ip_p1.jpg"),
    "3ea37282ace8d0de5d136066259cf32d": ("shots_out", "ip_p2.jpg"), "56e7b23e6ccdb4676b6f75c60e9fe570": ("shots_out", "ip_p3.jpg"),
    "c7c9ded557b1773c4236cab88302bf90": ("demo_jpg2", "p2_bike_wide.jpg"), "1156c87e9bcb4c314a874e35a14471b9": ("demo_jpg2", "p4_week.jpg"),
}
for k, (d, f) in ids.items():
    shutil.copy(os.path.join(SP, d, f), os.path.join(OUT, "img", k + ".jpg"))

deck = json.load(open(os.path.join(SRC, "deck.json"), encoding="utf-8"))
head = ('<!doctype html><meta charset="utf-8"><title>Tropa</title><style>@page{size:1920px 1080px;margin:0}*{box-sizing:border-box}p,h1,h2,h3{margin:0}'
        '@font-face{font-family:Rubik;src:url(Rubik-Variable.ttf);font-weight:300 700}@font-face{font-family:Unbounded;src:url(Unbounded-Variable.ttf);font-weight:200 900}'
        'html,body{margin:0;background:#fff}.page{width:1920px;height:1080px;position:relative;overflow:hidden;page-break-after:always;break-after:page}'
        '.page>section{position:absolute;left:0;top:0;width:1920px;height:1080px;overflow:hidden}</style>')
body = []
for sid in deck["order"]:
    t = open(os.path.join(SRC, "slides", sid + ".html"), encoding="utf-8").read()
    t = re.sub(r"<aside>.*?</aside>", "", t, flags=re.S)
    for k in ids:
        t = t.replace("/_blob/" + k, "img/" + k + ".jpg")
    body.append('<div class="page">' + t + "</div>")
open(os.path.join(OUT, "slides.html"), "w", encoding="utf-8").write(head + "".join(body))
print("ok", len(body))
