param(
    [string]$Adb = 'adb',
    [string]$Serial = $env:ANDROID_SERIAL,
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Serial)) { throw 'Pass -Serial or set ANDROID_SERIAL.' }
$root = Split-Path -Parent $PSScriptRoot
$moduleSource = if ($SourceRoot) { $SourceRoot } else { Join-Path $root 'module-src' }
$stage = '/data/local/tmp/hyperos4-launcher-scheduling-stage'
$moduleDirectory = '/data/adb/modules/hyperos4_recents_source_app_yield'

function Invoke-Adb {
    param([string[]]$Arguments)
    & $Adb @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "ADB failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

Invoke-Adb @('-s', $Serial, 'shell', 'su', '-c', "rm -rf $stage")
Invoke-Adb @('-s', $Serial, 'shell', 'su', '-c', "mkdir -p $stage/lib $stage/bin")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'module.prop'), "$stage/module.prop")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'service.sh'), "$stage/service.sh")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'action.sh'), "$stage/action.sh")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'uninstall.sh'), "$stage/uninstall.sh")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'webui.sh'), "$stage/webui.sh")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'lib'), $stage)
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'webroot'), $stage)
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'bin\launcher-logwatch'), "$stage/bin/launcher-logwatch")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'bin\launcher-threadctl'), "$stage/bin/launcher-threadctl")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'bin\source-guard'), "$stage/bin/source-guard")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $moduleSource 'bin\systemui-threadctl'), "$stage/bin/systemui-threadctl")
Invoke-Adb @('-s', $Serial, 'push', (Join-Path $PSScriptRoot 'deploy-runtime.sh'), "$stage/deploy-runtime.sh")
Invoke-Adb @('-s', $Serial, 'shell', 'su', '-c',
    "chmod 0755 $stage/bin/launcher-logwatch $stage/bin/launcher-threadctl $stage/bin/source-guard $stage/bin/systemui-threadctl $stage/deploy-runtime.sh")
Invoke-Adb @('-s', $Serial, 'shell', 'su', '-c', "$stage/deploy-runtime.sh")
Invoke-Adb @('-s', $Serial, 'shell', 'su', '-c',
    "setsid -d /system/bin/sh $moduleDirectory/service.sh </dev/null >/dev/null 2>&1 &")

$ready = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $daemonPid = & $Adb -s $Serial shell su -c "test -S /dev/.hyperos4-launcher-scheduling/source-guard.sock && cat $moduleDirectory/daemon.pid" 2>$null
    if ($LASTEXITCODE -eq 0 -and $daemonPid) {
        $ready = $true
        break
    }
    Start-Sleep -Milliseconds 250
}
if (-not $ready) { throw 'The scheduling service did not become ready.' }
"runtime_ready=1 daemon_pid=$daemonPid"
