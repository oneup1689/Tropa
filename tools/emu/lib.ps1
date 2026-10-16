# Shared helpers of the emulator scenarios (dot-sourced by tools\emu_run.ps1). ASCII only: Windows PowerShell 5.1.
$env:Path += ";$env:LOCALAPPDATA\Android\Sdk\platform-tools;$env:LOCALAPPDATA\Android\Sdk\emulator"
$env:MSYS_NO_PATHCONV = 1
$env:ANDROID_SERIAL = "emulator-5554"
$script:pkg = "app.tropa.tropa"
$script:root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:tmp = Join-Path $env:TEMP "tropa_emu"
New-Item -ItemType Directory -Force $script:tmp | Out-Null
$script:Results = New-Object System.Collections.ArrayList

function Tap($x, $y) { adb shell input tap $x $y | Out-Null }
function Swipe-Up { adb shell input swipe 540 1900 540 600 300 | Out-Null; Start-Sleep 1 }
function Back { adb shell input keyevent 4 | Out-Null; Start-Sleep 1 }
function Dump { adb shell "uiautomator dump /sdcard/ui.xml" | Out-Null; (adb shell "cat /sdcard/ui.xml") -join "" }

# Screenshot, kept only for failures (the folder is cleared at the start of a run).
function Shot($name) { adb shell screencap -p /sdcard/s.png; adb pull /sdcard/s.png (Join-Path $script:tmp "$name.png") | Out-Null }

# Taps the smallest element whose label matches; false when there is none.
function TapLabel($pattern) {
    $xml = Dump
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
    if ($null -eq $best) { return $false }
    Tap $best.X $best.Y
    return $true
}

# Is there an element with such a label on the screen now? $enabled: also report its enabled flag.
function HasLabel($pattern) {
    $xml = Dump
    foreach ($m in [regex]::Matches($xml, '<node[^>]*?>')) {
        $d = [regex]::Match($m.Value, '(?:content-desc|text)="([^"]+)"').Groups[1].Value
        if ($d -and $d -match $pattern) { return @{ Found = $true; Enabled = ([regex]::Match($m.Value, 'enabled="(\w+)"').Groups[1].Value -eq "true") } }
    }
    return @{ Found = $false; Enabled = $false }
}

# Lines of the app debug log that match.
function Log($pattern, $last = 50) {
    ((adb shell "run-as $pkg cat app_flutter/tropa_debug_log.txt") -join "`n") -split "`n" | Where-Object { $_ -match $pattern } | Select-Object -Last $last
}
function LogHas($pattern) { return (@(Log $pattern 1)).Count -gt 0 }

function Check($scenario, $name, $ok, $detail = "") {
    [void]$script:Results.Add([pscustomobject]@{ Scenario = $scenario; Check = $name; Result = $(if ($ok) { "PASS" } else { "FAIL" }); Detail = $detail })
    if (-not $ok) { Shot ("fail_" + $scenario + "_" + ($name -replace '[^\w]+', '_')) }
}

function Walk($lon, $lat, $steps, $dLon, $dLat, $ms = 1500) {
    for ($i = 0; $i -lt $steps; $i++) {
        $lon += $dLon; $lat += $dLat
        adb emu geo fix $lon $lat | Out-Null
        Start-Sleep -Milliseconds $ms
    }
    return @($lon, $lat)
}

function Start-App($wait = 40) { adb shell am start -n "$pkg/.MainActivity" | Out-Null; Start-Sleep $wait }

# Fresh app data, two test routes (In-map inside the test map, No-map outside) and the test map on the phone.
function Ensure-Fixture {
    adb shell pm clear $pkg | Out-Null
    foreach ($p in "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION", "POST_NOTIFICATIONS", "ACTIVITY_RECOGNITION") { adb shell pm grant $pkg android.permission.$p 2>$null | Out-Null }
    adb shell settings put secure location_mode 3
    Start-App 45
    adb shell am force-stop $pkg
    $db = Join-Path $script:tmp "tropa.db"
    adb shell "run-as $pkg cat databases/tropa.db > /data/local/tmp/pulled.db"
    adb pull /data/local/tmp/pulled.db $db | Out-Null
    python -I (Join-Path $script:root "tools\emu_add_two_routes.py") $db | Out-Null
    adb push $db /data/local/tmp/tropa.db | Out-Null
    adb shell "run-as $pkg cp /data/local/tmp/tropa.db databases/tropa.db"
    adb shell "run-as $pkg rm -f databases/tropa.db-wal databases/tropa.db-shm"
    adb shell mkdir -p /sdcard/Android/data/$pkg/files/maps
    adb push (Join-Path $script:root "data\maps\testwalk.pmtiles") /sdcard/Android/data/$pkg/files/maps/ | Out-Null
}

# Opens a route of the Routes switch and its "walk it" button (the route screen has a map: the button is below the fold).
function Open-Route($name) {
    TapLabel "^Routes" | Out-Null; Start-Sleep 2
    TapLabel $name | Out-Null; Start-Sleep 4
    Swipe-Up
}

function Stop-Walk {
    if (HasLabel "^Finish$" | ForEach-Object { $_.Found }) {
        TapLabel "^Finish$" | Out-Null; Start-Sleep 2
        TapLabel "^Finish$" | Out-Null; Start-Sleep 4
    } else {
        TapLabel "^Stop$" | Out-Null; Start-Sleep 4
    }
}
