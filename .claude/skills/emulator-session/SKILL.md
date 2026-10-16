---
name: emulator-session
description: Run, drive and tear down the Android emulator for Tropa tests (start, install, grant permissions, GPS/Wi-Fi/storage scenarios, screenshots) and ALWAYS clean up afterwards (emulator, adb, Gradle daemon, leftovers). Use whenever the task needs the emulator or when finishing a work stretch that used it.
---

# Emulator session for Tropa (Windows, PowerShell)

Owner's PC has little RAM: never leave heavy processes running after the work.

## 0. Fast path (since 2026-10-16): `tools\emu_run.ps1`
Prefer the one script to doing steps by hand: `powershell -NoProfile -File tools\emu_run.ps1 -List`, then e.g. `-Tests nav,wait24,delete-guard,notes-after,settings -Cleanup` (core = `emu_check.ps1`, ~6 min, after changes of the native service; `all` runs everything; `-Wipe` = clean image). It starts the emulator if needed, installs the debug APK, whitelists the app from battery optimisation, runs the chosen scenarios (`tools\emu\*.ps1`, helpers in `lib.ps1`), writes `dist\emu_result.json` and keeps screenshots of failed checks only (`%TEMP%	ropa_emu`); read the short table and the JSON, not the whole log. `-Cleanup` closes the emulator, adb and Gradle. A new scenario is a new file with `Test-Run` and `Check $s "name" $condition`. The manual steps below are for work the scenarios do not cover. Note: the userdata image was deleted on 2026-10-16 (the owner agreed); the first start recreates it and is slower.

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
- Low-storage test: fill with `dd if=/dev/zero of=/data/local/tmp/filler.bin bs=1048576 count=2500`, afterwards free it with `truncate -s 0` (the tool blocks `rm` in PowerShell). WARNING: the AVD disk image (`userdata-qemu.img.qcow2`) only grows and never shrinks, so every such fill permanently adds the filled size on the PC disk (in Oct 2026 it reached 8.4 GB for 2.9 GB of real data). Do this test rarely, and tell the owner that the image should be compacted/wiped afterwards (see section 6).
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

## 6. Disk hygiene (the PC disk is almost full: C: had 0.7 GB free in Oct 2026)
Cause found 2026-10-14: a leaked 5 GB task output, an AVD image grown to 8.4 GB, a stale quick-boot snapshot (2 GB), a forgotten test AVD with its system image (6 + 2.4 GB). Rules:
- **No spare AVDs.** Use only `Pixel_5`. A temporary AVD (other Android version, Play Store, destructive test) is created for one task and removed at its end: `avdmanager delete avd -n <name>` (or delete `~\.android\avd\<name>.avd` and `.ini`), and remove its now-unused system image from `Sdk\system-images`. Never leave one "for later" without telling the owner.
- Always start with `-no-snapshot-save`; if `~\.android\avd\Pixel_5.avd\snapshots` exists, tell the owner (2 GB, stale).
- At the end of a work stretch (and always when a project/stage is finished) check sizes: `Get-ChildItem ~\.android\avd -Recurse -File | Measure Length -Sum`, AVD folder should stay below ~6 GB; if the `.qcow2` is far larger than real data (`adb shell df /data`), propose compaction (`qemu-img convert -O qcow2`) or `-wipe-data`, do not do it silently.
- Temp files of the work (APK copies, unpacked archives, screenshots, DB pulls, rendered posters in `dist/`) are deleted when no longer needed; `build/` can be cleaned with `flutter clean` when a stage is closed (ask first: next build is slow).
- Never start an interactive REPL (`python`, `node`, `sqlite3` without script) as a background task: with no stdin it loops and writes gigabytes into `%LOCALAPPDATA%\Temp\claude\...\tasks\*.output`. Run scripts from files only. After long sessions glance at that folder (`Get-ChildItem $env:LOCALAPPDATA\Temp\claude -Recurse -File | ? Length -gt 100MB`).
- Before deleting anything big that is not clearly ours (other projects' AVDs, system images, Chrome profiles, caches) ask the owner; deletion of own temp files and the throwaway AVD created in this task is fine without asking.
- When free space on C: is under ~10 GB, say so at the start of the task and suggest a cleanup pass.

## 5. Report
Say what was checked on the emulator and what was NOT (phone-only things: real GPS, Xiaomi battery/autostart, HyperOS), and that cleanup is done (or what was left running and why).
