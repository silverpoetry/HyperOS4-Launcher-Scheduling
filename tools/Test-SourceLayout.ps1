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
    'bin\launcher-logwatch', 'bin\source-guard',
    'lib\config.sh', 'lib\runtime.sh', 'lib\topology.sh',
    'lib\source-guard.sh', 'lib\process-policy.sh', 'lib\coordinator.sh',
    'lib\webui-status.sh', 'lib\webui-control.sh',
    'webroot\index.html', 'webroot\js\main.js'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $moduleRoot $relative) -PathType Leaf)) {
        throw "Missing required module source: $relative"
    }
}

$legacy = @(
    'lib\events.sh', 'lib\state-machine.sh', 'lib\launcher-policy.sh',
    'lib\systemui-policy.sh', 'lib\frequency-policy.sh',
    'bin\launcher-threadctl', 'bin\systemui-threadctl',
    'thread-policy.sh', 'webroot\app.js', 'webroot\styles.css'
)
foreach ($relative in $legacy) {
    if (Test-Path -LiteralPath (Join-Path $moduleRoot $relative)) {
        throw "Legacy transition path must not return: $relative"
    }
}

$version = (Get-Content -LiteralPath (Join-Path $RepositoryRoot 'VERSION') -Raw).Trim()
$module = Get-Content -LiteralPath (Join-Path $moduleRoot 'module.prop') -Raw
$moduleVersion = ([regex]::Match($module, '(?m)^version=(.+)$')).Groups[1].Value
if ($moduleVersion -ne $version) {
    throw "VERSION ($version) and module.prop ($moduleVersion) disagree"
}
if ($module -notmatch '(?m)^author=silverpoetry$') {
    throw 'Module author metadata must use the repository author name'
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

$watcher = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\launcher_logwatch.c') -Raw
foreach ($needle in @(
    'struct coordinator', 'transition_id = monotonic_ns()',
    'send_guard("enter %llu"', 'send_guard("handoff %llu %s"',
    'send_guard("complete %llu %u"', 'policy_timer_main',
    'transition_policy_reassert', 'visual_quiet_ms', 'reassert_ms',
    'list_alloc(ANDROID_LOG_RDONLY, 1, coordinator->launcher_pid)',
    'pthread_mutex_t event_lock', 'sigwait(&termination_signals',
    'target_unsuppressed', 'launcher-resumed-intermediate',
    'proc_move_controller(getpid(), "/dev/cpuset", "/top-app")',
    'uint64_t mask = config->masks[5]'
)) {
    if (-not $watcher.Contains($needle)) {
        throw "Native coordinator invariant is missing: $needle"
    }
}
if ($watcher -match 'SOURCE_APP_FILE|source-app\.native|yield_source_native|system\(|popen\(|fork\(|ANDROID_LOG_NONBLOCK') {
    throw 'Coordinator hot path must not read source files or launch subprocesses'
}

$guard = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\source_guard.c') -Raw
foreach ($needle in @(
    'accepted_transition_id', 'completion_timer_fd', 'timerfd_create',
    'begin_transition', 'adopt_package', 'replace_current',
    'cgroup_attach_task', 'reassert_source(pid_t tid)', 'SOCK_DGRAM',
    'unsigned long long starttime', 'restore_nice(top_app)',
    'release_source(state.pid, 0, 0)', 'capture_known_baseline()',
    'if (!state.active) capture_known_baseline();', 'restore_affinity()',
    'proc_set_affinity(record->tid, record->original_affinity)'
)) {
    if (-not $guard.Contains($needle)) {
        throw "Source guard invariant is missing: $needle"
    }
}
if ($guard -match 'source_affinityctl|SOURCE_AFFINITY|SAF[1-4]') {
    throw 'Legacy source-affinity transactions must not be packaged'
}
$reassertStart = $guard.IndexOf('static void reassert_source(pid_t tid)')
$reassertEnd = $guard.IndexOf('static int release_source(', $reassertStart)
if ($reassertStart -lt 0 -or $reassertEnd -le $reassertStart) {
    throw 'Source guard reassert function boundary is missing'
}
$reassertBody = $guard.Substring($reassertStart, $reassertEnd - $reassertStart)
if ($reassertBody -match 'refresh_tasks\(\)|apply_nice\(\)') {
    throw 'Cgroup overwrite correction must remain constant-time'
}

$policy = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'native\transition_policy.c') -Raw
foreach ($needle in @(
    'android.anim', 'android.display', 'TaskSnapshot',
    'wmshell.main', 'LAUNCHER_RASTER', 'transition_policy_reassert',
    'proc_get_affinity(record->tid) != record->target_mask'
)) {
    if (-not $policy.Contains($needle)) {
        throw "Transition policy invariant is missing: $needle"
    }
}

$service = Get-Content -LiteralPath (Join-Path $moduleRoot 'service.sh') -Raw
if ($service -notmatch 'run_transition_coordinator' -or
    $service -match 'handle_launcher_event|trigger_transition_thread_policies|schedule_app_completion_timeout') {
    throw 'Service must delegate transition work to the native coordinator'
}

$configuration = Get-Content -LiteralPath (Join-Path $moduleRoot 'lib\config.sh') -Raw
foreach ($default in @(
    'write_default "$THREAD_RASTER_PLACEMENT_FILE" 4',
    'write_default "$SYSTEMUI_CRITICAL_PLACEMENT_FILE" 2',
    'write_default "$SYSTEM_SERVER_CRITICAL_PLACEMENT_FILE" 2',
    'write_default "$SOURCE_PLACEMENT_FILE" 7',
    'write_default "$SOURCE_NICE_SUPPRESSION_FILE" 40',
    'write_default "$VISUAL_QUIET_TIMEOUT_FILE" 450',
    'write_default "$POLICY_REASSERT_INTERVAL_FILE" 20'
)) {
    if (-not $configuration.Contains($default)) {
        throw "Configuration default is missing: $default"
    }
}

$control = Get-Content -LiteralPath (Join-Path $moduleRoot 'lib\webui-control.sh') -Raw
$model = Get-Content -LiteralPath (Join-Path $moduleRoot 'webroot\js\model.js') -Raw
if ($control -notmatch 'launcher_placement\) valid_number "\$value" 1 8' -or
    $control -notmatch 'system_server_critical_placement\) valid_number "\$value" 1 8' -or
    $model -notmatch '\[8, "效率核（预留一核）"') {
    throw 'All placement fields must use the shared eight-set topology enum'
}

$nativeBuilder = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'tools\Build-Native.ps1') -Raw
if ($nativeBuilder -notmatch 'transition_policy\.c' -or
    $nativeBuilder -notmatch 'proc_control\.c' -or
    $nativeBuilder -notmatch '-Wall -Wextra -Werror' -or
    $nativeBuilder -match 'launcher_threadctl|systemui_threadctl') {
    throw 'Native build must contain only the coordinator and source guard architecture'
}

Write-Output 'source_layout=passed'
