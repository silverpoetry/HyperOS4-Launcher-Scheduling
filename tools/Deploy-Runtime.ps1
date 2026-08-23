param(
    [string]$Adb = 'E:\Develop\Android\Sdk\platform-tools\adb.exe',
    [string]$Serial = '192.168.3.2:5555'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stage = '/data/local/tmp/hyperos4-launcher-scheduling-stage'

& $Adb -s $Serial shell su -c "mkdir -p $stage"
& $Adb -s $Serial push (Join-Path $root 'module-src\module.prop') "$stage/module.prop"
& $Adb -s $Serial push (Join-Path $root 'module-src\service.sh') "$stage/service.sh"
& $Adb -s $Serial push (Join-Path $root 'module-src\thread-policy.sh') "$stage/thread-policy.sh"
& $Adb -s $Serial push (Join-Path $root 'module-src\bin\launcher-logwatch') "$stage/launcher-logwatch"
& $Adb -s $Serial push (Join-Path $root 'module-src\bin\launcher-threadctl') "$stage/launcher-threadctl"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'deploy-runtime.sh') "$stage/deploy-runtime.sh"
& $Adb -s $Serial shell su -c "chmod 0755 $stage/launcher-logwatch $stage/launcher-threadctl $stage/deploy-runtime.sh"
& $Adb -s $Serial shell su -c "$stage/deploy-runtime.sh"
