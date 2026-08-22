$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'module-src'
$dist = Join-Path $root 'dist'
$zipName = 'Shennong-Host-ADB-TCP-5555-v1.zip'
$zip = Join-Path $dist $zipName

if (Test-Path -LiteralPath $dist) {
    Remove-Item -LiteralPath $dist -Recurse -Force
}
New-Item -ItemType Directory -Path $dist | Out-Null

Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zip.sha256" -Value "$hash  $zipName" -Encoding ascii

Get-Item -LiteralPath $zip
Get-Content -LiteralPath "$zip.sha256"
