param(
    [string]$ResultsRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'test-results')
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = (Resolve-Path -LiteralPath $ResultsRoot).Path
$prefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
$targets = @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Filter 'validated-recents-*')
$bytes = 0L

foreach ($target in $targets) {
    if (-not $target.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Target escaped the results directory: $($target.FullName)"
    }
    $measurement = Get-ChildItem -LiteralPath $target.FullName -File -Recurse |
        Measure-Object -Property Length -Sum
    if ($measurement.Sum) { $bytes += $measurement.Sum }
}

foreach ($target in $targets) {
    Remove-Item -LiteralPath $target.FullName -Recurse -Force
}

[pscustomobject]@{
    RemovedDirectories = $targets.Count
    RemovedBytes = $bytes
    RemainingDirectories = @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Filter 'validated-recents-*').Count
}
