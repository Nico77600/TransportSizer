#Requires -Version 5.1
<#
    Transport Sizer - runs the Pester tests (Pester 6.1 or later) with the PowerShell that runs this script:
    Windows PowerShell 5.1 or PowerShell 7. Pester is looked up in the module paths of both editions.
    Result: artifacts\pester-results-<edition>.xml.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pester = Get-Module Pester -ListAvailable | Where-Object { $_.Version -ge [version]'6.1.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    $candidates = @((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester'), (Join-Path $env:ProgramFiles 'PowerShell\Modules\Pester'))
    $pester = Get-ChildItem -Path $candidates -Filter 'Pester.psd1' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Version = [version]$_.Directory.Name } } |
        Where-Object { $_.Version -ge [version]'6.1.0' } | Sort-Object Version -Descending | Select-Object -First 1
}
if (-not $pester) { throw 'Pester 6.1 ou plus récent est introuvable (Install-Module Pester -MinimumVersion 6.1.0 -Scope CurrentUser).' }
Import-Module $pester.Path -Force

$edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'windowspowershell' }
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'tests\TransportSizer.Tests.ps1'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
$configuration.TestDrive.Enabled = $false
$configuration.TestRegistry.Enabled = $false
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $PSScriptRoot "artifacts\pester-results-$edition.xml"
[void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'artifacts'))
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
    throw "Tests en échec : $($result.FailedCount)."
}
