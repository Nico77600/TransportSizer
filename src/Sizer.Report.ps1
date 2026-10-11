<#
.SYNOPSIS
    Transport Sizer - report files and console summary (dot-sourced by TransportSizer.psm1).

.DESCRIPTION
    One folder per report, TransportSizer_<scenario>_<yyyyMMdd-HHmmss>, with:
      TransportSizer.html            self-contained technical report (templates\Report.template.html):
                                     target configuration, composition of the queue and of the system
                                     volume, every value with its formula, computation and origin
      TransportSizer-Synthese.html   visual summary for the customer (templates\Report-Client.template.html):
                                     architecture, target server, capacity, day profile, network, incident
      TransportSizer-Result.json     the whole result, for scripts and comparisons
      TransportSizer-Scenario.json   the scenario, calibration embedded: reopening it gives the same report

.NOTES
    Author  : Nicolas Fabert
    Version : 1.10.0
#>

function ConvertTo-TsEmbeddedJson {
    <# JSON safe inside a <script type="application/json"> block. #>
    param([AllowNull()][object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 14 -Compress
    if ([string]::IsNullOrEmpty($json)) { $json = 'null' }
    return $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
}

function Get-TsSafeName {
    param([string]$Name)
    $safe = ($Name -replace '[^\p{L}\p{Nd}\-_. ]', '').Trim() -replace '\s+', '-' -replace '-{2,}', '-'
    if (-not $safe) { $safe = 'Scenario' }
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    return $safe
}

function Get-TsResultData {
    <# The result without the lookup table of values (already in the sections). #>
    param([Parameter(Mandatory = $true)][object]$Result)
    $Result | Select-Object -Property * -ExcludeProperty Values
}

function Export-TsReport {
    <#
    .SYNOPSIS
        Writes the HTML report, the JSON result and the scenario of a sizing in a new folder.
    .PARAMETER Result
        Result of Invoke-TsSizing.
    .PARAMETER OutputPath
        Parent folder. Default: reports under the tool folder.
    .PARAMETER Open
        Opens the technical report and the customer summary with the default browser.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [string]$OutputPath,
        [switch]$Open
    )

    if (-not $OutputPath) { $OutputPath = Join-Path $script:ToolRoot 'reports' }
    # .NET resolves relative paths against the process folder, not the PowerShell location.
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $name = Get-TsSafeName ([string]$Result.Scenario.Name)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $folder = Join-Path $OutputPath ('TransportSizer_{0}_{1}' -f $name, $stamp)
    $suffix = 1
    while (Test-Path -LiteralPath $folder) { $suffix++; $folder = Join-Path $OutputPath ('TransportSizer_{0}_{1}-{2}' -f $name, $stamp, $suffix) }
    [void](New-Item -ItemType Directory -Path $folder -Force)

    $data = Get-TsResultData -Result $Result
    $json = ConvertTo-TsEmbeddedJson $data
    $utf8 = [Text.UTF8Encoding]::new($false)
    $htmlPath = Join-Path $folder 'TransportSizer.html'
    $synthesisPath = Join-Path $folder 'TransportSizer-Synthese.html'
    $jsonPath = Join-Path $folder 'TransportSizer-Result.json'
    $scenarioPath = Join-Path $folder 'TransportSizer-Scenario.json'
    foreach ($page in @(@('Report.template.html', $htmlPath, 'Transport Sizer'), @('Report-Client.template.html', $synthesisPath, 'Synthèse'))) {
        $template = [IO.File]::ReadAllText((Join-Path $script:ToolRoot ('templates\' + $page[0])), [Text.Encoding]::UTF8)
        foreach ($marker in '{{TITLE}}', '{{DATA}}') {
            $count = ([regex]::Matches($template, [regex]::Escape($marker))).Count
            if ($count -ne 1) { throw "Modèle de rapport invalide ($($page[0])) : le marqueur $marker apparaît $count fois au lieu d’une." }
        }
        $title = [Net.WebUtility]::HtmlEncode(('{0} · {1}' -f $Result.Scenario.Name, $page[2]))
        [IO.File]::WriteAllText($page[1], $template.Replace('{{TITLE}}', $title).Replace('{{DATA}}', $json), $utf8)
    }
    [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $data -Depth 14), $utf8)
    [void](Export-TsScenario -Scenario $Result.Scenario -Path $scenarioPath)
    if ($Open) { Start-Process -FilePath $synthesisPath; Start-Process -FilePath $htmlPath }
    [pscustomobject]@{ Folder = $folder; Html = $htmlPath; Synthesis = $synthesisPath; Json = $jsonPath; Scenario = $scenarioPath }
}

function Write-TsResultSummary {
    <# Console summary of a sizing (command line). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Result)

    $s = $Result.Summary
    Write-Host ''
    Write-Host ('  Transport Sizer {0}  ·  {1}' -f $Result.Version, $Result.Scenario.Name) -ForegroundColor Magenta
    if ($Result.Valid) {
        Write-Host ('  {0} · {1} · {2} serveur(s), {3} restant(s) ({4})' -f $s.RoleLabel, $s.DeploymentLabel, $s.Servers, $s.Alive, $s.FailureLabel.ToLower())
        Write-Host ('  Débit de dimensionnement {0} msg/s par serveur ; mail.que {1} Go au pire moment' -f (Format-TsNumber $s.RateDesign 1), (Format-TsNumber $s.MailQueGB 1))
        $profileText = switch ($s.ProfileSource) { 'Reference' { 'référence du labo (générique)' } 'Custom' { 'mesuré chez le client' } default { 'aucun' } }
        Write-Host ('  Profil : {0} · {1}' -f $(if ($s.CalibrationName) { $s.CalibrationName } else { '—' }), $profileText) -ForegroundColor DarkGray
        Write-Host ''
        foreach ($row in $Result.Config) {
            $color = switch ($row.Status) { 'ok' { 'Green' } 'missing' { 'Yellow' } 'partial' { 'Yellow' } 'warning' { 'Yellow' } default { 'Gray' } }
            Write-Host ('  {0,-26} ' -f $row.Component) -NoNewline
            Write-Host ('{0,-22}' -f $row.Value) -ForegroundColor $color -NoNewline
            Write-Host (' {0}' -f $row.Detail) -ForegroundColor DarkGray
        }
    }
    if ($Result.Checks.Count -gt 0) { Write-Host '' }
    foreach ($check in $Result.Checks) {
        $color = switch ($check.Level) { 'Error' { 'Red' } 'Warning' { 'Yellow' } default { 'Cyan' } }
        $label = switch ($check.Level) { 'Error' { 'Erreur' } 'Warning' { 'Attention' } default { 'Info' } }
        Write-Host ('  [{0}] {1}' -f $label, $check.Message) -ForegroundColor $color
    }
    Write-Host ''
}
