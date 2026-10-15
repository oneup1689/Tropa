# Emulator scenario (v28): a route far from the phone, "Wait at the start", the GPS walks to the start, the service begins recording by itself.
# Usage: powershell -NoProfile -File tools\emu_wait_start.ps1  (emulator Pixel_5 running, debug APK built; wipes the app data). Prints the [WAIT]/[NAV] log lines.
$ErrorActionPreference = "Stop"
$env:Path += ";$env:LOCALAPPDATA\Android\Sdk\platform-tools"
$env:MSYS_NO_PATHCONV = 1
$env:ANDROID_SERIAL = "emulator-5554"
$pkg = "app.tropa.tropa"
$sp = [System.IO.Path]::GetTempPath()
function Tap($x, $y) { adb shell input tap $x $y | Out-Null }
function TapLabel($pattern) {
    adb shell "uiautomator dump /sdcard/ui.xml" | Out-Null
    $xml = (adb shell "cat /sdcard/ui.xml") -join ""
    $best = $null
    foreach ($m in [regex]::Matches($xml, '<node[^>]*?>')) {
        $n = $m.Value
        $d = [regex]::Match($n, '(?:content-desc|text|hint)="([^"]+)"').Groups[1].Value
        if (-not $d -or $d -notmatch $pattern) { continue }
        $b = [regex]::Match($n, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
        if (-not $b.Success) { continue }
        $v = 1..4 | ForEach-Object { [int]$b.Groups[$_].Value }
        $area = ($v[2] - $v[0]) * ($v[3] - $v[1])
        if ($null -eq $best -or $area -lt $best.Area) { $best = @{ Area = $area; X = [int](($v[0] + $v[2]) / 2); Y = [int](($v[1] + $v[3]) / 2) } }
    }
    if ($null -eq $best) { Write-Host "no label $pattern"; return $false }
    Tap $best.X $best.Y
    return $true
}
function Log { (adb shell "run-as $pkg cat app_flutter/tropa_debug_log.txt") -join "`n" }

adb install -r build\app\outputs\flutter-apk\app-debug.apk | Out-Null
adb shell pm clear $pkg | Out-Null
foreach ($p in "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION", "POST_NOTIFICATIONS", "ACTIVITY_RECOGNITION") { adb shell pm grant $pkg android.permission.$p 2>$null | Out-Null }
adb shell settings put secure location_mode 3
adb shell am start -n "$pkg/.MainActivity" | Out-Null
Start-Sleep 45
adb shell am force-stop $pkg
adb shell "run-as $pkg cat databases/tropa.db > /data/local/tmp/pulled.db"
adb pull /data/local/tmp/pulled.db "$sp\emu_tropa.db" | Out-Null
python -I "$PSScriptRoot\emu_add_zroute.py" "$sp\emu_tropa.db"
adb push "$sp\emu_tropa.db" /data/local/tmp/tropa.db | Out-Null
adb shell "run-as $pkg cp /data/local/tmp/tropa.db databases/tropa.db"
adb shell "run-as $pkg rm -f databases/tropa.db-wal databases/tropa.db-shm"
adb emu geo fix 105.8560 21.0500 | Out-Null
adb shell am start -n "$pkg/.MainActivity" | Out-Null
Start-Sleep 35
adb emu geo fix 105.8560 21.0500 | Out-Null
TapLabel "Routes|Маршруты" | Out-Null
Start-Sleep 2
TapLabel "L-test" | Out-Null
Start-Sleep 4
TapLabel "Follow the route|Идти по маршруту" | Out-Null
Start-Sleep 12
TapLabel "Wait at the start|Ждать у старта" | Out-Null
Start-Sleep 6
Write-Host "--- after choosing wait"
Log | Select-String "WAIT|NAV" | Select-Object -Last 8 | ForEach-Object { $_.Line }
# walk toward the start: fixes every 11 s (the service asks for a position every 10 s)
$lat = 21.0500
for ($i = 0; $i -lt 12; $i++) {
    $lat -= 0.0017
    if ($lat -lt 21.03) { $lat = 21.0300 }
    adb emu geo fix 105.8560 $lat | Out-Null
    Start-Sleep 11
}
Start-Sleep 5
Write-Host "--- after approach"
Log | Select-String "WAIT|NAV|SVC\] started" | Select-Object -Last 12 | ForEach-Object { $_.Line }
