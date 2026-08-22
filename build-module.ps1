$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'module-src'
$dist = Join-Path $root 'dist'
$nativeBuilder = Join-Path $root 'tools\Build-Native.ps1'
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$zipName = "HyperOS4-Launcher-Scheduling-v$version.zip"
$zip = Join-Path $dist $zipName
$rootFull = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar)
$distFull = [IO.Path]::GetFullPath($dist)
if (-not $distFull.StartsWith("$rootFull$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to replace a dist directory outside the repository: $distFull"
}

& $nativeBuilder | Out-Null

if (Test-Path -LiteralPath $dist) {
    Remove-Item -LiteralPath $dist -Recurse -Force
}
New-Item -ItemType Directory -Path $dist | Out-Null

Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zip.sha256" -Value "$hash  $zipName" -Encoding ascii

Get-Item -LiteralPath $zip
Get-Content -LiteralPath "$zip.sha256"
