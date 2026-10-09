<#
.SYNOPSIS
    Transport Sizer - sizing of Exchange transport servers (Edge Transport, Mailbox transport) without Excel.

.DESCRIPTION
    Without parameter: opens the window (WPF, Fluent theme of Windows 11 with PowerShell 7.5 and later).
    With -Scenario: sizes the scenario, prints the summary and writes the HTML reports (technical report and customer summary).

    The report explains every number: formula, computation with the values, origin (input, Microsoft,
    lab, assumption, calibration). CPU, memory and IOPS come only from a calibration profile measured on
    a reference server (calibration\Measure-TransportLoad.ps1).

    Runs with Windows PowerShell 5.1 (nothing to install) and PowerShell 7.

.PARAMETER Scenario
    Scenario file (JSON), written by the window (Enregistrer) or taken from examples.

.PARAMETER Calibration
    Calibration profile (JSON) used instead of the one of the scenario.

.PARAMETER LogReport
    Detailed report of Exchange Log Report (its folder, its <prefix>-Messages.csv file, or the folder of the
    reports): its traffic replaces the flows of the scenario (messages per day, sizes, peak hour, messages per
    SMTP session, TLS). Without -Scenario, the default scenario of the role of the report is used.

.PARAMETER LogReportDay
    Average (default): average day of the period of the report. Busiest: busiest complete day.

.PARAMETER SaveScenario
    Writes the scenario sized (JSON), for instance after -LogReport, to open it again in the window.

.PARAMETER OutputPath
    Folder of the reports. Default: reports under the tool folder.

.PARAMETER Gui
    Opens the window, with the scenario when one is given.

.PARAMETER Open
    Opens the customer summary and the technical report in the browser (command line).

.PARAMETER PassThru
    Returns the result object of the sizing (command line).

.EXAMPLE
    .\Invoke-TransportSizer.ps1
    Opens the window.

.EXAMPLE
    .\Invoke-TransportSizer.ps1 -Scenario .\examples\Edge-Internet.json -Calibration .\examples\Calibration-Reference-Edge.json -Open
    Sizes the scenario with the lab calibration and opens the report.

.EXAMPLE
    .\Invoke-TransportSizer.ps1 -LogReport D:\ExchangeLogReport\reports -Calibration .\examples\Calibration-REF-EDGE-factors-lab.json -SaveScenario .\Edge-measured.json
    Sizes the traffic measured by the latest detailed Exchange Log Report and saves the scenario.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.10.0
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Scenario,
    [string]$Calibration,
    [string]$LogReport,
    [ValidateSet('Average', 'Busiest')][string]$LogReportDay = 'Average',
    [string]$SaveScenario,
    [string]$OutputPath,
    [switch]$Gui,
    [switch]$Open,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TransportSizer.psd1') -Force

$loaded = $null
if ($Scenario) { $loaded = Import-TsScenario -Path $Scenario }
if ($LogReport) {
    $import = Import-TsLogReport -Path $LogReport -Day $LogReportDay
    if (-not $loaded) { $loaded = Get-TsDefaultScenario -Role $import.Role }
    Write-Host ''
    foreach ($line in Format-TsLogReportSummary -LogReport $import -ScenarioRole $loaded.Role) {
        Write-Host ('  ' + $line) -ForegroundColor $(if ($line.StartsWith('Attention')) { 'Yellow' } else { 'Gray' })
    }
    $loaded = Update-TsScenarioFromLogReport -Scenario $loaded -LogReport $import -WarningAction SilentlyContinue
}
if ($Calibration) {
    if (-not $loaded) { $loaded = Get-TsDefaultScenario -Role Edge }
    $loaded.Calibration = Import-TsCalibration -Path $Calibration
    $loaded.CalibrationPath = (Resolve-Path -LiteralPath $Calibration).ProviderPath
}

if ($SaveScenario -and $loaded) {
    $saved = Export-TsScenario -Scenario $loaded -Path $SaveScenario
    Write-Host ('  Scénario : {0}' -f $saved.FullName) -ForegroundColor Green
}

if ($Gui -or (-not $Scenario -and -not $LogReport)) {
    $guiArgs = @{}
    if ($loaded) { $guiArgs.Scenario = $loaded }
    if ($OutputPath) { $guiArgs.OutputPath = $OutputPath }
    Show-TsSizerGui @guiArgs
    return
}

$result = Invoke-TsSizing -Scenario $loaded
Write-TsResultSummary -Result $result
if ($result.Valid) {
    $reportArgs = @{ Result = $result; Open = $Open }
    if ($OutputPath) { $reportArgs.OutputPath = $OutputPath }
    $files = Export-TsReport @reportArgs
    Write-Host ('  Rapport technique : {0}' -f $files.Html) -ForegroundColor Green
    Write-Host ('  Synthèse client   : {0}' -f $files.Synthesis) -ForegroundColor Green
    Write-Host ''
}
if ($PassThru) { return $result }
if (-not $result.Valid) { exit 1 }
