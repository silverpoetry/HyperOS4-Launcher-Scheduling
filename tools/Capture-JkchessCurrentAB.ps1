param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }

$projectRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultRoot = Join-Path $projectRoot "test-results\jkchess-current-ab-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-jkchess-current-ab'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-jkchess-current-ab.pbtxt'
$remoteScenario = "$deviceRoot/scenario.sh"
$module = '/data/adb/modules/hyperos4_recents_source_app_yield'
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()
$sourceBefore = (& $Adb -s $Serial shell su -c "$module/webui.sh status" |
    Select-String '^source_policy=' | ForEach-Object { $_.Line.Split('=', 2)[1] }).Trim()

function Get-ModuleStatus {
    & $Adb -s $Serial shell su -c "$module/webui.sh status"
}

function Get-DaemonStats {
    foreach ($name in @('launcher-logwatch', 'source-guard')) {
        $processId = (& $Adb -s $Serial shell pidof $name).Trim().Split(' ')[0]
        "NAME=$name PID=$processId"
        if (-not [string]::IsNullOrWhiteSpace($processId)) {
            & $Adb -s $Serial shell su -c "cat /proc/$processId/stat"
        }
    }
}

function Capture-Case {
    param([string]$Name, [string]$SourceState)

    $caseRoot = Join-Path $resultRoot $Name
    $remoteTrace = "/data/misc/perfetto-traces/hyperos4-jkchess-$Name.perfetto-trace"
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

    & $Adb -s $Serial shell su -c "$module/webui.sh configure source=$SourceState" |
        Out-File -LiteralPath (Join-Path $caseRoot 'configure.txt') -Encoding utf8
    Start-Sleep -Seconds 1
    & $Adb -s $Serial shell am start -W -n com.tencent.jkchess/.ApolloZGame |
        Out-File -LiteralPath (Join-Path $caseRoot 'launch.txt') -Encoding utf8
    Start-Sleep -Seconds 3

    $gamePid = (& $Adb -s $Serial shell pidof com.tencent.jkchess).Trim().Split(' ')[0]
    if ([string]::IsNullOrWhiteSpace($gamePid)) { throw "Game process is absent in $Name" }
    $gamePid | Out-File -LiteralPath (Join-Path $caseRoot 'game-pid.txt') -Encoding ascii
    Get-ModuleStatus | Out-File -LiteralPath (Join-Path $caseRoot 'status-before.txt') -Encoding utf8
    Get-DaemonStats | Out-File -LiteralPath (Join-Path $caseRoot 'daemon-before.txt') -Encoding utf8

    & $Adb -s $Serial shell rm -f $remoteTrace
    $perfettoPid = (& $Adb -s $Serial shell perfetto --txt -c $remoteConfig -o $remoteTrace --background-wait).Trim()
    Start-Sleep -Milliseconds 400
    & $Adb -s $Serial shell su -c "$remoteScenario 4" |
        Out-File -LiteralPath (Join-Path $caseRoot 'phases.txt') -Encoding ascii

    for ($poll = 0; $poll -lt 30; $poll++) {
        & $Adb -s $Serial shell test -d "/proc/$perfettoPid"
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep -Milliseconds 500
    }

    Get-DaemonStats | Out-File -LiteralPath (Join-Path $caseRoot 'daemon-after.txt') -Encoding utf8
    Get-ModuleStatus | Out-File -LiteralPath (Join-Path $caseRoot 'status-after.txt') -Encoding utf8
    & $Adb -s $Serial pull $remoteTrace (Join-Path $caseRoot 'trace.perfetto-trace') | Out-Null
    & $Adb -s $Serial shell dumpsys window displays |
        Select-String -Pattern 'mCurrentFocus|mFocusedApp' |
        Select-Object -First 4 |
        Out-File -LiteralPath (Join-Path $caseRoot 'focus-after.txt') -Encoding utf8
}

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-current-ab-trace.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'jkchess-three-finger-ab.sh') $remoteScenario | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $remoteScenario"

try {
    & $Adb -s $Serial shell settings put global stay_on_while_plugged_in 15
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    Capture-Case -Name 'enabled-a' -SourceState 'enabled'
    Capture-Case -Name 'disabled' -SourceState 'disabled'
    Capture-Case -Name 'enabled-b' -SourceState 'enabled'
}
finally {
    & $Adb -s $Serial shell su -c "$module/webui.sh configure source=$sourceBefore" | Out-Null
    if ($stayOn -match '^\d+$') {
        & $Adb -s $Serial shell settings put global stay_on_while_plugged_in $stayOn
    } else {
        & $Adb -s $Serial shell settings delete global stay_on_while_plugged_in
    }
    & $Adb -s $Serial shell su -c "rm -rf $deviceRoot"
    & $Adb -s $Serial shell rm -f $remoteConfig
    & $Adb -s $Serial shell rm -f /data/misc/perfetto-traces/hyperos4-jkchess-enabled-a.perfetto-trace
    & $Adb -s $Serial shell rm -f /data/misc/perfetto-traces/hyperos4-jkchess-disabled.perfetto-trace
    & $Adb -s $Serial shell rm -f /data/misc/perfetto-traces/hyperos4-jkchess-enabled-b.perfetto-trace
}

$resultRoot
