param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $RepositoryRoot 'module-src'

$required = @(
    'service.sh', 'webui.sh', 'action.sh', 'uninstall.sh', 'module.prop',
    'lib\config.sh', 'lib\runtime.sh', 'lib\topology.sh',
    'lib\launcher-policy.sh', 'lib\frequency-policy.sh',
    'lib\systemui-policy.sh',
    'lib\process-policy.sh', 'lib\state-machine.sh', 'lib\events.sh',
    'lib\webui-status.sh', 'lib\webui-control.sh',
    'webroot\index.html', 'webroot\js\main.js'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $moduleRoot $relative) -PathType Leaf)) {
        throw "Missing required module source: $relative"
    }
}

foreach ($legacy in @('thread-policy.sh', 'webroot\app.js', 'webroot\styles.css')) {
    if (Test-Path -LiteralPath (Join-Path $moduleRoot $legacy)) {
        throw "Legacy source must not return: $legacy"
    }
}

$version = (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'VERSION') -Raw).Trim()
$moduleVersion = (Select-String -LiteralPath (Join-Path $moduleRoot 'module.prop') -Pattern '^version=(.+)$').Matches[0].Groups[1].Value
if ($moduleVersion -ne $version) {
    throw "VERSION ($version) and module.prop ($moduleVersion) disagree"
}

$sourceFiles = Get-ChildItem -LiteralPath $moduleRoot -File -Recurse |
    Where-Object { $_.Extension -in '.sh', '.prop', '.html', '.css', '.js' }
foreach ($file in $sourceFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ([Array]::IndexOf($bytes, [byte]13) -ge 0) {
        throw "CRLF is not allowed in packaged source: $($file.FullName)"
    }
    $lineCount = (Get-Content -LiteralPath $file.FullName).Count
    if ($file.Extension -in '.sh', '.html', '.css', '.js' -and $lineCount -gt 260) {
        throw "Source file exceeds 260-line responsibility budget: $($file.FullName) ($lineCount)"
    }
}

$shellPattern = [regex]'\.\s+"\$MODDIR/([^"\r\n]+)"'
foreach ($script in Get-ChildItem -LiteralPath $moduleRoot -Filter '*.sh' -File -Recurse) {
    $text = Get-Content -LiteralPath $script.FullName -Raw
    foreach ($match in $shellPattern.Matches($text)) {
        $dependency = Join-Path $moduleRoot ($match.Groups[1].Value.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
            throw "Missing shell dependency in $($script.Name): $dependency"
        }
    }
}

$importPattern = [regex]'from\s+["''](\.[^"'']+)["'']'
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $moduleRoot 'webroot\js') -Filter '*.js' -File) {
    $text = Get-Content -LiteralPath $script.FullName -Raw
    foreach ($match in $importPattern.Matches($text)) {
        $dependency = [IO.Path]::GetFullPath((Join-Path $script.DirectoryName $match.Groups[1].Value))
        if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
            throw "Missing JavaScript import in $($script.Name): $dependency"
        }
    }
}

$html = Get-Content -LiteralPath (Join-Path $moduleRoot 'webroot\index.html') -Raw
$assetPattern = [regex]'(?:href|src)="(\./[^"?#]+)"'
foreach ($match in $assetPattern.Matches($html)) {
    $dependency = Join-Path (Join-Path $moduleRoot 'webroot') $match.Groups[1].Value
    if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
        throw "Missing WebUI asset: $dependency"
    }
}

$threadController = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\launcher_threadctl.c') -Raw
if ($threadController -notmatch 'CLASS_RASTER[\s\S]*select_mask\(raster_placement' -or
    $threadController -notmatch 'render_mask') {
    throw 'Launcher Raster must use the configurable topology-derived placement mask'
}

$logWatcher = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\launcher_logwatch.c') -Raw
$yieldFunction = [regex]::Match(
    $logWatcher,
    'static struct yield_result yield_source_native\(void\) \{(?<body>[\s\S]*?)\n\}',
    [Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $yieldFunction.Success) {
    throw 'yield_source_native was not found'
}
$yieldBody = $yieldFunction.Groups['body'].Value
$affinityApply = $yieldBody.IndexOf('run_affinity_apply(result.pid, result.uid)')
if ($affinityApply -lt 0) {
    throw 'Native source yield must invoke the atomic affinity controller transaction'
}
if ($logWatcher -notmatch '\(char \*\)"yield"') {
    throw 'Native source yield must use the snapshot-before-cgroup operation'
}
if ($logWatcher -notmatch 'finish_remote_transition to_home = false') {
    throw 'Native watcher must forward same-app return completion'
}

$events = Get-Content -LiteralPath (Join-Path $moduleRoot 'lib\events.sh') -Raw
if ($events -notmatch 'finish_remote_transition to_home = false') {
    throw 'State machine must restore the source on same-app return completion'
}

$affinityController = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\source_affinityctl.c') -Raw
$yieldState = [regex]::Match(
    $affinityController,
    'static int yield_state\([^)]*\) \{(?<body>[\s\S]*?)\n\}',
    [Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $yieldState.Success) {
    throw 'yield_state was not found in source_affinityctl'
}
$yieldStateBody = $yieldState.Groups['body'].Value
if ($yieldStateBody -notmatch 'apply_state\(pid, uid, path, 1\)') {
    throw 'Source yield must request the atomic snapshot-cgroup-affinity transaction'
}
$applyStart = $affinityController.IndexOf('static int apply_state(')
$applyEnd = $affinityController.IndexOf('static int yield_state(', $applyStart + 1)
if ($applyStart -lt 0 -or $applyEnd -le $applyStart) {
    throw 'apply_state was not found in source_affinityctl'
}
$applyStateBody = $affinityController.Substring($applyStart, $applyEnd - $applyStart)
$snapshotSave = $applyStateBody.IndexOf('save_state(path')
$backgroundMove = $applyStateBody.LastIndexOf('write_pid(BACKGROUND_CPUSET_PROCS, pid)')
$affinityBind = $applyStateBody.LastIndexOf('sched_setaffinity(records[i].tid')
if ($snapshotSave -lt 0 -or $backgroundMove -lt 0 -or $affinityBind -lt 0 -or
    $snapshotSave -gt $backgroundMove -or $backgroundMove -gt $affinityBind) {
    throw 'Source transaction order must be snapshot, background cgroup, then affinity'
}

$systemUiController = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\systemui_threadctl.c') -Raw
if ($systemUiController -notmatch 'HeapTaskDaemon' -or
    $systemUiController -notmatch 'wmshell\.main' -or
    $systemUiController -notmatch 'restore_policy') {
    throw 'SystemUI controller must separate and restore render and maintenance threads'
}

Write-Output 'source_layout=passed'
