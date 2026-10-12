# Вспомогательные скрипты Tropa

Нужны для проверки на эмуляторе и для подготовки данных карт. Личных данных здесь нет: пути к GPX передаются параметрами.

| Файл | Что делает | Как запускать |
|---|---|---|
| `feed_gps.ps1` | Подаёт точки из GPX на эмулятор как GPS (`adb emu geo fix`). `-LatOffset 0.0015` сдвигает точки на ~167 м (имитация схода с маршрута) | `powershell -File tools\feed_gps.ps1 -Gpx путь\к.gpx -From 0 -Count 60 -DelaySec 2` |
| `make_test_db.py` | Собирает `tropa.db` (схема v3) из GPX: сессия, заметка, импортированный маршрут, синтетическое давление | `python -I tools\make_test_db.py путь\к.gpx out.db`, затем `adb push` в `/data/local/tmp` и `adb shell "run-as app.tropa.tropa cp ... databases/tropa.db"` (приложение остановить) |
| `make_styles.mjs` | Генерирует `assets/map/style_{light,dark}.json` из Protomaps (`npm i @protomaps/basemaps`) | `node tools/make_styles.mjs assets/map` |
| `egm_convert.py` | Конвертирует геоид EGM96 (GeoTIFF из PROJ CDN) в `assets/geoid/egm96_half_deg.bin` | `python -I tools/egm_convert.py egm96.tif out.bin` |

Карта региона (не в Git): `data\tools\pmtiles.exe extract https://build.protomaps.com/<ГГГГММДД>.pmtiles data\maps\<имя>.pmtiles --bbox=<minLon>,<minLat>,<maxLon>,<maxLat> --maxzoom=14`
(актуальные сборки: https://build-metadata.protomaps.dev/builds.json). Загрузка может оборваться на 90+ % — повторить, потом `pmtiles verify`.

Эмулятор: `emulator -avd Pixel_5 -gpu host -memory 1536` (с программным рендером MapLibre не рисует текст). Нажатия: `adb shell input tap X Y` (скриншот 1080x2340, координаты брать из `adb exec-out screencap -p`). После холодного старта приложения первые секунды UI не реагирует — ждать ~30 с.
Внимание: PowerShell-инструмент блокирует строки с `rm` внутри команд — не вставлять их.
