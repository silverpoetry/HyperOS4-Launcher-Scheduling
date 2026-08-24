param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $RepositoryRoot 'module-src'
$buildScript = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'build-module.ps1') -Raw
if ($buildScript -match 'Compress-Archive' -or -not $buildScript.Contains(".Replace('\', '/')")) {
    throw 'Release ZIP entries must use Android-compatible forward-slash paths'
}

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
if ((Get-Content -LiteralPath (Join-Path $moduleRoot 'module.prop') -Raw) -notmatch '(?m)^author=silverpoetry$') {
    throw 'Module author metadata must use the repository author name without a transport prefix'
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
if ($yieldBody -notmatch 'run_affinity_apply\("yield", result.pid, result.uid\)') {
    throw 'Native source yield must invoke the atomic affinity controller transaction'
}
if ($logWatcher -notmatch 'run_affinity_apply\("yield"') {
    throw 'Native source yield must use the snapshot-before-cgroup operation'
}
if ($logWatcher -notmatch 'Start proc ' -or
    $logWatcher -notmatch "cursor\[1\] != 'u'" -or
    $logWatcher -notmatch "\*end != 'a'" -or
    $logWatcher -notmatch 'run_affinity_apply\("replace-yield"' -or
    $logWatcher -notmatch 'access\(SOURCE_AFFINITY_STATE, F_OK\)' -or
    $logWatcher -notmatch 'logger_open\(list, LOG_ID_SYSTEM\)') {
    throw 'Native watcher must atomically replace a restarted source while its yield transaction is active'
}
if ($logWatcher -notmatch 'finish_remote_transition to_home = false') {
    throw 'Native watcher must forward same-app return completion'
}

$events = Get-Content -LiteralPath (Join-Path $moduleRoot 'lib\events.sh') -Raw
if ($events -notmatch 'NativeSourceSpawn') {
    throw 'State log must retain native restarted-source transaction results'
}
if ($events -notmatch 'finish_remote_transition to_home = false') {
    throw 'State machine must restore the source on same-app return completion'
}

$configuration = Get-Content -LiteralPath (Join-Path $moduleRoot 'lib\config.sh') -Raw
if ($configuration -notmatch 'write_default "\$THREAD_RASTER_PLACEMENT_FILE" 4') {
    throw 'Launcher Raster must default to the topology-derived prime mask'
}

$processPolicy = Get-Content -LiteralPath (Join-Path $moduleRoot 'lib\process-policy.sh') -Raw
if ($processPolicy -notmatch 'cache_pid_record "\$pid" "\$destination" "\$package"' -or
    $processPolicy -notmatch 'cache_pid_record "\$pid" "\$SOURCE_FILE" "\$resumed"') {
    throw 'Source records must retain the full Android package identity'
}
if ($configuration -notmatch 'write_default "\$SYSTEMUI_CRITICAL_PLACEMENT_FILE" 2') {
    throw 'SystemUI critical threads must default to the non-prime performance mask'
}
if ($configuration -notmatch 'write_default "\$SOURCE_PLACEMENT_FILE" 7') {
    throw 'Source placement must default to Android system background CPUs'
}

$runtime = Get-Content -LiteralPath (Join-Path $moduleRoot 'lib\runtime.sh') -Raw
foreach ($requiredRuntimeFunction in @(
    'claim_service_instance', 'acquire_restart_lock',
    'is_module_service_pid', 'find_active_service_pid', 'release_restart_lock',
    'promote_controller_process'
)) {
    if ($runtime -notmatch "(?m)^$requiredRuntimeFunction\(\)") {
        throw "Missing service lifecycle function: $requiredRuntimeFunction"
    }
}
if ($runtime -notmatch 'while \[ "\$attempt" -lt 50 \]' -or
    $runtime -notmatch 'is_module_service_pid "\$daemon_pid"') {
    throw 'Service restart must wait for and validate the new daemon PID'
}

$affinityController = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\source_affinityctl.c') -Raw
if ($affinityController -notmatch 'read_source_target_mask' -or
    $affinityController -notmatch 'SOURCE_PLACEMENT_FILE' -or
    $affinityController -notmatch 'selected = placement == 5 \? little_mask : background_mask') {
    throw 'Source placement must distinguish the efficiency and system background sets'
}
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
