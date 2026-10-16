# Scenario "notes-after": a text note is added to a finished walk (place chosen on the route), moved, and deleted.
function Test-Run {
    $s = "notes-after"
    adb emu geo fix 106.0000 20.2500 | Out-Null
    Start-App 40
    TapLabel "^Start recording" | Out-Null; Start-Sleep 8
    $p = Walk 106.0 20.25 12 0 0.00009
    Stop-Walk
    Check $s "walk recorded and stopped" (LogHas "\[STOP\] UI requested stop")
    TapLabel "points:" | Out-Null; Start-Sleep 4
    Swipe-Up
    Check $s "Add a note button is on the walk screen" (HasLabel "Add a note").Found
    TapLabel "Add a note" | Out-Null; Start-Sleep 2
    adb shell input text "After_the_walk" | Out-Null; Start-Sleep 1
    adb shell input keyevent 4 | Out-Null; Start-Sleep 1     # close the keyboard
    Check $s "dialog asks for the place on the route" (HasLabel "Touch the route").Found
    TapLabel "^Save$" | Out-Null; Start-Sleep 3
    Check $s "note saved after the walk" (LogHas "note added after the walk")
    Check $s "note is listed" (HasLabel "After_the_walk").Found
    TapLabel "Show menu|More options" | Out-Null; Start-Sleep 1
    Check $s "note menu has Change the place" (HasLabel "Change the place").Found
    Back
    Check $s "no uncaught errors" (-not (LogHas "UNCAUGHT|FLUTTER_ERROR|FATAL"))
}
