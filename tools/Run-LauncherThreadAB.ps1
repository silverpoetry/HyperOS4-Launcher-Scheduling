param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL,
    [int]$Repetitions = 3,
    [int]$StartRepetition = 1,
    [string[]]$Scenarios = @('fast-home', 'slow-recents', 'cancel-half', 'open-home-file-manager', 'open-recents-center')
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultRoot = Join-Path $root "test-results\shennong-thread-policy-$stamp"
New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null

$deviceRoot = '/data/local/tmp/hyperos4-launcher-ab'
$files = @(
    'gesture-scenarios.sh',
    'set-thread-policy.sh',
    'run-launcher-stat.sh',
    'launcher-frametimeline.pbtxt'
)

& $Adb connect $Serial | Out-Null
& $Adb -s $Serial shell su -c "mkdir -p $deviceRoot"
foreach ($file in $files) {
    & $Adb -s $Serial push (Join-Path $PSScriptRoot $file) "$deviceRoot/$file" | Out-Null
}
& $Adb -s $Serial shell su -c "chmod 0755 $deviceRoot/*.sh"

function Prepare-Scenario([string]$Scenario) {
    switch ($Scenario) {
        'fast-home' {
            & $Adb -s $Serial shell input keyevent BACK
            & $Adb -s $Serial shell am start -a android.settings.SETTINGS | Out-Null
            Start-Sleep -Milliseconds 1400
        }
        'slow-recents' {
            & $Adb -s $Serial shell input keyevent BACK
            & $Adb -s $Serial shell am start -a android.settings.SETTINGS | Out-Null
            Start-Sleep -Milliseconds 1400
        }
        'cancel-half' {
            & $Adb -s $Serial shell input keyevent BACK
            & $Adb -s $Serial shell am start -a android.settings.SETTINGS | Out-Null
            Start-Sleep -Milliseconds 1400
        }
        'open-home-file-manager' {
            & $Adb -s $Serial shell input keyevent HOME
            Start-Sleep -Milliseconds 1400
        }
        'open-recents-center' {
            & $Adb -s $Serial shell am start -a android.settings.SETTINGS | Out-Null
            Start-Sleep -Milliseconds 1200
            & $Adb -s $Serial shell "$deviceRoot/gesture-scenarios.sh" slow-recents
            Start-Sleep -Milliseconds 1400
        }
    }
}

function Run-Case([string]$Policy, [string]$Scenario, [int]$Repetition) {
    $caseName = "$Scenario-$Policy-r$Repetition"
    $caseDirectory = Join-Path $resultRoot $caseName
    New-Item -ItemType Directory -Path $caseDirectory -Force | Out-Null
    & $Adb -s $Serial shell su -c "$deviceRoot/set-thread-policy.sh $Policy" | Out-File -LiteralPath (Join-Path $caseDirectory 'policy.txt') -Encoding utf8
    Prepare-Scenario $Scenario

    $traceDevice = "$deviceRoot/$caseName.perfetto-trace"
    $statDevice = "$deviceRoot/$caseName.simpleperf.csv"
    $trace = Start-Process -FilePath $Adb -ArgumentList @(
        '-s', $Serial, 'shell', 'perfetto', '--txt',
        '-c', "$deviceRoot/launcher-frametimeline.pbtxt",
        '-o', $traceDevice
    ) -PassThru -WindowStyle Hidden
    $stat = Start-Process -FilePath $Adb -ArgumentList @(
        '-s', $Serial, 'shell', 'su', '-c',
        "$deviceRoot/run-launcher-stat.sh $statDevice"
    ) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 250
    & $Adb -s $Serial shell "$deviceRoot/gesture-scenarios.sh" $Scenario
    $stat.WaitForExit()
    $trace.WaitForExit()

    & $Adb -s $Serial pull $traceDevice (Join-Path $caseDirectory 'trace.perfetto-trace') | Out-Null
    & $Adb -s $Serial pull $statDevice (Join-Path $caseDirectory 'simpleperf.csv') | Out-Null
    & $Adb -s $Serial shell su -c "cat /data/adb/modules/hyperos4_recents_source_app_yield/launcher-mode; dumpsys window | grep mCurrentFocus; tail -n 24 /data/local/tmp/hyperos4-launcher-scheduling.log" |
        Out-File -LiteralPath (Join-Path $caseDirectory 'after.txt') -Encoding utf8
    & $Adb -s $Serial shell rm -f $traceDevice $statDevice
}

try {
    & $Adb -s $Serial shell svc power stayon true
    & $Adb -s $Serial shell input keyevent WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    $lastRepetition = $StartRepetition + $Repetitions - 1
    for ($repetition = $StartRepetition; $repetition -le $lastRepetition; $repetition++) {
        foreach ($scenario in $Scenarios) {
            $order = if (($repetition % 2) -eq 1) { @('disabled', 'enabled') } else { @('enabled', 'disabled') }
            foreach ($policy in $order) {
                Run-Case $policy $scenario $repetition
            }
        }
    }
}
finally {
    & $Adb -s $Serial shell su -c "$deviceRoot/set-thread-policy.sh enabled" | Out-Null
    & $Adb -s $Serial shell svc power stayon false
    & $Adb -s $Serial shell input keyevent SLEEP
}

$resultRoot
