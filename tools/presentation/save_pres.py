import os
import shutil

from PIL import Image, ImageOps

try:
    import pillow_heif
    pillow_heif.register_heif_opener()
except Exception:
    pass

SP = r"C:\Users\Nikita\AppData\Local\Temp\claude\C--Users-Nikita-Desktop-Coder-Projects-Tropa\c81c2703-d0a3-47ff-8ba3-ce716e1cffa2\scratchpad"
PROJ = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa"
TD = r"C:\Users\Nikita\Desktop\Coder\Projects\Tropa_testdata\presentation"
PH = os.path.join(PROJ, "Фото для презентации")

# ---------------- private repo: photos (resized), screenshots, posters, tracks
for sub in ("photos", "app_screenshots", "posters", "demo_tracks"):
    os.makedirs(os.path.join(TD, sub), exist_ok=True)

names = {"В горы": "hike", "На велосипедах": "bike", "На авто + сплав": "car_raft"}
for folder, tag in names.items():
    d = os.path.join(PH, folder)
    for f in sorted(os.listdir(d)):
        im = ImageOps.exif_transpose(Image.open(os.path.join(d, f))).convert("RGB")
        im.thumbnail((1600, 1600))
        im.save(os.path.join(TD, "photos", "%s_%s.jpg" % (tag, os.path.splitext(f)[0])), quality=85)

shots = os.path.join(PH, "Скриншоты приложения")
for f in sorted(os.listdir(shots)):
    shutil.copy(os.path.join(shots, f), os.path.join(TD, "app_screenshots", f))
for f in sorted(os.listdir(SP + r"\shots_out")):
    if f.startswith("ip_") and f.endswith(".jpg") and f != "ip_check.jpg" and f != "ip_check2.jpg":
        shutil.copy(os.path.join(SP, "shots_out", f), os.path.join(TD, "app_screenshots", f))
shutil.copy(os.path.join(SP, "shots_out", "record_edit.jpg"), os.path.join(TD, "app_screenshots", "record_edit_realistic_values.jpg"))

for f in os.listdir(PROJ + r"\dist\demo_posters"):
    shutil.copy(os.path.join(PROJ, "dist", "demo_posters", f), os.path.join(TD, "posters", f))
for f in os.listdir(SP + r"\demo2"):
    if f.endswith(".json"):
        shutil.copy(os.path.join(SP, "demo2", f), os.path.join(TD, "demo_tracks", f))

# ---------------- public repo: slide sources + build scripts
os.makedirs(PROJ + r"\docs\presentation\slides", exist_ok=True)
for f in os.listdir(SP + r"\deck\project\slides"):
    shutil.copy(os.path.join(SP, "deck", "project", "slides", f), os.path.join(PROJ, "docs", "presentation", "slides", f))
shutil.copy(SP + r"\deck\project\deck.json", PROJ + r"\docs\presentation\deck.json")
os.makedirs(PROJ + r"\tools\presentation", exist_ok=True)
for f in ("gen_slides.py", "iphone_fit.py", "edit_record.py", "mkprev3.py", "save_pres.py"):
    shutil.copy(os.path.join(SP, f), os.path.join(PROJ, "tools", "presentation", f))
print("saved")
