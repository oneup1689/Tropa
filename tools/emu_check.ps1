# Emulator regression check of the native recording service (Pixel_5 emulator, 1080x2340, app language any).
# Usage:  powershell -File tools\emu_check.ps1 [-Apk build\app\outputs\flutter-apk\app-debug.apk]
# Needs a running emulator (emulator -avd Pixel_5 -gpu host -memory 1536). Wipes the app data first.
# Taps use fixed pixel coordinates of the Pixel_5 screen; if the UI layout changes, adjust them below.
param([string]$Apk = "build\app\outputs\flutter-apk\app-debug.apk")

$ErrorActionPreference = "Stop"
$env:Path += ";$env:LOCALAPPDATA\Android\Sdk\platform-tools"
$env:MSYS_NO_PATHCONV = 1
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$pkg = "app.tropa.tropa"
$results = @()

function Check($name, $ok) {
    $script:results += [pscustomobject]@{ Check = $name; Result = $(if ($ok) { "PASS" } else { "FAIL" }) }
}
function AppLog { (adb shell "run-as $pkg cat app_flutter/tropa_debug_log.txt") -join "`n" }
function Walk($lon, $lat, $steps, $dLon, $dLat) {
    for ($i = 0; $i -lt $steps; $i++) {
        $lon += $dLon; $lat += $dLat
        adb emu geo fix $lon $lat | Out-Null
        Start-Sleep -Milliseconds 1800
    }
    return @($lon, $lat)
}
function Tap($x, $y) { adb shell input tap $x $y | Out-Null }

# --- install and prepare
adb install -r $Apk | Out-Null
adb shell pm clear $pkg | Out-Null
foreach ($p in "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION", "POST_NOTIFICATIONS", "ACTIVITY_RECOGNITION") {
    adb shell pm grant $pkg android.permission.$p 2>$null | Out-Null
}
adb shell settings put secure location_mode 3
adb shell am start -n "$pkg/.MainActivity" | Out-Null
Start-Sleep 45

# --- 1. recording through the service
Tap 538 1012   # Start recording
Start-Sleep 4
$pos = Walk 105.8542 21.0285 25 0.00004 0.00002
$log = AppLog
Check "recording stores points" ($log -match "\[FIX\].*stored")
Check "heartbeat is written" ($log -match "\[BEAT\] native points=")

# --- 2. GPS switched off and on
adb shell settings put secure location_mode 0
Start-Sleep 14
Check "alert 1002 posted when GPS is off" (((adb shell dumpsys notification) -join "`n") -match "id=1002")
adb shell settings put secure location_mode 3
Start-Sleep 3
$pos = Walk $pos[0] $pos[1] 4 0.00004 0.00002
# When GPS comes back the service cancels the alert at once (no separate log line).
Check "alert cleared after GPS on" (-not (((adb shell dumpsys notification) -join "`n") -match "GPS is off|GPS выключен"))
Check "provider re-enabled is seen" ((AppLog) -match "provider gps enabled")

# --- 3. app killed: the service must continue the session
adb shell am force-stop $pkg
adb shell am start -n "$pkg/.MainActivity" | Out-Null
Start-Sleep 30
Check "session resumed after kill" ((AppLog) -match "resumed session=\d+ points=\d+ restartedBySystem=true")

# --- 4. stop from the UI
Tap 538 1023   # Stop (no route banner)
Start-Sleep 4
Check "session closed on stop" ((AppLog) -match "\[SVC\] stopped session=")

# --- 5. route navigation: off route, then back
$sp = [System.IO.Path]::GetTempPath()
adb shell am force-stop $pkg
adb shell "run-as $pkg cat databases/tropa.db > /data/local/tmp/pulled.db"
adb pull /data/local/tmp/pulled.db "$sp\emu_tropa.db" | Out-Null   # (a '>' redirect would corrupt the binary file in Windows PowerShell 5.1)
python -I "$PSScriptRoot\emu_add_route.py" "$sp\emu_tropa.db" | Out-Null
adb push "$sp\emu_tropa.db" /data/local/tmp/tropa.db | Out-Null
adb shell "run-as $pkg cp /data/local/tmp/tropa.db databases/tropa.db"
adb shell "run-as $pkg rm -f databases/tropa.db-wal databases/tropa.db-shm"
adb shell am start -n "$pkg/.MainActivity" | Out-Null
Start-Sleep 30
Tap 1013 213   # menu
Start-Sleep 2
Tap 600 642    # Routes
Start-Sleep 3
Tap 337 727    # Follow the route (first route in the list)
Start-Sleep 5
adb emu geo fix 105.8560 21.0300 | Out-Null
Start-Sleep 3
$pos = Walk 105.8560 21.0300 8 0.00004 0.00002          # along the route
$pos = Walk $pos[0] $pos[1] 12 0.00004 0.00020          # leaves it (~190 m)
Check "route loaded" ((AppLog) -match "\[NAV\] route \d+ loaded")
Check "off-route warning" ((AppLog) -match "\[NAV\] OFF ROUTE")
for ($i = 0; $i -lt 5; $i++) {
    adb emu geo fix 105.8568 21.0304 | Out-Null; Start-Sleep -Milliseconds 2200
    adb emu geo fix 105.85684 21.03042 | Out-Null; Start-Sleep -Milliseconds 2200
}
Check "back on route" ((AppLog) -match "\[NAV\] back on route")
Tap 538 1231   # Stop (route banner shifts the button down)
Start-Sleep 4

# --- 6. nothing fatal in the log
Check "no FATAL / exceptions in the service" (-not ((AppLog) -match "FATAL|beat failed"))

adb shell am force-stop $pkg
$results | Format-Table -AutoSize
if ($results.Result -contains "FAIL") { Write-Host "SOME CHECKS FAILED" -ForegroundColor Red; exit 1 }
Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
