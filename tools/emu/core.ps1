# Scenario "core": the regression check of the native recording service (tools\emu_check.ps1, about 6 min). It wipes
# the app data and needs the debug APK; its table is turned into results here.
function Test-Run {
    $out = powershell -NoProfile -File (Join-Path $script:root "tools\emu_check.ps1") 2>&1 | Out-String
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^(.+?)\s{2,}(PASS|FAIL)\s*$') { Check "core" $Matches[1].Trim() ($Matches[2] -eq "PASS") }
    }
}
