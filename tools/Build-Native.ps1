param(
    [string]$AndroidSdk
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $root 'module-src\bin'

$sdkCandidates = @(
    $AndroidSdk,
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME,
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

$compiler = $null
foreach ($sdk in $sdkCandidates) {
    $ndkRoot = Join-Path $sdk 'ndk'
    if (-not (Test-Path -LiteralPath $ndkRoot)) {
        continue
    }
    $ndkDirectories = Get-ChildItem -LiteralPath $ndkRoot -Directory
    $preferredNdk = $ndkDirectories | Where-Object Name -EQ '28.2.13676358' | Select-Object -First 1
    $orderedNdkDirectories = @()
    if ($preferredNdk) {
        $orderedNdkDirectories += $preferredNdk
    }
    $orderedNdkDirectories += @($ndkDirectories |
        Where-Object { -not $preferredNdk -or $_.FullName -ne $preferredNdk.FullName } |
        Sort-Object { [version]$_.Name } -Descending)
    $compiler = $orderedNdkDirectories |
        ForEach-Object {
            Join-Path $_.FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android29-clang.cmd'
        } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ($compiler) {
        break
    }
}
if (-not $compiler) {
    throw 'No Windows Android NDK arm64 compiler was found. Pass -AndroidSdk or set ANDROID_SDK_ROOT.'
}
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
foreach ($target in @(
    @{ Sources = @('launcher_logwatch.c', 'transition_policy.c', 'proc_control.c'); Output = 'launcher-logwatch'; Libraries = @('-ldl', '-pthread') },
    @{ Sources = @('source_guard.c'); Output = 'source-guard'; Libraries = @() }
)) {
    $sources = @($target.Sources | ForEach-Object { Join-Path $root (Join-Path 'native' $_) })
    $output = Join-Path $outputDirectory $target.Output
    & $compiler -std=gnu17 -Wall -Wextra -Werror -fPIE -pie -Oz `
        '-Wl,--strip-all' @($target.Libraries) -o $output @sources
    if ($LASTEXITCODE -ne 0) {
        throw "NDK compiler failed to build $($target.Output): $LASTEXITCODE"
    }
    Get-Item -LiteralPath $output
    Get-FileHash -LiteralPath $output -Algorithm SHA256
}
