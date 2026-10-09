<#
.SYNOPSIS
    Transport Sizer - traffic measured by Exchange Log Report (dot-sourced by TransportSizer.psm1).

.DESCRIPTION
    Exchange Log Report reads the message tracking and SMTP protocol logs of the Exchange servers. Its
    detailed report (-ReportType Detailed) writes one row per message (<prefix>-Messages.csv) and one row per
    SMTP transaction (<prefix>-SmtpSessions.csv). Import-TsLogReport turns them into the traffic inputs of a
    scenario; Update-TsScenarioFromLogReport puts them in a scenario.

    A message is classified by the directionality of message tracking and the final status of its recipients:

        Incoming                                 Inbound
        Originating, at least one recipient sent Outbound (Edge: every Originating message)
        Originating, delivered only              Internal (Mailbox)
        Refused or deferred during SMTP          not counted: no message in the queue
        Journal report (system sender)           not counted: the Journaling group of the scenario adds them

    Messages per day: messages of the period ÷ hours covered × 24 (average day), or the busiest complete day.
    Peak hour: messages of the busiest hour ÷ messages per day, so that the engine finds that hour again.
    Transmissions: recipient domains sent per outbound message (one SMTP transmission per domain).
    Messages per session and TLS: receive sessions of the transport service (Edge, else Hub, else FrontEnd).

.NOTES
    Author  : Nicolas Fabert
    Version : 1.9.0
#>

$script:TsLogDays = [ordered]@{ Average = 'jour moyen de la période'; Busiest = 'jour complet le plus chargé' }

function Initialize-TsLogReader {
    <# The CSV reader of src\Sizer.LogReader.cs, compiled once per session (one pass, aggregates only). #>
    if (-not ('TransportSizer.LogReader' -as [type])) {
        Add-Type -Path (Join-Path $script:ToolRoot 'src\Sizer.LogReader.cs')
    }
}
function Find-TsLogReportFiles {
    <#
        The CSV files of a detailed report: the folder of the report, one of its CSV files, or a folder of
        reports (the most recent detailed report inside is taken).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Rapport Exchange Log Report introuvable : $Path" }
    $item = Get-Item -LiteralPath $Path
    $messages = $null
    if (-not $item.PSIsContainer) {
        if ($item.Name -notmatch '^(?<prefix>.+?)-(Messages|SmtpSessions|SmtpClients|SmtpDestinations|Servers|Daily|Users|Clients|Operations|ClientSessions|ClientAccess-Daily|ClientAccess-Requests)\.csv$') {
            throw "« $($item.Name) » n’est pas un fichier CSV d’Exchange Log Report (<préfixe>-Messages.csv)."
        }
        $messages = Join-Path $item.DirectoryName ($Matches.prefix + '-Messages.csv')
        $folder = $item.Directory
    }
    else {
        $folder = $item
        $found = @(Get-ChildItem -LiteralPath $item.FullName -Filter '*-Messages.csv' -File | Sort-Object LastWriteTime -Descending)
        if ($found.Count -eq 0) {
            $found = @(Get-ChildItem -LiteralPath $item.FullName -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*-Messages.csv' -File } | Sort-Object LastWriteTime -Descending)
        }
        if ($found.Count -gt 0) { $messages = $found[0].FullName; $folder = $found[0].Directory }
    }
    if (-not $messages -or -not (Test-Path -LiteralPath $messages)) {
        $usage = @(Get-ChildItem -LiteralPath $folder.FullName -Filter '*-Daily.csv' -File)
        if ($usage.Count -gt 0) {
            throw "Rapport « Usage » d’Exchange Log Report : il ne contient pas la liste des messages. Relancer le rapport en détaillé, sur au moins 7 jours, sans nouvelle collecte : .\Invoke-ExchangeLogReport.ps1 -Range Last7Days -ReportType Detailed -NoCollect"
        }
        throw "Aucun fichier <préfixe>-Messages.csv d’Exchange Log Report dans « $($folder.FullName) »."
    }
    $prefix = (Split-Path -Leaf $messages) -replace '-Messages\.csv$', ''
    $other = { param($name) $p = Join-Path $folder.FullName "$prefix-$name.csv"; if (Test-Path -LiteralPath $p) { $p } else { $null } }
    [pscustomobject]@{
        Folder = $folder.FullName; Prefix = $prefix; Messages = $messages
        SmtpSessions = & $other 'SmtpSessions'; Servers = & $other 'Servers'; SmtpDestinations = & $other 'SmtpDestinations'
    }
}

function Get-TsLogSessions {
    <#
        Receive sessions of SmtpSessions.csv: messages accepted per session and share of TLS sessions, for the
        role of the transport service (Edge, else Hub, else FrontEnd, else every receive session).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-TsLogReader
    $roles = @([TransportSizer.LogReader]::ReadSessions($Path))
    $selected = $null
    foreach ($candidate in 'Edge', 'Hub', 'FrontEnd') {
        $selected = $roles | Where-Object { $_.Role -eq $candidate -and $_.Accepted -gt 0 } | Select-Object -First 1
        if ($selected) { break }
    }
    if (-not $selected) {
        $selected = [TransportSizer.RoleSessions]::new()
        $selected.Role = 'toutes'
        foreach ($r in $roles) {
            $selected.Sessions += $r.Sessions; $selected.TlsSessions += $r.TlsSessions
            $selected.Accepted += $r.Accepted; $selected.SessionsWithMessages += $r.SessionsWithMessages
        }
    }
    if ($selected.Sessions -le 0 -or $selected.SessionsWithMessages -le 0) { return $null }
    [pscustomobject]@{
        Role = $selected.Role; Sessions = $selected.Sessions; SessionsWithMessages = $selected.SessionsWithMessages; Messages = $selected.Accepted
        MessagesPerSession = $selected.Accepted / $selected.SessionsWithMessages; TlsPercent = 100.0 * $selected.TlsSessions / $selected.Sessions
        Roles = @($roles | ForEach-Object { $_.Role } | Sort-Object)
    }
}

function Import-TsLogReport {
    <#
    .SYNOPSIS
        Traffic of a detailed Exchange Log Report: message flows, peak hour, messages per SMTP session, TLS.
    .PARAMETER Path
        Folder of the detailed report, one of its CSV files (<prefix>-Messages.csv), or the folder of the
        reports (the most recent detailed report is taken).
    .PARAMETER Day
        Average (default): messages per day of the average day of the period (nights and weekends included).
        Busiest: messages of the busiest complete day.
    .PARAMETER Role
        Edge or Mailbox. Default: Edge when the report is an Edge report (SmtpDestinations.csv, Edge sessions).
    .OUTPUTS
        Flows and Load ready for a scenario, the figures measured, warnings (French).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Average', 'Busiest')][string]$Day = 'Average',
        [ValidateSet('', 'Edge', 'Mailbox')][string]$Role = ''
    )

    $files = Find-TsLogReportFiles -Path $Path
    $warnings = [Collections.Generic.List[string]]::new()
    $sessions = $null
    if ($files.SmtpSessions) { $sessions = Get-TsLogSessions -Path $files.SmtpSessions }
    $edgeReport = [bool]$files.SmtpDestinations -or ($sessions -and $sessions.Role -eq 'Edge') -or ((Split-Path -Leaf $files.Folder) -match '_Edge(Usage|Detailed)_')
    if (-not $Role) { $Role = $(if ($edgeReport) { 'Edge' } else { 'Mailbox' }) }
    $edge = $Role -eq 'Edge'

    $keys = @('Inbound', 'Outbound', 'Internal')
    $culture = [Globalization.CultureInfo]::InvariantCulture
    Initialize-TsLogReader
    $read = [TransportSizer.LogReader]::ReadMessages($files.Messages, $edge)
    $stats = $read.Flows
    $hours = $read.Hours
    $days = $read.Days
    $refused = $read.Refused; $journal = $read.Journal; $journalKB = $read.JournalKB; $unknown = $read.Unknown; $undated = $read.Undated
    $first = $read.First; $last = $read.Last
    $servers = $read.Servers

    $counted = ($keys | ForEach-Object { $stats[$_].Messages } | Measure-Object -Sum).Sum
    if ($counted -eq 0 -or $first -eq [datetime]::MaxValue) {
        throw "Aucun message traité dans « $($files.Messages) » (messages refusés en SMTP : $refused, rapports de journal : $journal)."
    }

    # Hours covered: from the hour of the first message to the end of the hour of the last one.
    $startHour = [datetime]::new($first.Year, $first.Month, $first.Day, $first.Hour, 0, 0)
    $endHour = [datetime]::new($last.Year, $last.Month, $last.Day, $last.Hour, 0, 0).AddHours(1)
    $span = ($endHour - $startHour).TotalHours
    $busiest = $null
    $perDay = @{}
    if ($Day -eq 'Busiest') {
        $totals = @{}
        foreach ($entry in $days.GetEnumerator()) {
            $date = $entry.Key.Split('|')[0]
            $start = [datetime]::ParseExact($date, 'yyyy-MM-dd', $culture)
            if ($start -lt $startHour -or $start.AddDays(1) -gt $endHour) { continue }
            $totals[$date] = $(if ($totals.ContainsKey($date)) { $totals[$date] } else { 0 }) + $entry.Value
        }
        if ($totals.Count -gt 0) {
            $busiest = @($totals.GetEnumerator() | Sort-Object -Property Value -Descending)[0].Key
            foreach ($k in $keys) { $dayKey = "$busiest|$k"; $perDay[$k] = $(if ($days.ContainsKey($dayKey)) { $days[$dayKey] } else { 0.0 }) }
        }
        else {
            $warnings.Add('Aucun jour complet dans la période : base « jour moyen » utilisée à la place du jour le plus chargé.')
            $Day = 'Average'
        }
    }
    if ($Day -eq 'Average') { foreach ($k in $keys) { $perDay[$k] = $stats[$k].Messages / $span * 24 } }
    $dayTotal = ($keys | ForEach-Object { $perDay[$_] } | Measure-Object -Sum).Sum
    if ($dayTotal -le 0) { throw 'Aucun message le jour retenu.' }

    $peak = @($hours.GetEnumerator() | Sort-Object -Property Value -Descending)[0]
    $peakPercent = [Math]::Min(100.0, [Math]::Max(100.0 / 24, 100.0 * $peak.Value / $dayTotal))

    # Working day from the hours of the day over the whole period (at least one full day): working hours = hours
    # above the hourly average, peak hours = hours at 80 % or more of the busiest hour of the day.
    $workingDay = $null
    if ($span -ge 24) {
        $byHour = [double[]]::new(24)
        foreach ($entry in $hours.GetEnumerator()) { $byHour[[int]$entry.Key.Substring(11, 2)] += $entry.Value }
        $sum = ($byHour | Measure-Object -Sum).Sum
        if ($sum -gt 0) {
            $shares = @($byHour | ForEach-Object { $_ / $sum })
            $maxShare = ($shares | Measure-Object -Maximum).Maximum
            $working = @(0..23 | Where-Object { $shares[$_] -ge 1.0 / 24 - 1e-12 })
            $workingH = [Math]::Max(1, $working.Count)
            $off = $(if ($workingH -ge 24) { 0.0 } else { 1.0 - (($working | ForEach-Object { $shares[$_] }) | Measure-Object -Sum).Sum })
            $peakH = [Math]::Max(1, @(0..23 | Where-Object { $shares[$_] -ge 0.8 * $maxShare }).Count)
            $peakH = [Math]::Min($peakH, $workingH)
            # The peak hours cannot carry more than the working day (busiest hour of a weekday against an average day).
            $peakH = [Math]::Max(1, [Math]::Min($peakH, [Math]::Floor((1 - $off) / ($peakPercent / 100))))
            $workingDay = [pscustomobject]@{
                WorkingHours = $workingH; OffHoursPercent = [Math]::Round(100 * $off, 0); PeakHours = $peakH
                First = '{0:00}:00' -f ($working | Select-Object -First 1); Last = '{0:00}:00' -f ((($working | Select-Object -Last 1) + 1) % 24)
                Shares = $shares
            }
        }
    }
    else { $warnings.Add('Moins d’’une journée : heures ouvrées et durée de la pointe non mesurées, celles du scénario sont gardées.') }

    $names = if ($edge) { @{ Inbound = 'Entrant Internet (ELR)'; Outbound = 'Sortant Internet (ELR)'; Internal = 'Interne (ELR)' } }
    else { @{ Inbound = 'Entrant (ELR)'; Outbound = 'Sortant (ELR)'; Internal = 'Interne (ELR)' } }
    $directions = [Collections.Generic.List[object]]::new()
    $flows = [Collections.Generic.List[object]]::new()
    foreach ($k in $keys) {
        $s = $stats[$k]
        if ($s.Messages -eq 0) { continue }
        $avg = $(if ($s.Sized -gt 0) { $s.SizeSum / $s.Sized } else { $null })
        if ($null -eq $avg) { $warnings.Add("$($script:TsDirections[$k]) : aucune taille de message dans le rapport, 75 Ko retenus.") }
        $fanOut = $(if ($k -eq 'Outbound') { [Math]::Max(1.0, $s.Domains / $s.Messages) } else { 1.0 })
        $directions.Add([pscustomobject]@{
                Direction = $k; Label = $script:TsDirections[$k]; Messages = $s.Messages; PerDay = $perDay[$k]
                AverageSizeKB = $avg; FanOut = $fanOut; RecipientsPerMessage = $s.Recipients / $s.Messages
            })
        if ($perDay[$k] -le 0) { continue }
        $flows.Add([ordered]@{
                Name = $names[$k]; Direction = $k; MessagesPerDay = [Math]::Round($perDay[$k], 0, [MidpointRounding]::AwayFromZero)
                AverageSizeKB = $(if ($null -ne $avg) { [Math]::Round($avg, 1) } else { 75.0 })
                FanOut = [Math]::Round($fanOut, 2); HeldDuringOutage = $true
            })
    }

    # The engine checks the peak with the values the scenario will hold: the rounded share outside working hours and
    # the measured peak rate ÷ the rounded messages per day of the flows.
    if ($workingDay -and $flows.Count -gt 0) {
        $flowDay = ($flows | ForEach-Object { [double]$_.MessagesPerDay } | Measure-Object -Sum).Sum
        $pScenario = [double]$peak.Value / [Math]::Max(1.0, $flowDay)
        $offScenario = $workingDay.OffHoursPercent / 100
        if ($pScenario -gt 1 - $offScenario) {
            $workingDay.OffHoursPercent = [Math]::Max(0, [Math]::Floor(100 * (1 - $pScenario)))
            $offScenario = $workingDay.OffHoursPercent / 100
        }
        $workingDay.PeakHours = [Math]::Max(1, [Math]::Min([double]$workingDay.PeakHours, [Math]::Floor((1 - $offScenario + 1e-9) / $pScenario)))
    }

    if ($edge -and $stats['Internal'].Messages -gt 0) { $warnings.Add('Rapport lu comme Edge : pas de flux interne.') }
    if ($span -lt 24) { $warnings.Add(('Période de {0} h seulement : messages par jour extrapolés sur 24 h. Prendre au moins 7 jours.' -f (Format-TsNumber $span 0))) }
    elseif ($span -lt 168) { $warnings.Add(('Période de {0} jour(s) : moins d’’une semaine, le jour moyen ne reflète pas l’’alternance semaine / week-end.' -f (Format-TsNumber ($span / 24) 1))) }
    if ($unknown -gt 0) { $warnings.Add(('{0} message(s) sans sens dans le suivi des messages (directionality vide) : classés {1}.' -f $unknown, $(if ($edge) { 'entrants' } else { 'sortants s’’ils sont relayés, sinon internes' }))) }
    if ($undated -gt 0) { $warnings.Add(('{0} message(s) sans date lisible : comptés dans les tailles, pas dans les messages par jour.' -f $undated)) }
    if ($journal -gt 0) {
        $warnings.Add(('{0} rapport(s) de journal exclus des flux ({1} % des messages) : activer la journalisation du scénario (rôle Mailbox), qui les calcule.' -f $journal, (Format-TsNumber (100.0 * $journal / $counted) 1)))
    }
    if (-not $edge -and $stats['Outbound'].Messages -gt 0) {
        $warnings.Add('Transmissions du flux sortant : domaines de destination par message. Derrière un Edge ou un relais, une Mailbox n’’envoie qu’’une copie par message : ramener à 1 si besoin.')
    }
    if (-not $sessions) { $warnings.Add('Pas de sessions SMTP reçues (SmtpSessions.csv) : messages par session et part TLS non mesurés.') }
    elseif ($sessions.Role -in 'FrontEnd', 'toutes') { $warnings.Add(('Sessions SMTP lues sur le rôle {0} : journal de protocole du transport (Hub) absent.' -f $sessions.Role)) }

    $load = [ordered]@{ PeakHourPercent = [Math]::Round($peakPercent, 1); PeakRate = [double]$peak.Value; PeakRateUnit = 'PerHour'; MessagesPerSession = $null; TlsPercent = $null
        WorkingHours = $null; OffHoursPercent = $null; PeakHours = $null }
    if ($workingDay) { $load.WorkingHours = [double]$workingDay.WorkingHours; $load.OffHoursPercent = [double]$workingDay.OffHoursPercent; $load.PeakHours = [double]$workingDay.PeakHours }
    if ($sessions) {
        $load.MessagesPerSession = [Math]::Round([Math]::Max(1.0, $sessions.MessagesPerSession), 1)
        $load.TlsPercent = [Math]::Round($sessions.TlsPercent, 0)
    }
    [pscustomobject]@{
        Source = $files.Folder; Prefix = $files.Prefix; Files = $files; Role = $Role; EdgeReport = $edgeReport
        Start = $first; End = $last; Hours = $span; Day = $Day; DayLabel = $script:TsLogDays[$Day]; BusiestDay = $busiest
        Messages = [double]$counted; MessagesPerDay = $dayTotal; Refused = $refused; JournalReports = $journal
        JournalAverageKB = $(if ($journal -gt 0) { $journalKB / $journal } else { $null }); Unclassified = $unknown
        PeakHour = [pscustomobject]@{ Hour = $peak.Key + ':00'; Messages = $peak.Value; Percent = $peakPercent }; WorkingDay = $workingDay
        Directions = $directions.ToArray(); Flows = $flows.ToArray(); Load = $load; Sessions = $sessions
        Servers = @($servers | Sort-Object); Warnings = $warnings.ToArray()
    }
}

function Format-TsLogReportSummary {
    <# French lines describing an import (console and window). ScenarioRole: role of the scenario that receives it. #>
    param([Parameter(Mandatory = $true)][object]$LogReport, [string]$ScenarioRole = '')

    $r = $LogReport
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add(('Exchange Log Report : {0} ({1}, {2})' -f $r.Source, $(if ($r.EdgeReport) { 'rapport Edge' } else { 'rapport Mailbox' }), ($r.Servers -join ', ')))
    $lines.Add(('Période : {0} → {1} ({2} h), {3} messages traités ; base : {4}{5}' -f $r.Start.ToString('yyyy-MM-dd HH:mm'), $r.End.ToString('yyyy-MM-dd HH:mm'),
            (Format-TsNumber $r.Hours 0), (Format-TsNumber $r.Messages 0), $r.DayLabel, $(if ($r.BusiestDay) { " ($($r.BusiestDay))" } else { '' })))
    foreach ($d in $r.Directions) {
        $lines.Add(('  {0,-8} {1,10} msg/j  {2,8} Ko  {3} transmission(s)  {4} destinataire(s) par message' -f $d.Label, (Format-TsNumber $d.PerDay 0),
                $(if ($null -ne $d.AverageSizeKB) { Format-TsNumber $d.AverageSizeKB 1 } else { '—' }), (Format-TsNumber $d.FanOut 2), (Format-TsNumber $d.RecipientsPerMessage 1)))
    }
    $lines.Add(('Heure de pointe : {0}, {1} messages (débit de pointe mesuré, msg/h) = {2} % du jour retenu' -f $r.PeakHour.Hour, (Format-TsNumber $r.PeakHour.Messages 0), (Format-TsNumber $r.Load.PeakHourPercent 1)))
    if ($r.WorkingDay) {
        $lines.Add(('Journée : {0} h ouvrées ({1} → {2}, heures au-dessus de la moyenne horaire), {3} % du trafic hors heures ouvrées, pointe de {4} h (heures à 80 % ou plus de la plus chargée)' -f
                (Format-TsNumber $r.WorkingDay.WorkingHours 0), $r.WorkingDay.First, $r.WorkingDay.Last, (Format-TsNumber $r.WorkingDay.OffHoursPercent 0), (Format-TsNumber $r.WorkingDay.PeakHours 0)))
    }
    if ($r.Sessions) {
        $lines.Add(('Sessions SMTP reçues ({0}) : {1} messages par session, {2} % en TLS ({3} sessions)' -f $r.Sessions.Role, (Format-TsNumber $r.Load.MessagesPerSession 1),
                (Format-TsNumber $r.Load.TlsPercent 0), (Format-TsNumber $r.Sessions.Sessions 0)))
    }
    if ($r.Refused -gt 0) { $lines.Add(('Refusés pendant la session SMTP (non comptés) : {0}' -f (Format-TsNumber $r.Refused 0))) }
    if ($ScenarioRole -and $ScenarioRole -ne $r.Role) {
        $lines.Add(('Attention : trafic d’’un rapport {0} dans un scénario {1} : vérifier les flux (le trafic interne ne passe pas par un Edge).' -f $script:TsRoles[$r.Role], $script:TsRoles[$ScenarioRole]))
    }
    foreach ($w in $r.Warnings) { $lines.Add("Attention : $w") }
    return $lines.ToArray()
}

function Update-TsScenarioFromLogReport {
    <#
    .SYNOPSIS
        The scenario with the traffic of an Exchange Log Report import: flows replaced, peak rate measured (msg/h),
        share of the peak hour, working hours, share outside them and length of the peak when the period covers at
        least a day, messages per session and TLS share when they were measured. The other inputs are kept.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Scenario, [Parameter(Mandatory = $true)][object]$LogReport)

    $s = ConvertTo-TsScenario -Scenario $Scenario
    $r = $LogReport
    if ($r.Role -ne $s.Role) {
        Write-Warning ('Trafic d’’un rapport {0} importé dans un scénario {1}.' -f $script:TsRoles[$r.Role], $script:TsRoles[$s.Role])
    }
    $s.Flows = @($r.Flows | ForEach-Object { ConvertTo-TsFlow -Flow $_ -Index 0 })
    foreach ($key in 'PeakHourPercent', 'PeakRate', 'MessagesPerSession', 'TlsPercent', 'WorkingHours', 'OffHoursPercent', 'PeakHours') {
        if ($r.Load.Contains($key) -and $null -ne $r.Load[$key]) { $s.Load[$key] = [double]$r.Load[$key] }
    }
    if ($r.Load.Contains('PeakRateUnit') -and $r.Load.PeakRateUnit) { $s.Load.PeakRateUnit = [string]$r.Load.PeakRateUnit }
    # A scenario kept with its own working day: the peak hours never exceed its working hours.
    if ($s.Load.PeakHours -gt $s.Load.WorkingHours) { $s.Load.PeakHours = $s.Load.WorkingHours }
    $note = 'Trafic importé d’’Exchange Log Report ({0}) : {1} → {2}, {3} messages, {4}.' -f $r.Source, $r.Start.ToString('yyyy-MM-dd HH:mm'), $r.End.ToString('yyyy-MM-dd HH:mm'),
        (Format-TsNumber $r.Messages 0), $r.DayLabel
    $s.Notes = $(if ($s.Notes) { $s.Notes.TrimEnd() + ' ' + $note } else { $note })
    return $s
}
