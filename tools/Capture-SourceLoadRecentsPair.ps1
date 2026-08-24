param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$pairRoot = Join-Path $projectRoot "test-results\source-load-pair-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-source-load-pair'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-source-load-pair.pbtxt'
$remoteScenario = "$deviceRoot/recents-rounds.sh"
$remoteInjector = "$deviceRoot/three-finger-swipe"
$localInjector = Join-Path $PSScriptRoot 'bin\three-finger-swipe'
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()

if (-not (Test-Path -LiteralPath $localInjector)) {
    & (Join-Path $PSScriptRoot 'Build-ThreeFingerInjector.ps1')
}

New-Item -ItemType Directory -Path $pairRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'source-load-recents-pair.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-recents-stress.sh') $remoteScenario | Out-Null
& $Adb -s $Serial push $localInjector $remoteInjector | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $remoteScenario $remoteInjector"

function Capture-Case {
    param(
        [string]$Name,
        [string]$LaunchCommand,
        [string]$SourcePackage
    )

    $caseRoot = Join-Path $pairRoot $Name
    $remoteTrace = "/data/misc/perfetto-traces/hyperos4-source-load-$Name.perfetto-trace"
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

    & $Adb -s $Serial shell $LaunchCommand |
        Out-File -LiteralPath (Join-Path $caseRoot 'launch.txt') -Encoding utf8
    Start-Sleep -Seconds 4
    (& $Adb -s $Serial shell pidof $SourcePackage).Trim() |
        Out-File -LiteralPath (Join-Path $caseRoot 'source-pid.txt') -Encoding ascii

    & $Adb -s $Serial shell rm -f $remoteTrace
    $perfettoPid = (& $Adb -s $Serial shell perfetto --txt -c $remoteConfig -o $remoteTrace --background-wait).Trim()
    Start-Sleep -Milliseconds 500
    & $Adb -s $Serial shell su -c $remoteScenario |
        Out-File -LiteralPath (Join-Path $caseRoot 'phases.txt') -Encoding ascii

    for ($poll = 0; $poll -lt 24; $poll++) {
        & $Adb -s $Serial shell test -d "/proc/$perfettoPid"
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep -Seconds 1
    }

    & $Adb -s $Serial pull $remoteTrace (Join-Path $caseRoot 'trace.perfetto-trace') | Out-Null
    & $Adb -s $Serial shell su -c 'cat /data/local/tmp/hyperos4-launcher-scheduling.log' |
        Out-File -LiteralPath (Join-Path $caseRoot 'module.log') -Encoding utf8
    & $Adb -s $Serial shell rm -f $remoteTrace
}

try {
    & $Adb -s $Serial shell settings put global stay_on_while_plugged_in 15
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard

    Capture-Case -Name 'high-jkchess' `
        -LaunchCommand 'am start -W -n com.tencent.jkchess/.ApolloZGame' `
        -SourcePackage 'com.tencent.jkchess'

    & $Adb -s $Serial shell am force-stop com.tencent.jkchess
    Capture-Case -Name 'low-settings' `
        -LaunchCommand 'am start -W -a android.settings.SETTINGS' `
        -SourcePackage 'com.android.settings'
}
finally {
    if ($stayOn -match '^\d+$') {
        & $Adb -s $Serial shell settings put global stay_on_while_plugged_in $stayOn
    } else {
        & $Adb -s $Serial shell settings delete global stay_on_while_plugged_in
    }
    & $Adb -s $Serial shell su -c "rm -f $remoteScenario $remoteInjector $remoteConfig"
    & $Adb -s $Serial shell su -c "rmdir $deviceRoot"
}

$pairRoot
