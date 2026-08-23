$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'module-src'
$collectionRoot = Split-Path -Parent $root
$dist = Join-Path $collectionRoot 'output'
$nativeBuilder = Join-Path $root 'tools\Build-Native.ps1'
$sourceValidator = Join-Path $root 'tools\Test-SourceLayout.ps1'
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$zipName = "HyperOS4-Launcher-Scheduling-v$version.zip"
$zip = Join-Path $dist $zipName
$collectionFull = [IO.Path]::GetFullPath($collectionRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$distFull = [IO.Path]::GetFullPath($dist)
if (-not $distFull.StartsWith("$collectionFull$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to replace output outside the Magisk collection: $distFull"
}

& $sourceValidator -RepositoryRoot $root | Out-Null
& $nativeBuilder | Out-Null

New-Item -ItemType Directory -Path $dist -Force | Out-Null
Remove-Item -LiteralPath $zip, "$zip.sha256" -Force -ErrorAction SilentlyContinue

Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zip.sha256" -Value "$hash  $zipName" -Encoding ascii

Get-Item -LiteralPath $zip
Get-Content -LiteralPath "$zip.sha256"
