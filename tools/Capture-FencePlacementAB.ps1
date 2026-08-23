param(
    [Parameter(Mandatory = $true)][ValidateSet('little', 'mid')][string]$Placement,
    [string]$Adb = 'E:\Develop\Android\Sdk\platform-tools\adb.exe',
    [string]$Serial = '192.168.3.3:5555'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultRoot = Join-Path $root "test-results\fence-$Placement-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-fence-ab'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-fence-ab.pbtxt'
$remoteTrace = '/data/misc/perfetto-traces/hyperos4-fence-ab.perfetto-trace'
$remoteScenario = "$deviceRoot/settings-recents-fence-ab.sh"
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'settings-recents-fence-ab.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'settings-recents-fence-ab.sh') $remoteScenario | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'gesture-scenarios-dynamic.sh') "$deviceRoot/gesture-scenarios-dynamic.sh" | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $remoteScenario $deviceRoot/gesture-scenarios-dynamic.sh"

try {
    & $Adb -s $Serial shell settings put global stay_on_while_plugged_in 15
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    & $Adb -s $Serial shell su -c 'cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq' |
        Out-File -LiteralPath (Join-Path $resultRoot 'policy0-before.txt') -Encoding ascii
    & $Adb -s $Serial shell su -c '/data/adb/modules/hyperos4_recents_source_app_yield/webui.sh threads' |
        Out-File -LiteralPath (Join-Path $resultRoot 'threads-before.txt') -Encoding utf8
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
    & $Adb -s $Serial shell su -c 'cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq' |
        Out-File -LiteralPath (Join-Path $resultRoot 'policy0-after.txt') -Encoding ascii
}
finally {
    if ($stayOn -match '^\d+$') {
        & $Adb -s $Serial shell settings put global stay_on_while_plugged_in $stayOn
    } else {
        & $Adb -s $Serial shell settings delete global stay_on_while_plugged_in
    }
    & $Adb -s $Serial shell su -c "rm -f $remoteScenario $deviceRoot/gesture-scenarios-dynamic.sh $remoteConfig $remoteTrace"
    & $Adb -s $Serial shell su -c "rmdir $deviceRoot"
}

$resultRoot
