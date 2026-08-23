param(
    [string]$Adb = 'E:\Develop\Android\Sdk\platform-tools\adb.exe',
    [string]$Serial = '192.168.3.2:5555',
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$moduleSource = if ($SourceRoot) { $SourceRoot } else { Join-Path $root 'module-src' }
$stage = '/data/local/tmp/hyperos4-launcher-scheduling-stage'

& $Adb -s $Serial shell su -c "mkdir -p $stage"
& $Adb -s $Serial push (Join-Path $moduleSource 'module.prop') "$stage/module.prop"
& $Adb -s $Serial push (Join-Path $moduleSource 'service.sh') "$stage/service.sh"
& $Adb -s $Serial push (Join-Path $moduleSource 'thread-policy.sh') "$stage/thread-policy.sh"
& $Adb -s $Serial push (Join-Path $moduleSource 'bin\launcher-logwatch') "$stage/launcher-logwatch"
& $Adb -s $Serial push (Join-Path $moduleSource 'bin\launcher-threadctl') "$stage/launcher-threadctl"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'deploy-runtime.sh') "$stage/deploy-runtime.sh"
& $Adb -s $Serial shell su -c "chmod 0755 $stage/launcher-logwatch $stage/launcher-threadctl $stage/deploy-runtime.sh"
& $Adb -s $Serial shell su -c "$stage/deploy-runtime.sh"
