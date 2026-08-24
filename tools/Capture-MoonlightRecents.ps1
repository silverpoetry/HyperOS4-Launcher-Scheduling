param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL,
    [int]$Repetitions = 3
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultRoot = Join-Path $root "test-results\sheng-moonlight-recents-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-moonlight-recents'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-moonlight-recents.pbtxt'
$remoteScenario = "$deviceRoot/moonlight-recents-roundtrip.sh"
$remoteInjector = "$deviceRoot/three-finger-swipe"
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'moonlight-recents-trace.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'moonlight-recents-roundtrip.sh') $remoteScenario | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'bin\three-finger-swipe') $remoteInjector | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $remoteScenario $remoteInjector"

try {
    & $Adb -s $Serial shell svc power stayon true
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard

    for ($run = 1; $run -le $Repetitions; $run++) {
        $caseDir = Join-Path $resultRoot "run-$run"
        $remoteTrace = "/data/misc/perfetto-traces/hyperos4-moonlight-recents-$run.perfetto-trace"
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null

        & $Adb -s $Serial shell am start -n com.silverpoetry.moonlight/com.limelight.LandscapeGameActivity | Out-Null
        Start-Sleep -Milliseconds 1200
        & $Adb -s $Serial shell rm -f $remoteTrace
        $perfettoPid = (& $Adb -s $Serial shell perfetto --txt -c $remoteConfig -o $remoteTrace --background-wait).Trim()
        $perfettoPid | Out-File -LiteralPath (Join-Path $caseDir 'perfetto-pid.txt') -Encoding ascii
        Start-Sleep -Milliseconds 400
        & $Adb -s $Serial shell su -c $remoteScenario |
            Out-File -LiteralPath (Join-Path $caseDir 'phases.txt') -Encoding ascii
        Start-Sleep -Milliseconds 2700

        & $Adb -s $Serial pull $remoteTrace (Join-Path $caseDir 'trace.perfetto-trace') | Out-Null
        & $Adb -s $Serial shell su -c "cat /data/adb/modules/hyperos4_recents_source_app_yield/launcher-mode; cat /data/adb/modules/hyperos4_recents_source_app_yield/source-app; cat /proc/pressure/cpu; cat /proc/pressure/memory" |
            Out-File -LiteralPath (Join-Path $caseDir 'after.txt') -Encoding utf8
    }
}
finally {
    if ($stayOn -match '^\d+$') {
        & $Adb -s $Serial shell settings put global stay_on_while_plugged_in $stayOn
    } else {
        & $Adb -s $Serial shell settings delete global stay_on_while_plugged_in
    }
    & $Adb -s $Serial shell su -c "rm -f $remoteScenario $remoteInjector $remoteConfig /data/misc/perfetto-traces/hyperos4-moonlight-recents-1.perfetto-trace /data/misc/perfetto-traces/hyperos4-moonlight-recents-2.perfetto-trace /data/misc/perfetto-traces/hyperos4-moonlight-recents-3.perfetto-trace"
    & $Adb -s $Serial shell su -c "rmdir $deviceRoot"
}

$resultRoot
