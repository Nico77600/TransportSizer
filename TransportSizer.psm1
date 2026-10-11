<#
.SYNOPSIS
    Transport Sizer - PowerShell module.

.DESCRIPTION
    Sizing of the Exchange transport servers (Edge Transport, and Mailbox servers for their transport
    part, with or without mailboxes) without Excel. Loads the parts of the tool:

        src\Sizer.Scenario.ps1   scenarios and calibration profiles (defaults, checks, JSON)
        src\Sizer.Engine.ps1     sizing engine: every value with its formula, computation and origin
        src\Sizer.LogReport.ps1  traffic measured by Exchange Log Report (detailed report)
        src\Sizer.Report.ps1     HTML report, JSON result, console summary
        src\Sizer.Gui.ps1        WPF window (Fluent theme of Windows 11 with .NET 9 and later)

    Runs with Windows PowerShell 5.1 (Windows Server, nothing to install) and PowerShell 7.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.10.0
    History : see CHANGELOG.md
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.10.0'
$script:ToolRoot = $PSScriptRoot

foreach ($part in 'Scenario', 'Disk', 'Engine', 'LogReport', 'Report', 'Gui') {
    . (Join-Path $PSScriptRoot "src\Sizer.$part.ps1")
}

Export-ModuleMember -Function @(
    'Get-TsDefaultScenario', 'ConvertTo-TsScenario', 'Import-TsScenario', 'Export-TsScenario'
    'ConvertTo-TsCalibration', 'Import-TsCalibration', 'Get-TsReference', 'Get-TsReferenceProfile', 'Get-TsProcessorCatalog', 'Get-TsDiskCatalog'
    'Invoke-TsSizing', 'Get-TsMicrosoftQueueEstimate', 'Format-TsNumber'
    'Import-TsLogReport', 'Update-TsScenarioFromLogReport', 'Format-TsLogReportSummary'
    'Export-TsReport', 'Write-TsResultSummary'
    'Show-TsSizerGui', 'New-TsSizerForm'
)
