<#
.SYNOPSIS
    Transport Sizer - sizing engine (dot-sourced by TransportSizer.psm1).

.DESCRIPTION
    Invoke-TsSizing turns a scenario (traffic, topology, resilience, hardware) and a calibration profile
    into the configuration of one transport server: Edge Transport, or Mailbox server for its transport
    part. Every number is recorded with its formula, the computation with the actual values and its
    origin (input, Microsoft, lab, assumption, calibration, rule, computed), so that the report explains
    all of them.

    Rules of the model:
      - Edge Transport: queue = messages in transit + backlog of an outage of the next hop. Safety Net and
        shadow redundancy do not apply to the Edge role.
      - Mailbox (transport): queue = transit + backlog + Safety Net and, with shadow redundancy (at least
        two servers left), the same again for the shadow copies held for the other servers. This applies
        even when the servers host no mailbox.
      - CPU, memory and IOPS come only from the calibration profile (linear models per message/s measured
        on a reference server). Without a calibration they are not computed: no invented constant.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.10.0
#>

$script:TsCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR').Clone()
$script:TsCulture.NumberFormat.NumberGroupSeparator = [string][char]0x00A0
$script:TsKindLabels = [ordered]@{
    Input = 'Saisie'; Computed = 'Calcul'; Microsoft = 'Microsoft'; Lab = 'Mesure lab'; Assumption = 'Hypothèse'; Calibration = 'Calibration'; Rule = 'Règle'
}
$script:TsSectionCatalog = @(
    @{ Id = 'load'; Title = 'Charge de transport'
        Intro = 'Le trafic de l’’organisation, augmenté de la croissance, est réparti sur les serveurs qui restent après la panne retenue. Le débit de dimensionnement est celui de l’’heure de pointe, multiplié par le facteur de rafale.' }
    @{ Id = 'queue'; Title = 'File d’’attente (mail.que)'
        Intro = 'Ce que la base de file d’’attente doit contenir au pire moment : les messages en transit, ceux accumulés pendant une panne du saut suivant et, pour le rôle Mailbox uniquement, Safety Net et les copies shadow.' }
    @{ Id = 'cpu'; Title = 'Processeur'
        Intro = 'Consommation mesurée sur le serveur de référence, terme par terme (à vide, par message, taille, règles de transport, sessions SMTP, TLS), corrigée par les paliers de validation, ramenée à la performance par cœur du serveur cible, puis divisée par l’’utilisation maximale visée.' }
    @{ Id = 'memory'; Title = 'Mémoire'
        Intro = 'La RAM doit garder EdgeTransport.exe sous le seuil PrivateBytes et l’’ensemble des processus sous le seuil SystemMemory de back pressure, au débit de dimensionnement et avec la file pleine.' }
    @{ Id = 'storage'; Title = 'Volumes'
        Intro = 'Contenu de chaque volume, divisé par le taux de remplissage maximal : le plus bas entre la marge de conception et le seuil de back pressure de ce qui est stocké sur le volume.' }
    @{ Id = 'disk'; Title = 'Disques et IOPS'
        Intro = 'Entrées/sorties mesurées sur le volume de la file au débit de dimensionnement, avec le surcoût d’’E/S. En physique : pénalité d’’écriture et réserve de reconstruction RAID, puis nombre de disques.' }
    @{ Id = 'network'; Title = 'Réseau'
        Intro = 'Chaque message est reçu une fois et émis autant de fois que de transmissions. Edge : la réception et l’’émission se font sur deux cartes (interne et externe). Mailbox : la redondance shadow ajoute une copie vers un autre serveur.' }
    @{ Id = 'resilience'; Title = 'Capacité et vidange'
        Intro = 'Débit maximal que le serveur proposé supporte (processeur et réseau) et temps nécessaire pour vider la file accumulée pendant la panne, en plus du trafic normal.' }
    @{ Id = 'microsoft'; Title = 'Calculateur Microsoft (comparaison)'
        Intro = 'Ce que le Role Requirements Calculator 10.7 donnerait avec les mêmes messages : il ne dimensionne le transport que par la taille de la base, avec un facteur shadow ×2 et Safety Net appliqués à tout serveur de transport.' }
)

function Format-TsNumber {
    <# French number: non-breaking space between thousands, comma as decimal separator. #>
    param([AllowNull()][object]$Value, [int]$Decimals = 1)

    if ($null -eq $Value) { return '—' }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return '—' }
    # Half away from zero, like the numbers of the HTML report (Intl.NumberFormat): 4,25 gives 4,3 on both sides.
    $number = [Math]::Round($number, [Math]::Min([Math]::Max($Decimals, 0), 15), [MidpointRounding]::AwayFromZero)
    return $number.ToString('N' + $Decimals, $script:TsCulture)
}

function Fn {
    <# Short form of Format-TsNumber for the computations. #>
    param([AllowNull()][object]$Value, [int]$Decimals = 1)
    Format-TsNumber -Value $Value -Decimals $Decimals
}

function Get-TsCeiling {
    <# Rounds up to a multiple of Step, without the floating point noise (120.0000001 stays 120). #>
    param([double]$Value, [double]$Step = 1)
    if ($Step -le 0) { return $Value }
    return [Math]::Ceiling(($Value / $Step) - 1e-9) * $Step
}

function New-TsContext {
    $sections = [ordered]@{}
    foreach ($section in $script:TsSectionCatalog) {
        $sections[$section.Id] = [pscustomobject]@{ Id = $section.Id; Title = $section.Title; Intro = $section.Intro; Values = [Collections.Generic.List[object]]::new() }
    }
    @{ Sections = $sections; Values = @{}; Checks = [Collections.Generic.List[object]]::new() }
}

function Add-TsValue {
    <#
        Records one number of the sizing and returns it. Kind: Input, Computed, Microsoft, Lab, Assumption,
        Calibration or Rule. Formula is the rule in words, Computation the same rule with the values.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][object]$Value,
        [string]$Unit = '',
        [string]$Formula = '',
        [string]$Computation = '',
        [ValidateSet('Input', 'Computed', 'Microsoft', 'Lab', 'Assumption', 'Calibration', 'Rule')][string]$Kind = 'Computed',
        [string]$Source = '',
        [int]$Decimals = 1,
        [string]$Note = ''
    )

    if ($null -eq $Value) { $display = '—' }
    elseif ($Value -is [string]) { $display = $Value }
    elseif ($Value -is [bool]) { $display = if ($Value) { 'Oui' } else { 'Non' } }
    else { $display = Format-TsNumber -Value $Value -Decimals $Decimals }
    $item = [pscustomobject]@{
        Id = $Id; Label = $Label; Value = $Value; Unit = $Unit; Display = $display; Formula = $Formula; Computation = $Computation
        Kind = $Kind; KindLabel = $script:TsKindLabels[$Kind]; Source = $Source; Note = $Note
    }
    $Context.Sections[$Section].Values.Add($item)
    $Context.Values[$Id] = $item
    return $Value
}

function Add-TsCheck {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('Error', 'Warning', 'Info')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $Context.Checks.Add([pscustomobject]@{ Level = $Level; Code = $Code; Message = $Message; Index = $Context.Checks.Count })
}

$script:TsLoadTerms = @(
    [pscustomobject]@{ Key = 'Slope'; Factor = 'Rate'; Label = 'par message'; Unit = 'msg/s' }
    [pscustomobject]@{ Key = 'PerMBps'; Factor = 'MBps'; Label = 'taille'; Unit = 'Mo/s' }
    [pscustomobject]@{ Key = 'PerRuleMsg'; Factor = 'RulesRate'; Label = 'règles de transport'; Unit = 'msg/s × règles' }
    [pscustomobject]@{ Key = 'PerSession'; Factor = 'Sessions'; Label = 'sessions SMTP'; Unit = 'sessions/s' }
    [pscustomobject]@{ Key = 'PerTlsSession'; Factor = 'TlsSessions'; Label = 'négociations TLS'; Unit = 'sessions TLS/s' }
    [pscustomobject]@{ Key = 'PerTlsMBps'; Factor = 'TlsMBps'; Label = 'chiffrement TLS'; Unit = 'Mo/s TLS' }
    [pscustomobject]@{ Key = 'PerJournal'; Factor = 'JournalRate'; Label = 'rapports de journal'; Unit = 'rapports/s' }
)

function New-TsLoad {
    <#
        Load factors of a server at a rate: messages/s, MB/s, messages/s × rules, sessions opened per second,
        TLS negotiations per second, MB/s over TLS and journal reports written per second (Mailbox role).
    #>
    param([double]$Rate, [double]$SizeKB = 0, [double]$Rules = 0, [double]$MessagesPerSession = 1, [double]$TlsShare = 0, [double]$JournalRate = 0)
    $mbps = $Rate * $SizeKB / 1024
    $sessions = $Rate / [Math]::Max(1.0, $MessagesPerSession)
    [ordered]@{ Rate = $Rate; MBps = $mbps; RulesRate = $Rate * $Rules; Sessions = $sessions; TlsSessions = $sessions * $TlsShare; TlsMBps = $mbps * $TlsShare; JournalRate = $JournalRate }
}

function Resolve-TsModelLoad {
    <#
        The load a model is evaluated on. A load split for journal reports (JournalRate apart from the messages
        received over SMTP) keeps the whole load in Plain: a model without a measured journal term costs the
        reports as ordinary messages, never at zero.
    #>
    param([AllowNull()][object]$Model, [Collections.IDictionary]$Load)
    if ($null -ne $Model -and $Load.Contains('Plain') -and -not ($Model.Contains('PerJournal') -and [double]$Model['PerJournal'] -gt 0)) { return $Load['Plain'] }
    return $Load
}

function Get-TsModelValue {
    <# Value of a calibration model for a load (New-TsLoad) or, for an old profile, a rate (messages/s). #>
    param([AllowNull()][object]$Model, [object]$Load)
    if ($null -eq $Model) { return $null }
    if ($Load -isnot [Collections.IDictionary]) { $Load = New-TsLoad -Rate ([double]$Load) }
    $Load = Resolve-TsModelLoad $Model $Load
    $value = [double]$Model.Intercept
    foreach ($term in $script:TsLoadTerms) {
        if ($Model.Contains($term.Key)) { $value += [double]$Model[$term.Key] * [double]$Load[$term.Factor] }
    }
    return $value
}

function Get-TsModelPerMessage {
    <# Growth of a model per message/s when every factor follows the rate (same size, rules, sessions, TLS). #>
    param([AllowNull()][object]$Model, [Collections.IDictionary]$Load)
    if ($null -eq $Model) { return 0.0 }
    $Load = Resolve-TsModelLoad $Model $Load
    if ($Load.Rate -le 0) { return 0.0 }
    return ((Get-TsModelValue $Model $Load) - [double]$Model.Intercept) / $Load.Rate
}

function Format-TsModel {
    param([AllowNull()][object]$Model, [string]$Unit, [int]$Decimals = 2)
    if ($null -eq $Model) { return '' }
    $terms = @(foreach ($term in $script:TsLoadTerms) {
            if ($Model.Contains($term.Key) -and ($term.Key -eq 'Slope' -or [double]$Model[$term.Key] -ne 0)) { '{0} × {1}' -f (Fn $Model[$term.Key] ([Math]::Max($Decimals, 3))), $term.Unit }
        })
    '{0} = {1} + {2} (R² {3}, {4} paliers)' -f $Unit, (Fn $Model.Intercept $Decimals), ($terms -join ' + '), (Fn $Model.R2 3), $Model.Points
}

function Format-TsModelComputation {
    <# The model with the values of the load: intercept + coefficient × factor + … #>
    param([AllowNull()][object]$Model, [Collections.IDictionary]$Load, [int]$Decimals = 2)
    if ($null -eq $Model) { return '' }
    $Load = Resolve-TsModelLoad $Model $Load
    $parts = @(Fn $Model.Intercept $Decimals)
    foreach ($term in $script:TsLoadTerms) {
        if ($Model.Contains($term.Key) -and ($term.Key -eq 'Slope' -or [double]$Model[$term.Key] -ne 0)) { $parts += '{0} × {1}' -f (Fn $Model[$term.Key] ([Math]::Max($Decimals, 3))), (Fn $Load[$term.Factor] 2) }
    }
    return ($parts -join ' + ')
}

function Get-TsRaidLayout {
    <#
        Disks of one physical volume: enough data disks for the capacity and enough spindles for the
        back-end IOPS (reads + writes x write penalty, with the I/O overhead, divided by 1 - rebuild
        overhead), in the RAID organisation asked. RAID-1 that needs more than one data disk becomes RAID-1/0.
    #>
    param(
        [Parameter(Mandatory = $true)][double]$CapacityGB,
        [double]$ReadIops = 0,
        [double]$WriteIops = 0,
        [Parameter(Mandatory = $true)][string]$Raid,
        [Parameter(Mandatory = $true)][double]$DiskIops,
        [Parameter(Mandatory = $true)][double]$DiskSizeGB,
        [double]$IoOverhead = 0
    )

    $reference = Get-TsReference
    $info = $reference.Raid[$Raid]
    $formatted = $DiskSizeGB * 1e9 / [Math]::Pow(2, 30)
    $dataForCapacity = [int][Math]::Max(1.0, (Get-TsCeiling ($CapacityGB / $formatted) 1))
    $backend = ($ReadIops + $WriteIops * $info.WritePenalty) * (1 + $IoOverhead) / (1 - $info.RebuildOverhead)
    $disksForIops = 0
    if ($DiskIops -gt 0 -and $backend -gt 0) { $disksForIops = [int](Get-TsCeiling ($backend / $DiskIops) 1) }
    $layout = $Raid
    $upgraded = $false
    switch ($Raid) {
        'RAID-1' {
            if ($dataForCapacity -gt 1 -or $disksForIops -gt 2) { $layout = 'RAID-1/0'; $upgraded = $true }
            $data = [int][Math]::Max($dataForCapacity, [Math]::Ceiling($disksForIops / 2))
            $total = 2 * $data
        }
        'RAID-1/0' {
            $data = [int][Math]::Max($dataForCapacity, [Math]::Ceiling($disksForIops / 2))
            $total = 2 * $data
        }
        default {
            $data = [int][Math]::Max([Math]::Max($dataForCapacity, 2), $disksForIops - $info.Parity)
            $total = $data + $info.Parity
        }
    }
    if ($info.Mirror) {
        $label = if ($data -eq 1) { 'RAID-1 (1+1)' } else { "RAID-1/0 ($data+$data)" }
    }
    else { $label = "$Raid ($data+$($info.Parity))" }
    [pscustomobject]@{
        Raid = $Raid; Layout = $layout; Label = $label; Upgraded = $upgraded; FormattedGB = $formatted; DataDisks = $data; TotalDisks = $total
        DisksForCapacity = $dataForCapacity; DisksForIops = $disksForIops; BackendIops = $backend; UsableGB = $data * $formatted
        WritePenalty = $info.WritePenalty; RebuildOverhead = $info.RebuildOverhead; DiskIops = $DiskIops; DiskSizeGB = $DiskSizeGB
    }
}

function Get-TsMicrosoftQueueEstimate {
    <#
    .SYNOPSIS
        Transport database size per server of the Role Requirements Calculator 10.7 (sheet Role
        Requirements, C185 to C189): messages/day/server x 2 (shadow) x (1 + 0.5 x expiration days +
        Safety Net days) x average size (KB) / 1048576.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$MessagesPerDayPerServer,
        [Parameter(Mandatory = $true)][double]$AverageSizeKB,
        [double]$MessageExpirationDays = 2,
        [double]$SafetyNetDays = 2,
        [bool]$Shadow = $true
    )
    $reference = Get-TsReference
    $shadowFactor = if ($Shadow) { [double]$reference.Calculator.ShadowFactor } else { 1 }
    $multiplier = 1 + [double]$reference.Calculator.MessageQueueRate * $MessageExpirationDays + $SafetyNetDays
    $messages = $MessagesPerDayPerServer * $shadowFactor * $multiplier
    [pscustomobject]@{ ShadowFactor = $shadowFactor; Multiplier = $multiplier; Messages = $messages; SizeGB = $messages * $AverageSizeKB / 1048576 }
}

function Format-TsTimeSpan {
    <# Hours as an Exchange time span: 48 -> 2.00:00:00. #>
    param([double]$Hours)
    $span = [TimeSpan]::FromHours($Hours)
    $text = '{0:00}:{1:00}:{2:00}' -f $span.Hours, $span.Minutes, $span.Seconds
    if ($span.Days -gt 0) { $text = '{0}.{1}' -f $span.Days, $text }
    return $text
}

function Get-TsMemorySize {
    <# Memory to install: a multiple of 4 GB for a VM, the next usual size for a physical server. #>
    param([double]$NeededGB, [double]$MinimumGB, [bool]$Virtual)
    $needed = [Math]::Max($NeededGB, $MinimumGB)
    if ($Virtual) { return (Get-TsCeiling $needed 4) }
    foreach ($size in (Get-TsReference).MemorySizesGB) { if ($size -ge $needed - 1e-9) { return [double]$size } }
    return (Get-TsCeiling $needed 64)
}

#region ENGINE
function Invoke-TsSizing {
    <#
    .SYNOPSIS
        Sizes one transport server for a scenario: summary, target configuration, explained values, checks.
    .PARAMETER Scenario
        Scenario (hashtable or JSON object, complete or partial).
    .PARAMETER Calibration
        Calibration profile. Default: the one of the scenario, else the reference profile of the role (lab
        measurements shipped with the tool). $null: no calibration, so CPU, memory and IOPS are not computed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Scenario, [AllowNull()][object]$Calibration)

    $s = ConvertTo-TsScenario -Scenario $Scenario
    $cal = $s.Calibration
    if ($PSBoundParameters.ContainsKey('Calibration')) {
        $cal = $null
        if ($Calibration) { $cal = ConvertTo-TsCalibration -Calibration $Calibration }
    }
    elseif (-not $cal) { $cal = Get-TsReferenceProfile -Role $s.Role }
    # A profile named by the scenario but not loaded (file moved): the reference replaces it, and the report says so.
    $missingProfile = (-not $PSBoundParameters.ContainsKey('Calibration')) -and (-not $s.Calibration) -and [bool]$s.CalibrationPath
    $s.Calibration = $cal
    $profileSource = $(if (-not $cal) { 'None' } elseif ($cal.Reference) { 'Reference' } else { 'Custom' })
    $adj = $s.Adjustment
    $ref = Get-TsReference
    $ctx = New-TsContext
    $edge = $s.Role -eq 'Edge'
    $virtual = $s.Deployment -eq 'Virtual'
    $topo = $s.Topology; $load = $s.Load; $res = $s.Resilience; $sto = $s.Storage; $net = $s.Network; $cmp = $s.Compute; $phy = $s.Physical
    $bp = $ref.BackPressure
    $msReq = 'Microsoft : configuration requise Exchange 2019 / SE'
    $msBp = 'Microsoft : back pressure (EdgeTransport.exe.config)'
    $msCalc = 'Role Requirements Calculator 10.7'
    $calLabel = ''
    if ($cal) { $calLabel = $(if ($cal.Reference) { "Profil de référence « $($cal.Name) »" } else { "Calibration « $($cal.Name) »" }) }

    # ---------------------------------------------------------------- topology and traffic
    $sites = [int]$topo.Sites
    $perSite = [int]$topo.ServersPerSite
    $servers = $sites * $perSite
    $lost = switch ($topo.Failure) { 'OneServer' { 1 } 'TwoServers' { 2 } 'OneSite' { $perSite } default { 0 } }
    if ($sites -lt 1 -or $perSite -lt 1) { Add-TsCheck $ctx Error 'Topology' 'Il faut au moins un site et un serveur par site.' }
    if ($topo.Failure -eq 'OneSite' -and $sites -lt 2) { Add-TsCheck $ctx Error 'SiteFailure' 'La perte d’’un site suppose au moins deux sites.' }
    $alive = $servers - $lost
    if ($servers -ge 1 -and $alive -lt 1) { Add-TsCheck $ctx Error 'NoServerLeft' "Aucun serveur ne reste après la panne retenue ($servers déployé(s), $lost perdu(s))." }
    $flows = @($s.Flows | Where-Object { $_.MessagesPerDay -gt 0 })
    if ($flows.Count -eq 0) { Add-TsCheck $ctx Error 'NoTraffic' 'Aucun flux de messages : saisir au moins un flux avec des messages par jour.' }
    # Share of the day in one peak hour: from the measured peak rate of the organisation when it is given (the
    # messages per day of the flows are the same day), otherwise the share entered.
    $inputDayAll = 0.0
    foreach ($f in $flows) { $inputDayAll += $f.MessagesPerDay }
    $peakFromRate = $load.PeakRate -gt 0
    $peakRatePerHour = $(if ($load.PeakRateUnit -eq 'PerSecond') { $load.PeakRate * 3600 } else { $load.PeakRate })
    $peakPercent = $load.PeakHourPercent
    if ($peakFromRate -and $inputDayAll -gt 0) { $peakPercent = 100 * $peakRatePerHour / $inputDayAll }
    $minimumPeak = 100 / 24
    if ($peakPercent -lt $minimumPeak - 1e-9) {
        if ($peakFromRate) { Add-TsCheck $ctx Error 'PeakHour' ('Le débit de pointe mesuré ({0} msg/h pour l’’organisation) est inférieur au débit moyen sur 24 h ({1} msg/h) : vérifier le débit, son unité ou les messages par jour.' -f (Fn $peakRatePerHour 0), (Fn ($inputDayAll / 24) 0)) }
        else { Add-TsCheck $ctx Error 'PeakHour' ('La part de l’’heure de pointe ne peut pas être inférieure à la moyenne horaire (100 % ÷ 24 = {0} %).' -f (Fn $minimumPeak 1)) }
    }
    elseif ($load.PeakHours * $peakPercent / 100 -gt 1 - $load.OffHoursPercent / 100 + 1e-9) {
        Add-TsCheck $ctx Error 'PeakTooLong' ('{0} heure(s) de pointe à {1} % du jour portent {2} % du trafic, plus que les {3} % des heures ouvrées : réduire la durée de la pointe, sa part ou le trafic hors heures ouvrées.' -f (Fn $load.PeakHours 0), (Fn $peakPercent 1), (Fn ($load.PeakHours * $peakPercent) 0), (Fn (100 - $load.OffHoursPercent) 0))
    }
    if ($load.BurstFactor -lt 1) { Add-TsCheck $ctx Error 'Burst' 'Le facteur de rafale vaut au moins 1 (1 = pas de rafale au-delà de l’’heure de pointe).' }
    if (@($ctx.Checks | Where-Object { $_.Level -eq 'Error' }).Count -gt 0) {
        return (New-TsResult -Context $ctx -Scenario $s -Valid $false)
    }

    $failureLabel = $script:TsFailures[$topo.Failure]
    $growth = 1 + $load.GrowthPercent / 100
    # Hourly profile of the day: the peak hours, the other working hours, the hours outside the working day.
    $workingH = [double]$load.WorkingHours
    $offShare = $load.OffHoursPercent / 100
    $peakH = [double]$load.PeakHours
    $workingAvg = (1 - $offShare) / $workingH
    $peak = $peakPercent / 100
    if ($peak -lt $workingAvg - 1e-12) {
        Add-TsCheck $ctx Warning 'PeakBelowWorkingAverage' ('Pointe ({0} % du jour par heure) en dessous de la moyenne des heures ouvrées ({1} % par heure, {2} % du trafic sur {3} h) : la moyenne des heures ouvrées est retenue comme pointe.' -f (Fn ($peak * 100) 1), (Fn ($workingAvg * 100) 1), (Fn (100 * (1 - $offShare)) 0), (Fn $workingH 0))
        $peak = $workingAvg
    }
    $otherWorking = $(if ($workingH -gt $peakH) { ((1 - $offShare) - $peakH * $peak) / ($workingH - $peakH) } else { 0.0 })
    $offHour = $(if ($workingH -lt 24) { $offShare / (24 - $workingH) } else { 0.0 })
    $hourShares = [Collections.Generic.List[double]]::new()
    for ($h = 0; $h -lt 24; $h++) { $hourShares.Add($(if ($h -lt $peakH) { $peak } elseif ($h -lt $workingH) { $otherWorking } else { $offHour })) }
    $hourShares.Sort(); $hourShares.Reverse()
    $burst = $load.BurstFactor

    # ---------------------------------------------------------------- journaling (Mailbox role)
    # The Journaling agent of the Transport service on the Mailbox servers writes one journal report per journaled
    # message and journal recipient: the original message attached unaltered, and a summary of its envelope. The
    # reports are messages of their own: queue, Safety Net, shadow copies, network, held when the destination is down.
    $jr = $s.Journaling
    # Values shown after those of the load section.
    $journalCtx = New-TsContext
    $userMessages = 0.0; $userKB = 0.0
    foreach ($f in $flows) { $userMessages += $f.MessagesPerDay; $userKB += $f.MessagesPerDay * $f.AverageSizeKB }
    if ($jr.Enabled -and $edge) {
        Add-TsCheck $ctx Info 'JournalingOnMailbox' 'Journalisation : les rapports de journal sont écrits par les serveurs Mailbox (agent de journalisation), pas par l’’Edge. Si l’’archive externe est jointe par les Edge, saisir ses rapports comme un flux sortant (valeur « Rapports de journal par jour » du dimensionnement Mailbox).'
    }
    elseif ($jr.Enabled -and $jr.Percent -gt 0) {
        $directions = switch ($jr.Scope) { 'Internal' { @('Internal') } 'External' { @('Inbound', 'Outbound') } default { @('Inbound', 'Outbound', 'Internal') } }
        $inScope = @($flows | Where-Object { $_.Direction -in $directions })
        $share = $jr.Percent / 100 * $jr.Recipients
        $journalDay = 0.0; $journalKB = 0.0
        foreach ($f in $inScope) { $journalDay += $f.MessagesPerDay * $share; $journalKB += $f.MessagesPerDay * $share * ($f.AverageSizeKB + $jr.OverheadKB) }
        $msJournal = 'Microsoft : journalisation dans Exchange Server (journalisation d’’enveloppe)'
        if ($journalDay -gt 0) {
            $journalSize = $journalKB / $journalDay
            $flows += [pscustomobject]@{
                Name = 'Rapports de journal (calculé)'; Direction = $(if ($jr.Destination -eq 'Internal') { 'Internal' } else { 'Outbound' })
                MessagesPerDay = $journalDay; AverageSizeKB = $journalSize; FanOut = 1.0; HeldDuringOutage = [bool]$jr.HeldDuringOutage; Journal = $true
            }
            [void](Add-TsValue $journalCtx 'load' 'journal.scope' 'Journalisation : portée' ('{0} · {1} % · {2} destination(s) · {3}' -f $script:TsJournalScopes[$jr.Scope], (Fn $jr.Percent 0), (Fn $jr.Recipients 0), $script:TsJournalDestinations[$jr.Destination]) -Kind Input `
                    -Source $msJournal -Note 'Portée des règles de journal : messages internes (source et destination dans l’’organisation), externes (expéditeur ou destinataire hors de l’’organisation) ou tous. Une règle « tous les messages » peut journaliser à nouveau un message déjà journalisé par une autre règle : compter une destination de plus.')
            [void](Add-TsValue $journalCtx 'load' 'journal.messages' 'Rapports de journal par jour (organisation)' $journalDay -Unit 'msg/j' -Formula 'Σ flux dans la portée : messages par jour × part journalisée × destinations de journal' `
                    -Computation ('{0} × {1} % × {2}' -f (Fn (($inScope | ForEach-Object { $_.MessagesPerDay } | Measure-Object -Sum).Sum) 0), (Fn $jr.Percent 0), (Fn $jr.Recipients 0)) -Decimals 0 -Source $msJournal `
                    -Note 'Un rapport par message et par destination de journal, quel que soit le nombre de destinataires du message.')
            [void](Add-TsValue $journalCtx 'load' 'journal.size' 'Taille moyenne d’’un rapport de journal' $journalSize -Unit 'Ko' -Formula 'Taille du message journalisé + enveloppe (expéditeur, objet, Message-ID, destinataires)' `
                    -Computation ('moyenne pondérée des flux + {0} Ko' -f (Fn $jr.OverheadKB 1)) -Decimals 1 -Source $msJournal -Note 'Le rapport contient le message d’’origine en pièce jointe, inchangé : la journalisation double presque le volume des messages journalisés.')
            [void](Add-TsValue $journalCtx 'load' 'journal.increase' 'Hausse du volume traité par la journalisation' ($journalKB / $userKB * 100) -Unit '%' -Formula 'Volume des rapports ÷ volume des flux saisis' `
                    -Computation ('{0} Go ÷ {1} Go par jour' -f (Fn ($journalKB / 1048576) 1), (Fn ($userKB / 1048576) 1)) -Decimals 0)
            if ($jr.Destination -eq 'External') {
                Add-TsCheck $ctx Info 'JournalingExternal' ('Journalisation vers une archive externe : {0} rapports par jour ({1} Go) sortent de l’’organisation. S’’ils passent par des serveurs Edge, les ajouter en flux sortant à leur dimensionnement ; si l’’archive est injoignable, les rapports restent en file jusqu’’à l’’expiration (MessageExpirationTimeout), puis sont perdus sauf boîte de journalisation de secours.' -f (Fn $journalDay 0), (Fn ($journalKB / 1048576) 1))
            }
            if (-not $jr.HeldDuringOutage) {
                Add-TsCheck $ctx Info 'JournalingNotHeld' 'Rapports de journal non retenus pendant une panne : hypothèse d’’une destination toujours joignable (ou d’’une boîte de journalisation de secours qui reçoit les rapports non remis).'
            }
        }
    }

    $flowRows = [Collections.Generic.List[object]]::new()
    $inputDay = 0.0; $totalDay = 0.0; $totalKB = 0.0
    foreach ($f in $flows) {
        $day = $f.MessagesPerDay * $growth
        $perServer = $day / $alive
        $design = $perServer * $peak / 3600 * $burst
        $inputDay += $f.MessagesPerDay; $totalDay += $day; $totalKB += $day * $f.AverageSizeKB
        $flowRows.Add([pscustomobject]@{
                Name = $f.Name; Direction = $f.Direction; DirectionLabel = $script:TsDirections[$f.Direction]; MessagesPerDay = $f.MessagesPerDay
                WithGrowth = $day; PerServer = $perServer; AverageSizeKB = $f.AverageSizeKB; FanOut = $f.FanOut; Held = $f.HeldDuringOutage; Journal = [bool](Get-TsField $f 'Journal' $false)
                DesignRate = $design; DesignMbps = $design * $f.AverageSizeKB * 1024 * 8 / 1e6; VolumeGBPerDay = $perServer * $f.AverageSizeKB / 1048576
            })
    }
    $avgKB = $totalKB / $totalDay
    $mDay = $totalDay / $alive
    $rateAvg = $mDay / 86400
    $rateWorking = $mDay * $workingAvg / 3600
    $ratePeak = $mDay * $peak / 3600
    $rateDesign = $ratePeak * $burst

    [void](Add-TsValue $ctx 'load' 'load.servers' 'Serveurs déployés' $servers -Unit 'serveurs' -Formula 'Sites × serveurs par site' -Computation ('{0} × {1}' -f $sites, $perSite) -Kind Input -Decimals 0)
    [void](Add-TsValue $ctx 'load' 'load.alive' 'Serveurs restants pendant la panne' $alive -Unit 'serveurs' -Formula "Serveurs déployés − serveurs perdus ($($failureLabel.ToLower()))" -Computation ('{0} − {1}' -f $servers, $lost) -Decimals 0 `
            -Note 'Le trafic de toute l’’organisation doit passer par les serveurs restants.')
    [void](Add-TsValue $ctx 'load' 'load.input' $(if ($flows.Count -gt @($s.Flows | Where-Object { $_.MessagesPerDay -gt 0 }).Count) { 'Messages par jour (organisation, flux saisis et rapports de journal)' } else { 'Messages par jour (organisation, saisis)' }) $inputDay -Unit 'msg/j' -Formula 'Somme des flux' -Computation ((@($flows | ForEach-Object { Fn $_.MessagesPerDay 0 })) -join ' + ') -Kind Input -Decimals 0)
    [void](Add-TsValue $ctx 'load' 'load.growth' 'Croissance' $load.GrowthPercent -Unit '%' -Kind Input -Decimals 0)
    [void](Add-TsValue $ctx 'load' 'load.messages' 'Messages par jour avec la croissance' $totalDay -Unit 'msg/j' -Formula 'Messages par jour × (1 + croissance)' -Computation ('{0} × {1}' -f (Fn $inputDay 0), (Fn $growth 2)) -Decimals 0)
    [void](Add-TsValue $ctx 'load' 'load.perServer' 'Messages par jour et par serveur' $mDay -Unit 'msg/j' -Formula 'Messages par jour ÷ serveurs restants' -Computation ('{0} ÷ {1}' -f (Fn $totalDay 0), $alive) -Decimals 0)
    [void](Add-TsValue $ctx 'load' 'load.avgSize' 'Taille moyenne des messages' $avgKB -Unit 'Ko' -Formula 'Σ (messages × taille) ÷ Σ messages' -Computation ('{0} Ko ÷ {1}' -f (Fn $totalKB 0), (Fn $totalDay 0)) -Decimals 1)
    [void](Add-TsValue $ctx 'load' 'load.volume' 'Volume de messages par jour et par serveur' ($mDay * $avgKB / 1048576) -Unit 'Go' -Formula 'Messages par jour et par serveur × taille moyenne ÷ 1 048 576' -Computation ('{0} × {1} Ko ÷ 1 048 576' -f (Fn $mDay 0), (Fn $avgKB 1)) -Decimals 1)
    [void](Add-TsValue $ctx 'load' 'load.avgRate' 'Débit moyen sur 24 h (information)' $rateAvg -Unit 'msg/s' -Formula 'Messages par jour et par serveur ÷ 86 400 s' -Computation ('{0} ÷ 86 400' -f (Fn $mDay 0)) -Decimals 2)
    [void](Add-TsValue $ctx 'load' 'load.workingHours' 'Heures ouvrées par jour' $workingH -Unit 'h' -Kind Input -Decimals 0 -Note 'Heures pendant lesquelles passe l’’essentiel du trafic. 24 = trafic réparti sur toute la journée.')
    [void](Add-TsValue $ctx 'load' 'load.offHours' 'Trafic hors heures ouvrées' $load.OffHoursPercent -Unit '%' -Kind Input -Decimals 0)
    [void](Add-TsValue $ctx 'load' 'load.workingRate' 'Débit moyen des heures ouvrées' $rateWorking -Unit 'msg/s' -Formula 'Messages par jour et par serveur × (1 − part hors heures ouvrées) ÷ heures ouvrées ÷ 3 600 s' `
            -Computation ('{0} × {1} ÷ {2} ÷ 3 600 = {3} msg/h' -f (Fn $mDay 0), (Fn (1 - $offShare) 2), (Fn $workingH 0), (Fn ($rateWorking * 3600) 0)) -Decimals 2 `
            -Note 'Trafic qui continue pendant une vidange en journée.')
    if ($peakFromRate) {
        [void](Add-TsValue $ctx 'load' 'load.peakRateInput' 'Débit de pointe mesuré (organisation)' $load.PeakRate -Unit $script:TsPeakRateUnits[$load.PeakRateUnit] -Kind Input -Decimals $(if ($load.PeakRateUnit -eq 'PerSecond') { 2 } else { 0 }) `
                -Note 'Heure la plus chargée de l’’existant, pour toute l’’organisation, le jour des messages par jour saisis.')
        [void](Add-TsValue $ctx 'load' 'load.peakShare' 'Part du trafic journalier dans l’’heure de pointe' $peakPercent -Unit '%' -Formula 'Débit de pointe mesuré (msg/h) ÷ messages par jour (organisation, saisis)' `
                -Computation ('{0} ÷ {1}' -f (Fn $peakRatePerHour 0), (Fn $inputDayAll 0)) -Decimals 1 -Note 'La croissance et la répartition sur les serveurs restants s’’appliquent ensuite comme au reste du trafic.')
    }
    else {
        [void](Add-TsValue $ctx 'load' 'load.peakShare' 'Part du trafic journalier dans l’’heure de pointe' $load.PeakHourPercent -Unit '%' -Kind Input -Decimals 1 `
                -Note 'À mesurer sur l’’existant (suivi des messages par heure, Exchange Log Report), ou saisir le débit de pointe mesuré. Avec 24 heures ouvrées, 4,2 % = trafic réparti uniformément.')
    }
    [void](Add-TsValue $ctx 'load' 'load.peakHours' 'Durée de la pointe' $peakH -Unit 'h' -Kind Input -Decimals 0 `
            -Note ('Les autres heures ouvrées portent {0} % du jour chacune, les heures hors journée {1} %.' -f (Fn ($otherWorking * 100) 1), (Fn ($offHour * 100) 2)))
    [void](Add-TsValue $ctx 'load' 'load.peakRate' 'Débit de l’’heure de pointe' $ratePeak -Unit 'msg/s' -Formula 'Messages par jour et par serveur × part de l’’heure de pointe ÷ 3 600 s' `
            -Computation ('{0} × {1} ÷ 3 600 = {2} msg/h' -f (Fn $mDay 0), (Fn $peak 3), (Fn ($ratePeak * 3600) 0)) -Decimals 2 `
            -Note ('Organisation : {0} messages pendant l’’heure de pointe, croissance comprise.' -f (Fn ($totalDay * $peak) 0)))
    [void](Add-TsValue $ctx 'load' 'load.burst' 'Facteur de rafale' $burst -Unit '×' -Kind Input -Decimals 2 -Note 'Pointes de quelques minutes au-delà de la moyenne de l’’heure de pointe (campagnes, rafales applicatives). 1 = aucune.')
    [void](Add-TsValue $ctx 'load' 'load.designRate' 'Débit de dimensionnement' $rateDesign -Unit 'msg/s' -Formula 'Débit de l’’heure de pointe × facteur de rafale' -Computation ('{0} × {1}' -f (Fn $ratePeak 2), (Fn $burst 2)) -Decimals 2)
    # Load factors of the calibration models at the design rate.
    $transportRules = [double]$load.TransportRules
    $tlsShare = $load.TlsPercent / 100
    $perSession = [double]$load.MessagesPerSession
    # A profile that measured journal reports (Range.MaxJournalPerSec, journal term of the CPU model) costs them as a
    # factor of their own: the Journaling agent writes them on the server, they are not received over SMTP (no
    # session, no MB received). The models without a journal term keep the whole load (Resolve-TsModelLoad).
    $journalFactor = [bool]($cal -and $cal.Range.MaxJournalPerSec -gt 0 -and [double]$cal.Models.CpuPercent.PerJournal -gt 0)
    $journalShare = 0.0; $journalKBShare = 0.0
    if ($journalFactor) {
        foreach ($row in @($flowRows | Where-Object { $_.Journal })) { $journalShare += $row.PerServer / $mDay; $journalKBShare += $row.PerServer * $row.AverageSizeKB / ($mDay * $avgKB) }
    }
    $newLoad = {
        param([double]$Rate)
        $plain = New-TsLoad -Rate $Rate -SizeKB $avgKB -Rules $transportRules -MessagesPerSession $perSession -TlsShare $tlsShare
        if ($journalShare -le 0) { return $plain }
        $smtpKB = $(if ($journalShare -lt 1) { $avgKB * (1 - $journalKBShare) / (1 - $journalShare) } else { 0.0 })
        $split = New-TsLoad -Rate ($Rate * (1 - $journalShare)) -SizeKB $smtpKB -Rules $transportRules -MessagesPerSession $perSession -TlsShare $tlsShare -JournalRate ($Rate * $journalShare)
        $split.Plain = $plain
        return $split
    }
    $designLoad = & $newLoad $rateDesign
    if ($journalShare -gt 0) {
        [void](Add-TsValue $ctx 'load' 'load.smtpRate' 'Messages reçus par SMTP au débit de dimensionnement' $designLoad.Rate -Unit 'msg/s' -Formula 'Débit de dimensionnement − rapports de journal' `
                -Computation ('{0} − {1}' -f (Fn $rateDesign 2), (Fn $designLoad.JournalRate 2)) -Decimals 2 -Source $calLabel `
                -Note 'Le profil de calibration a mesuré les rapports de journal comme un facteur à part (compteur Journal Reports Created/sec) : ils ne passent pas par une session SMTP reçue.')
        [void](Add-TsValue $ctx 'load' 'load.journalRate' 'Rapports de journal écrits par seconde' $designLoad.JournalRate -Unit 'rapports/s' -Formula 'Débit de dimensionnement × part des rapports de journal dans les messages' `
                -Computation ('{0} × {1}' -f (Fn $rateDesign 2), (Fn $journalShare 3)) -Decimals 2)
    }
    $smtpText = $(if ($journalShare -gt 0) { 'Messages reçus par SMTP' } else { 'Débit de dimensionnement' })
    [void](Add-TsValue $ctx 'load' 'load.designMBps' 'Volume de messages au débit de dimensionnement' $designLoad.MBps -Unit 'Mo/s' -Formula "$smtpText × taille moyenne ÷ 1 024" `
            -Computation ('{0} × {1} ÷ 1 024' -f (Fn $designLoad.Rate 2), (Fn ($designLoad.MBps * 1024 / [Math]::Max(1e-9, $designLoad.Rate)) 1)) -Decimals 2 -Note 'Le coût de la taille (analyse du contenu, écriture dans mail.que) suit ce volume, pas le nombre de messages.')
    [void](Add-TsValue $ctx 'load' 'load.rules' $(if ($edge) { 'Règles de transport Edge (Get-TransportRule sur l’’Edge)' } else { 'Règles de transport de l’’organisation' }) $transportRules -Unit 'règles' -Kind Input -Decimals 0 `
            -Note 'Chaque message est évalué contre toutes les règles actives : le coût suit messages × règles.')
    [void](Add-TsValue $ctx 'load' 'load.perSession' 'Messages par session SMTP reçue' $perSession -Unit 'messages' -Kind Assumption -Decimals 1 `
            -Note $(if ($edge) { 'Internet : la plupart des expéditeurs ouvrent une session par message ; les grands hébergeurs en envoient plusieurs. 1 = hypothèse prudente.' } else { 'Entre serveurs Exchange, les sessions SMTP sont réutilisées pour plusieurs messages.' }))
    [void](Add-TsValue $ctx 'load' 'load.sessions' 'Sessions SMTP ouvertes par seconde' $designLoad.Sessions -Unit 'sessions/s' -Formula "$smtpText ÷ messages par session" -Computation ('{0} ÷ {1}' -f (Fn $designLoad.Rate 2), (Fn $perSession 1)) -Decimals 2)
    [void](Add-TsValue $ctx 'load' 'load.tls' 'Part des sessions en TLS' $load.TlsPercent -Unit '%' -Kind Assumption -Decimals 0 `
            -Note 'Exchange négocie TLS (STARTTLS) dès que l’’autre serveur le propose : la quasi-totalité du trafic Internet et tout le trafic entre serveurs Exchange.')
    foreach ($v in $journalCtx.Sections['load'].Values) { $ctx.Sections['load'].Values.Add($v); $ctx.Values[$v.Id] = $v }
    # ---------------------------------------------------------------- queue database
    $residence = $res.ResidenceSeconds
    $transitMsgs = 0.0; $transitKB = 0.0
    # Journal reports have no shadow copy (REF-MAILBOX: 3 SMTP sends per journaled message, not 4): their part is kept apart.
    $jTransitMsgs = 0.0; $jTransitKB = 0.0; $jBacklogMsgs = 0.0; $jBacklogKB = 0.0; $jSafetyNetMsgs = 0.0; $jSafetyNetKB = 0.0
    foreach ($row in $flowRows) {
        $transitMsgs += $row.DesignRate * $residence; $transitKB += $row.DesignRate * $residence * $row.AverageSizeKB
        if ($row.Journal) { $jTransitMsgs += $row.DesignRate * $residence; $jTransitKB += $row.DesignRate * $residence * $row.AverageSizeKB }
    }
    $expirationH = $res.MessageExpirationHours
    $outageH = [Math]::Min($res.OutageHours, $expirationH)
    $outageDays = [Math]::Floor($outageH / 24)
    $outageRest = $outageH - 24 * $outageDays
    # Worst window of the outage: whole days, then the busiest hours of the hourly profile.
    $restShare = 0.0; $restLeft = $outageRest
    foreach ($share in $hourShares) { if ($restLeft -le 0) { break }; $restShare += $share * [Math]::Min(1.0, $restLeft); $restLeft -= 1 }
    $fraction = $outageDays + [Math]::Min(1.0, $restShare)
    $backlogMsgs = 0.0; $backlogKB = 0.0
    foreach ($row in @($flowRows | Where-Object { $_.Held })) {
        $backlogMsgs += $row.PerServer * $fraction; $backlogKB += $row.PerServer * $fraction * $row.AverageSizeKB
        if ($row.Journal) { $jBacklogMsgs += $row.PerServer * $fraction; $jBacklogKB += $row.PerServer * $fraction * $row.AverageSizeKB }
    }
    if ($res.OutageHours -gt $expirationH) {
        Add-TsCheck $ctx Info 'OutageCapped' ('La panne retenue ({0} h) dépasse l’’expiration des messages ({1} h) : au-delà, les messages expirent (rapport de non-remise) et quittent la file ; l’’accumulation est plafonnée à {1} h.' -f (Fn $res.OutageHours 0), (Fn $expirationH 0))
    }
    $heldNames = @($flowRows | Where-Object { $_.Held } | ForEach-Object { $_.Name })

    [void](Add-TsValue $ctx 'queue' 'queue.residence' 'Temps de séjour d’’un message en transit' $residence -Unit 's' -Kind Assumption -Decimals 0 `
            -Note $(if ($cal -and $cal.ResidenceSeconds -gt 0) { 'Durée moyenne entre la réception et l’’accusé du saut suivant, sans panne. Mesuré sur la référence : {0} s (messages en file ÷ débit, palier le plus long) ; la valeur saisie garde une marge pour un saut suivant lent.' -f (Fn $cal.ResidenceSeconds 1) } else { 'Durée moyenne entre la réception et l’’accusé du saut suivant, sans panne.' }))
    [void](Add-TsValue $ctx 'queue' 'queue.transit' 'Messages en transit' $transitMsgs -Unit 'messages' -Formula 'Loi de Little : débit de dimensionnement × temps de séjour' -Computation ('{0} × {1} s' -f (Fn $rateDesign 2), (Fn $residence 0)) -Decimals 0)
    [void](Add-TsValue $ctx 'queue' 'queue.expiration' 'Expiration des messages (MessageExpirationTimeout)' $expirationH -Unit 'h' -Kind Input -Decimals 0 -Source 'Microsoft : 2 jours par défaut')
    [void](Add-TsValue $ctx 'queue' 'queue.outageInput' 'Panne du saut suivant à absorber' $res.OutageHours -Unit 'h' -Kind Input -Decimals 0 `
            -Note $(if ($edge) { 'Serveurs Mailbox injoignables (entrant) ou Internet / relais aval injoignable (sortant) : les messages des flux retenus restent sur l’’Edge.' } else { 'Saut suivant injoignable (Edge, serveurs de boîtes, relais aval) : les messages des flux retenus restent en file.' }))
    [void](Add-TsValue $ctx 'queue' 'queue.outage' 'Durée d’’accumulation' $outageH -Unit 'h' -Formula 'min(panne, expiration des messages)' -Computation ('min({0}, {1})' -f (Fn $res.OutageHours 0), (Fn $expirationH 0)) -Decimals 0)
    [void](Add-TsValue $ctx 'queue' 'queue.fraction' 'Part du trafic journalier accumulée' $fraction -Unit 'jour(s)' -Formula 'Jours entiers + parts des heures les plus chargées de la journée pour les heures restantes' `
            -Computation ('{0} + {1} ({2} h : {3} h de pointe à {4} %, puis heures ouvrées à {5} %, puis hors journée à {6} %)' -f $outageDays, (Fn ([Math]::Min(1.0, $restShare)) 3), (Fn $outageRest 1),
                (Fn ([Math]::Min($peakH, $outageRest)) 0), (Fn ($peak * 100) 1), (Fn ($otherWorking * 100) 1), (Fn ($offHour * 100) 2)) -Decimals 2 `
            -Note 'Pire fenêtre : une panne de moins d’’un jour tombe sur les heures les plus chargées (la pointe, puis le reste de la journée de travail).')
    [void](Add-TsValue $ctx 'queue' 'queue.backlog' 'Messages accumulés pendant la panne' $backlogMsgs -Unit 'messages' -Formula 'Σ flux retenus : messages par jour et par serveur × part accumulée' `
            -Computation ('flux retenus : {0}' -f $(if ($heldNames) { $heldNames -join ', ' } else { 'aucun' })) -Decimals 0)

    $safetyNetMsgs = 0.0; $safetyNetKB = 0.0; $shadowMsgs = 0.0; $shadowKB = 0.0; $shadowActive = $false; $safetyNetH = 0.0
    if ($edge) {
        [void](Add-TsValue $ctx 'queue' 'queue.edgeRule' 'Safety Net et redondance shadow' 'Non concernés (Edge Transport)' -Kind Rule `
                -Formula 'Le rôle Edge Transport ne porte ni Safety Net ni la redondance shadow : seul le rôle Mailbox les porte.')
        Add-TsCheck $ctx Info 'EdgeRule' 'Edge Transport : Safety Net et la redondance shadow ne concernent que le rôle Mailbox ; leurs paramètres sont ignorés pour ce scénario.'
    }
    else {
        $safetyNetH = [Math]::Max($res.SafetyNetHoldTimeHours, $res.ReplayLagHours)
        if ($res.ReplayLagHours -gt $res.SafetyNetHoldTimeHours) {
            Add-TsCheck $ctx Info 'ReplayLag' ('Délai de relecture des copies décalées ({0} h) supérieur à SafetyNetHoldTime ({1} h) : Safety Net est dimensionné sur le délai de relecture, comme le calculateur Microsoft.' -f (Fn $res.ReplayLagHours 0), (Fn $res.SafetyNetHoldTimeHours 0))
        }
        foreach ($row in $flowRows) {
            $safetyNetMsgs += $row.PerServer * $safetyNetH / 24; $safetyNetKB += $row.PerServer * $safetyNetH / 24 * $row.AverageSizeKB
            if ($row.Journal) { $jSafetyNetMsgs += $row.PerServer * $safetyNetH / 24; $jSafetyNetKB += $row.PerServer * $safetyNetH / 24 * $row.AverageSizeKB }
        }
        # Shadow boundary: the DAG, or the Active Directory site for servers outside a DAG. The queue is sized
        # on the busiest server, the one that keeps shadow copies for a partner when one is left.
        switch ($topo.Failure) {
            'OneServer' { $bestSite = $(if ($sites -ge 2) { $perSite } else { $perSite - 1 }); $worstSite = $perSite - 1 }
            'TwoServers' { $bestSite = $(if ($sites -ge 2) { $perSite } else { $perSite - 2 }); $worstSite = $(if ($sites -ge 2) { $perSite - 1 } else { $perSite - 2 }) }
            default { $bestSite = $perSite; $worstSite = $perSite }
        }
        if ($worstSite -lt 1) { $worstSite = $perSite }
        if ($topo.Dag) {
            $shadowActive = $res.ShadowRedundancy -and $alive -ge 2
            $alone = $alive -lt 2
            $boundaryText = 'au moins deux serveurs restants dans le DAG'
            $boundaryComputation = '{0} serveur(s) restant(s) dans le DAG' -f $alive
        }
        else {
            $shadowActive = $res.ShadowRedundancy -and $bestSite -ge 2
            $alone = $worstSite -lt 2
            $boundaryText = 'au moins deux serveurs restants dans un même site AD (sans DAG, la copie shadow reste dans le site)'
            $boundaryComputation = 'site le mieux doté : {0} serveur(s), le moins doté : {1}' -f $bestSite, $worstSite
        }
        if ($res.ShadowRedundancy -and -not $shadowActive) {
            if ($topo.Dag) { Add-TsCheck $ctx Warning 'ShadowInactive' 'Redondance shadow activée mais un seul serveur reste dans le DAG : aucune copie shadow n’’est possible, les messages en file ne sont protégés que par Safety Net.' }
            else { Add-TsCheck $ctx Warning 'ShadowInactive' 'Redondance shadow activée mais aucun site ne garde deux serveurs : sans DAG, la copie shadow est faite sur un autre serveur Mailbox du même site AD, elle est donc impossible. Les messages en file ne sont protégés que par Safety Net.' }
        }
        elseif ($res.ShadowRedundancy -and $alone) {
            Add-TsCheck $ctx Warning 'ShadowAlone' ('Sans DAG, un serveur peut rester seul dans son site après la panne retenue ({0}) : ses messages n’’ont pas de copie shadow. La file est dimensionnée sur le serveur le plus chargé, celui qui garde aussi les copies shadow d’’un voisin.' -f $failureLabel.ToLower())
        }
        if ($shadowActive) {
            $shadowMsgs = ($transitMsgs - $jTransitMsgs) + ($backlogMsgs - $jBacklogMsgs) + ($safetyNetMsgs - $jSafetyNetMsgs)
            $shadowKB = ($transitKB - $jTransitKB) + ($backlogKB - $jBacklogKB) + ($safetyNetKB - $jSafetyNetKB)
        }
        [void](Add-TsValue $ctx 'queue' 'queue.safetyNetHold' 'Durée de rétention Safety Net' $safetyNetH -Unit 'h' -Formula 'max(SafetyNetHoldTime, délai de relecture)' -Computation ('max({0}, {1})' -f (Fn $res.SafetyNetHoldTimeHours 0), (Fn $res.ReplayLagHours 0)) `
                -Kind Rule -Decimals 1 -Source 'Microsoft : SafetyNetHoldTime 2 jours par défaut' -Note 'Rôle Mailbox : chaque message traité est gardé dans Safety Net, même sans boîte aux lettres sur le serveur.')
        [void](Add-TsValue $ctx 'queue' 'queue.safetyNet' 'Messages dans Safety Net' $safetyNetMsgs -Unit 'messages' -Formula 'Messages par jour et par serveur × rétention (jours)' -Computation ('{0} × {1}' -f (Fn $mDay 0), (Fn ($safetyNetH / 24) 2)) -Decimals 0)
        [void](Add-TsValue $ctx 'queue' 'queue.shadowActive' 'Redondance shadow effective' $shadowActive -Kind Rule -Formula ('ShadowRedundancyEnabled et {0}' -f $boundaryText) `
                -Computation ('{0} ; {1}' -f $(if ($res.ShadowRedundancy) { 'activée' } else { 'désactivée' }), $boundaryComputation) -Source 'Microsoft : frontière de haute disponibilité du transport = DAG, ou site AD hors DAG')
        [void](Add-TsValue $ctx 'queue' 'queue.shadow' 'Copies shadow détenues pour les autres serveurs' $shadowMsgs -Unit 'messages' -Formula 'Transit + panne + Safety Net (shadow Safety Net compris), si shadow effective' `
                -Computation $(if ($jSafetyNetMsgs -gt 0) { '({0} + {1} + {2}) − rapports de journal {3}' -f (Fn $transitMsgs 0), (Fn $backlogMsgs 0), (Fn $safetyNetMsgs 0), (Fn ($jTransitMsgs + $jBacklogMsgs + $jSafetyNetMsgs) 0) } else { '{0} + {1} + {2}' -f (Fn $transitMsgs 0), (Fn $backlogMsgs 0), (Fn $safetyNetMsgs 0) }) -Decimals 0 `
                -Note $(if ($jSafetyNetMsgs -gt 0) { 'Chaque serveur garde, pour ses voisins, autant de copies shadow que ses voisins en gardent pour lui. Les rapports de journal, écrits sur le serveur, n’’ont pas de copie shadow (REF-MAILBOX : 3 envois SMTP par message journalisé, pas 4).' } else { 'Chaque serveur garde, pour ses voisins, autant de copies shadow que ses voisins en gardent pour lui.' }))
    }
    $queueMsgs = $transitMsgs + $backlogMsgs + $safetyNetMsgs + $shadowMsgs
    $dataGB = ($transitKB + $backlogKB + $safetyNetKB + $shadowKB) / 1048576
    $ese = 1.0; $eseKind = 'Assumption'; $eseNote = 'Non calibré : base comptée à la taille des messages, sans pages ESE, index ni espace libre.'
    if ($cal -and $cal.Backlog -and $cal.Backlog.EseOverheadFactor -gt 0) { $ese = $cal.Backlog.EseOverheadFactor; $eseKind = 'Calibration'; $eseNote = 'Croissance de mail.que ÷ taille des messages injectés pendant le palier backlog.' }
    elseif ($cal -and $cal.Role -eq 'Mailbox' -and $cal.Retention -and $cal.Retention.Factor -gt 1) {
        # On a Mailbox server Safety Net keeps every message processed: the growth of mail.que per MB processed is
        # the stored size of the messages kept, measured over the whole load chain instead of one backlog step.
        $ese = $cal.Retention.Factor; $eseKind = 'Calibration'
        $eseNote = 'Mesuré sur un serveur Mailbox, où Safety Net garde chaque message traité : croissance de mail.que ÷ Mo traités (messages reçus et rapports de journal), +{0} Go pour {1} Go.' -f (Fn ($cal.Retention.GrowthMB / 1024) 1), (Fn ($cal.Retention.ProcessedMB / 1024) 1)
    }
    elseif ($cal -and $cal.Backlog -and $cal.Backlog.EseNote) {
        $eseNote = 'Non mesurable pendant la calibration ({0}) : base comptée à la taille des messages.' -f $cal.Backlog.EseNote
        Add-TsCheck $ctx Warning 'EseNotCalibrated' ('Facteur ESE de mail.que non mesuré par le palier backlog ({0}) : la base est comptée à la taille des messages. Refaire un palier backlog plus long pour le mesurer.' -f $cal.Backlog.EseNote)
    }
    elseif ($cal) { Add-TsCheck $ctx Warning 'EseNotCalibrated' 'Facteur ESE de mail.que non calibré (pas de palier backlog dans le profil) : la base est comptée à la taille des messages, sans le surcoût des pages, des index et de l’’espace libre.' }
    $emptyGB = [double]$ref.Lab.EmptyMailQueGB
    # The space of delivered messages is only reused after a reclamation of the queue database (transport restart,
    # online defragmentation at QueueDatabaseOnlineDefragSchedule): until then, everything processed stays in mail.que.
    $reclaimDays = [double]$res.SpaceReclaimDays
    $windowKB = $mDay * $reclaimDays * $avgKB
    $journalDayKB = 0.0
    if ($shadowActive) {
        foreach ($row in @($flowRows | Where-Object { $_.Journal })) { $journalDayKB += $row.PerServer * $row.AverageSizeKB }
        $windowKB = 2 * $windowKB - $reclaimDays * $journalDayKB
    }
    $windowFactor = $ese; $windowKind = $eseKind; $windowNote = 'Facteur ESE des messages en file.'
    if ($cal -and $cal.Retention -and $cal.Retention.Factor -gt $windowFactor) {
        $windowFactor = $cal.Retention.Factor; $windowKind = 'Calibration'
        $windowNote = 'Croissance de mail.que mesurée par Mo traité, file presque vide : +{0} Go pour {1} Go de messages.' -f (Fn ($cal.Retention.GrowthMB / 1024) 1), (Fn ($cal.Retention.ProcessedMB / 1024) 1)
    }
    $windowGB = $windowKB / 1048576 * $windowFactor
    $mailQueGB = $emptyGB + $dataGB * $ese + $windowGB
    $logsGB = $bp.LogReserveFactor * $bp.CheckpointDepthMaxMB / 1024
    $otherGB = $sto.OtherTransportDataGB
    $queueContentGB = $mailQueGB + $logsGB + $otherGB

    [void](Add-TsValue $ctx 'queue' 'queue.messages' 'Messages dans mail.que au pire moment' $queueMsgs -Unit 'messages' -Formula $(if ($edge) { 'Transit + panne' } else { 'Transit + panne + Safety Net + copies shadow' }) `
            -Computation $(if ($edge) { '{0} + {1}' -f (Fn $transitMsgs 0), (Fn $backlogMsgs 0) } else { '{0} + {1} + {2} + {3}' -f (Fn $transitMsgs 0), (Fn $backlogMsgs 0), (Fn $safetyNetMsgs 0), (Fn $shadowMsgs 0) }) -Decimals 0)
    [void](Add-TsValue $ctx 'queue' 'queue.data' 'Données des messages' $dataGB -Unit 'Go' -Formula 'Σ messages × taille du flux ÷ 1 048 576' -Decimals 2)
    [void](Add-TsValue $ctx 'queue' 'queue.ese' 'Facteur ESE (taille de la base ÷ données)' $ese -Unit '×' -Kind $eseKind -Decimals 2 -Source $calLabel -Note $eseNote)
    [void](Add-TsValue $ctx 'queue' 'queue.empty' 'Base mail.que vide' $emptyGB -Unit 'Go' -Kind Lab -Decimals 1 -Source 'REF-EDGE : mail.que = 503,9 Mo, file vide')
    [void](Add-TsValue $ctx 'queue' 'queue.reclaimDays' 'Jours entre deux récupérations de l’’espace de mail.que' $reclaimDays -Unit 'jour(s)' -Kind Input -Decimals 1 `
            -Note 'Mesuré sur REF-EDGE : l’’espace des messages remis n’’est pas réutilisé tant que le service tourne (+4,9 Go pour 3 Go traités, 64 messages en file au plus) ; il l’’est après un redémarrage du transport et après la défragmentation en ligne (QueueDatabaseOnlineDefragSchedule, 01:00 chaque jour). 0 = non compté.')
    [void](Add-TsValue $ctx 'queue' 'queue.window' 'Messages remis dont l’’espace n’’est pas encore récupéré' $windowGB -Unit 'Go' `
            -Formula $(if ($journalDayKB -gt 0) { '(Messages par jour et par serveur × taille moyenne × 2 (copies shadow) − rapports de journal, sans copie shadow) × jours × facteur' } elseif ($shadowActive) { 'Messages par jour et par serveur × jours × taille moyenne × 2 (copies shadow) × facteur' } else { 'Messages par jour et par serveur × jours × taille moyenne × facteur' }) `
            -Computation $(if ($journalDayKB -gt 0) { '({0} × {1} Ko × 2 − {2} Ko) × {3} ÷ 1 048 576 × {4}' -f (Fn $mDay 0), (Fn $avgKB 1), (Fn $journalDayKB 0), (Fn $reclaimDays 1), (Fn $windowFactor 2) } else { '{0} × {1} × {2} Ko{3} ÷ 1 048 576 × {4}' -f (Fn $mDay 0), (Fn $reclaimDays 1), (Fn $avgKB 1), $(if ($shadowActive) { ' × 2' } else { '' }), (Fn $windowFactor 2) }) `
            -Kind $windowKind -Decimals 1 -Source $calLabel -Note ('{0} S’’ajoute au pire moment : une panne peut survenir juste avant la récupération suivante.' -f $windowNote))
    if (-not $edge -and $reclaimDays -gt 0) { Add-TsCheck $ctx Info 'ReclaimMeasuredOnEdge' 'Réutilisation de l’’espace de mail.que mesurée sur un Edge Transport (REF-EDGE) : appliquée au rôle Mailbox par analogie, à confirmer par une calibration Mailbox.' }
    [void](Add-TsValue $ctx 'queue' 'queue.mailQue' 'Taille de mail.que' $mailQueGB -Unit 'Go' -Formula 'Base vide + données en file × facteur ESE + messages remis non récupérés' -Computation ('{0} + {1} × {2} + {3}' -f (Fn $emptyGB 1), (Fn $dataGB 2), (Fn $ese 2), (Fn $windowGB 1)) -Decimals 1)
    [void](Add-TsValue $ctx 'queue' 'queue.logs' 'Journaux de transactions de la file' $logsGB -Unit 'Go' -Formula '3 × DatabaseCheckPointDepthMax' -Computation ('3 × {0} Mo' -f $bp.CheckpointDepthMaxMB) -Kind Microsoft -Decimals 2 `
            -Source $msBp -Note 'Espace que back pressure garde libre (niveau haut de UsedDiskSpace) ; journalisation circulaire.')
    [void](Add-TsValue $ctx 'queue' 'queue.other' 'Autres données de transport (Temp, IpFilter, réputation)' $otherGB -Unit 'Go' -Kind Assumption -Decimals 1 -Source 'Mesuré sur REF-EDGE : 0,04 Go')
    [void](Add-TsValue $ctx 'queue' 'queue.content' 'Contenu du dossier de la file d’’attente' $queueContentGB -Unit 'Go' -Formula 'mail.que + journaux + autres données' -Computation ('{0} + {1} + {2}' -f (Fn $mailQueGB 1), (Fn $logsGB 2), (Fn $otherGB 1)) -Decimals 1)
    if ($mailQueGB -gt $ref.Exchange.MaxQueueDatabaseGB) {
        Add-TsCheck $ctx Warning 'QueueTooLarge' ('mail.que atteindrait {0} Go : au-delà de {1} Go (limite du calculateur Microsoft), ajouter des serveurs ou réduire la panne, l’’expiration ou Safety Net.' -f (Fn $mailQueGB 0), (Fn $ref.Exchange.MaxQueueDatabaseGB 0))
    }
    $queueParts = @(
        [pscustomobject]@{ Id = 'empty'; Label = 'Base vide'; Messages = 0; GB = $emptyGB }
        [pscustomobject]@{ Id = 'transit'; Label = 'Transit'; Messages = $transitMsgs; GB = $transitKB / 1048576 * $ese }
        [pscustomobject]@{ Id = 'backlog'; Label = 'Panne du saut suivant'; Messages = $backlogMsgs; GB = $backlogKB / 1048576 * $ese }
        [pscustomobject]@{ Id = 'safetynet'; Label = 'Safety Net'; Messages = $safetyNetMsgs; GB = $safetyNetKB / 1048576 * $ese }
        [pscustomobject]@{ Id = 'shadow'; Label = 'Copies shadow'; Messages = $shadowMsgs; GB = $shadowKB / 1048576 * $ese }
        [pscustomobject]@{ Id = 'retained'; Label = 'Messages remis non récupérés'; Messages = 0; GB = $windowGB }
        [pscustomobject]@{ Id = 'logs'; Label = 'Journaux'; Messages = 0; GB = $logsGB }
        [pscustomobject]@{ Id = 'other'; Label = 'Autres données'; Messages = 0; GB = $otherGB }
    )
    # ---------------------------------------------------------------- calibration
    if (-not $cal) {
        Add-TsCheck $ctx Warning 'NoCalibration' 'Aucun profil de calibration : processeur, mémoire et IOPS ne sont pas calculés. Mesurer un serveur de référence (calibration\Measure-TransportLoad.ps1), puis importer le profil.'
    }
    else {
        if ($cal.Reference) {
            if ($missingProfile) {
                Add-TsCheck $ctx Warning 'CalibrationMissing' ('Profil de calibration « {0} » du scénario introuvable : le profil de référence est utilisé à la place. Remettre le fichier à côté du scénario ou importer le profil à nouveau.' -f $s.CalibrationPath)
            }
            Add-TsCheck $ctx Info 'ReferenceProfile' ('Profil de référence « {0} » : mesures du labo, dimensionnement générique. Si un serveur Exchange du client est disponible, le mesurer (calibration\Measure-TransportLoad.ps1) et importer son profil ; sinon, adapter le profil au contexte (ajustements processeur, E/S, mémoire au repos).' -f $cal.Name)
            if (-not $edge -and $adj.MemoryAtRestGB -le 0 -and $cal.Models.UsedMemoryMB) {
                Add-TsCheck $ctx Info 'ReferenceMemoryAtRest' ('Mémoire au repos du profil Mailbox de référence : {0} Go, la mémoire des bases de boîtes du labo déduite. Elle comprend IIS et l’’indexation, présents sur tout serveur Mailbox ; si celle d’’un serveur du client est connue, la saisir dans « Mémoire au repos ».' -f (Fn ($cal.Models.UsedMemoryMB.Intercept / 1024) 1))
            }
        }
        if ($cal.Role -and $cal.Role -ne $s.Role) {
            Add-TsCheck $ctx Warning 'CalibrationRole' ('Le profil de calibration a été mesuré sur un serveur {0}, le scénario porte sur le rôle {1} : les consommations ne sont pas transposables.' -f $script:TsRoles[$cal.Role], $script:TsRoles[$s.Role])
        }
        if ($cal.MaxRate -gt 0 -and $rateDesign -gt 1.5 * $cal.MaxRate) {
            Add-TsCheck $ctx Warning 'Extrapolation' ('Débit de dimensionnement ({0} msg/s par serveur) au-delà de 1,5 × le débit le plus élevé mesuré ({1} msg/s) : extrapolation, refaire un palier de calibration plus chargé.' -f (Fn $rateDesign 1), (Fn $cal.MaxRate 1))
        }
        $weak = @(foreach ($name in 'CpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'QueueReadIops', 'QueueWriteIops') {
                $model = $cal.Models[$name]
                if ($model -and $model.Points -ge 3 -and $model.R2 -lt 0.8) { '{0} (R² {1})' -f $name, (Fn $model.R2 2) }
            })
        if ($weak) { Add-TsCheck $ctx Warning 'WeakModel' ('Modèle de calibration peu linéaire : {0}. Vérifier les paliers (durée, charge stable).' -f ($weak -join ', ')) }
        $cpuTerms = $cal.Models.CpuPercent
        $range = $cal.Range
        if ($cpuTerms.PerMBps -gt 0 -and $range -and $range.MaxSizeKB -gt 0) {
            if ($avgKB -gt 1.5 * $range.MaxSizeKB -or $avgKB -lt $range.MinSizeKB / 1.5) {
                Add-TsCheck $ctx Warning 'SizeExtrapolation' ('Taille moyenne des messages ({0} Ko) hors de la plage mesurée ({1} à {2} Ko) : le coût de la taille est extrapolé.' -f (Fn $avgKB 0), (Fn $range.MinSizeKB 0), (Fn $range.MaxSizeKB 0))
            }
        }
        elseif ($cal.MessageSizeKB -gt 0 -and ($avgKB -gt 2 * $cal.MessageSizeKB -or $avgKB -lt $cal.MessageSizeKB / 2)) {
            Add-TsCheck $ctx Warning 'SizeNotCalibrated' ('Le profil a été mesuré avec des messages de {0} Ko, le scénario a une taille moyenne de {1} Ko : le coût de la taille n’’est pas mesuré (paliers à plusieurs tailles, avec pièces jointes).' -f (Fn $cal.MessageSizeKB 0), (Fn $avgKB 0))
        }
        if ($transportRules -gt 0) {
            if ($cpuTerms.PerRuleMsg -le 0) { Add-TsCheck $ctx Info 'RulesNotCalibrated' ('{0} règle(s) de transport : leur coût n’’est pas mesuré par le profil (paliers avec règles).' -f (Fn $transportRules 0)) }
            elseif ($range -and $range.MaxRules -gt 0 -and $transportRules -gt 1.5 * $range.MaxRules) { Add-TsCheck $ctx Warning 'RulesExtrapolation' ('{0} règles de transport : au-delà de 1,5 × les {1} règles mesurées, coût extrapolé.' -f (Fn $transportRules 0), (Fn $range.MaxRules 0)) }
        }
        if ($cpuTerms.PerSession -le 0 -and $cpuTerms.PerTlsSession -le 0 -and $perSession -lt 5) {
            Add-TsCheck $ctx Info 'SessionsNotCalibrated' 'Le coût d’’une session SMTP (connexion, EHLO, négociation TLS) n’’est pas mesuré par le profil, dont les paliers gardent les sessions ouvertes : avec peu de messages par session (Internet), le processeur est sous-estimé. Ajouter des paliers à une session par message, en clair et en TLS.'
        }
        elseif (($cpuTerms.PerSession -gt 0 -or $cpuTerms.PerTlsSession -gt 0) -and $range -and $range.MaxSessionsPerSec -gt 0 -and $designLoad.Sessions -gt 1.5 * $range.MaxSessionsPerSec) {
            Add-TsCheck $ctx Warning 'SessionsExtrapolation' ('{0} sessions SMTP par seconde : au-delà de 1,5 × les {1} sessions/s mesurées, coût extrapolé.' -f (Fn $designLoad.Sessions 1), (Fn $range.MaxSessionsPerSec 1))
        }
    }

    # ---------------------------------------------------------------- processor
    $cores = $null; $coresNeeded = $null; $cpuUtilization = $null; $rateCpuMax = $null; $vcpuShare = 1.0; $specKnown = $false; $specTarget = 0.0
    $drainCal = $null; $drainCost = $null; $busyWorking = $null; $scale = 1.0; $coresDrain = 0; $drainCoresNeeded = $null; $drainRateTarget = $null; $rateForCores = $null
    $maxCpu = $cmp.MaxCpuPercent / 100
    if ($cal) {
        $lp = $cal.Server.LogicalProcessors
        $cpuModel = $cal.Models.CpuPercent
        $refModel = [Math]::Max(0.0, (Get-TsModelValue $cpuModel $designLoad)) / 100 * $lp
        # A validation step (kept out of the fit) measured above the prediction: the gap is applied, never a reduction.
        $validationFactor = 1.0; $validationLabel = ''
        foreach ($v in @($cal.Validation)) {
            $saturated = [bool](Get-TsField $v 'Saturated' $false)
            $cpuCheck = Get-TsField $v 'CpuPercent' $null
            if ($saturated -or -not $cpuCheck) { continue }
            $measured = [double](Get-TsField $cpuCheck 'Measured' 0); $predicted = [double](Get-TsField $cpuCheck 'Predicted' 0)
            if ($predicted -gt 0 -and $measured / $predicted -gt $validationFactor) { $validationFactor = $measured / $predicted; $validationLabel = [string](Get-TsField $v 'Label' '') }
        }
        $refBusy = $refModel * $validationFactor
        # Capacity of one logical processor of the reference and of one vCPU (or core) of the target, in SPEC CPU2017
        # integer rate per core (both taken as the same core when one of them is unknown).
        $specRef = [double]$cal.Server.SpecIntRatePerCore
        $specTarget = [double]$cmp.TargetSpecIntRatePerCore
        $specTargetText = $(if ($cmp.TargetProcessor) { $cmp.TargetProcessor } else { 'saisi' })
        if (-not $virtual -and $phy.Cores -gt 0 -and $phy.SpecIntRate2017 -gt 0) { $specTarget = $phy.SpecIntRate2017 / $phy.Cores; $specTargetText = '{0} ÷ {1} cœurs' -f (Fn $phy.SpecIntRate2017 0), (Fn $phy.Cores 0) }
        $specKnown = ($specRef -gt 0 -and $specTarget -gt 0)
        if (-not $specKnown) { Add-TsCheck $ctx Info 'SpecUnknown' 'Performance par cœur (SPECint_rate2017) du serveur de référence ou du serveur cible non renseignée : même performance par cœur supposée.' }
        $sRef = $(if ($specKnown) { $specRef } else { 1.0 }); $sTarget = $(if ($specKnown) { $specTarget } else { 1.0 })
        $specUnit = $(if ($specKnown) { 'SPECint' } else { 'cœur de réf.' })
        $smt = 1 + $cmp.SmtGainPercent / 100
        $refCores = [double]$cal.Server.Cores
        if ($refCores -le 0 -or $refCores -gt $lp) { $refCores = [double]$lp }
        # A logical processor of the reference is a hyper-thread sharing its core (fewer cores than logical processors:
        # Azure vCPU, physical server with SMT), a vCPU with a core of its own (virtual machine without SMT, host not
        # saturated during the calibration) or a core.
        if ($refCores -lt $lp) { $perLpRef = $sRef * $refCores / $lp; $perLpFormula = 'SPECint par cœur × cœurs ÷ processeurs logiques (threads d’’un même cœur)'; $perLpComputation = '{0} × {1} ÷ {2}' -f (Fn $sRef 2), (Fn $refCores 0), (Fn $lp 0) }
        elseif ($cal.Server.Virtual) { $perLpRef = $sRef / $smt; $perLpFormula = 'SPECint par cœur ÷ gain de l’’hyperthreading (un vCPU seul sur son cœur)'; $perLpComputation = '{0} ÷ {1}' -f (Fn $sRef 2), (Fn $smt 2) }
        else { $perLpRef = $sRef; $perLpFormula = 'SPECint par cœur (sans hyperthreading)'; $perLpComputation = '' }
        # A vCPU of the target gets the share of a physical core the host can guarantee when every vCPU is busy: one core
        # per vCPU at most (its single thread, a core ÷ the SMT gain), half a core at 2:1, a third at 3:1. A core of a
        # physical target counts whole, its threads included.
        $vcpuShare = $(if ($virtual) { 1 / [Math]::Max($cmp.VcpuRatio, $smt) } else { 1.0 })
        $perUnitTarget = $sTarget * $vcpuShare
        $capacityRatio = $perLpRef / $perUnitTarget
        $hypervisor = 1.0
        $hvRate = $cmp.HypervisorOverheadPercent / 100
        if ($virtual -and -not $cal.Server.Virtual) { $hypervisor = 1 + $hvRate }
        elseif (-not $virtual -and $cal.Server.Virtual) { $hypervisor = 1 / (1 + $hvRate) }
        $cpuAdjust = $adj.CpuPercent / 100
        $scale = $capacityRatio * $hypervisor * $cpuAdjust
        if ($virtual -and $cmp.VcpuRatio -gt $ref.Virtualization.MaxSupportedVcpuRatio) {
            Add-TsCheck $ctx Warning 'VcpuRatioUnsupported' ('{0} vCPU par cœur physique : au-delà du maximum pris en charge par Microsoft pour Exchange ({1}:1, 1:1 recommandé). Chaque vCPU ne compte que sur {2} % d’’un cœur : il faut davantage de vCPU, et le temps d’’attente processeur (ready, co-stop) grandit avec eux.' -f (Fn $cmp.VcpuRatio 1), (Fn $ref.Virtualization.MaxSupportedVcpuRatio 0), (Fn ($vcpuShare * 100) 0))
        }
        $coresNeeded = $refBusy * $scale
        $coresMin = Get-TsCeiling ($coresNeeded / $maxCpu) 1
        # Per message of the design rate (journal reports included when they are a factor of their own).
        $cpuPerMessage = (Get-TsModelPerMessage $cpuModel $designLoad) * $designLoad.Rate / $rateDesign
        # Drain: the working-hours traffic keeps arriving while the queue of the outage is sent again. A message sent
        # from the queue costs the measured drain CPU (no reception, no antispam); without that measure, a reception.
        $drainCal = $cal.Drain
        if ($drainCal -and -not $drainCal.Measured) { Add-TsCheck $ctx Info 'DrainByAnalogy' ('CPU d’’un message renvoyé depuis la file non mesuré sur ce profil, déduit par analogie : {0}' -f $drainCal.Note) }
        $drainCost = $(if ($drainCal) { [double]$drainCal.CpuPercentPerMsg } else { $cpuPerMessage * $validationFactor })
        $busyWorking = [Math]::Max(0.0, (Get-TsModelValue $cpuModel (& $newLoad $rateWorking))) * $validationFactor
        if ($res.DrainTargetHours -gt 0 -and $backlogMsgs -gt 0 -and $drainCost -gt 0) {
            $drainRateTarget = $backlogMsgs / ($res.DrainTargetHours * 3600)
            # Cores beyond what the measured drain rate needs would not drain faster (next hop, delivery connections).
            $rateForCores = $(if ($drainCal -and $drainCal.Rate -gt 0) { [Math]::Min($drainRateTarget, [double]$drainCal.Rate) } else { $drainRateTarget })
            $drainCoresNeeded = ($busyWorking + $drainCost * $rateForCores) / 100 * $lp * $scale
            $coresDrain = Get-TsCeiling ($drainCoresNeeded / $maxCpu) 1
        }
        $coresTarget = [Math]::Max($coresMin, $coresDrain)
        if ($virtual) {
            $cores = [int][Math]::Max($cmp.MinCores, $coresTarget)
            if ($cmp.EvenVcpu -and $cores % 2 -ne 0) { $cores++ }
        }
        elseif ($phy.Cores -gt 0) {
            $cores = [int]$phy.Cores
            if ($cores -lt $coresMin) { Add-TsCheck $ctx Error 'CoresShort' ('Le serveur physique a {0} cœurs, il en faut {1} pour rester sous {2} % de CPU au débit de dimensionnement.' -f $cores, $coresMin, (Fn $cmp.MaxCpuPercent 0)) }
            elseif ($cores -lt $coresDrain) { Add-TsCheck $ctx Warning 'DrainCoresShort' ('Le serveur physique a {0} cœurs, il en faut {1} pour vider la file de la panne en {2} h.' -f $cores, $coresDrain, (Fn $res.DrainTargetHours 0)) }
        }
        else { $cores = [int][Math]::Max($cmp.MinCores, (Get-TsCeiling $coresTarget 2)) }
        $cpuUtilization = $coresNeeded / $cores
        if ($cpuPerMessage -gt 0) { $rateCpuMax = (($cores * $maxCpu / $scale) / $lp * 100 / $validationFactor - $cpuModel.Intercept) / $cpuPerMessage }
        if ($cores -gt $ref.Exchange.MaxCores) { Add-TsCheck $ctx Warning 'TooManyCores' ('{0} cœurs par serveur : au-delà des {1} cœurs recommandés pour Exchange 2019 / SE, ajouter des serveurs.' -f $cores, $ref.Exchange.MaxCores) }
        $refText = '{0} · {1} processeurs logiques · {2}' -f $(if ($cal.Server.Name) { $cal.Server.Name } else { 'serveur de référence' }), (Fn $lp 0), $(if ($cal.Server.Virtual) { 'virtuel' } else { 'physique' })
        [void](Add-TsValue $ctx 'cpu' 'cpu.reference' 'Serveur de référence' $refText -Kind Calibration -Source $calLabel -Note $cal.Server.Processor)
        [void](Add-TsValue $ctx 'cpu' 'cpu.model' 'Modèle mesuré (CPU total du serveur)' ('R² {0} · {1} paliers' -f (Fn $cpuModel.R2 3), $cpuModel.Points) -Formula (Format-TsModel $cpuModel '% CPU') -Kind Calibration -Source $calLabel)
        foreach ($term in @([pscustomobject]@{ Key = 'Intercept'; Factor = $null; Label = 'à vide (système, services, supervision)' }) + $script:TsLoadTerms) {
            if ($term.Key -ne 'Intercept' -and -not ($cpuModel.Contains($term.Key) -and [double]$cpuModel[$term.Key] -ne 0)) { continue }
            $percent = $(if ($term.Key -eq 'Intercept') { [double]$cpuModel.Intercept } else { [double]$cpuModel[$term.Key] * [double]$designLoad[$term.Factor] })
            [void](Add-TsValue $ctx 'cpu' ('cpu.term.' + $term.Key) ('CPU de la référence : {0}' -f $term.Label) $percent -Unit '%' `
                    -Formula $(if ($term.Key -eq 'Intercept') { 'Ordonnée à l’’origine du modèle' } else { 'Coefficient mesuré × {0}' -f $term.Unit }) `
                    -Computation $(if ($term.Key -eq 'Intercept') { '' } else { '{0} × {1}' -f (Fn $cpuModel[$term.Key] 4), (Fn $designLoad[$term.Factor] 2) }) -Kind Calibration -Decimals 1 -Source $calLabel)
        }
        [void](Add-TsValue $ctx 'cpu' 'cpu.refModel' 'Processeurs logiques occupés sur la référence selon le modèle' $refModel -Unit 'proc. log.' -Formula 'Somme des termes du modèle ÷ 100 × processeurs logiques' `
                -Computation ('({0}) ÷ 100 × {1}' -f (Format-TsModelComputation $cpuModel $designLoad), (Fn $lp 0)) -Decimals 2)
        [void](Add-TsValue $ctx 'cpu' 'cpu.validation' 'Correction de validation' $validationFactor -Unit '×' -Formula 'max(1, CPU mesuré ÷ CPU prédit) des paliers de validation' `
                -Computation $(if ($validationLabel) { 'palier {0}' -f $validationLabel } else { 'aucun palier au-dessus de la prédiction' }) -Kind $(if ($validationLabel) { 'Calibration' } else { 'Rule' }) -Decimals 2 -Source $calLabel `
                -Note 'Un palier gardé hors de l’’ajustement (mélange de tailles) qui coûte plus que la prédiction corrige le résultat ; jamais à la baisse.')
        [void](Add-TsValue $ctx 'cpu' 'cpu.refBusy' 'Processeurs logiques occupés sur la référence au débit de dimensionnement' $refBusy -Unit 'proc. log.' -Formula 'Processeurs logiques selon le modèle × correction de validation' `
                -Computation ('{0} × {1}' -f (Fn $refModel 3), (Fn $validationFactor 2)) -Decimals 2)
        [void](Add-TsValue $ctx 'cpu' 'cpu.specRef' 'SPECint_rate2017 par cœur de la référence' $specRef -Unit 'SPECint' -Kind $(if ($specRef -gt 0) { 'Calibration' } else { 'Assumption' }) -Decimals 2 -Source $calLabel `
                -Note $(if ($cal.Server.SpecIntNote) { $cal.Server.SpecIntNote } elseif ($specRef -le 0) { 'Non renseigné dans le profil.' } else { '' }))
        [void](Add-TsValue $ctx 'cpu' 'cpu.specTarget' $(if ($virtual) { 'SPECint_rate2017 par cœur de l’’hôte' } else { 'SPECint_rate2017 par cœur du serveur' }) $specTarget -Unit 'SPECint' -Kind Input -Decimals 2 `
                -Computation $(if ($specTarget -gt 0) { $specTargetText } else { 'non renseigné' }) `
                -Note 'Médiane des résultats SPEC CPU2017 integer rate (base) publiés pour le processeur, divisée par ses cœurs : catalogue data\Processors.csv (spec.org), ou valeur de la fiche du serveur.')
        [void](Add-TsValue $ctx 'cpu' 'cpu.perLpRef' 'Capacité d’’un processeur logique de la référence' $perLpRef -Unit $specUnit -Formula $perLpFormula -Computation $perLpComputation -Decimals 2 `
                -Note ('{0} processeurs logiques, {1} cœur(s) : les vCPU Azure sont les deux threads d’’un même cœur, chacun la moitié de sa capacité quand les deux travaillent.' -f (Fn $lp 0), (Fn $refCores 0)))
        if ($virtual) {
            [void](Add-TsValue $ctx 'cpu' 'cpu.vcpuRatio' 'vCPU alloués par cœur physique de l’’hôte' $cmp.VcpuRatio -Unit ': 1' -Kind Input -Decimals 1 -Source 'Microsoft : 2:1 au plus pris en charge, 1:1 recommandé' `
                    -Note 'Somme des vCPU des machines de l’’hôte (ou du cluster) ÷ cœurs physiques, hors hyperthreading. Une VM avec réservation processeur complète compte comme 1:1.')
            [void](Add-TsValue $ctx 'cpu' 'cpu.smt' 'Gain de l’’hyperthreading' $cmp.SmtGainPercent -Unit '%' -Kind Assumption -Decimals 0 -Source 'SPEC CPU2017 : 5 systèmes mesurés avec et sans SMT, 3 à 22 %, médiane 20 %' `
                    -Note 'Un thread seul sur un cœur fait le débit du cœur ÷ (1 + gain) : c’’est le plus qu’’un vCPU peut obtenir d’’un cœur.')
            [void](Add-TsValue $ctx 'cpu' 'cpu.vcpuShare' 'Part d’’un cœur physique garantie à un vCPU' ($vcpuShare * 100) -Unit '%' -Formula '1 ÷ max(vCPU par cœur, 1 + gain de l’’hyperthreading)' `
                    -Computation ('1 ÷ max({0}, {1})' -f (Fn $cmp.VcpuRatio 2), (Fn $smt 2)) -Decimals 0 `
                    -Note 'Pire cas : tous les vCPU de l’’hôte travaillent en même temps, comme lors d’’une bascule de site ou d’’une panne qui charge aussi les autres VM.')
        }
        [void](Add-TsValue $ctx 'cpu' 'cpu.perUnit' $(if ($virtual) { 'Capacité garantie d’’un vCPU de la cible' } else { 'Capacité d’’un cœur de la cible' }) $perUnitTarget -Unit $specUnit `
                -Formula $(if ($virtual) { 'SPECint par cœur de l’’hôte × part d’’un cœur garantie' } else { 'SPECint par cœur du serveur (threads compris)' }) -Computation $(if ($virtual) { '{0} × {1}' -f (Fn $sTarget 2), (Fn $vcpuShare 3) } else { '' }) -Decimals 2)
        [void](Add-TsValue $ctx 'cpu' 'cpu.spec' $(if ($virtual) { 'vCPU de la cible par processeur logique de la référence' } else { 'Cœurs de la cible par processeur logique de la référence' }) $capacityRatio -Unit '×' `
                -Formula 'Capacité d’’un processeur logique de la référence ÷ capacité d’’une unité de la cible' -Computation ('{0} ÷ {1}' -f (Fn $perLpRef 2), (Fn $perUnitTarget 2)) -Decimals 2)
        [void](Add-TsValue $ctx 'cpu' 'cpu.hypervisor' 'Surcoût d’’hyperviseur' $hypervisor -Unit '×' -Formula 'Cible virtuelle et référence physique : 1 + surcoût ; l’’inverse : ÷ (1 + surcoût) ; sinon 1' `
                -Computation ('surcoût {0} %' -f (Fn $cmp.HypervisorOverheadPercent 0)) -Kind Microsoft -Decimals 2 -Source 'Microsoft : virtualisation d’’Exchange (environ 10 %)')
        [void](Add-TsValue $ctx 'cpu' 'cpu.adjust' 'Ajustement processeur du profil' $adj.CpuPercent -Unit '%' -Kind Input -Decimals 0 `
                -Note 'Adaptation du profil au contexte du client quand il n’’a pas été mesuré sur place : processeurs plus lents ou plus rapides que ceux de la référence, agents ou antivirus en plus. 100 % = profil tel que mesuré.')
        [void](Add-TsValue $ctx 'cpu' 'cpu.needed' $(if ($virtual) { 'vCPU nécessaires à 100 %' } else { 'Cœurs nécessaires à 100 %' }) $coresNeeded -Unit $(if ($virtual) { 'vCPU' } else { 'cœurs' }) -Formula 'Processeurs logiques occupés sur la référence × unités de la cible par processeur logique × surcoût d’’hyperviseur × ajustement' `
                -Computation ('{0} × {1} × {2} × {3}' -f (Fn $refBusy 2), (Fn $capacityRatio 2), (Fn $hypervisor 2), (Fn $cpuAdjust 2)) -Decimals 2)
        [void](Add-TsValue $ctx 'cpu' 'cpu.max' 'Utilisation maximale visée' $cmp.MaxCpuPercent -Unit '%' -Kind Input -Decimals 0 -Source "$msCalc : 80 %")
        [void](Add-TsValue $ctx 'cpu' 'cpu.cores' $(if ($virtual) { 'vCPU proposés' } else { 'Cœurs physiques' }) $cores -Unit $(if ($virtual) { 'vCPU' } else { 'cœurs' }) `
                -Formula $(if ($virtual) { 'max(minimum, ⌈cœurs nécessaires ÷ utilisation maximale⌉, ⌈cœurs pour la vidange ÷ utilisation maximale⌉)' + $(if ($cmp.EvenVcpu) { ', arrondi au nombre pair' } else { '' }) } elseif ($phy.Cores -le 0) { 'max(minimum, cœurs pour la pointe, cœurs pour la vidange), arrondi au nombre pair' } else { 'Cœurs du serveur saisi' }) `
                -Computation ('max({0}, ⌈{1} ÷ {2}⌉, {3}){4}' -f (Fn $cmp.MinCores 0), (Fn $coresNeeded 2), (Fn $maxCpu 2), $(if ($null -ne $drainCoresNeeded) { '⌈{0} ÷ {1}⌉' -f (Fn $drainCoresNeeded 2), (Fn $maxCpu 2) } else { '—' }), $(if (($virtual -and $cmp.EvenVcpu) -or (-not $virtual -and $phy.Cores -le 0)) { ' → pair' } else { '' })) -Decimals 0 `
                -Note $(if ($virtual) { 'Un nombre pair de vCPU s’’aligne sur les sockets × cœurs et le vNUMA de VMware et Hyper-V, et sur les paires de threads des cœurs physiques ; Microsoft recommande 1 vCPU par cœur physique (2 au plus). En dessous de 4 vCPU, Windows, Exchange, l’’antivirus et les agents de supervision n’’ont pas de marge.' } else { '' }))
        [void](Add-TsValue $ctx 'cpu' 'cpu.utilization' 'Utilisation au débit de dimensionnement' ($cpuUtilization * 100) -Unit '%' -Formula 'Cœurs nécessaires ÷ cœurs proposés' -Computation ('{0} ÷ {1}' -f (Fn $coresNeeded 2), $cores) -Decimals 0)
        if ($specTarget -gt 0) {
            [void](Add-TsValue $ctx 'cpu' 'cpu.megacycles' 'Mégacycles par cœur de la cible (formule du calculateur, information)' ($specTarget * $ref.Calculator.SpecToMegacycles) -Unit 'Mcycles' `
                    -Formula 'SPECint_rate2017 par cœur × 2 000 ÷ 33,75 ÷ 0,10832' -Computation ('{0} × {1}' -f (Fn $specTarget 2), (Fn $ref.Calculator.SpecToMegacycles 2)) -Kind Microsoft -Decimals 0 -Source $msCalc)
        }
    }
    else {
        [void](Add-TsValue $ctx 'cpu' 'cpu.missing' 'Processeur' 'À calibrer' -Kind Rule -Formula 'Aucune constante Microsoft ne donne le coût CPU d’’un message de transport : il se mesure sur un serveur de référence.')
    }

    # ---------------------------------------------------------------- memory
    $ramGB = $null; $ramNeededGB = $null; $pagefileGB = $null; $memReservedGB = $null; $memReserveMinGB = $null
    $privateModel = $null; $usedModel = $null
    if ($cal) { $privateModel = $cal.Models.TransportPrivateMB; $usedModel = $cal.Models.UsedMemoryMB }
    $atRestMB = $null
    if ($usedModel -and $adj.MemoryAtRestGB -gt 0) {
        # Memory at rest of the customer's servers: replaces the intercept of the measured model (REF-MAILBOX holds a mounted database).
        $atRestMB = $adj.MemoryAtRestGB * 1024
        $copy = [ordered]@{}
        foreach ($key in $usedModel.Keys) { $copy[$key] = $usedModel[$key] }
        $copy.Intercept = $atRestMB
        $usedModel = $copy
    }
    if ($privateModel -or $usedModel) {
        # Messages in transit are kept whole in memory; those of the outage are dehydrated by Exchange under memory pressure
        # (SystemMemory or PrivateBytes at the medium level): only their envelope stays in memory, the content is read
        # again from mail.que. Measured on REF-EDGE: 63 KB per queued message of 75 KB, 21 KB once dehydrated.
        $copies = $(if ($shadowActive) { 2 } else { 1 })
        $transitInMemory = $copies * $transitMsgs - $(if ($shadowActive) { $jTransitMsgs } else { 0 })
        $backlogInMemory = $copies * $backlogMsgs - $(if ($shadowActive) { $jBacklogMsgs } else { 0 })
        $queuedInMemory = $transitInMemory + $backlogInMemory
        $kbPerQueued = 0.0; $kbKind = 'Assumption'; $kbFormula = ''; $kbComputation = ''
        if ($cal.Backlog -and $cal.Backlog.MemoryPerKB -gt 0) {
            $kbPerQueued = $cal.Backlog.MemoryBaseKB + $cal.Backlog.MemoryPerKB * $avgKB; $kbKind = 'Calibration'
            $kbFormula = 'Part fixe + part par Ko × taille moyenne (paliers backlog à plusieurs tailles)'
            $kbComputation = '{0} + {1} × {2}' -f (Fn $cal.Backlog.MemoryBaseKB 2), (Fn $cal.Backlog.MemoryPerKB 4), (Fn $avgKB 1)
        }
        elseif ($cal.Backlog -and $cal.Backlog.MemoryKBPerQueued -gt 0) { $kbPerQueued = $cal.Backlog.MemoryKBPerQueued; $kbKind = 'Calibration' }
        else { Add-TsCheck $ctx Warning 'QueueMemoryNotCalibrated' 'Mémoire par message en file non calibrée (pas de palier backlog) : la mémoire occupée par une file pleine n’’est pas comptée.' }
        $kbDehydrated = $kbPerQueued; $dehydration = $false
        if ($cal.Backlog -and $cal.Backlog.DehydratedKBPerQueued -gt 0 -and $kbPerQueued -gt 0) {
            # Measured for messages of the backlog size: the same share of the hydrated cost for the scenario size.
            $kbDehydrated = [Math]::Min($kbPerQueued, $cal.Backlog.DehydratedKBPerQueued * $kbPerQueued / [Math]::Max(1e-9, $(if ($cal.Backlog.MemoryKBPerQueued -gt 0) { $cal.Backlog.MemoryKBPerQueued } else { $kbPerQueued })))
            $dehydration = $true
            if (-not $cal.Backlog.DehydrationMeasured) { Add-TsCheck $ctx Info 'DehydrationByAnalogy' ('Mémoire d’’un message déshydraté non mesurée sur ce profil, déduite par analogie : {0}' -f $cal.Backlog.DehydrationNote) }
        }
        elseif ($backlogInMemory -gt 0 -and $kbPerQueued -gt 0) {
            Add-TsCheck $ctx Info 'DehydrationNotCalibrated' 'Déshydratation des messages en file non mesurée par le profil : toute la file de la panne est comptée complète en mémoire, ce qui majore la RAM pour une longue panne.'
        }
        $transitMB = $transitInMemory * $kbPerQueued / 1024
        $backlogMB = $backlogInMemory * $kbDehydrated / 1024
        $queuedMB = $transitMB + $backlogMB
        [void](Add-TsValue $ctx 'memory' 'mem.queued' 'Messages en file au pire moment' $queuedInMemory -Unit 'messages' -Formula $(if ($shadowActive -and ($jTransitMsgs + $jBacklogMsgs) -gt 0) { '(transit + panne) × 2 (copies shadow) − rapports de journal (sans copie shadow)' } elseif ($shadowActive) { '(transit + panne) × 2 (copies shadow)' } else { 'Transit + panne' }) `
                -Computation ('{0} en transit + {1} de la panne' -f (Fn $transitInMemory 0), (Fn $backlogInMemory 0)) -Decimals 0 -Note 'Safety Net reste dans la base, pas en mémoire.')
        [void](Add-TsValue $ctx 'memory' 'mem.perQueued' 'Mémoire par message complet en file' $kbPerQueued -Unit 'Ko' -Kind $kbKind -Decimals 2 -Source $calLabel -Formula $kbFormula -Computation $kbComputation `
                -Note $(if ($cal.Backlog -and $cal.Backlog.MemoryReference) { 'Mesure : ' + $cal.Backlog.MemoryReference + '.' } else { '' }))
        if ($dehydration) {
            [void](Add-TsValue $ctx 'memory' 'mem.perDehydrated' 'Mémoire par message déshydraté' $kbDehydrated -Unit 'Ko' -Kind Calibration -Decimals 2 -Source $calLabel `
                    -Formula 'Mesure après déshydratation × mémoire par message complet ÷ celle du palier mesuré' `
                    -Computation ('{0} × {1} ÷ {2}' -f (Fn $cal.Backlog.DehydratedKBPerQueued 2), (Fn $kbPerQueued 2), (Fn $(if ($cal.Backlog.MemoryKBPerQueued -gt 0) { $cal.Backlog.MemoryKBPerQueued } else { $kbPerQueued }) 2)) `
                    -Note ('Sous pression mémoire (SystemMemory ou PrivateBytes au niveau moyen), Exchange retire le contenu des messages en file de la mémoire et le relit dans mail.que (DehydrateMessagesUnderMemoryPressure). {0}' -f $cal.Backlog.DehydrationNote))
        }
        [void](Add-TsValue $ctx 'memory' 'mem.queuedMB' 'Mémoire des messages en file' $queuedMB -Unit 'Mo' -Formula $(if ($dehydration) { 'Transit × mémoire par message complet + panne × mémoire par message déshydraté' } else { 'Messages en file × mémoire par message ÷ 1 024' }) `
                -Computation $(if ($dehydration) { '({0} × {1} + {2} × {3}) ÷ 1 024' -f (Fn $transitInMemory 0), (Fn $kbPerQueued 2), (Fn $backlogInMemory 0), (Fn $kbDehydrated 2) } else { '{0} × {1} ÷ 1 024' -f (Fn $queuedInMemory 0), (Fn $kbPerQueued 2) }) -Decimals 0 `
                -Note $(if ($dehydration) { 'La RAM doit tenir la file déshydratée sous les seuils : la file complète n’’est qu’’un cache que Exchange libère quand la mémoire manque.' } else { '' }))
        $byPrivate = 0.0; $byUsed = 0.0
        if ($privateModel) {
            $privateMB = (Get-TsModelValue $privateModel $designLoad) + $queuedMB
            $byPrivate = $privateMB / ($bp.PrivateBytes / 100) / 1024
            [void](Add-TsValue $ctx 'memory' 'mem.private' 'Mémoire privée d’’EdgeTransport.exe' $privateMB -Unit 'Mo' -Formula 'Modèle mesuré au débit de dimensionnement + messages en file' `
                    -Computation ('{0} + {1}' -f (Format-TsModelComputation $privateModel $designLoad 0), (Fn $queuedMB 0)) -Kind Calibration -Decimals 0 -Source $calLabel)
            [void](Add-TsValue $ctx 'memory' 'mem.byPrivate' ('RAM pour rester sous PrivateBytes ({0} %)' -f $bp.PrivateBytes) $byPrivate -Unit 'Go' -Formula 'Mémoire privée ÷ seuil ÷ 1 024' `
                    -Computation ('{0} ÷ {1} ÷ 1 024' -f (Fn $privateMB 0), (Fn ($bp.PrivateBytes / 100) 2)) -Decimals 1 -Source $msBp)
        }
        if ($usedModel) {
            if ($null -ne $atRestMB) {
                [void](Add-TsValue $ctx 'memory' 'mem.atRest' 'Mémoire au repos (ajustement du profil)' $adj.MemoryAtRestGB -Unit 'Go' -Kind Input -Decimals 1 `
                        -Note ('Mémoire utilisée sans charge par un serveur du client, à la place des {0} Go du profil.' -f (Fn ($cal.Models.UsedMemoryMB.Intercept / 1024) 1)))
            }
            $usedMB = (Get-TsModelValue $usedModel $designLoad) + $queuedMB
            $byUsed = $usedMB / ($bp.SystemMemory / 100) / 1024
            [void](Add-TsValue $ctx 'memory' 'mem.used' 'Mémoire utilisée par tous les processus' $usedMB -Unit 'Mo' -Formula 'Modèle mesuré au débit de dimensionnement + messages en file' `
                    -Computation ('{0} + {1}' -f (Format-TsModelComputation $usedModel $designLoad 0), (Fn $queuedMB 0)) -Kind Calibration -Decimals 0 -Source $calLabel `
                    -Note $(if ($null -ne $atRestMB) { 'Mémoire au repos saisie ({0} Go) à la place de celle du profil ({1} Go) ; la part de la charge reste celle du profil.' -f (Fn $adj.MemoryAtRestGB 1), (Fn ($cal.Models.UsedMemoryMB.Intercept / 1024) 1) }
                        else { 'Système et autres processus Exchange supposés identiques à ceux du serveur de référence.' + (@(@($cal.Corrections) | Where-Object { (Get-TsField $_ 'Model' '') -eq 'UsedMemoryMB' } | ForEach-Object { ' Correction du profil : {0} Mo, {1}' -f (Fn (Get-TsField $_ 'DeltaMB' 0) 0), (Get-TsField $_ 'Reason' '') }) -join '') }))
            [void](Add-TsValue $ctx 'memory' 'mem.byUsed' ('RAM pour rester sous SystemMemory ({0} %)' -f $bp.SystemMemory) $byUsed -Unit 'Go' -Formula 'Mémoire utilisée ÷ seuil ÷ 1 024' `
                    -Computation ('{0} ÷ {1} ÷ 1 024' -f (Fn $usedMB 0), (Fn ($bp.SystemMemory / 100) 2)) -Decimals 1 -Source $msBp)
        }
        $ramNeededGB = [Math]::Max($byPrivate, $byUsed) * (1 + $cmp.RamMarginPercent / 100)
        $ramGB = Get-TsMemorySize -NeededGB $ramNeededGB -MinimumGB $cmp.MinRamGB -Virtual $virtual
        $pagefileGB = $ramGB * $ref.Exchange.PagefilePercent / 100
        if ($dehydration -and $backlogInMemory -gt 0 -and $privateModel -and $usedModel) {
            # Messages of the outage the proposed RAM keeps whole before the first medium level: SystemMemory (dehydration only)
            # or PrivateBytes (dehydration, and messages of non-Exchange servers refused until EdgeTransport goes back down).
            $ramMB = $ramGB * 1024
            $roomUsed = $bp.SystemMemory / 100 * $ramMB - ($usedMB - $backlogMB)
            $roomPrivate = $bp.PrivateBytes / 100 * $ramMB - ($privateMB - $backlogMB)
            $byPrivateFirst = $roomPrivate -lt $roomUsed
            $hydratedMsgs = [Math]::Max(0.0, [Math]::Min($roomUsed, $roomPrivate) * 1024 / $kbPerQueued)
            [void](Add-TsValue $ctx 'memory' 'mem.hydrated' 'Messages de la panne gardés complets avant la déshydratation' ([Math]::Min($hydratedMsgs, $backlogInMemory)) -Unit 'messages' `
                    -Formula 'min(SystemMemory × RAM − mémoire utilisée hors panne, PrivateBytes × RAM − mémoire privée hors panne) ÷ mémoire par message complet' `
                    -Computation ('min({0}, {1}) Mo ÷ {2} Ko' -f (Fn $roomUsed 0), (Fn $roomPrivate 0), (Fn $kbPerQueued 2)) -Decimals 0 `
                    -Note $(if ($byPrivateFirst) { 'Seuil atteint en premier : PrivateBytes (EdgeTransport).' } else { 'Seuil atteint en premier : SystemMemory (tous les processus).' }))
            if ($backlogInMemory -gt $hydratedMsgs) {
                if ($byPrivateFirst) {
                    Add-TsCheck $ctx Warning 'DehydrationRejects' ('Au-delà de {0} messages en file, EdgeTransport atteint {1} % de la RAM avant que la mémoire totale n’’atteigne {2} % : d’’après les seuils de back pressure de Microsoft, Exchange déshydrate alors la file mais refuse aussi les messages des serveurs non Exchange (code 4xx, l’’expéditeur réessaie) jusqu’’au retour sous le seuil. Non observé au labo, où la mémoire totale atteint 88 % en premier sur 8 Go. Plus de RAM ne l’’évite pas, elle le retarde.' -f (Fn $hydratedMsgs 0), $bp.PrivateBytes, $bp.SystemMemory)
                }
                else {
                    Add-TsCheck $ctx Info 'Dehydration' ('Au-delà de {0} messages en file, la mémoire totale atteint {1} % : Exchange déshydrate la file (contenu relu dans mail.que) sans refuser de messages. Mesuré sur REF-EDGE : la file a continué de croître pendant la déshydratation.' -f (Fn $hydratedMsgs 0), $bp.SystemMemory)
                }
            }
        }
        [void](Add-TsValue $ctx 'memory' 'mem.margin' 'Marge' $cmp.RamMarginPercent -Unit '%' -Kind Input -Decimals 0)
        [void](Add-TsValue $ctx 'memory' 'mem.needed' 'RAM nécessaire' $ramNeededGB -Unit 'Go' -Formula 'max(RAM PrivateBytes, RAM SystemMemory) × (1 + marge)' `
                -Computation ('max({0}, {1}) × {2}' -f (Fn $byPrivate 1), (Fn $byUsed 1), (Fn (1 + $cmp.RamMarginPercent / 100) 2)) -Decimals 1)
        [void](Add-TsValue $ctx 'memory' 'mem.ram' 'RAM proposée' $ramGB -Unit 'Go' -Formula $(if ($virtual) { 'Multiple de 4 Go supérieur, au moins le minimum' } else { 'Taille de mémoire usuelle supérieure, au moins le minimum' }) `
                -Computation ('RAM nécessaire {0} Go, minimum {1} Go' -f (Fn $ramNeededGB 1), (Fn $cmp.MinRamGB 0)) -Decimals 0)
        [void](Add-TsValue $ctx 'memory' 'mem.pagefile' 'Fichier d’’échange (taille fixe)' $pagefileGB -Unit 'Go' -Formula '25 % de la RAM' -Computation ('{0} × 25 %' -f (Fn $ramGB 0)) -Kind Microsoft -Decimals 0 -Source $msReq)
        if ($ramGB -gt $ref.Exchange.MaxMemoryGB) { Add-TsCheck $ctx Warning 'TooMuchMemory' ('{0} Go de RAM par serveur : au-delà des {1} Go pris en charge par Exchange 2019 / SE, ajouter des serveurs.' -f (Fn $ramGB 0), $ref.Exchange.MaxMemoryGB) }
        if ($virtual) {
            # Reservation on the host: the RAM the VM is sure to keep. Without a panne the server needs its memory at rest and the
            # messages in transit; during an outage, the dehydrated queue too. Above that (margin, rounding), the host may share.
            $normalGB = 0.0
            if ($privateModel) { $normalGB = [Math]::Max($normalGB, ((Get-TsModelValue $privateModel $designLoad) + $transitMB) / ($bp.PrivateBytes / 100) / 1024) }
            if ($usedModel) { $normalGB = [Math]::Max($normalGB, ((Get-TsModelValue $usedModel $designLoad) + $transitMB) / ($bp.SystemMemory / 100) / 1024) }
            $worstGB = [Math]::Max($byPrivate, $byUsed)
            $memReserveMinGB = [Math]::Min($ramGB, [Math]::Ceiling($worstGB))
            $memReservedGB = $ramGB * $cmp.MemoryReservedPercent / 100
            [void](Add-TsValue $ctx 'memory' 'mem.normal' 'RAM nécessaire hors panne' $normalGB -Unit 'Go' -Formula 'max(mémoire privée, mémoire utilisée) au débit de dimensionnement, messages en transit compris, sous les seuils' -Decimals 1)
            [void](Add-TsValue $ctx 'memory' 'mem.reserveMin' 'Mémoire à réserver au minimum sur l’’hôte' $memReserveMinGB -Unit 'Go' -Formula 'RAM nécessaire au pire moment, sans la marge' `
                    -Computation ('⌈max({0}, {1})⌉' -f (Fn $byPrivate 1), (Fn $byUsed 1)) -Decimals 0 `
                    -Note 'En dessous, la file d’’une panne n’’est plus garantie : c’’est pendant une panne ou une bascule de site que l’’hôte est le plus chargé et reprend de la mémoire.')
            [void](Add-TsValue $ctx 'memory' 'mem.reserved' 'Mémoire réservée sur l’’hôte' $memReservedGB -Unit 'Go' -Formula 'RAM proposée × part réservée' -Computation ('{0} × {1} %' -f (Fn $ramGB 0), (Fn $cmp.MemoryReservedPercent 0)) -Decimals 1 `
                    -Source 'Microsoft : la mémoire dynamique et la surallocation ne sont pas prises en charge pour Exchange')
            if ($cmp.MemoryReservedPercent -lt 100) {
                $memWhy = 'Si l’’hôte reprend de la mémoire par ballooning, Windows la voit occupée : Exchange déshydrate la file plus tôt et, si EdgeTransport atteint {0} %, refuse temporairement les messages. Si l’’hôte la met dans son fichier d’’échange, Exchange ne le voit pas et tout ralentit.' -f $bp.PrivateBytes
                if ($memReservedGB -lt $normalGB) {
                    Add-TsCheck $ctx Warning 'MemoryReserveNormal' ('Mémoire réservée ({0} Go) sous le besoin hors panne ({1} Go) : même sans incident, la VM dépend de la mémoire libre de l’’hôte. {2}' -f (Fn $memReservedGB 1), (Fn $normalGB 1), $memWhy)
                }
                elseif ($memReservedGB -lt $memReserveMinGB) {
                    Add-TsCheck $ctx Warning 'MemoryReserveOutage' ('Mémoire réservée ({0} Go) sous la réservation minimale ({1} Go, besoin d’’une panne) : la file accumulée n’’est pas garantie au moment où l’’hôte est le plus sollicité (panne, bascule de site). {2}' -f (Fn $memReservedGB 1), (Fn $memReserveMinGB 0), $memWhy)
                }
                else {
                    Add-TsCheck $ctx Info 'MemoryNotReserved' ('Mémoire réservée à {0} % ({1} Go), au moins la réservation minimale ({2} Go, besoin au pire moment) : seule la marge est partagée avec l’’hôte. Microsoft ne prend pas en charge la mémoire dynamique ni la surallocation pour Exchange.' -f (Fn $cmp.MemoryReservedPercent 0), (Fn $memReservedGB 1), (Fn $memReserveMinGB 0))
                }
            }
        }
    }
    else {
        [void](Add-TsValue $ctx 'memory' 'mem.missing' 'Mémoire' 'À calibrer' -Kind Rule -Formula 'Mesurer la mémoire privée d’’EdgeTransport.exe et la mémoire utilisée sur un serveur de référence.')
        Add-TsCheck $ctx Info 'NoPagefile' 'RAM non calculée : le fichier d’’échange (25 % de la RAM) n’’est pas compté dans le volume système.'
    }
    [void](Add-TsValue $ctx 'memory' 'mem.microsoft' 'RAM minimale recommandée par Microsoft (information)' ([double]$ref.Exchange.RecommendedMemoryGB[$s.Role]) -Unit 'Go' -Kind Microsoft -Decimals 0 -Source $msReq `
            -Note 'Valeur générique du rôle : affichée pour information, jamais utilisée comme résultat.')
    # ---------------------------------------------------------------- storage
    $queueOnSystem = $sto.QueueVolume -eq 'System'
    $bpQueue = [Math]::Min([double]$bp.DatabaseUsedSpace, [double]$bp.UsedDiskSpaceQueue)
    $queueFill = [Math]::Min($sto.MaxFillPercent, $bpQueue)
    $systemFill = [Math]::Min($sto.MaxFillPercent, [double]$bp.UsedDiskSpaceData)
    if ($queueOnSystem) { $systemFill = [Math]::Min($systemFill, $bpQueue) }
    $systemParts = [Collections.Generic.List[object]]::new()
    $systemParts.Add([pscustomobject]@{ Id = 'os'; Label = 'Windows Server'; GB = $sto.OsGB })
    $systemParts.Add([pscustomobject]@{ Id = 'binaries'; Label = 'Binaires Exchange'; GB = $sto.ExchangeBinariesGB })
    $systemParts.Add([pscustomobject]@{ Id = 'install'; Label = 'Espace libre d’’installation'; GB = [double]$ref.Exchange.InstallFreeSpaceGB })
    $systemParts.Add([pscustomobject]@{ Id = 'diagnostics'; Label = 'Journaux de diagnostic'; GB = $sto.DiagnosticLogsGB })
    $systemParts.Add([pscustomobject]@{ Id = 'transportlogs'; Label = 'Journaux de transport'; GB = $sto.TransportLogsGB })
    if ($null -ne $pagefileGB) { $systemParts.Add([pscustomobject]@{ Id = 'pagefile'; Label = 'Fichier d’’échange'; GB = $pagefileGB }) }
    if ($queueOnSystem) { $systemParts.Add([pscustomobject]@{ Id = 'queue'; Label = 'File d’’attente'; GB = $queueContentGB }) }
    $systemContentGB = 0.0
    foreach ($part in $systemParts) { $systemContentGB += $part.GB }
    $systemNeedGB = $systemContentGB / ($systemFill / 100)
    $queueNeedGB = $queueContentGB / ($queueFill / 100)

    [void](Add-TsValue $ctx 'storage' 'sto.os' 'Windows Server' $sto.OsGB -Unit 'Go' -Kind Assumption -Decimals 0 -Note 'Windows Server demande 32 Go minimum ; marge pour les mises à jour cumulatives.')
    [void](Add-TsValue $ctx 'storage' 'sto.binaries' 'Binaires Exchange' $sto.ExchangeBinariesGB -Unit 'Go' -Kind Assumption -Decimals 0)
    [void](Add-TsValue $ctx 'storage' 'sto.install' 'Espace libre exigé sur le lecteur d’’installation' ([double]$ref.Exchange.InstallFreeSpaceGB) -Unit 'Go' -Kind Microsoft -Decimals 0 -Source $msReq -Note 'Nécessaire aussi pour les mises à jour cumulatives.')
    [void](Add-TsValue $ctx 'storage' 'sto.diagnostics' $(if ($edge) { 'Journaux de diagnostic (Logging)' } else { 'Journaux de diagnostic (Logging) et IIS' }) $sto.DiagnosticLogsGB -Unit 'Go' -Kind Assumption -Decimals 0)
    [void](Add-TsValue $ctx 'storage' 'sto.transportLogs' 'Journaux de transport (suivi, protocole, connectivité…)' $sto.TransportLogsGB -Unit 'Go' -Kind $(if ($edge) { 'Lab' } else { 'Assumption' }) -Decimals 2 `
            -Source $(if ($edge) { 'REF-EDGE : somme des *MaxDirectorySize de Get-TransportService' } else { '' }) -Note 'Bornés par les MaxDirectorySize : à recalculer si ces paramètres changent.')
    if ($null -ne $pagefileGB) { [void](Add-TsValue $ctx 'storage' 'sto.pagefile' 'Fichier d’’échange' $pagefileGB -Unit 'Go' -Formula '25 % de la RAM proposée' -Kind Microsoft -Decimals 0 -Source $msReq) }
    if ($queueOnSystem) { [void](Add-TsValue $ctx 'storage' 'sto.queueOnSystem' 'File d’’attente (sur le volume système)' $queueContentGB -Unit 'Go' -Decimals 1) }
    [void](Add-TsValue $ctx 'storage' 'sto.systemContent' 'Contenu du volume système' $systemContentGB -Unit 'Go' -Formula 'Somme des éléments ci-dessus' -Computation ((@($systemParts | ForEach-Object { Fn $_.GB 1 })) -join ' + ') -Decimals 1)
    [void](Add-TsValue $ctx 'storage' 'sto.systemFill' 'Remplissage maximal du volume système' $systemFill -Unit '%' -Formula $(if ($queueOnSystem) { 'min(marge de conception, back pressure de la file)' } else { 'min(marge de conception, back pressure UsedDiskSpace de TransportRoles\data)' }) `
            -Computation ('min({0}, {1})' -f (Fn $sto.MaxFillPercent 0), (Fn $(if ($queueOnSystem) { $bpQueue } else { $bp.UsedDiskSpaceData }) 0)) -Decimals 0 -Source $msBp `
            -Note 'TransportRoles\data (conversion de contenu) est sur le lecteur d’’installation par défaut.')
    [void](Add-TsValue $ctx 'storage' 'sto.systemNeed' 'Taille utile nécessaire du volume système' $systemNeedGB -Unit 'Go' -Formula 'Contenu ÷ remplissage maximal' -Computation ('{0} ÷ {1}' -f (Fn $systemContentGB 1), (Fn ($systemFill / 100) 2)) -Decimals 1)
    if (-not $queueOnSystem) {
        [void](Add-TsValue $ctx 'storage' 'sto.queueBp' 'Seuil back pressure du volume de la file' $bpQueue -Unit '%' -Formula 'min(DatabaseUsedSpace, UsedDiskSpace des journaux)' -Computation ('min({0}, {1})' -f $bp.DatabaseUsedSpace, $bp.UsedDiskSpaceQueue) -Kind Microsoft -Decimals 0 -Source $msBp `
                -Note 'Au-delà, Exchange refuse les messages des serveurs non Exchange. mail.que et ses journaux sont dans le même dossier par défaut.')
        [void](Add-TsValue $ctx 'storage' 'sto.queueFill' 'Remplissage maximal du volume de la file' $queueFill -Unit '%' -Formula 'min(marge de conception, seuil back pressure)' -Computation ('min({0}, {1})' -f (Fn $sto.MaxFillPercent 0), $bpQueue) -Decimals 0)
        [void](Add-TsValue $ctx 'storage' 'sto.queueNeed' 'Taille utile nécessaire du volume de la file' $queueNeedGB -Unit 'Go' -Formula 'Contenu du dossier de la file ÷ remplissage maximal' -Computation ('{0} ÷ {1}' -f (Fn $queueContentGB 1), (Fn ($queueFill / 100) 2)) -Decimals 1)
    }
    else {
        Add-TsCheck $ctx Info 'QueueOnSystem' 'File d’’attente sur le volume système : une panne qui remplit la file peut déclencher back pressure à cause du système, et inversement. Un volume dédié isole les deux.'
    }

    # ---------------------------------------------------------------- disks and IOPS
    $readIops = $null; $writeIops = $null; $frontIops = $null; $writeMBps = $null; $readBps = $null; $writeBps = $null; $ioOverhead = $sto.IoOverheadPercent / 100
    if ($cal -and $cal.Models.QueueReadIops -and $cal.Models.QueueWriteIops) {
        $ioAdjust = $adj.IoPercent / 100
        $adjustText = $(if ($ioAdjust -ne 1) { ' × {0} (ajustement)' -f (Fn $ioAdjust 2) } else { '' })
        $readIops = [Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueReadIops $designLoad)) * $ioAdjust
        $writeIops = [Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueWriteIops $designLoad)) * $ioAdjust
        $frontIops = ($readIops + $writeIops) * (1 + $ioOverhead)
        [void](Add-TsValue $ctx 'disk' 'io.read' 'Lectures par seconde sur le volume de la file' $readIops -Unit 'IOPS' -Formula (Format-TsModel $cal.Models.QueueReadIops 'lectures/s') `
                -Computation ((Format-TsModelComputation $cal.Models.QueueReadIops $designLoad) + $adjustText) -Kind Calibration -Decimals 1 -Source $calLabel)
        [void](Add-TsValue $ctx 'disk' 'io.write' 'Écritures par seconde sur le volume de la file' $writeIops -Unit 'IOPS' -Formula (Format-TsModel $cal.Models.QueueWriteIops 'écritures/s') `
                -Computation ((Format-TsModelComputation $cal.Models.QueueWriteIops $designLoad) + $adjustText) -Kind Calibration -Decimals 1 -Source $calLabel)
        [void](Add-TsValue $ctx 'disk' 'io.adjust' 'Ajustement E/S du profil' $adj.IoPercent -Unit '%' -Kind Input -Decimals 0 `
                -Note 'Adaptation du profil au stockage du client quand il n’’a pas été mesuré sur place (cache du contrôleur, antivirus sur le dossier de la file). 100 % = profil tel que mesuré.')
        [void](Add-TsValue $ctx 'disk' 'io.overhead' 'Surcoût d’’E/S' $sto.IoOverheadPercent -Unit '%' -Kind Input -Decimals 0 -Source "$msCalc : 20 %")
        [void](Add-TsValue $ctx 'disk' 'io.front' 'IOPS à fournir au volume de la file' $frontIops -Unit 'IOPS' -Formula '(lectures + écritures) × (1 + surcoût)' -Computation ('({0} + {1}) × {2}' -f (Fn $readIops 1), (Fn $writeIops 1), (Fn (1 + $ioOverhead) 2)) -Decimals 0)
        if ($cal.Models.QueueWriteBps) {
            $writeBps = [Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueWriteBps $designLoad)) * $ioAdjust
            $writeMBps = $writeBps / 1048576 * (1 + $ioOverhead)
            [void](Add-TsValue $ctx 'disk' 'io.writeMBps' 'Débit d’’écriture du volume (Mo/s)' $writeMBps -Unit 'Mo/s' -Formula 'Modèle des octets écrits sur le volume ÷ 1 048 576 × (1 + surcoût) × ajustement' `
                    -Computation ('({0}) ÷ 1 048 576 × {1} × {2}' -f (Format-TsModelComputation $cal.Models.QueueWriteBps $designLoad 0), (Fn (1 + $ioOverhead) 2), (Fn $ioAdjust 2)) -Kind Calibration -Decimals 1 -Source $calLabel `
                    -Note 'Les disques cloud (Azure, AWS) plafonnent à la fois les IOPS et le débit en Mo/s : vérifier les deux pour les gros messages.')
        }
        if ($cal.Models.QueueReadBps) {
            $readBps = [Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueReadBps $designLoad)) * $ioAdjust
            [void](Add-TsValue $ctx 'disk' 'io.readMBps' 'Débit de lecture du volume' ($readBps / 1048576 * (1 + $ioOverhead)) -Unit 'Mo/s' -Kind Calibration -Decimals 1 -Source $calLabel `
                    -Formula 'Modèle des octets lus ÷ 1 048 576 × (1 + surcoût) × ajustement')
        }
        foreach ($pair in @(@('read', $readBps, $readIops, 'lecture'), @('write', $writeBps, $writeIops, 'écriture'))) {
            if ($null -ne $pair[1] -and $pair[2] -gt 0) {
                [void](Add-TsValue $ctx 'disk' ('io.' + $pair[0] + 'KB') ('Taille moyenne d’’une E/S en ' + $pair[3]) ($pair[1] / $pair[2] / 1024) -Unit 'Ko' -Kind Calibration -Decimals 1 -Source $calLabel `
                        -Formula 'Octets par seconde ÷ opérations par seconde ÷ 1 024' -Note 'E/S du volume mesurées, pas taille des messages ni page des bases de boîtes aux lettres.')
            }
        }
    }
    else {
        [void](Add-TsValue $ctx 'disk' 'io.missing' 'IOPS du volume de la file' 'À calibrer' -Kind Rule -Formula 'Mesurer les lectures et écritures du volume de mail.que sur un serveur de référence.')
    }

    $systemGB = $null; $queueVolumeGB = $null; $systemRaid = $null; $queueRaid = $null
    if ($virtual) {
        $systemGB = Get-TsCeiling $systemNeedGB $sto.RoundingGB
        [void](Add-TsValue $ctx 'storage' 'sto.systemSize' 'Disque virtuel système' $systemGB -Unit 'Go' -Formula ('Arrondi au multiple de {0} Go supérieur' -f (Fn $sto.RoundingGB 0)) -Computation ('⌈{0}⌉' -f (Fn $systemNeedGB 1)) -Decimals 0)
        if (-not $queueOnSystem) {
            $queueVolumeGB = Get-TsCeiling $queueNeedGB $sto.RoundingGB
            [void](Add-TsValue $ctx 'storage' 'sto.queueSize' 'Disque virtuel de la file d’’attente' $queueVolumeGB -Unit 'Go' -Formula ('Arrondi au multiple de {0} Go supérieur' -f (Fn $sto.RoundingGB 0)) -Computation ('⌈{0}⌉' -f (Fn $queueNeedGB 1)) -Decimals 0)
        }
        [void](Add-TsValue $ctx 'disk' 'io.latency' 'Latences visées sur le volume de la file' ('lecture ≤ {0} ms, écriture ≤ {1} ms' -f $ref.Exchange.DesignReadLatencyMs, $ref.Exchange.DesignWriteLatencyMs) -Kind Microsoft `
                -Source 'Microsoft : seuils de performance des bases ESE Exchange')
    }
    else {
        $volumes = ,@('system', 'système', $phy.SystemDiskType, $phy.SystemDiskSizeGB, $phy.SystemDiskIops, $phy.SystemRaid, $systemNeedGB, $queueOnSystem)
        if (-not $queueOnSystem) { $volumes += ,@('queue', 'file', $phy.DiskType, $phy.DiskSizeGB, $phy.DiskIops, $phy.QueueRaid, $queueNeedGB, $true) }
        foreach ($volume in $volumes) {
            $id = [string]$volume[0]; $label = [string]$volume[1]; $disk = Get-TsDiskCatalog -Name $volume[2]
            $hasQueue = [bool]$volume[7]
            $volumeRead = 0.0; $volumeWrite = 0.0; $ioSizeKB = [double]$ref.Storage.DatasheetIoKB; $sizeKnown = -not $hasQueue
            if ($hasQueue) {
                $volumeRead = $(if ($null -ne $readIops) { $readIops } else { 0.0 })
                $volumeWrite = $(if ($null -ne $writeIops) { $writeIops } else { 0.0 })
                if ($phy.IoSizeKB -gt 0) { $ioSizeKB = $phy.IoSizeKB; $sizeKnown = $true }
                elseif ($null -ne $readBps -and $null -ne $writeBps -and ($volumeRead + $volumeWrite) -gt 0) {
                    $penalty = [double]$ref.Raid[$volume[5]].WritePenalty
                    # RAID duplicates/parity operations are costed with the corresponding write transfer size.
                    $ioSizeKB = ($readBps + $writeBps * $penalty) / ($volumeRead + $volumeWrite * $penalty) / 1024
                    $sizeKnown = $true
                }
                if (-not $sizeKnown -and $volume[4] -le 0) {
                    Add-TsCheck $ctx Warning 'DiskIoSizeMissing' 'Taille d’’E/S du transport inconnue : budget de la fiche à 4 Ko seulement, nombre de disques provisoire. Mesurer les octets lus/écrits ou saisir Physical.IoSizeKB (ou les IOPS réellement mesurées par disque). Les 32 Ko des bases de boîtes ne sont pas supposés.'
                }
                [void](Add-TsValue $ctx 'disk' 'io.sizeKB' 'Taille d’’E/S retenue pour le disque de la file' $ioSizeKB -Unit 'Ko' -Kind $(if ($phy.IoSizeKB -gt 0) { 'Input' } elseif ($sizeKnown) { 'Calibration' } else { 'Assumption' }) `
                        -Formula $(if ($phy.IoSizeKB -gt 0) { 'Taille moyenne saisie' } elseif ($sizeKnown) { '(octets lus + octets écrits × pénalité RAID) ÷ (lectures + écritures × pénalité RAID) ÷ 1 024' } else { '4 Ko de la fiche, taille transport inconnue' }) -Decimals 1)
                if ($disk.Ssd -and $disk.Dwpd -lt 3) {
                    Add-TsCheck $ctx Warning 'DiskEndurance' ('File sur « {0} » ({1} DWPD) : vérifier l’’endurance au trafic réel ; SSD usage mixte 3 DWPD préférable pour les écritures du transport.' -f $disk.Name, (Fn $disk.Dwpd 0))
                }
                if (-not $disk.Ssd -and $volume[5] -in 'RAID-5', 'RAID-6') {
                    Add-TsCheck $ctx Warning 'RaidSlowDisks' ('Volume {0} : {1} sur disque mécanique ({2}), pénalité d’’écriture élevée ; préférer SSD ou RAID-1/0 et confirmer les latences.' -f $label, $volume[5], $disk.Name)
                }
            }
            $layout = Select-TsRaidDisks -Disk $disk -CapacityGB $volume[6] -Raid $volume[5] -ReadIops $volumeRead -WriteIops $volumeWrite -SizeGB $volume[3] -DiskIops $volume[4] -IoOverhead $ioOverhead -IoSizeKB $ioSizeKB
            $layout.PerformanceKnown = $layout.PerformanceKnown -and (-not $hasQueue -or (($null -ne $readIops) -and ($sizeKnown -or $volume[4] -gt 0)))
            if ($hasQueue -and $layout.DiskIops -le 0) { Add-TsCheck $ctx Warning 'DiskIopsMissing' ('« {0} » : IOPS mixtes non publiées par le fabricant. Nombre de disques fondé sur la capacité uniquement ; saisir une mesure par disque.' -f $disk.Name) }
            if ($volume[3] -gt 0 -and $disk.SizesGB -notcontains $volume[3]) {
                Add-TsCheck $ctx Warning 'DiskSizeOffCatalog' ('Volume {0} : {1} Go saisis, capacité absente du catalogue serveur de « {2} » ; confirmer la référence réelle. La saisie est conservée.' -f $label, (Fn $volume[3] 0), $disk.Name)
            }
            if ($layout.TooWide) { Add-TsCheck $ctx Warning 'RaidTooWide' ('Volume {0} : RAID-5 de {1} disques, au-delà de 7 ; préférer RAID-6 ou revoir le groupe RAID.' -f $label, $layout.TotalDisks) }
            [void](Add-TsValue $ctx 'disk' ('io.' + $id + '.disk') ('Modèle de disque du volume ' + $label) $disk.Name -Kind Input -Source $disk.Source -Note ('Vérifié le {0}. {1}' -f $disk.Checked, $disk.Note))
            [void](Add-TsValue $ctx 'disk' ('io.' + $id + '.iops') ('Budget IOPS par disque du volume ' + $label) $layout.DiskIops -Unit 'IOPS' -Kind $(if ($volume[4] -gt 0) { 'Input' } else { 'Assumption' }) -Decimals 0 -Source $disk.Source -Formula $layout.IopsBasis `
                    -Note $(if ($layout.PerformanceKnown) { 'Estimation de conception ; valider les latences sur le stockage réel.' } else { 'Dimensionnement IOPS incomplet.' }))
            [void](Add-TsValue $ctx 'disk' ('io.' + $id + '.size') ('Capacité brute par disque du volume ' + $label) $layout.DiskSizeGB -Unit 'Go' -Kind $(if ($volume[3] -gt 0) { 'Input' } else { 'Rule' }) -Decimals 0 `
                    -Formula 'Saisie, ou capacité du catalogue donnant le moins de disques ; plus petite capacité en cas d’’égalité' -Note ('Modèles dans cette capacité : {0}' -f ($layout.Models -join ' ; ')))
            if ($id -eq 'system') { $systemRaid = $layout } else { $queueRaid = $layout }
        }
        $ioRaid = if ($queueOnSystem) { $systemRaid } else { $queueRaid }
        [void](Add-TsValue $ctx 'disk' 'io.diskIops' 'IOPS par disque portant la file' $ioRaid.DiskIops -Unit 'IOPS' -Kind Assumption -Decimals 1 -Source $ioRaid.Source -Formula $ioRaid.IopsBasis)
        [void](Add-TsValue $ctx 'disk' 'io.formatted' 'Capacité formatée par disque portant la file' $ioRaid.FormattedGB -Unit 'Go' -Formula 'Capacité brute × 10⁹ ÷ 2³⁰' -Computation ('{0} × 10⁹ ÷ 2³⁰' -f (Fn $ioRaid.DiskSizeGB 0)) -Decimals 1)
        $systemGB = $systemRaid.UsableGB
        [void](Add-TsValue $ctx 'storage' 'sto.systemSize' 'Volume système (capacité utile)' $systemGB -Unit 'Go' -Formula 'Disques de données × capacité formatée' -Computation ('{0} × {1}' -f $systemRaid.DataDisks, (Fn $systemRaid.FormattedGB 1)) -Decimals 0)
        [void](Add-TsValue $ctx 'disk' 'io.system' 'Disques du volume système' ('{0} · {1} × {2} Go' -f $systemRaid.Label, $systemRaid.TotalDisks, (Fn $systemRaid.DiskSizeGB 0)) -Kind Computed `
                -Formula 'Disques de données pour la capacité (et les IOPS si la file y est), selon le RAID' -Computation ('capacité : {0} disque(s) de données ; IOPS : {1} disque(s)' -f $systemRaid.DisksForCapacity, $systemRaid.DisksForIops))
        if ($systemRaid.Upgraded) { Add-TsCheck $ctx Info 'RaidUpgraded' ('Volume système : RAID-1 ne suffit pas (capacité ou IOPS), {0} proposé.' -f $systemRaid.Label) }
        if (-not $queueOnSystem) {
            $queueVolumeGB = $queueRaid.UsableGB
            [void](Add-TsValue $ctx 'storage' 'sto.queueSize' 'Volume de la file d’’attente (capacité utile)' $queueVolumeGB -Unit 'Go' -Formula 'Disques de données × capacité formatée' -Computation ('{0} × {1}' -f $queueRaid.DataDisks, (Fn $queueRaid.FormattedGB 1)) -Decimals 0)
            if ($queueRaid.Upgraded) { Add-TsCheck $ctx Info 'RaidUpgradedQueue' ('Volume de la file : RAID-1 ne suffit pas (capacité ou IOPS), {0} proposé.' -f $queueRaid.Label) }
        }
        if ($null -ne $readIops) {
            [void](Add-TsValue $ctx 'disk' 'io.penalty' 'Pénalité d’’écriture RAID' $ioRaid.WritePenalty -Unit '×' -Kind Microsoft -Decimals 0 -Source $msCalc -Note $ioRaid.Raid)
            [void](Add-TsValue $ctx 'disk' 'io.rebuild' 'Réserve pour reconstruction RAID' ($ioRaid.RebuildOverhead * 100) -Unit '%' -Kind Microsoft -Decimals 0 -Source "$msCalc (Storage Design)")
            [void](Add-TsValue $ctx 'disk' 'io.backend' 'IOPS physiques à fournir' $ioRaid.BackendIops -Unit 'IOPS' -Formula '(lectures + écritures × pénalité) × (1 + surcoût) ÷ (1 − réserve de reconstruction)' `
                    -Computation ('({0} + {1} × {2}) × {3} ÷ {4}' -f (Fn $readIops 1), (Fn $writeIops 1), $ioRaid.WritePenalty, (Fn (1 + $ioOverhead) 2), (Fn (1 - $ioRaid.RebuildOverhead) 2)) -Decimals 0)
        }
        if ($queueRaid) {
            [void](Add-TsValue $ctx 'disk' 'io.queue' 'Disques du volume de la file' ('{0} · {1} × {2} Go' -f $queueRaid.Label, $queueRaid.TotalDisks, (Fn $queueRaid.DiskSizeGB 0)) -Kind Computed `
                    -Formula 'max(disques de données pour la capacité, disques pour les IOPS), selon le RAID' -Computation ('capacité : {0} disque(s) de données ; IOPS : {1} disque(s)' -f $queueRaid.DisksForCapacity, $queueRaid.DisksForIops))
        }
        [void](Add-TsValue $ctx 'storage' 'sto.microsoftOs' 'Volume système minimal du calculateur (information)' ([double]$ref.Calculator.MinOsVolumeGB) -Unit 'Go' -Kind Microsoft -Decimals 0 -Source "$msCalc (varMinOSVolume)")
    }
    if ($null -ne $queueVolumeGB -and ($queueVolumeGB - $queueContentGB) -lt $ref.Exchange.QueueFreeSpaceGB) {
        Add-TsCheck $ctx Warning 'QueueFreeSpace' 'Moins de 500 Mo libres sur le volume de la file au pire moment (exigence Microsoft).'
    }
    # ---------------------------------------------------------------- network
    $overhead = 1 + $net.ProtocolOverheadPercent / 100
    $toMbps = 8 / 1e6 * $overhead
    $extIn = 0.0; $extOut = 0.0; $intIn = 0.0; $intOut = 0.0; $dayIn = 0.0; $dayOut = 0.0
    foreach ($row in $flowRows) {
        $inBps = $row.DesignRate * $row.AverageSizeKB * 1024
        $outBps = $inBps * $row.FanOut
        $dayIn += $row.PerServer * $row.AverageSizeKB; $dayOut += $row.PerServer * $row.AverageSizeKB * $row.FanOut
        switch ($row.Direction) {
            'Inbound' { $extIn += $inBps; $intOut += $outBps }
            'Outbound' { $intIn += $inBps; $extOut += $outBps }
            default { $intIn += $inBps; $intOut += $outBps }
        }
    }
    $shadowBps = 0.0
    if ($shadowActive) {
        foreach ($row in @($flowRows | Where-Object { -not $_.Journal })) { $shadowBps += $row.DesignRate * $row.AverageSizeKB * 1024 }
        $dayIn += $mDay * $avgKB; $dayOut += $mDay * $avgKB
    }
    [void](Add-TsValue $ctx 'network' 'net.overhead' 'Surcoût protocolaire (SMTP, TLS, TCP/IP)' $net.ProtocolOverheadPercent -Unit '%' -Kind Assumption -Decimals 0 `
            -Note 'La taille d’’un message Exchange inclut déjà l’’encodage MIME (base64).')
    if ($edge) {
        $extMbps = [Math]::Max($extIn, $extOut) * $toMbps
        $intMbps = [Math]::Max($intIn, $intOut) * $toMbps
        $nicMbps = [Math]::Max($extMbps, $intMbps)
        [void](Add-TsValue $ctx 'network' 'net.extIn' 'Carte externe : réception (Internet vers Edge)' ($extIn * $toMbps) -Unit 'Mbit/s' -Formula 'Σ flux entrants : débit × taille × 8 × (1 + surcoût)' -Decimals 1)
        [void](Add-TsValue $ctx 'network' 'net.extOut' 'Carte externe : émission (Edge vers Internet)' ($extOut * $toMbps) -Unit 'Mbit/s' -Formula 'Σ flux sortants : débit × taille × transmissions × 8 × (1 + surcoût)' -Decimals 1)
        [void](Add-TsValue $ctx 'network' 'net.intIn' 'Carte interne : réception (organisation vers Edge)' ($intIn * $toMbps) -Unit 'Mbit/s' -Formula 'Σ flux sortants et internes : débit × taille × 8 × (1 + surcoût)' -Decimals 1)
        [void](Add-TsValue $ctx 'network' 'net.intOut' 'Carte interne : émission (Edge vers organisation)' ($intOut * $toMbps) -Unit 'Mbit/s' -Formula 'Σ flux entrants et internes : débit × taille × transmissions × 8 × (1 + surcoût)' -Decimals 1)
        [void](Add-TsValue $ctx 'network' 'net.nic' 'Carte la plus chargée (sens le plus chargé)' $nicMbps -Unit 'Mbit/s' -Formula 'max(externe, interne), en duplex intégral' -Computation ('max({0}, {1})' -f (Fn $extMbps 1), (Fn $intMbps 1)) -Decimals 1)
    }
    else {
        $inMbps = ($extIn + $intIn + $shadowBps) * $toMbps
        $outMbps = ($extOut + $intOut + $shadowBps) * $toMbps
        $nicMbps = [Math]::Max($inMbps, $outMbps)
        [void](Add-TsValue $ctx 'network' 'net.in' 'Réception' $inMbps -Unit 'Mbit/s' -Formula 'Σ flux : débit × taille × 8 × (1 + surcoût) + copies shadow reçues' -Decimals 1)
        [void](Add-TsValue $ctx 'network' 'net.out' 'Émission' $outMbps -Unit 'Mbit/s' -Formula 'Σ flux : débit × taille × transmissions × 8 × (1 + surcoût) + copies shadow émises' -Decimals 1)
        [void](Add-TsValue $ctx 'network' 'net.shadow' 'Dont redondance shadow (chaque sens)' ($shadowBps * $toMbps) -Unit 'Mbit/s' -Formula 'Une copie de chaque message reçu vers un autre serveur, et autant reçues des autres' -Decimals 1)
        [void](Add-TsValue $ctx 'network' 'net.nic' 'Carte réseau (sens le plus chargé)' $nicMbps -Unit 'Mbit/s' -Formula 'max(réception, émission), en duplex intégral' -Computation ('max({0}, {1})' -f (Fn $inMbps 1), (Fn $outMbps 1)) -Decimals 1)
    }
    $linkUse = $nicMbps / $net.LinkMbps * 100
    [void](Add-TsValue $ctx 'network' 'net.link' 'Débit de la carte' $net.LinkMbps -Unit 'Mbit/s' -Kind Input -Decimals 0)
    [void](Add-TsValue $ctx 'network' 'net.use' 'Utilisation au débit de dimensionnement' $linkUse -Unit '%' -Formula 'Carte la plus chargée ÷ débit de la carte' -Computation ('{0} ÷ {1}' -f (Fn $nicMbps 1), (Fn $net.LinkMbps 0)) -Decimals 1)
    [void](Add-TsValue $ctx 'network' 'net.dayIn' 'Volume reçu par jour et par serveur' ($dayIn * $overhead / 1048576) -Unit 'Go' -Formula 'Σ messages par jour × taille × (1 + surcoût)' -Decimals 1)
    [void](Add-TsValue $ctx 'network' 'net.dayOut' 'Volume émis par jour et par serveur' ($dayOut * $overhead / 1048576) -Unit 'Go' -Formula 'Σ messages par jour × taille × transmissions × (1 + surcoût)' -Decimals 1)
    if ($cal -and $cal.Models.NetworkInBps -and $cal.MessageSizeKB -gt 0 -and $cal.Models.NetworkInBps.Slope -gt 0) {
        [void](Add-TsValue $ctx 'network' 'net.calibrated' 'Octets reçus par octet de message (mesuré, information)' ($cal.Models.NetworkInBps.Slope / ($cal.MessageSizeKB * 1024)) -Unit '×' `
                -Formula 'Pente du réseau entrant ÷ taille des messages de calibration' -Kind Calibration -Decimals 2 -Source $calLabel -Note 'Inclut les protocoles et le trafic annexe (AD, EdgeSync, supervision) : comparer au surcoût protocolaire saisi.')
    }
    if ($linkUse -gt $net.MaxUtilizationPercent) {
        Add-TsCheck $ctx Warning 'LinkSaturated' ('Carte réseau utilisée à {0} % au débit de dimensionnement (maximum visé {1} %) : prévoir une carte plus rapide ou des serveurs supplémentaires.' -f (Fn $linkUse 0), (Fn $net.MaxUtilizationPercent 0))
    }

    # ---------------------------------------------------------------- capacity and drain
    $rateNetMax = $null
    if ($nicMbps -gt 0) { $rateNetMax = $rateDesign * ($net.LinkMbps * $net.MaxUtilizationPercent / 100) / $nicMbps }
    $rateMax = $rateNetMax
    if ($null -ne $rateCpuMax) { $rateMax = [Math]::Min($rateCpuMax, $rateNetMax) }
    $drainHours = $null
    if ($null -ne $rateCpuMax) {
        [void](Add-TsValue $ctx 'resilience' 'res.cpuMax' 'Débit maximal permis par le processeur' $rateCpuMax -Unit 'msg/s' -Formula '(unités proposées × utilisation maximale ÷ (unités par processeur logique de la référence × hyperviseur × ajustement) ÷ processeurs logiques de la référence × 100 − ordonnée) ÷ coût par message' -Decimals 1)
    }
    [void](Add-TsValue $ctx 'resilience' 'res.netMax' 'Débit maximal permis par le réseau' $rateNetMax -Unit 'msg/s' -Formula 'Débit de dimensionnement × (débit de la carte × utilisation maximale) ÷ charge de la carte' `
            -Computation ('{0} × {1} ÷ {2}' -f (Fn $rateDesign 2), (Fn ($net.LinkMbps * $net.MaxUtilizationPercent / 100) 0), (Fn $nicMbps 1)) -Decimals 1)
    $maxNote = ''
    if ($cal -and $cal.MaxRate -gt 0 -and $rateMax -gt 1.5 * $cal.MaxRate) {
        $maxNote = 'Extrapolé au-delà de 1,5 × le débit le plus élevé mesuré ({0} msg/s).' -f (Fn $cal.MaxRate 1)
    }
    [void](Add-TsValue $ctx 'resilience' 'res.max' 'Débit maximal du serveur proposé' $rateMax -Unit 'msg/s' -Formula $(if ($null -ne $rateCpuMax) { 'min(processeur, réseau)' } else { 'Réseau seul (processeur non calibré)' }) -Decimals 1 -Note $maxNote)
    [void](Add-TsValue $ctx 'resilience' 'res.headroom' 'Marge au-dessus du débit de dimensionnement' ($rateMax / $rateDesign) -Unit '×' -Formula 'Débit maximal ÷ débit de dimensionnement' -Computation ('{0} ÷ {1}' -f (Fn $rateMax 1), (Fn $rateDesign 2)) -Decimals 1)
    if ($cal -and $cal.MaxRate -gt 0) {
        [void](Add-TsValue $ctx 'resilience' 'res.calMax' 'Débit le plus élevé mesuré pendant la calibration' $cal.MaxRate -Unit 'msg/s' -Kind Calibration -Decimals 1 -Source $calLabel -Note 'Au-delà de 1,5 fois cette valeur, les modèles sont extrapolés.')
    }
    if ($backlogMsgs -gt 0) {
        [void](Add-TsValue $ctx 'resilience' 'res.backlog' 'Messages à vider après la panne' $backlogMsgs -Unit 'messages' -Kind Computed -Decimals 0 -Note 'Les copies shadow et Safety Net ne sont pas renvoyées : seule la file primaire se vide.')
        # Drain rate: what the processor (and the network) leaves once the working-hours traffic is handled.
        $drainRate = $null; $drainNetRate = $null; $drainCapped = $false; $drainCpuRate = $null
        if ($null -ne $rateNetMax) { $drainNetRate = $rateNetMax - $rateWorking }
        if ($null -ne $rateCpuMax) {
            $capacity = $cores * $maxCpu / $scale / $lp * 100
            $drainCpuRate = ($capacity - $busyWorking) / $drainCost
            $drainRate = $(if ($null -ne $drainNetRate) { [Math]::Min($drainCpuRate, $drainNetRate) } else { $drainCpuRate })
            # Beyond the drain rate measured, nothing says the server sends faster: the next hop and the delivery
            # connections set the pace (REF-EDGE: 97.5 msg/s at 13 % of CPU, limited by the Mailbox servers of the lab).
            $drainCapped = $false
            if ($drainCal -and $drainCal.Rate -gt 0 -and $drainRate -gt $drainCal.Rate) { $drainRate = [double]$drainCal.Rate; $drainCapped = $true }
            [void](Add-TsValue $ctx 'resilience' 'res.drainCost' 'CPU de la référence par message/s renvoyé depuis la file' $drainCost -Unit '% par msg/s' -Kind $(if ($drainCal) { 'Calibration' } else { 'Rule' }) -Decimals 3 -Source $calLabel `
                    -Formula $(if ($drainCal) { 'Mesuré pendant une vidange' } else { 'Coût d’’un message reçu (pente du modèle × correction de validation)' }) `
                    -Note $(if ($drainCal) { 'Palier {0} : {1} messages renvoyés à {2} msg/s. {3}' -f $drainCal.Step, (Fn $drainCal.Messages 0), (Fn $drainCal.Rate 1), $drainCal.Note } else { 'Vidange non mesurée par le profil : un message renvoyé est compté comme un message reçu (antispam, analyse), ce qui majore la durée de vidange.' }))
            [void](Add-TsValue $ctx 'resilience' 'res.busyWorking' 'CPU de la référence au débit moyen des heures ouvrées' $busyWorking -Unit '%' -Formula 'Modèle au débit moyen des heures ouvrées × correction de validation' `
                    -Computation ('{0} msg/s' -f (Fn $rateWorking 2)) -Decimals 1)
            [void](Add-TsValue $ctx 'resilience' 'res.drainCpuRate' 'Débit de vidange permis par le processeur' $drainCpuRate -Unit 'msg/s' `
                    -Formula '(capacité de la référence à l’’utilisation maximale − CPU des heures ouvrées) ÷ CPU par message renvoyé' `
                    -Computation ('({0} − {1}) ÷ {2}' -f (Fn $capacity 1), (Fn $busyWorking 1), (Fn $drainCost 3)) -Decimals 1 `
                    -Note 'Capacité = cœurs proposés × utilisation maximale ÷ (rapport × hyperviseur × ajustement), ramenée en % des processeurs logiques de la référence.')
        }
        elseif ($null -ne $drainNetRate) { $drainRate = $drainNetRate }
        if ($null -ne $drainRate -and $drainRate -gt 0) {
            $drainHours = $backlogMsgs / ($drainRate * 3600)
            $drainRateFormula = $(if ($null -eq $rateCpuMax) { 'Réseau − débit des heures ouvrées (processeur non calibré)' } elseif ($drainCapped) { 'Débit de vidange mesuré par le profil (plafond : au-delà, non mesuré)' } else { 'min(processeur, réseau − débit des heures ouvrées)' })
            [void](Add-TsValue $ctx 'resilience' 'res.drainRate' 'Débit de vidange (en plus du trafic des heures ouvrées)' $drainRate -Unit 'msg/s' -Formula $drainRateFormula -Decimals 1 `
                    -Note $(if ($drainCapped) { 'Le processeur permettrait {0} msg/s ; le profil n’’a mesuré qu’’une vidange à {1} msg/s, limitée par le saut suivant : la durée de vidange en reste là.' -f (Fn $drainCpuRate 0), (Fn $drainCal.Rate 1) } else { '' }))
            [void](Add-TsValue $ctx 'resilience' 'res.drain' 'Durée de vidange' $drainHours -Unit 'h' -Formula 'Messages à vider ÷ (débit de vidange × 3 600)' `
                    -Computation ('{0} ÷ ({1} × 3 600)' -f (Fn $backlogMsgs 0), (Fn $drainRate 1)) -Decimals 1 -Note 'Limite du serveur : le saut suivant (serveurs de boîtes, Internet, relais) peut accepter moins. Sur REF-EDGE, la vidange a été limitée par les serveurs Mailbox du labo (97,5 à 110 msg/s).')
            if ($null -ne $readIops) {
                $drainIo = $(if ($drainCal) { [double]$drainCal.ReadIopsPerMsg + [double]$drainCal.WriteIopsPerMsg } else { 0.0 })
                if ($drainIo -gt 0) {
                    # Traffic of the working hours by the models, plus the reads and writes measured per message sent from the queue.
                    $workLoad = & $newLoad $rateWorking
                    $drainIops = ([Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueReadIops $workLoad)) + [Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueWriteIops $workLoad)) + $drainRate * $drainIo) * (1 + $ioOverhead) * $adj.IoPercent / 100
                    $drainIopsFormula = '(Modèles d’’E/S au débit des heures ouvrées + débit de vidange × E/S mesurées par message renvoyé) × (1 + surcoût)'
                    $drainIopsComputation = '{0} msg/s × {1} E/S par message' -f (Fn $drainRate 1), (Fn $drainIo 2)
                }
                else {
                    $maxLoad = & $newLoad ($rateWorking + $drainRate)
                    $drainIops = ([Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueReadIops $maxLoad)) + [Math]::Max(0.0, (Get-TsModelValue $cal.Models.QueueWriteIops $maxLoad))) * (1 + $ioOverhead) * $adj.IoPercent / 100
                    $drainIopsFormula = 'Modèles d’’E/S au débit des heures ouvrées + vidange × (1 + surcoût)'
                    $drainIopsComputation = ''
                }
                [void](Add-TsValue $ctx 'resilience' 'res.drainIops' 'IOPS de la file pendant la vidange' $drainIops -Unit 'IOPS' -Formula $drainIopsFormula -Computation $drainIopsComputation -Kind Calibration -Decimals 0 -Source $calLabel `
                        -Note 'Un message déshydraté est relu dans mail.que. Si le stockage ne fournit pas ces IOPS, la vidange est plus lente : ce n’’est pas une condition de dimensionnement.')
            }
        }
        else { Add-TsCheck $ctx Warning 'NoDrain' 'Le serveur proposé ne dépasse pas le débit moyen des heures ouvrées : la file accumulée pendant une panne en journée ne se viderait qu’’après la journée de travail.' }
        if ($res.DrainTargetHours -gt 0) {
            [void](Add-TsValue $ctx 'resilience' 'res.drainTarget' 'Durée de vidange visée' $res.DrainTargetHours -Unit 'h' -Kind Input -Decimals 1 `
                    -Note 'Les processeurs sont dimensionnés pour renvoyer la file de la panne dans ce délai tout en recevant le trafic des heures ouvrées. 0 = pas de condition.')
            if ($null -ne $drainCoresNeeded) {
                [void](Add-TsValue $ctx 'resilience' 'res.drainCores' 'Cœurs nécessaires à 100 % pour la vidange visée' $drainCoresNeeded -Unit 'cœurs' `
                        -Formula '(CPU des heures ouvrées + CPU par message renvoyé × min(messages à vider ÷ durée visée, vidange mesurée)) ÷ 100 × processeurs logiques × rapport × hyperviseur × ajustement' `
                        -Computation ('({0} + {1} × {2}) ÷ 100 × {3} × {4}' -f (Fn $busyWorking 1), (Fn $drainCost 3), (Fn $rateForCores 1), (Fn $lp 0), (Fn $scale 2)) -Decimals 2)
            }
            if ($null -ne $drainHours -and $drainHours -gt $res.DrainTargetHours * 1.001) {
                Add-TsCheck $ctx Warning 'DrainSlow' ('Vidange de {0} h, au-delà des {1} h visées : {2} limite le débit de vidange.' -f (Fn $drainHours 1), (Fn $res.DrainTargetHours 0), $(if ($drainCapped) { 'la vidange mesurée par le profil ({0} msg/s, saut suivant du labo), pas le processeur,' -f (Fn $drainCal.Rate 1) } elseif ($null -ne $drainNetRate -and $drainRate -ge $drainNetRate) { 'le réseau' } else { 'le processeur du serveur saisi' }))
            }
        }
    }

    # ---------------------------------------------------------------- Microsoft calculator
    $msSafetyNetDays = $res.SafetyNetHoldTimeHours / 24
    if (-not $edge) { $msSafetyNetDays = $safetyNetH / 24 }
    $ms = Get-TsMicrosoftQueueEstimate -MessagesPerDayPerServer $mDay -AverageSizeKB $avgKB -MessageExpirationDays ($expirationH / 24) -SafetyNetDays $msSafetyNetDays -Shadow $true
    [void](Add-TsValue $ctx 'microsoft' 'ms.perServer' 'Messages par jour et par serveur' $mDay -Unit 'msg/j' -Kind Computed -Decimals 0 -Note 'Mêmes messages que ce modèle (croissance et panne comprises).')
    [void](Add-TsValue $ctx 'microsoft' 'ms.shadow' 'Effet shadow' $ms.ShadowFactor -Unit '×' -Kind Microsoft -Decimals 0 -Source "$msCalc (Role Requirements C187)" `
            -Note $(if ($edge) { 'Appliqué par le calculateur à tout serveur de transport ; sans objet pour un Edge.' } else { 'Toujours ×2, même si un seul serveur reste.' }))
    [void](Add-TsValue $ctx 'microsoft' 'ms.multiplier' 'Multiplicateur de file' $ms.Multiplier -Unit '×' -Formula '1 + 0,5 × expiration (jours) + Safety Net (jours)' `
            -Computation ('1 + 0,5 × {0} + {1}' -f (Fn ($expirationH / 24) 2), (Fn $msSafetyNetDays 2)) -Kind Microsoft -Decimals 2 -Source "$msCalc (Role Requirements C188, Variables K56)" `
            -Note $(if ($edge) { 'Safety Net appliqué par le calculateur ; sans objet pour un Edge.' } else { '0,5 = part des messages supposée en file pendant toute l’’expiration.' }))
    [void](Add-TsValue $ctx 'microsoft' 'ms.queue' 'Base de transport par serveur (calculateur)' $ms.SizeGB -Unit 'Go' -Formula 'Messages par jour et par serveur × shadow × multiplicateur × taille moyenne ÷ 1 048 576' `
            -Computation ('{0} × {1} × {2} × {3} Ko ÷ 1 048 576' -f (Fn $mDay 0), $ms.ShadowFactor, (Fn $ms.Multiplier 2), (Fn $avgKB 1)) -Kind Microsoft -Decimals 1 -Source "$msCalc (Role Requirements C189)")
    [void](Add-TsValue $ctx 'microsoft' 'ms.ours' 'mail.que de ce modèle' $mailQueGB -Unit 'Go' -Kind Computed -Decimals 1)
    $gap = $null
    if ($ms.SizeGB -gt 0) {
        $gap = ($mailQueGB - $ms.SizeGB) / $ms.SizeGB * 100
        [void](Add-TsValue $ctx 'microsoft' 'ms.gap' 'Écart avec le calculateur' $gap -Unit '%' -Formula '(ce modèle − calculateur) ÷ calculateur' -Computation ('({0} − {1}) ÷ {1}' -f (Fn $mailQueGB 1), (Fn $ms.SizeGB 1)) -Decimals 0)
    }
    [void](Add-TsValue $ctx 'microsoft' 'ms.cpu' 'Processeur, mémoire, IOPS et réseau de transport' 'Non calculés par le calculateur' -Kind Microsoft -Source $msCalc `
            -Note 'Le calculateur dimensionne le processeur et la mémoire à partir des boîtes aux lettres ; un serveur sans boîte ou un Edge n’’a pas de profil.')

    # ---------------------------------------------------------------- target configuration
    $config = [Collections.Generic.List[object]]::new()
    $coreUnit = if ($virtual) { 'vCPU' } else { 'cœurs' }
    if ($null -ne $cores) {
        $cpuDetail = 'utilisation de {0} % au débit de dimensionnement ({1} msg/s)' -f (Fn ($cpuUtilization * 100) 0), (Fn $rateDesign 1)
        if ($null -ne $drainHours) { $cpuDetail += ' ; file de la panne vidée en {0} h' -f (Fn $drainHours 1) }
        if (-not $virtual -and $phy.SpecIntRate2017 -gt 0) { $cpuDetail += (' ; SPECint_rate2017 {0}' -f (Fn $phy.SpecIntRate2017 0)) }
        if ($virtual) { $cpuDetail += (' ; {0} vCPU par cœur de l’’hôte : un vCPU compte pour {1} % d’’un cœur{2}' -f (Fn $cmp.VcpuRatio 1), (Fn ($vcpuShare * 100) 0), $(if ($cmp.TargetProcessor) { ' ({0})' -f $cmp.TargetProcessor } elseif ($specKnown) { ' (SPECint {0} par cœur)' -f (Fn $specTarget 1) } else { '' })) }
        $config.Add([pscustomobject]@{ Component = 'Processeur'; Value = ('{0} {1}' -f $cores, $coreUnit); Detail = $cpuDetail; Status = 'ok' })
    }
    else { $config.Add([pscustomobject]@{ Component = 'Processeur'; Value = 'À calibrer'; Detail = 'Importer un profil de calibration.'; Status = 'missing' }) }
    if ($null -ne $ramGB) {
        $config.Add([pscustomobject]@{ Component = 'Mémoire'; Value = ('{0} Go' -f (Fn $ramGB 0)); Detail = ('{0} Go nécessaires (seuils back pressure {1} % / {2} %, marge {3} %){4}' -f (Fn $ramNeededGB 1), $bp.PrivateBytes, $bp.SystemMemory, (Fn $cmp.RamMarginPercent 0), $(if ($null -ne $memReservedGB) { ' ; réservée sur l’’hôte : {0} Go, au moins {1} Go' -f (Fn $memReservedGB 1), (Fn $memReserveMinGB 0) } else { '' })); Status = $(if ($null -ne $memReservedGB -and $memReservedGB -lt $memReserveMinGB) { 'warning' } else { 'ok' }) })
    }
    else { $config.Add([pscustomobject]@{ Component = 'Mémoire'; Value = 'À calibrer'; Detail = 'Importer un profil de calibration.'; Status = 'missing' }) }
    $systemDetail = 'Windows, Exchange, journaux' + $(if ($null -ne $pagefileGB) { (', fichier d’’échange {0} Go' -f (Fn $pagefileGB 0)) } else { ', sans le fichier d’’échange (RAM non calculée)' }) + $(if ($queueOnSystem) { ', file d’’attente' } else { '' })
    if ($virtual) {
        $config.Add([pscustomobject]@{ Component = 'Disque système'; Value = ('{0} Go' -f (Fn $systemGB 0)); Detail = $systemDetail; Status = $(if ($null -ne $pagefileGB) { 'ok' } else { 'partial' }) })
        if (-not $queueOnSystem) {
            $queueDetail = 'mail.que {0} Go et journaux ; {1}{2}lecture ≤ {3} ms, écriture ≤ {4} ms' -f (Fn $mailQueGB 1), $(if ($null -ne $frontIops) { '≥ {0} IOPS, ' -f (Fn $frontIops 0) } else { 'IOPS à calibrer, ' }),
            $(if ($null -ne $writeMBps) { '≥ {0} Mo/s en écriture, ' -f (Fn $writeMBps 1) } else { '' }), $ref.Exchange.DesignReadLatencyMs, $ref.Exchange.DesignWriteLatencyMs
            $config.Add([pscustomobject]@{ Component = 'Disque file d’’attente'; Value = ('{0} Go' -f (Fn $queueVolumeGB 0)); Detail = $queueDetail; Status = $(if ($null -ne $frontIops) { 'ok' } else { 'partial' }) })
        }
    }
    else {
        $config.Add([pscustomobject]@{ Component = 'Disques système'; Value = ('{0} × {1} Go' -f $systemRaid.TotalDisks, (Fn $systemRaid.DiskSizeGB 0)); Detail = ('{0}, {1} ; {2} Go utiles pour {3} Go nécessaires ; {4}' -f $systemRaid.Label, $systemRaid.DiskName, (Fn $systemRaid.UsableGB 0), (Fn $systemNeedGB 0), $systemDetail); Status = $(if ($queueOnSystem -and -not $systemRaid.PerformanceKnown) { 'partial' } else { 'ok' }) })
        if ($queueRaid) {
            $config.Add([pscustomobject]@{ Component = 'Disques file d’’attente'; Value = ('{0} × {1} Go' -f $queueRaid.TotalDisks, (Fn $queueRaid.DiskSizeGB 0)); Status = $(if ($queueRaid.PerformanceKnown) { 'ok' } else { 'partial' })
                    Detail = ('{0}, {1} ; {2} Go utiles pour {3} Go nécessaires ; {4}' -f $queueRaid.Label, $queueRaid.DiskName, (Fn $queueRaid.UsableGB 0), (Fn $queueNeedGB 0), $(if ($queueRaid.PerformanceKnown) { '{0} IOPS physiques, budget {1} IOPS/disque' -f (Fn $queueRaid.BackendIops 0), (Fn $queueRaid.DiskIops 0) } else { 'Dimensionnement IOPS incomplet, voir les points d’’attention' }))
                })
        }
    }
    if ($edge) {
        $config.Add([pscustomobject]@{ Component = 'Réseau'; Value = ('2 cartes {0} Mbit/s' -f (Fn $net.LinkMbps 0)); Detail = ('interne {0} Mbit/s et externe {1} Mbit/s au débit de dimensionnement' -f (Fn $intMbps 1), (Fn $extMbps 1)); Status = $(if ($linkUse -gt $net.MaxUtilizationPercent) { 'warning' } else { 'ok' }) })
    }
    else {
        $config.Add([pscustomobject]@{ Component = 'Réseau'; Value = ('1 carte {0} Mbit/s' -f (Fn $net.LinkMbps 0)); Detail = ('{0} Mbit/s au débit de dimensionnement{1}' -f (Fn $nicMbps 1), $(if ($shadowActive) { ', redondance shadow comprise' } else { '' })); Status = $(if ($linkUse -gt $net.MaxUtilizationPercent) { 'warning' } else { 'ok' }) })
    }
    if ($null -ne $pagefileGB) { $config.Add([pscustomobject]@{ Component = 'Fichier d’’échange'; Value = ('{0} Go' -f (Fn $pagefileGB 0)); Detail = 'Taille fixe (minimum = maximum), 25 % de la RAM'; Status = 'ok' }) }
    $settings = @('MessageExpirationTimeout {0}' -f (Format-TsTimeSpan $expirationH))
    if (-not $edge) { $settings += @(('SafetyNetHoldTime {0}' -f (Format-TsTimeSpan $res.SafetyNetHoldTimeHours)), ('ShadowRedundancyEnabled {0}' -f $res.ShadowRedundancy)) }
    if (-not $queueOnSystem) { $settings += 'QueueDatabasePath et QueueDatabaseLoggingPath sur le volume de la file (Move-TransportDatabase.ps1)' }
    $config.Add([pscustomobject]@{ Component = 'Paramètres de transport'; Value = $(if ($edge) { 'Edge Transport' } else { 'Mailbox' }); Detail = ($settings -join ' ; '); Status = 'ok' })

    $rules = if ($edge) {
        @(
            'Edge Transport : ni Safety Net ni redondance shadow (rôle Mailbox uniquement) ; leurs paramètres sont ignorés.'
            'File d’’attente = messages en transit + messages accumulés pendant une panne du saut suivant (plafonnée à l’’expiration).'
            'Deux cartes réseau : externe (Internet) et interne (organisation) ; chaque message passe une fois par chacune.'
        )
    }
    else {
        @(
            'Mailbox (transport) : Safety Net garde chaque message traité pendant SafetyNetHoldTime, même sans boîte aux lettres sur le serveur.'
            'Redondance shadow : chaque message en file a une copie sur un autre serveur Mailbox du même site AD (sans DAG) ou du DAG ; chaque serveur détient autant de copies pour ses voisins. Elle est comptée dès qu’’un site (ou le DAG) garde deux serveurs.'
            'File d’’attente = transit + panne du saut suivant + Safety Net, doublés par les copies shadow.'
        )
    }
    $rules += 'Processeur, mémoire et IOPS : uniquement mesurés (calibration), jamais tirés de valeurs génériques.'
    $rules += 'Coût d’’un message = coût fixe + taille (Mo/s) + règles de transport + sessions SMTP et TLS, chaque terme mesuré séparément quand le profil le permet.'

    $summary = [ordered]@{
        Role = $s.Role; RoleLabel = $script:TsRoles[$s.Role]; Deployment = $s.Deployment; DeploymentLabel = $script:TsDeployments[$s.Deployment]
        Sites = $sites; ServersPerSite = $perSite; Servers = $servers; Alive = $alive; Failure = $topo.Failure; FailureLabel = $failureLabel
        CoreUnit = $coreUnit; Cores = $cores; CpuUtilization = $cpuUtilization; VcpuRatio = $(if ($virtual) { $cmp.VcpuRatio } else { $null }); RamGB = $ramGB; MemoryReservedGB = $memReservedGB; MemoryReserveMinGB = $memReserveMinGB; SystemGB = $systemGB; QueueVolumeGB = $queueVolumeGB; QueueOnSystem = $queueOnSystem
        MailQueGB = $mailQueGB; QueueMessages = $queueMsgs; Iops = $frontIops; QueueWriteMBps = $writeMBps; NetworkMbps = $nicMbps; LinkUse = $linkUse
        MessagesPerDay = $totalDay; MessagesPerDayPerServer = $mDay; AverageSizeKB = $avgKB; RateAverage = $rateAvg; RatePeak = $ratePeak; Burst = $burst; RateWorking = $rateWorking; WorkingHours = $workingH; PeakHours = $peakH; PeakHourPercent = $peak * 100; PeakFromRate = $peakFromRate; RateDesign = $rateDesign; RateMax = $rateMax; RateMaxExtrapolated = [bool]$maxNote
        TransportRules = $transportRules; TlsPercent = $load.TlsPercent; MessagesPerSession = $perSession
        DrainHours = $drainHours; MicrosoftQueueGB = $ms.SizeGB; MicrosoftGap = $gap; Calibrated = [bool]$cal; CalibrationName = $(if ($cal) { $cal.Name } else { '' }); ProfileSource = $profileSource
        AdjustCpuPercent = $adj.CpuPercent; AdjustIoPercent = $adj.IoPercent; AdjustMemoryAtRestGB = $adj.MemoryAtRestGB
        SystemRaid = $systemRaid; QueueRaid = $queueRaid
        OperatingSystem = [string]$ref.Exchange.OperatingSystem; OffHoursPercent = $load.OffHoursPercent; GrowthPercent = $load.GrowthPercent; OutageHours = $res.OutageHours
    }
    return (New-TsResult -Context $ctx -Scenario $s -Valid $true -Summary $summary -Config $config -Flows $flowRows -QueueParts $queueParts -SystemParts $systemParts -Rules $rules)
}

function New-TsResult {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][object]$Scenario,
        [bool]$Valid,
        [AllowNull()][object]$Summary,
        [AllowNull()][object]$Config,
        [AllowNull()][object]$Flows,
        [AllowNull()][object]$QueueParts,
        [AllowNull()][object]$SystemParts,
        [AllowNull()][object]$Rules
    )
    $order = @{ Error = 0; Warning = 1; Info = 2 }
    $lists = @{ Config = $Config; Flows = $Flows; QueueParts = $QueueParts; SystemParts = $SystemParts; Rules = $Rules }
    foreach ($name in @($lists.Keys)) {
        $value = $lists[$name]
        $lists[$name] = @(foreach ($item in $value) { if ($null -ne $item) { $item } })
    }
    $sections = @(foreach ($section in $Context.Sections.Values) {
            if ($section.Values.Count -gt 0) { [pscustomobject]@{ Id = $section.Id; Title = $section.Title; Intro = $section.Intro; Values = @(foreach ($item in $section.Values) { $item }) } }
        })
    $checks = @($Context.Checks | Sort-Object -Property @{ Expression = { $order[$_.Level] } }, @{ Expression = { $_.Index } })
    [pscustomobject]@{
        Tool        = 'Transport Sizer'
        Version     = $script:ToolVersion
        GeneratedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        Valid       = $Valid
        Scenario    = $Scenario
        Summary     = $Summary
        Config      = $lists.Config
        Flows       = $lists.Flows
        QueueParts  = $lists.QueueParts
        SystemParts = $lists.SystemParts
        Rules       = $lists.Rules
        Sections    = $sections
        Checks      = $checks
        Values      = $Context.Values
    }
}
#endregion ENGINE
