param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$watchBinary = Join-Path (Split-Path -Parent $PSScriptRoot) 'module-src\bin\launcher-logwatch'
$stdout = Join-Path $env:TEMP 'native-logwatch.txt'
$stderr = Join-Path $env:TEMP 'native-logwatch.err'

& $Adb -s $Serial shell input keyevent WAKEUP
& $Adb -s $Serial shell wm dismiss-keyguard
& $Adb -s $Serial shell input keyevent BACK
& $Adb -s $Serial shell am start -a android.settings.SETTINGS | Out-Null
Start-Sleep -Seconds 3
& $Adb -s $Serial push $watchBinary /data/local/tmp/launcher-logwatch | Out-Null
& $Adb -s $Serial shell chmod 0755 /data/local/tmp/launcher-logwatch
Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue

$watch = Start-Process -FilePath $Adb `
    -ArgumentList @('-s', $Serial, 'shell', '/data/local/tmp/launcher-logwatch') `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
    -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 500
$swipe = Start-Process -FilePath $Adb `
    -ArgumentList @('-s', $Serial, 'shell', 'input', 'swipe', '1524', '2010', '1524', '650', '180') `
    -PassThru -WindowStyle Hidden
$timer = [Diagnostics.Stopwatch]::StartNew()
$firstLength = 0
while ($timer.ElapsedMilliseconds -lt 3000 -and $firstLength -eq 0) {
    Start-Sleep -Milliseconds 5
    if (Test-Path -LiteralPath $stdout) {
        $firstLength = (Get-Item -LiteralPath $stdout).Length
    }
}
$firstOutputMs = $timer.ElapsedMilliseconds
$swipe.WaitForExit()
Start-Sleep -Seconds 1
$watch.Kill()
$watch.WaitForExit()
"first_output_after_swipe_start_ms=$firstOutputMs"
Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue
Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue
