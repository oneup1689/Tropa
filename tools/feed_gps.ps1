param(
  [string]$Gpx,
  [int]$From = 0,
  [int]$Count = 60,
  [double]$DelaySec = 1.0,
  [double]$LatOffset = 0.0
)
# Sends points from the test GPX to the emulator as GPS fixes (adb emu geo fix lon lat).
# -LatOffset shifts every point north (0.001 deg is about 111 m) to simulate leaving a route.
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
[xml]$x = Get-Content $Gpx -Raw -Encoding UTF8
$ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
$ns.AddNamespace("g", "http://www.topografix.com/GPX/1/1")
$pts = $x.SelectNodes("//g:trkpt", $ns)
$inv = [System.Globalization.CultureInfo]::InvariantCulture
for ($i = $From; $i -lt [Math]::Min($pts.Count, $From + $Count); $i++) {
  $lat = ([double]::Parse($pts[$i].GetAttribute("lat"), $inv) + $LatOffset).ToString($inv)
  $lon = $pts[$i].GetAttribute("lon")
  & $adb emu geo fix $lon $lat | Out-Null
  Start-Sleep -Milliseconds ([int]($DelaySec * 1000))
}
"sent $Count points from index $From (lat offset $LatOffset)"
