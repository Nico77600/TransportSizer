#Requires -Version 5.1
<#
.SYNOPSIS
    Packages Transport Sizer from a reviewed source directory.
.DESCRIPTION
    Uses an explicit runtime allow-list. Never includes Git history, test results,
    generated reports or local calibration captures. Existing destinations are not replaced.
#>
[CmdletBinding()]
param([string]$Destination, [string]$ArchivePath)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'TransportSizer.psd1')).ModuleVersion
$name = "TransportSizer-$version"
if (-not $Destination) { $Destination = Join-Path (Split-Path $root -Parent) "package\$name" }
$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination).TrimEnd('\')
if (-not $ArchivePath) { $ArchivePath = "$Destination.zip" }
$ArchivePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchivePath)
$prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (($Destination + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $ArchivePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The package and ZIP must be outside the source directory.'
}
if (Test-Path -LiteralPath $Destination) { throw "Package destination already exists: $Destination" }
if (Test-Path -LiteralPath $ArchivePath) { throw "Archive already exists: $ArchivePath" }

$files = [Collections.Generic.List[string]]::new()
foreach ($file in 'Invoke-TransportSizer.ps1', 'TransportSizer.psd1', 'TransportSizer.psm1', 'README.md', 'CHANGELOG.md', 'LICENSE', 'SECURITY.md') { $files.Add($file) }
foreach ($directory in 'src', 'templates', 'data', 'calibration', 'examples', 'docs') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Recurse -File) {
        $relative = $file.FullName.Substring($root.Length + 1)
        if ($directory -eq 'examples' -and $file.Name -like 'Calibration-*') { continue }
        $files.Add($relative)
    }
}
foreach ($relative in $files) {
    $source = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required runtime file missing: $relative" }
}
[void][IO.Directory]::CreateDirectory($Destination)
foreach ($relative in $files) {
    $target = Join-Path $Destination $relative
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
    if ((Get-FileHash -LiteralPath $target).Hash -cne (Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash) { throw "Package copy mismatch: $relative" }
}
foreach ($forbidden in '.git', 'reports', 'artifacts', 'tests') {
    if (Test-Path -LiteralPath (Join-Path $Destination $forbidden)) { throw "Non-runtime content in package: $forbidden" }
}
[void][IO.Directory]::CreateDirectory((Split-Path $ArchivePath -Parent))
Compress-Archive -LiteralPath $Destination -DestinationPath $ArchivePath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{ Version = $version; Folder = $Destination; Archive = $ArchivePath; Files = $files.Count; Sha256 = $hash }
