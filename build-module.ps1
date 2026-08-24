param(
    [string]$AndroidSdk
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'module-src'
$srcFull = [IO.Path]::GetFullPath($src).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
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
& $nativeBuilder -AndroidSdk $AndroidSdk | Out-Null

New-Item -ItemType Directory -Path $dist -Force | Out-Null
Remove-Item -LiteralPath $zip, "$zip.sha256" -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $src -File -Recurse | Sort-Object FullName) {
        $fileFull = [IO.Path]::GetFullPath($file.FullName)
        if (-not $fileFull.StartsWith($srcFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to package a file outside module-src: $fileFull"
        }
        $relative = $fileFull.Substring($srcFull.Length).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $file.FullName,
            $relative,
            [IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$zip.sha256" -Value "$hash  $zipName" -Encoding ascii

Get-Item -LiteralPath $zip
Get-Content -LiteralPath "$zip.sha256"
