param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$pairRoot = Join-Path $projectRoot "test-results\jkchess-freeze-ab-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-jkchess-freeze-ab'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-jkchess-freeze-ab.pbtxt'
$remoteScenario = "$deviceRoot/recents-freeze-ab.sh"
$remoteInjector = "$deviceRoot/three-finger-swipe"
$localInjector = Join-Path $PSScriptRoot 'bin\three-finger-swipe'
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()

if (-not (Test-Path -LiteralPath $localInjector)) {
    & (Join-Path $PSScriptRoot 'Build-ThreeFingerInjector.ps1')
}

New-Item -ItemType Directory -Path $pairRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'source-load-recents-pair.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-recents-freeze-ab.sh') $remoteScenario | Out-Null
& $Adb -s $Serial push $localInjector $remoteInjector | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $remoteScenario $remoteInjector"

function Capture-Case {
    param([string]$Name, [string]$Mode)

    $caseRoot = Join-Path $pairRoot $Name
    $remoteTrace = "/data/misc/perfetto-traces/hyperos4-jkchess-$Name.perfetto-trace"
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

    & $Adb -s $Serial shell am start -W -n com.tencent.jkchess/.ApolloZGame |
        Out-File -LiteralPath (Join-Path $caseRoot 'launch.txt') -Encoding utf8
    Start-Sleep -Seconds 4

    & $Adb -s $Serial shell rm -f $remoteTrace
    $perfettoPid = (& $Adb -s $Serial shell perfetto --txt -c $remoteConfig -o $remoteTrace --background-wait).Trim()
    Start-Sleep -Milliseconds 500
    & $Adb -s $Serial shell su -c "$remoteScenario $Mode" |
        Out-File -LiteralPath (Join-Path $caseRoot 'phases.txt') -Encoding ascii

    for ($poll = 0; $poll -lt 24; $poll++) {
        & $Adb -s $Serial shell test -d "/proc/$perfettoPid"
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep -Seconds 1
    }

    & $Adb -s $Serial pull $remoteTrace (Join-Path $caseRoot 'trace.perfetto-trace') | Out-Null
    & $Adb -s $Serial shell rm -f $remoteTrace
}

try {
    & $Adb -s $Serial shell settings put global stay_on_while_plugged_in 15
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    Capture-Case -Name 'active' -Mode 'active'
    Capture-Case -Name 'frozen' -Mode 'frozen'
}
finally {
    & $Adb -s $Serial shell su -c 'kill -CONT $(pidof com.tencent.jkchess) 2>/dev/null || true'
    if ($stayOn -match '^\d+$') {
        & $Adb -s $Serial shell settings put global stay_on_while_plugged_in $stayOn
    } else {
        & $Adb -s $Serial shell settings delete global stay_on_while_plugged_in
    }
    & $Adb -s $Serial shell su -c "rm -f $remoteScenario $remoteInjector $remoteConfig"
    & $Adb -s $Serial shell su -c "rmdir $deviceRoot 2>/dev/null || true"
}

$pairRoot
