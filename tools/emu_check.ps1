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
# Taps a control by its label (Flutter exposes it as content-desc/text): robust against layout changes.
# Picks the smallest matching element; returns $false if none was found.
function TapLabel($pattern) {
    adb shell "uiautomator dump /sdcard/ui.xml" | Out-Null
    $xml = (adb shell "cat /sdcard/ui.xml") -join ""
    $best = $null
    foreach ($m in [regex]::Matches($xml, '<node[^>]*?>')) {
        $n = $m.Value
        $d = [regex]::Match($n, '(?:content-desc|text|hint)="([^"]+)"').Groups[1].Value   # non-empty: "text" is often empty and comes first
        if (-not $d -or $d -notmatch $pattern) { continue }
        $b = [regex]::Match($n, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
        if (-not $b.Success) { continue }
        $v = 1..4 | ForEach-Object { [int]$b.Groups[$_].Value }
        $area = ($v[2] - $v[0]) * ($v[3] - $v[1])
        if ($null -eq $best -or $area -lt $best.Area) { $best = @{ Area = $area; X = [int](($v[0] + $v[2]) / 2); Y = [int](($v[1] + $v[3]) / 2) } }
    }
    if ($null -eq $best) { return $false }
    Tap $best.X $best.Y
    return $true
}

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
TapLabel "^Start recording" | Out-Null   # Start recording (the position changes with the layout)
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
TapLabel "^Stop$" | Out-Null   # Stop
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
TapLabel "^Routes" | Out-Null   # since v26.1 the routes are the "Routes" switch of the Trails tab
Start-Sleep 2
adb emu geo fix 105.8560 21.0300 | Out-Null   # v28: the start flow asks where the phone is; it must be at the route start
Start-Sleep 3
TapLabel "emu-test" | Out-Null   # a route opens its own screen first
Start-Sleep 3
TapLabel "^Follow the route" | Out-Null
Start-Sleep 14   # position lookup (up to 8 s) before the recording starts
adb emu geo fix 105.8560 21.0300 | Out-Null
Start-Sleep 3
$pos = Walk 105.8560 21.0300 8 0.00004 0.00002          # along the route
$pos = Walk $pos[0] $pos[1] 20 0.00004 0.00012          # leaves it (~250 m, longer than the 15 s the warning needs)
Check "route loaded" ((AppLog) -match "\[NAV\] route \d+ loaded")
Check "off-route warning" ((AppLog) -match "\[NAV\] OFF ROUTE")
for ($i = 0; $i -lt 5; $i++) {
    adb emu geo fix 105.8568 21.0304 | Out-Null; Start-Sleep -Milliseconds 2200
    adb emu geo fix 105.85684 21.03042 | Out-Null; Start-Sleep -Milliseconds 2200
}
Check "back on route" ((AppLog) -match "\[NAV\] back on route")
Check "navigator started" ((AppLog) -match "\[NAV\] begin route=\d+")
adb shell input keyevent KEYCODE_BACK   # v27: "Follow the route" opens the navigation screen; back to the Trails tab
Start-Sleep 2
TapLabel "^Stop$" | Out-Null   # Stop (the route banner shifts the button down)
Start-Sleep 4

# --- 5b. distance goal with out-and-back: set in the UI (the service is not exported, adb cannot start it)
TapLabel "^Goal$" | Out-Null
Start-Sleep 2
1..4 | ForEach-Object { TapLabel "^Less" | Out-Null; Start-Sleep -Milliseconds 400 }   # v26: whole km, minimum 1 km; the card starts at 5 km
Start-Sleep 1
TapLabel "^Out and back" | Out-Null
TapLabel "^Done$" | Out-Null
Start-Sleep 2
adb emu geo fix 105.8542 21.0285 | Out-Null   # stand at the start BEFORE recording, otherwise the first step is a jump from the old place
Start-Sleep 3
TapLabel "^Start recording" | Out-Null
Start-Sleep 5
$pos = Walk 105.8542 21.0285 50 0.0002 0.0001          # ~23 m per fix (13 m/s): half way at 500 m, goal at 1 km
$log = AppLog
Check "goal: half-way notification" ($log -match "\[GOAL\] half way at")
Check "goal: reached notification" ($log -match "\[GOAL\] goal reached at")
TapLabel "^Stop$" | Out-Null
Start-Sleep 3

# --- 6. nothing fatal in the log
Check "no FATAL / exceptions in the service" (-not ((AppLog) -match "FATAL|beat failed"))

adb shell am force-stop $pkg
$results | Format-Table -AutoSize
if ($results.Result -contains "FAIL") { Write-Host "SOME CHECKS FAILED" -ForegroundColor Red; exit 1 }
Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
