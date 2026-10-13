---
name: emulator-session
description: Run, drive and tear down the Android emulator for Tropa tests (start, install, grant permissions, GPS/Wi-Fi/storage scenarios, screenshots) and ALWAYS clean up afterwards (emulator, adb, Gradle daemon, leftovers). Use whenever the task needs the emulator or when finishing a work stretch that used it.
---

# Emulator session for Tropa (Windows, PowerShell)

Owner's PC has little RAM: never leave heavy processes running after the work.

## 1. Start (only if not already running; `adb devices` first)
```powershell
$env:Path += ";$env:LOCALAPPDATA\Android\Sdk\platform-tools;$env:LOCALAPPDATA\Android\Sdk\emulator"
Start-Process emulator -ArgumentList "-avd","Pixel_5","-gpu","host","-memory","1536","-no-snapshot-save" -WindowStyle Hidden
adb wait-for-device; do { Start-Sleep 5; $b = adb shell getprop sys.boot_completed } until ($b -match "1")
```
`-gpu host` is required (software rendering draws no map text). Close other heavy apps first.

## 2. Install and prepare
- `adb install -r build\app\outputs\flutter-apk\app-debug.apk`
- Grant: `ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION, ACCESS_BACKGROUND_LOCATION, POST_NOTIFICATIONS, ACTIVITY_RECOGNITION` via `adb shell pm grant app.tropa.tropa android.permission.X` (without background location a permission dialog blocks the first start).
- Cold start of the app takes about 40 s: wait before tapping.
- Full automatic check of recording: `powershell -NoProfile -File tools\emu_check.ps1` (about 6 min).

## 3. Driving and checking
- GPS: `adb emu geo fix <lon> <lat>` (lon first), 1.5-2 s between fixes.
- Screenshot: `adb exec-out screencap -p > file.png` (1080x2340). Coordinates in a screenshot shown downscaled must be multiplied by 1.17. Menu items shift between Amateur and Pro mode, and dropdowns open at different heights: take a screenshot before tapping, do not reuse old coordinates.
- Log: `adb shell "run-as app.tropa.tropa cat app_flutter/tropa_debug_log.txt"` (`$env:MSYS_NO_PATHCONV=1` for paths).
- Binary files: never use `>` redirection in Windows PowerShell 5.1 for DB files; use `adb shell "run-as ... cat ... > /data/local/tmp/x"` then `adb pull`.
- Wi-Fi off: `adb shell svc wifi disable` (mobile data stays: status bar shows LTE). Restore with `enable`.
- Low-storage test: fill with `dd if=/dev/zero of=/data/local/tmp/filler.bin bs=1048576 count=2500`, afterwards free it with `truncate -s 0` (the tool blocks `rm` in PowerShell).
- Restore anything you changed (Wi-Fi, location mode, filler file, language/units/Pro mode in the app if it matters for the next test).

## 4. Clean up (ALWAYS at the end, unless the next step is already planned and restart is slow, then say that you keep it running)
```powershell
adb shell am force-stop app.tropa.tropa
adb emu kill; Start-Sleep 6
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
.\android\gradlew.bat --stop        # fails without JAVA_HOME
adb kill-server
Get-Process | ? { $_.ProcessName -match "qemu|emulator|adb|java|dart|flutter|gradle" }   # must be empty
```
`emulator -kill` helper processes exit by themselves within ~20 s. Also close browser tabs / preview servers opened for the task, and delete temporary files you created outside the project (screenshots in the scratchpad can stay).

## 5. Report
Say what was checked on the emulator and what was NOT (phone-only things: real GPS, Xiaomi battery/autostart, HyperOS), and that cleanup is done (or what was left running and why).
