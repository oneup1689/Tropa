# One entry point for the emulator checks: pick the scenarios, get one short result.
#   powershell -NoProfile -File tools\emu_run.ps1 -List
#   powershell -NoProfile -File tools\emu_run.ps1 -Tests nav,delete-guard           (after a change of the navigation screen)
#   powershell -NoProfile -File tools\emu_run.ps1 -Tests core -Cleanup              (after a change of the native service)
#   powershell -NoProfile -File tools\emu_run.ps1 -Tests all -Wipe -Cleanup         (full pass on a clean emulator)
# Starts the emulator if it is not running, installs the debug APK, runs the scenarios (tools\emu\<name>.ps1), writes
# dist\emu_result.json and prints a compact table; screenshots are kept only for failed checks (in %TEMP%\tropa_emu).
# -Cleanup closes the emulator, adb and the Gradle daemon at the end (the rules of the emulator-session skill).
param(
    [string]$Tests = "nav,wait24,delete-guard",
    [switch]$Wipe,
    [switch]$Cleanup,
    [switch]$List,
    [string]$Apk = "build\app\outputs\flutter-apk\app-debug.apk"
)
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "emu\lib.ps1")
$scenarioDir = Join-Path $PSScriptRoot "emu"
$all = Get-ChildItem $scenarioDir -Filter *.ps1 | Where-Object { $_.Name -ne "lib.ps1" } | ForEach-Object { $_.BaseName }
if ($List) { "Scenarios: " + ($all -join ", ") + "  (core = emu_check.ps1, about 6 min; the others 2-4 min each)"; return }
$run = if ($Tests -eq "all") { @("core") + ($all | Where-Object { $_ -ne "core" }) } else { $Tests -split "," | ForEach-Object { $_.Trim() } }
foreach ($t in $run) { if ($all -notcontains $t) { Write-Host "unknown scenario '$t'; -List shows them"; return } }
Get-ChildItem $script:tmp -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
Set-Location $script:root

# --- emulator
$devices = (adb devices) -join "`n"
if ($devices -notmatch "emulator-5554\s+device") {
    $emuArgs = @("-avd", "Pixel_5", "-gpu", "host", "-memory", "1536", "-no-snapshot-save")
    if ($Wipe) { $emuArgs += "-wipe-data" }
    Start-Process emulator -ArgumentList $emuArgs -WindowStyle Hidden
    adb wait-for-device | Out-Null
}
do { Start-Sleep 5; $b = adb shell getprop sys.boot_completed } until ($b -match "1")
adb install -r $Apk 2>&1 | Select-Object -Last 1
foreach ($p in "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION", "POST_NOTIFICATIONS", "ACTIVITY_RECOGNITION") { adb shell pm grant $pkg android.permission.$p 2>$null | Out-Null }

# --- scenarios (core makes its own data; the others share one fixture)
$fixtureDone = $false
foreach ($t in $run) {
    Write-Host "== $t"
    if ($t -ne "core" -and -not $fixtureDone) { Ensure-Fixture; $fixtureDone = $true }
    . (Join-Path $scenarioDir "$t.ps1")
    try { Test-Run } catch { Check $t "scenario crashed" $false $_.Exception.Message }
    if ($t -eq "core") { $fixtureDone = $false }
    adb shell am force-stop $pkg
}

# --- result
$failed = @($script:Results | Where-Object { $_.Result -eq "FAIL" })
$summary = [pscustomobject]@{
    when = (Get-Date).ToString("s"); scenarios = $run; passed = ($script:Results.Count - $failed.Count); failed = $failed.Count
    results = $script:Results; screenshots = $script:tmp
}
New-Item -ItemType Directory -Force (Join-Path $script:root "dist") | Out-Null
$summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $script:root "dist\emu_result.json") -Encoding UTF8
$script:Results | Format-Table Scenario, Check, Result -AutoSize | Out-String -Width 200
if ($failed.Count -eq 0) { "ALL $($script:Results.Count) CHECKS PASSED" } else { "$($failed.Count) FAILED of $($script:Results.Count): see dist\emu_result.json, screenshots in $script:tmp" }

if ($Cleanup) {
    adb shell am force-stop $pkg
    adb emu kill | Out-Null; Start-Sleep 6
    $env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
    & (Join-Path $script:root "android\gradlew.bat") --stop 2>&1 | Out-Null
    adb kill-server
    Get-Process | Where-Object { $_.ProcessName -match "qemu|emulator|adb|java|dart|flutter|gradle" } | Select-Object ProcessName
}
