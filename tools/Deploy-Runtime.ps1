param(
    [string]$Adb = 'E:\Develop\Android\Sdk\platform-tools\adb.exe',
    [string]$Serial = '192.168.3.2:5555',
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$moduleSource = if ($SourceRoot) { $SourceRoot } else { Join-Path $root 'module-src' }
$stage = '/data/local/tmp/hyperos4-launcher-scheduling-stage'

& $Adb -s $Serial shell su -c "rm -rf $stage"
& $Adb -s $Serial shell su -c "mkdir -p $stage/lib $stage/bin"
& $Adb -s $Serial push (Join-Path $moduleSource 'module.prop') "$stage/module.prop"
& $Adb -s $Serial push (Join-Path $moduleSource 'service.sh') "$stage/service.sh"
& $Adb -s $Serial push (Join-Path $moduleSource 'action.sh') "$stage/action.sh"
& $Adb -s $Serial push (Join-Path $moduleSource 'uninstall.sh') "$stage/uninstall.sh"
& $Adb -s $Serial push (Join-Path $moduleSource 'webui.sh') "$stage/webui.sh"
& $Adb -s $Serial push (Join-Path $moduleSource 'lib') "$stage"
& $Adb -s $Serial push (Join-Path $moduleSource 'webroot') "$stage"
& $Adb -s $Serial push (Join-Path $moduleSource 'bin\launcher-logwatch') "$stage/bin/launcher-logwatch"
& $Adb -s $Serial push (Join-Path $moduleSource 'bin\launcher-threadctl') "$stage/bin/launcher-threadctl"
& $Adb -s $Serial push (Join-Path $moduleSource 'bin\source-affinityctl') "$stage/bin/source-affinityctl"
& $Adb -s $Serial push (Join-Path $PSScriptRoot 'deploy-runtime.sh') "$stage/deploy-runtime.sh"
& $Adb -s $Serial shell su -c "chmod 0755 $stage/bin/launcher-logwatch $stage/bin/launcher-threadctl $stage/bin/source-affinityctl $stage/deploy-runtime.sh"
& $Adb -s $Serial shell su -c "$stage/deploy-runtime.sh"
