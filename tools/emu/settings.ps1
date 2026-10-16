# Scenario "settings": the merged "Sound and navigation" group, no "Recording" group, no Privacy in amateur mode, Help opens.
function Test-Run {
    $s = "settings"
    Start-App 40
    TapLabel "^Settings" | Out-Null; Start-Sleep 3
    adb shell input swipe 540 1700 540 1000 300; Start-Sleep 1
    Check $s "group 'Sound and navigation' exists" (HasLabel "Sound and navigation").Found
    Check $s "no separate 'Navigation' or 'Sounds' group" (-not (HasLabel "^Navigation$|^Sounds and vibration$").Found)
    Check $s "no 'Accuracy threshold' (Recording group removed)" (-not (HasLabel "Accuracy threshold").Found)
    Check $s "no Privacy group in amateur mode" (-not (HasLabel "^Privacy$").Found)
    Swipe-Up; Swipe-Up; Swipe-Up
    Check $s "Help is on the settings screen" (HasLabel "^Help").Found
    TapLabel "^Help" | Out-Null; Start-Sleep 3
    Check $s "Help screen opens with questions" (HasLabel "How do I start recording").Found
    TapLabel "How do I start recording" | Out-Null; Start-Sleep 2   # the expanded text is checked by eye (uiautomator does not show it)
    Check $s "no uncaught errors" (-not (LogHas "UNCAUGHT|FLUTTER_ERROR|FATAL"))
}
