@{
    RootModule           = 'TransportSizer.psm1'
    ModuleVersion        = '1.10.0'
    GUID                 = '6f1d9a3e-2c4b-4f7e-9b8a-5d3e1c7a9f20'
    Author               = 'Nicolas Fabert'
    CompanyName          = 'Nicolas Fabert'
    Copyright            = '(c) 2026 Nicolas Fabert. MIT License.'
    Description          = 'Sizing of Exchange transport servers (Edge Transport, Mailbox transport) from measured calibration profiles: WPF window, HTML report explaining every number, no Excel.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-TsDefaultScenario', 'ConvertTo-TsScenario', 'Import-TsScenario', 'Export-TsScenario'
        'ConvertTo-TsCalibration', 'Import-TsCalibration', 'Get-TsReference', 'Get-TsReferenceProfile', 'Get-TsProcessorCatalog', 'Get-TsDiskCatalog'
        'Invoke-TsSizing', 'Get-TsMicrosoftQueueEstimate', 'Format-TsNumber'
        'Import-TsLogReport', 'Update-TsScenarioFromLogReport', 'Format-TsLogReportSummary'
        'Export-TsReport', 'Write-TsResultSummary'
        'Show-TsSizerGui', 'New-TsSizerForm'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Exchange', 'EdgeTransport', 'Transport', 'Sizing', 'WPF')
            ReleaseNotes = 'See CHANGELOG.md'
        }
    }
}
