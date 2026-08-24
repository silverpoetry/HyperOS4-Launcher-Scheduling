param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL,
    [switch]$Warm
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$launchMode = if ($Warm) { 'warm' } else { 'cold' }
$resultRoot = Join-Path $root "test-results\sheng-jkchess-recents-$launchMode-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-jkchess-recents'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-jkchess-recents.pbtxt'
$remoteScenario = "$deviceRoot/jkchess-recents-stress.sh"
$remoteInjector = "$deviceRoot/three-finger-swipe"
$remoteTrace = '/data/misc/perfetto-traces/hyperos4-jkchess-recents.perfetto-trace'
$localInjector = Join-Path $PSScriptRoot 'bin\three-finger-swipe'
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()

if (-not (Test-Path -LiteralPath $localInjector)) {
    & (Join-Path $PSScriptRoot 'Build-ThreeFingerInjector.ps1')
}

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-recents-trace.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-recents-stress.sh') $remoteScenario | Out-Null
& $Adb -s $Serial push $localInjector $remoteInjector | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $remoteScenario $remoteInjector"

try {
    & $Adb -s $Serial shell svc power stayon true
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    & $Adb -s $Serial shell rm -f $remoteTrace

    $perfettoPid = (& $Adb -s $Serial shell perfetto --txt -c $remoteConfig -o $remoteTrace --background-wait).Trim()
    $perfettoPid | Out-File -LiteralPath (Join-Path $resultRoot 'perfetto-pid.txt') -Encoding ascii
    Start-Sleep -Milliseconds 500

    if ($Warm) {
        & $Adb -s $Serial shell am start -W -n com.tencent.jkchess/.ApolloZGame |
            Out-File -LiteralPath (Join-Path $resultRoot 'launch.txt') -Encoding utf8
        Start-Sleep -Seconds 2
    } else {
        & $Adb -s $Serial shell am force-stop com.tencent.jkchess
        & $Adb -s $Serial shell am start -W -n com.tencent.jkchess/com.tencent.gcloud.msdk.core.policy.ZGamePolicyActivity |
            Out-File -LiteralPath (Join-Path $resultRoot 'launch.txt') -Encoding utf8
        Start-Sleep -Seconds 6
    }
    (& $Adb -s $Serial shell pidof com.tencent.jkchess).Trim() |
        Out-File -LiteralPath (Join-Path $resultRoot 'game-pid.txt') -Encoding ascii
    & $Adb -s $Serial shell dumpsys activity activities |
        Select-String -Pattern 'topResumedActivity|mResumedActivity|com.tencent.jkchess' |
        Select-Object -First 40 |
        Out-File -LiteralPath (Join-Path $resultRoot 'foreground-before-stress.txt') -Encoding utf8

    & $Adb -s $Serial shell su -c $remoteScenario |
        Out-File -LiteralPath (Join-Path $resultRoot 'phases.txt') -Encoding ascii

    for ($poll = 0; $poll -lt 35; $poll++) {
        & $Adb -s $Serial shell test -d "/proc/$perfettoPid"
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep -Seconds 1
    }

    & $Adb -s $Serial pull $remoteTrace (Join-Path $resultRoot 'trace.perfetto-trace') | Out-Null
    & $Adb -s $Serial shell su -c "cat /data/local/tmp/hyperos4-launcher-scheduling.log" |
        Out-File -LiteralPath (Join-Path $resultRoot 'module.log') -Encoding utf8
    & $Adb -s $Serial shell dumpsys activity activities |
        Select-String -Pattern 'topResumedActivity|mResumedActivity|com.tencent.jkchess' |
        Select-Object -First 40 |
        Out-File -LiteralPath (Join-Path $resultRoot 'foreground-after-stress.txt') -Encoding utf8
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
