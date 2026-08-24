param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL,
    [string]$Package = 'com.android.fileexplorer',
    [string]$Component = 'com.android.fileexplorer/.FileExplorerTabActivity',
    [switch]$PreserveForeground,
    [switch]$ModuleDisabled
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultRoot = Join-Path $root "test-results\validated-recents-$stamp"
$deviceRoot = '/data/local/tmp/hyperos4-validated-recents'
$remoteConfig = '/data/misc/perfetto-configs/hyperos4-validated-recents.pbtxt'
$remoteTrace = '/data/misc/perfetto-traces/hyperos4-validated-recents.perfetto-trace'
$module = '/data/adb/modules/hyperos4_recents_source_app_yield'
$stayOn = (& $Adb -s $Serial shell settings get global stay_on_while_plugged_in).Trim()
$power = & $Adb -s $Serial shell dumpsys power
$wasAsleep = [bool]($power -match 'mWakefulness=Asleep')

function Get-ResumedActivity {
    $activities = & $Adb -s $Serial shell dumpsys activity activities
    return ($activities | Select-String 'topResumedActivity=|ResumedActivity:' | Select-Object -First 1).Line
}

function Get-ModuleStatus {
    $lines = & $Adb -s $Serial shell su -c "$module/webui.sh status"
    $status = @{}
    foreach ($line in $lines) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $status[$parts[0]] = $parts[1] }
    }
    return $status
}

New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
& $Adb -s $Serial shell su -c "rm -rf $deviceRoot"
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'validated-recents-trace.pbtxt') $remoteConfig | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'validated-recents-roundtrip.sh') "$deviceRoot/scenario.sh" | Out-Null
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'bin\three-finger-swipe') "$deviceRoot/three-finger-swipe" | Out-Null
& $Adb -s $Serial shell su -c "chmod 0755 $deviceRoot/scenario.sh $deviceRoot/three-finger-swipe"

try {
    & $Adb -s $Serial shell settings put global stay_on_while_plugged_in 15
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    if (-not $PreserveForeground) {
        & $Adb -s $Serial shell am force-stop $Package
        & $Adb -s $Serial shell am start -W -n $Component |
            Out-File -LiteralPath (Join-Path $resultRoot 'launch.txt') -Encoding utf8
        Start-Sleep -Milliseconds 1400
    }

    $resumedBefore = Get-ResumedActivity
    $resumedBefore | Out-File -LiteralPath (Join-Path $resultRoot 'resumed-before.txt') -Encoding utf8
    if ($resumedBefore -notlike "*$Package/*") { throw "Expected $Package before trace: $resumedBefore" }

    $inputDump = & $Adb -s $Serial shell dumpsys input
    $viewport = $inputDump | Select-String 'Viewport INTERNAL:.*orientation=' | Select-Object -First 1
    if (-not $viewport -or $viewport.Line -notmatch 'orientation=([0-3])') { throw 'Display orientation was not found' }
    $orientation = $Matches[1]

    $before = if ($ModuleDisabled) { @{} } else { Get-ModuleStatus }
    & $Adb -s $Serial shell rm -f $remoteTrace
    $perfettoPid = (& $Adb -s $Serial shell perfetto --txt -c $remoteConfig -o $remoteTrace --background-wait).Trim()
    Start-Sleep -Milliseconds 350
    & $Adb -s $Serial shell su -c "$deviceRoot/scenario.sh $orientation" |
        Out-File -LiteralPath (Join-Path $resultRoot 'phases.txt') -Encoding ascii

    for ($poll = 0; $poll -lt 20; $poll++) {
        & $Adb -s $Serial shell test -d "/proc/$perfettoPid"
        if ($LASTEXITCODE -ne 0) { break }
        Start-Sleep -Milliseconds 500
    }

    $after = if ($ModuleDisabled) { @{} } else { Get-ModuleStatus }
    $resumedAfter = Get-ResumedActivity
    $resumedAfter | Out-File -LiteralPath (Join-Path $resultRoot 'resumed-after.txt') -Encoding utf8
    if ($resumedAfter -notlike "*$Package/*") { throw "Expected $Package after card tap: $resumedAfter" }
    if (-not $ModuleDisabled) {
        if ($after['mode'] -ne 'app') { throw "Module did not return to app mode: $($after['mode'])" }
        if ([int]$after['transition_serial'] -le [int]$before['transition_serial']) {
            throw 'Module did not observe the recents gesture'
        }
    }

    & $Adb -s $Serial pull $remoteTrace (Join-Path $resultRoot 'trace.perfetto-trace') | Out-Null
    if (-not $ModuleDisabled) {
        & $Adb -s $Serial pull /data/local/tmp/hyperos4-launcher-scheduling.log (Join-Path $resultRoot 'module.log') | Out-Null
    }
    "orientation=$orientation`nmodule_disabled=$([int][bool]$ModuleDisabled)`nserial_before=$($before['transition_serial'])`nserial_after=$($after['transition_serial'])" |
        Out-File -LiteralPath (Join-Path $resultRoot 'validation.txt') -Encoding ascii
}
finally {
    if ($stayOn -match '^\d+$') {
        & $Adb -s $Serial shell settings put global stay_on_while_plugged_in $stayOn
    } else {
        & $Adb -s $Serial shell settings delete global stay_on_while_plugged_in
    }
    if ($wasAsleep) { & $Adb -s $Serial shell input keyevent SLEEP }
    & $Adb -s $Serial shell su -c "rm -rf $deviceRoot"
    & $Adb -s $Serial shell su -c "rm -f $remoteConfig $remoteTrace /data/local/tmp/recents-corrected.png /data/local/tmp/three-finger-swipe"
}

$resultRoot
