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

## Автопроверка записи на эмуляторе (с v18)
`tools\emu_check.ps1` (+ `emu_add_route.py`): ставит debug-APK, стирает данные приложения, гоняет сценарии (запись, GPS выкл/вкл, убийство процесса и восстановление, остановка, уход с маршрута и возврат) и печатает PASS/FAIL по строкам лога. Запуск: `powershell -NoProfile -File tools\emu_check.ps1` при запущенном эмуляторе Pixel_5 (~6 мин). Тапы по фиксированным координатам Pixel_5 — при смене вёрстки поправить. Внимание: `>` в Windows PowerShell 5.1 портит бинарные файлы — БД забирать через `adb shell "run-as ... cat ... > /data/local/tmp/x"` и `adb pull`.
Перед каждой сборкой — субагент `pre-build-check` (`.claude/agents/`): analyze, тесты, личные файлы в `git status`, переводы `t()`.

## Добавлено в v28–v30
- `emu_wait_start.ps1` — сценарий «ждать у старта» на эмуляторе (маршрут за 2 км, GPS подходит к старту, служба сама начинает запись); использует `emu_add_zroute.py` (Z-образный маршрут ~900 м у Ханоя 21.03, 105.856 в БД приложения).
- `emu_add_two_routes.py` — два тестовых маршрута: «In-map» внутри региона `data\maps\testwalk.pmtiles` (границы 105.8–106.2 / 20.1–20.4) и «No-map» вне его (для проверки карты в экране маршрута и загрузки фрагмента). Карту положить на эмулятор: `adb push data\maps\testwalk.pmtiles /sdcard/Android/data/app.tropa.tropa/files/maps/` (в Git Bash задать `MSYS_NO_PATHCONV=1`, иначе `/sdcard` превращается в путь Git).
- `analyze_gpx.py` — разбор записанной прогулки: `python -I tools\analyze_gpx.py test\tropa_N.gpx out.txt` (длина, время в движении/на месте, пропуски >40 с, скачки >60 м, скорости); вывод писать в файл (консоль cp1251 ломает юникод).
- Ловушки эмулятора: скриншоты — `adb exec-out screencap -p > file.png` из Git Bash (в Windows PowerShell 5.1 `>` портит PNG); если все проверки `emu_check` падают — на эмуляторе завис systemui («Application Not Responding»), перезапустить его; `emu_check` нужен debug-APK (release не читается через `run-as`).

## Добавлено 2026-10-15 (презентация)
- `demo_posters/` — генератор демо-постеров без эмулятора: `mapkit.py` (читатель PMTiles + MVT), `mapgen.py` (тёмная подложка как в приложении, дорожный граф и маршрутизация), `routes.py`, `ural_routes.py`, `altai_routes.py` (подбор маршрутов по реальным дорогам и рекам), `gen2.py` (треки, заметки, камера, карты) и тест `test/render_demo_posters_test.dart` (рендер постеров кодом приложения). Пути в скриптах абсолютные (рабочая папка сессии), перед запуском поправить `sp`/`OUT`. Подробности — `CLAUDE.md`, раздел 0б.
- `presentation/` — сборка слайдов презентации (`gen_slides.py`), подгонка экранов под iPhone (`iphone_fit.py`), подмена цифр на скриншоте (`edit_record.py`), предпросмотр (`mkprev3.py`). Описание — `docs/presentation/README.md`.
- `presentation_pptx/` — сборка .pptx (`assets.py` + `build.js`, нужен `npm install pptxgenjs` во временной папке) и HTML для PDF (`mkpdf.py`, печать Edge). См. `docs/presentation/README.md`.
