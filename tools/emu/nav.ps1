# Scenario "nav": walk the In-map route with navigation on a phone that has the map (map on the navigation screen, voice, finish).
function Test-Run {
    $s = "nav"
    adb emu geo fix 106.0000 20.2500 | Out-Null
    Start-App 40
    Open-Route "In-map"
    TapLabel "Follow the route|Walk this route" | Out-Null
    Start-Sleep 12
    Check $s "navigator began" (LogHas "\[NAV\] begin route=\d+")
    Check $s "navigation screen has the map (no download card)" (-not (HasLabel "Download the route map").Found)
    $p = Walk 106.0 20.25 40 0 0.00009        # 400 m north: the first turn comes
    Check $s "voice prompt before the turn" (LogHas 'say "In (100|30) meters')
    $p = Walk $p[0] $p[1] 20 0.0000962 0      # turn east
    Check $s "no off-route alarm on the route" (-not (LogHas "\[NAV\] OFF ROUTE"))
    # one wild fix must not make the voice say "left the route" (3 positions over 15 s are needed)
    adb emu geo fix $p[0] ($p[1] + 0.0009) | Out-Null; Start-Sleep 2
    adb emu geo fix $p[0] $p[1] | Out-Null; Start-Sleep 5
    Check $s "single outlier is not 'left the route'" (-not (LogHas 'say "You left the route'))
    Stop-Walk
    Check $s "walk stopped and navigation ended" ((LogHas "\[STOP\] UI requested stop") -and (LogHas "\[NAV\] end"))
    Check $s "no uncaught errors" (-not (LogHas "UNCAUGHT|FLUTTER_ERROR|FATAL"))
}
