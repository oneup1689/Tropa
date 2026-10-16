# Scenario "wait24": "Wait at the start" with 24/7 switched on survives a kill of the process and an app restart.
function Test-Run {
    $s = "wait24"
    adb emu geo fix 106.0000 20.2500 | Out-Null     # far from the start of No-map (Hanoi)
    Start-App 40
    # 24/7 on (the calendar button of the start card opens the Auto-record screen)
    TapLabel "Auto-record" | Out-Null; Start-Sleep 3
    Tap 931 452; Start-Sleep 3   # the switch of the card (a label tap does not reach it)
    Check $s "24/7 switched on" (LogHas "\[AUTO\] UI enabled 24/7")
    Back
    Open-Route "No-map"
    TapLabel "Follow the route|Walk this route" | Out-Null; Start-Sleep 12
    TapLabel "Wait at the start" | Out-Null; Start-Sleep 8
    Check $s "waiting started" (LogHas "\[WAIT\] waiting for the route start")
    $pid1 = (adb shell pidof $pkg).Trim()
    adb shell "run-as $pkg kill -9 $pid1" | Out-Null
    Start-Sleep 20
    Check $s "service resumed waiting after the kill" ((@(Log "\[WAIT\] waiting for the route start" 5)).Count -ge 2)
    Start-App 40
    Start-Sleep 12
    Check $s "banner 'Waiting for you at the start'" (HasLabel "Waiting for you at the").Found
    adb emu geo fix 105.8560 21.0302 | Out-Null     # arrive at the start
    Start-Sleep 25
    Check $s "recording began by itself at the start" (LogHas "\[WAIT\] arrived at the start")
    Check $s "navigation began" (LogHas "\[NAV\] begin route=2")
    Stop-Walk
    Check $s "no uncaught errors" (-not (LogHas "UNCAUGHT|FLUTTER_ERROR|FATAL"))
    # 24/7 off again, so that the next scenarios start clean
    TapLabel "Auto-record" | Out-Null; Start-Sleep 3
    Tap 931 452; Start-Sleep 2
    Back
}
