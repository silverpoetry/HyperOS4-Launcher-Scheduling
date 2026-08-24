param(
    [Parameter(Mandatory)] [string]$Adb,
    [Parameter(Mandatory)] [string]$Serial,
    [Parameter(Mandatory)] [string]$Zip,
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw "ADB was not found: $Adb" }
if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "Module ZIP was not found: $Zip" }

$state = (& $Adb -s $Serial get-state 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $state -ne 'device') { throw "ADB device is not ready: $Serial" }

$remote = "/data/local/tmp/$([IO.Path]::GetFileName($Zip))"
& $Adb -s $Serial push $Zip $remote
if ($LASTEXITCODE -ne 0) { throw "Failed to push the module to $Serial" }

& $Adb -s $Serial shell su -c "ksud module install $remote"
if ($LASTEXITCODE -ne 0) { throw "KernelSU failed to install the module on $Serial" }

& $Adb -s $Serial shell rm -f $remote
if ($Reboot) { & $Adb -s $Serial reboot }
