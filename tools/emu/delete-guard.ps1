# Scenario "delete-guard": a walk that is being recorded cannot be deleted; a note needs a GPS position.
function Test-Run {
    $s = "delete-guard"
    adb emu geo fix 106.0020 20.2536 | Out-Null
    Start-App 40
    TapLabel "^Start recording" | Out-Null; Start-Sleep 8
    adb emu geo fix 106.0021 20.2537 | Out-Null; Start-Sleep 3
    Check $s "recording started" (LogHas "\[SVC\] started session=")
    # the first card of the list is the walk being recorded
    Swipe-Up
    TapLabel "recording" | Out-Null; Start-Sleep 4
    TapLabel "Show menu" | Out-Null; Start-Sleep 1
    $del = HasLabel "^Delete$"
    Check $s "Delete is in the menu" $del.Found
    # a disabled item does nothing: no "Delete this walk?" question appears
    TapLabel "^Delete$" | Out-Null; Start-Sleep 2
    Check $s "Delete does nothing while recording" (-not (HasLabel "Delete this walk").Found)
    if ((HasLabel "Delete this walk").Found) { TapLabel "^Cancel$" | Out-Null }
    Back; Back
    Stop-Walk
    Check $s "walk stopped" (LogHas "\[STOP\] UI requested stop")
    Check $s "no uncaught errors" (-not (LogHas "UNCAUGHT|FLUTTER_ERROR|FATAL"))
}
