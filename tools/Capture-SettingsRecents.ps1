param(
    [string]$Adb = 'E:\Develop\Android\Sdk\platform-tools\adb.exe',
    [string]$Serial = '192.168.3.3:5555'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultRoot = Join-Path $root "test-results\sheng-settings-recents-lowload-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-settings-recents'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-settings-recents.pbtxt'
$remoteScenario = "$deviceRoot/jkchess-recents-stress.sh"
$remoteInjector = "$deviceRoot/three-finger-swipe"
$remoteTrace = '/data/misc/perfetto-traces/hyperos4-settings-recents.perfetto-trace'
$localInjector = Join-Path $PSScriptRoot 'bin\three-finger-swipe'
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-recents-trace.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-recents-stress.sh') $remoteScenario | Out-Null
& $Adb -s $Serial push $localInjector $remoteInjector | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $remoteScenario $remoteInjector"

try {
    & $Adb -s $Serial shell settings put global stay_on_while_plugged_in 15
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    & $Adb -s $Serial shell am force-stop com.tencent.jkchess
    & $Adb -s $Serial shell am start -W -a android.settings.SETTINGS |
        Out-File -LiteralPath (Join-Path $resultRoot 'launch.txt') -Encoding utf8
    Start-Sleep -Seconds 3
    (& $Adb -s $Serial shell pidof com.android.settings).Trim() |
        Out-File -LiteralPath (Join-Path $resultRoot 'source-pid.txt') -Encoding ascii
    & $Adb -s $Serial shell rm -f $remoteTrace
    $perfettoPid = (& $Adb -s $Serial shell perfetto --txt -c $remoteConfig -o $remoteTrace --background-wait).Trim()
    Start-Sleep -Milliseconds 500
    & $Adb -s $Serial shell su -c $remoteScenario |
        Out-File -LiteralPath (Join-Path $resultRoot 'phases.txt') -Encoding ascii
    for ($poll = 0; $poll -lt 35; $poll++) {
        & $Adb -s $Serial shell test -d "/proc/$perfettoPid"
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep -Seconds 1
    }
    & $Adb -s $Serial pull $remoteTrace (Join-Path $resultRoot 'trace.perfetto-trace') | Out-Null
    & $Adb -s $Serial shell su -c 'cat /data/local/tmp/hyperos4-launcher-scheduling.log' |
        Out-File -LiteralPath (Join-Path $resultRoot 'module.log') -Encoding utf8
}
finally {
    if ($stayOn -match '^\d+$') {
        & $Adb -s $Serial shell settings put global stay_on_while_plugged_in $stayOn
    } else {
        & $Adb -s $Serial shell settings delete global stay_on_while_plugged_in
    }
    & $Adb -s $Serial shell su -c "rm -f $remoteScenario $remoteInjector $remoteConfig $remoteTrace"
    & $Adb -s $Serial shell su -c "rmdir $deviceRoot"
}

$resultRoot
