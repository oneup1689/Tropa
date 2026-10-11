# Tropa — офлайн GPS-трекер ходьбы/велопрогулок (Flutter, Android + iOS)

Владелец: Nik (oneup1689 на GitHub, репозиторий публичный: github.com/oneup1689/Tropa). Язык общения — русский, код/коммиты — английский.

## Цель
Точная запись маршрута по GPS без интернета, без обрывов (главная боль: другие трекеры обрываются), офлайн-карты регионами (как Organic Maps), шаринг GPX и картинкой для рилс (с чекбоксами, что показывать). Интерфейс русский, потом английский. Целевая платформа — iOS (iPhone 13, iOS 27.0.1), отладка на Android (Xiaomi 12X / HyperOS).

## Окружение (Windows)
- Flutter: `C:\dev\flutter\bin` (добавлять в PATH в каждой PowerShell-команде). Android SDK: `%LOCALAPPDATA%\Android\Sdk`; cmdline-tools установлены; для платформы 37 создана junction `platforms\android-37` -> `android-37.0`.
- `permission_handler` закреплён на ^12 (13 требует compileSdk 37, AGP 9.1 поддерживает максимум 36). Не обновлять без проверки сборки.
- Сборка: `flutter build apk --release`, вывод писать в файл (первые сборки идут 5–20 мин). APK класть в `dist/` (в .gitignore).
- git/gh: аккаунт oneup1689; в этой папке локально настроен user.name/email.
- iOS: сборка только через GitHub Actions (macOS runner), подпись бесплатным Apple ID через SideStore/Sideloadly, 7 дней; TestFlight — 99 $/год. Проверить поддержку iOS 27 в SideStore до iOS-этапа.

## Архитектура сейчас (MVP, технический)
`lib/recorder.dart` (geolocator foreground service, watchdog, восстановление после убийства), `db.dart` (sqflite, каждая точка пишется сразу), `debug_log.dart` (лог на диск с flush), `gpx.dart` (разрыв >30 с = новый trkseg, прямых линий через пропуски нет), `route_view.dart` (предпросмотр без карты), `MainActivity.kt` (канал `tropa/system`: режимы Android, moveToBack).

## Известные решения
- Запись должна жить независимо от UI: план — нативный Kotlin foreground service с записью в SQLite (см. анализ тестовой прогулки 2026-10-11: 5 разрывов за 57 мин).
- Подложки карт: только легальные оффлайн-источники (OSM-векторные тайлы, топо, спутник EOX/Esri по лицензии). Google/Яндекс/2ГИС тайлы кэшировать офлайн нельзя по их условиям.
- Планировщик прогулок («предстартовый чек-лист») — после карт.
