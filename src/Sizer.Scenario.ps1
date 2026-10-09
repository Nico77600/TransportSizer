<#
.SYNOPSIS
    Transport Sizer - scenarios and calibration profiles (dot-sourced by TransportSizer.psm1).

.DESCRIPTION
    A scenario is the equivalent of the input sheet of the Excel calculator: role, deployment, topology,
    message flows, load, resilience, storage, network, compute and physical hardware. It is a nested
    hashtable, saved as JSON. ConvertTo-TsScenario completes a partial scenario with the defaults of its
    role and checks every value, so the engine always works on a complete and typed scenario.

    A calibration profile is the JSON written by calibration\Measure-TransportLoad.ps1 -Analyze: linear
    models (per message/s) of CPU, memory and IOPS measured on a reference server.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.10.0
#>

$script:TsReference = $null
$script:TsReferenceProfiles = $null
$script:TsProcessorCatalog = $null
$script:TsDirections = [ordered]@{ Inbound = 'Entrant'; Outbound = 'Sortant'; Internal = 'Interne' }
$script:TsFailures = [ordered]@{ None = 'Aucune panne'; OneServer = 'Perte d’’un serveur'; TwoServers = 'Perte de deux serveurs'; OneSite = 'Perte d’’un site' }
$script:TsRoles = [ordered]@{ Edge = 'Edge Transport'; Mailbox = 'Mailbox (transport)' }
$script:TsDeployments = [ordered]@{ Virtual = 'Virtuel'; Physical = 'Physique' }
$script:TsQueueVolumes = [ordered]@{ Dedicated = 'Volume dédié'; System = 'Volume système' }
$script:TsJournalScopes = [ordered]@{ Global = 'Tous les messages'; Internal = 'Messages internes'; External = 'Messages externes' }
$script:TsJournalDestinations = [ordered]@{ External = 'Archive externe (envoi sortant)'; Internal = 'Boîte de journalisation interne' }
$script:TsPeakRateUnits = [ordered]@{ PerHour = 'msg/h'; PerSecond = 'msg/s' }
# Terms of a calibration model besides the intercept and the cost per message (Slope).
$script:TsModelTerms = @('PerMBps', 'PerRuleMsg', 'PerSession', 'PerTlsSession', 'PerTlsMBps', 'PerJournal')

function Get-TsReference {
    <# The reference tables of data\Reference.psd1, loaded once. #>
    if (-not $script:TsReference) {
        $script:TsReference = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ToolRoot 'data\Reference.psd1')
    }
    return $script:TsReference
}

function Get-TsField {
    <# A property of a hashtable or of an object (JSON), or the default when it is missing or null. #>
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()][object]$Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) { return $property.Value }
    return $Default
}

function ConvertTo-TsNumber {
    <# A number typed by a user: comma or dot as decimal separator, spaces ignored. Throws in French. #>
    param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Value) { throw "$Name : valeur manquante." }
    if ($Value -is [bool]) { throw "$Name : nombre attendu." }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [single]) { return [double]$Value }
    $text = ([string]$Value).Trim() -replace '[\s\u00A0\u202F]', ''
    $text = $text.Replace(',', '.')
    $number = 0.0
    if ($text -eq '' -or -not [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        throw "$Name : « $Value » n’est pas un nombre."
    }
    return $number
}

function ConvertTo-TsBoolean {
    param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][string]$Name)

    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim()
    if ($text -in 'true', '1', 'oui', 'yes', 'vrai') { return $true }
    if ($text -in 'false', '0', 'non', 'no', 'faux', '') { return $false }
    throw "$Name : « $Value » n’est pas une valeur oui/non."
}

function Get-TsDefaultScenario {
    <#
    .SYNOPSIS
        The default scenario of a role: the starting point of the window and of ConvertTo-TsScenario.
    .DESCRIPTION
        Traffic values are examples to replace. The other values are documented defaults: Microsoft
        (message expiration, Safety Net hold time), reference lab measurements (transport logs) or
        assumptions shown as such in the report.
    #>
    [CmdletBinding()]
    param([ValidateSet('Edge', 'Mailbox')][string]$Role = 'Edge')

    $edge = $Role -eq 'Edge'
    if ($edge) {
        $flows = @(
            [ordered]@{ Name = 'Entrant Internet'; Direction = 'Inbound'; MessagesPerDay = 100000; AverageSizeKB = 75; FanOut = 1; HeldDuringOutage = $true }
            [ordered]@{ Name = 'Sortant Internet'; Direction = 'Outbound'; MessagesPerDay = 50000; AverageSizeKB = 75; FanOut = 1.2; HeldDuringOutage = $true }
        )
    }
    else {
        $flows = @(
            [ordered]@{ Name = 'Entrant (Edge, Internet)'; Direction = 'Inbound'; MessagesPerDay = 100000; AverageSizeKB = 75; FanOut = 1; HeldDuringOutage = $true }
            [ordered]@{ Name = 'Sortant (vers Edge, Internet)'; Direction = 'Outbound'; MessagesPerDay = 50000; AverageSizeKB = 75; FanOut = 1.2; HeldDuringOutage = $true }
            [ordered]@{ Name = 'Relais applicatif'; Direction = 'Internal'; MessagesPerDay = 20000; AverageSizeKB = 40; FanOut = 1; HeldDuringOutage = $true }
        )
    }
    $reference = Get-TsReference
    [ordered]@{
        SchemaVersion   = 1
        Name            = $(if ($edge) { 'Edge Transport' } else { 'Mailbox (transport)' })
        Customer        = ''
        Author          = ''
        Notes           = ''
        Role            = $Role
        Deployment      = 'Virtual'
        Topology        = [ordered]@{ Sites = 2; ServersPerSite = 2; Failure = 'OneServer'; Dag = $false }
        Flows           = $flows
        # Day of the traffic: working hours, share outside them, peak (share of the day per peak hour, or a rate
        # measured for the whole organisation when PeakRate > 0) and how many hours the peak lasts.
        Load            = [ordered]@{
            GrowthPercent = 20; PeakHourPercent = 15; BurstFactor = 1; TransportRules = 0; TlsPercent = 100; MessagesPerSession = $(if ($edge) { 1 } else { 10 })
            WorkingHours = 10; OffHoursPercent = 10; PeakHours = 2; PeakRate = 0; PeakRateUnit = 'PerHour'
        }
        # DrainTargetHours: time to send the queue of the outage again, on top of the working-hours traffic (0 = not a sizing condition).
        Resilience      = [ordered]@{ MessageExpirationHours = 48; OutageHours = 24; ResidenceSeconds = 60; SafetyNetHoldTimeHours = 48; ShadowRedundancy = $true; ReplayLagHours = 0; SpaceReclaimDays = 1; DrainTargetHours = 12 }
        Journaling      = [ordered]@{ Enabled = $false; Scope = 'Global'; Percent = 100; Recipients = 1; OverheadKB = 4; Destination = 'External'; HeldDuringOutage = $true }
        # Adaptation of the calibration profile (reference or imported) to the context of the customer.
        Adjustment      = [ordered]@{ CpuPercent = 100; IoPercent = 100; MemoryAtRestGB = 0 }
        Storage         = [ordered]@{
            QueueVolume = 'Dedicated'; MaxFillPercent = 80; IoOverheadPercent = 20; RoundingGB = 10
            OsGB = 40; ExchangeBinariesGB = $(if ($edge) { 6 } else { 15 }); DiagnosticLogsGB = $(if ($edge) { 10 } else { 20 })
            TransportLogsGB = $(if ($edge) { [double]$reference.Lab.TransportLogsEdgeGB } else { 10 }); OtherTransportDataGB = 1
        }
        Network         = [ordered]@{ LinkMbps = 1000; MaxUtilizationPercent = 70; ProtocolOverheadPercent = 5 }
        # EvenVcpu: virtual processors rounded up to an even number (sockets × cores, vNUMA, hyper-threading pairs).
        # VcpuRatio: vCPU allocated per physical core on the hosts (2 = 2:1, the most Microsoft supports); SmtGainPercent:
        # gain of hyper-threading on the hosts; MemoryReservedPercent: share of the RAM of the VM reserved on the host.
        Compute         = [ordered]@{
            MaxCpuPercent = 80; TargetProcessor = ''; TargetSpecIntRatePerCore = 0; HypervisorOverheadPercent = [double]$reference.Exchange.HypervisorOverheadPct
            VcpuRatio = [double]$reference.Virtualization.DefaultVcpuRatio; SmtGainPercent = [double]$reference.Virtualization.SmtGainPercent; MinCores = 4; EvenVcpu = $true
            RamMarginPercent = 10; MinRamGB = 8; MemoryReservedPercent = 100
        }
        Physical        = [ordered]@{
            SpecIntRate2017 = 0; Cores = 0; DiskType = 'SSD SAS usage mixte (3 DWPD)'; DiskSizeGB = 0; DiskIops = 0
            SystemDiskType = 'M.2 NVMe de démarrage (BOSS-N1, NS204i)'; SystemDiskSizeGB = 0; SystemDiskIops = 0
            IoSizeKB = 0; QueueRaid = 'RAID-1/0'; SystemRaid = 'RAID-1'
        }
        CalibrationPath = ''
        Calibration     = $null
    }
}

function ConvertTo-TsFlow {
    param([Parameter(Mandatory = $true)][object]$Flow, [int]$Index)

    $label = "Flux $Index"
    $name = [string](Get-TsField $Flow 'Name' $label)
    if ($name.Trim()) { $label = "Flux « $name »" }
    $direction = [string](Get-TsField $Flow 'Direction' 'Inbound')
    # The window and old files may use the French labels.
    foreach ($key in $script:TsDirections.Keys) { if ($script:TsDirections[$key] -eq $direction) { $direction = $key } }
    if (-not $script:TsDirections.Contains($direction)) { throw "$label : sens inconnu « $direction » (Inbound, Outbound ou Internal)." }
    $flow = [ordered]@{
        Name             = $name
        Direction        = $direction
        MessagesPerDay   = ConvertTo-TsNumber (Get-TsField $Flow 'MessagesPerDay' 0) "$label, messages par jour"
        AverageSizeKB    = ConvertTo-TsNumber (Get-TsField $Flow 'AverageSizeKB' 75) "$label, taille moyenne"
        FanOut           = ConvertTo-TsNumber (Get-TsField $Flow 'FanOut' 1) "$label, transmissions par message"
        HeldDuringOutage = ConvertTo-TsBoolean (Get-TsField $Flow 'HeldDuringOutage' $true) "$label, retenu pendant la panne"
    }
    if ($flow.MessagesPerDay -lt 0) { throw "$label : le nombre de messages par jour ne peut pas être négatif." }
    if ($flow.AverageSizeKB -le 0) { throw "$label : la taille moyenne doit être positive." }
    if ($flow.FanOut -lt 1) { throw "$label : au moins une transmission par message." }
    return $flow
}

function ConvertTo-TsScenario {
    <#
    .SYNOPSIS
        A complete, typed scenario from a partial one (hashtable or JSON object): the defaults of the role
        fill the missing values. Throws a French message on the first invalid value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Scenario)

    $role = [string](Get-TsField $Scenario 'Role' 'Edge')
    if (-not $script:TsRoles.Contains($role)) { throw "Rôle inconnu « $role » : Edge ou Mailbox." }
    $result = Get-TsDefaultScenario -Role $role
    foreach ($key in 'Name', 'Customer', 'Author', 'Notes', 'Deployment', 'CalibrationPath') {
        $result[$key] = [string](Get-TsField $Scenario $key $result[$key])
    }
    if (-not $script:TsDeployments.Contains($result.Deployment)) { throw "Déploiement inconnu « $($result.Deployment) » : Virtual ou Physical." }

    # A scenario of a version before 1.6 has a peak share for a day of 24 hours and no working day: it keeps that
    # meaning (24 working hours, no traffic outside them, one peak hour), so that its result does not change.
    $sourceLoad = Get-TsField $Scenario 'Load' $null
    if ($null -ne $sourceLoad -and $null -eq (Get-TsField $sourceLoad 'WorkingHours' $null)) {
        $result.Load.WorkingHours = 24; $result.Load.OffHoursPercent = 0; $result.Load.PeakHours = 1
    }
    # Same for 1.7: a scenario saved before keeps its processors (2 at least, no even rounding, no drain target).
    $sourceCompute = Get-TsField $Scenario 'Compute' $null
    if ($null -ne $sourceCompute -and $null -eq (Get-TsField $sourceCompute 'EvenVcpu' $null)) { $result.Compute.MinCores = 2; $result.Compute.EvenVcpu = $false }
    $sourceResilience = Get-TsField $Scenario 'Resilience' $null
    if ($null -ne $sourceResilience -and $null -eq (Get-TsField $sourceResilience 'DrainTargetHours' $null)) { $result.Resilience.DrainTargetHours = 0 }
    foreach ($group in 'Topology', 'Load', 'Resilience', 'Journaling', 'Adjustment', 'Storage', 'Network', 'Compute', 'Physical') {
        $source = Get-TsField $Scenario $group $null
        foreach ($key in @($result[$group].Keys)) {
            $default = $result[$group][$key]
            $value = Get-TsField $source $key $default
            $name = "$group.$key"
            if ($default -is [bool]) { $result[$group][$key] = ConvertTo-TsBoolean $value $name }
            elseif ($default -is [string]) { $result[$group][$key] = [string]$value }
            else { $result[$group][$key] = ConvertTo-TsNumber $value $name }
        }
    }

    $sourcePhysical = Get-TsField $Scenario 'Physical' $null
    if ($null -eq (Get-TsField $sourcePhysical 'DiskIops' $null)) {
        $result.Physical.DiskIops = ConvertTo-TsNumber (Get-TsField $sourcePhysical 'SsdIops' 0) 'Physical.SsdIops'
    }
    # Before 1.10, one disk choice applied to both volumes. Preserve that hardware, not the old IOPS table.
    if ($null -ne (Get-TsField $sourcePhysical 'DiskType' $null) -and $null -eq (Get-TsField $sourcePhysical 'SystemDiskType' $null)) {
        $result.Physical.SystemDiskType = $result.Physical.DiskType
        if ($null -eq (Get-TsField $sourcePhysical 'SystemDiskSizeGB' $null)) { $result.Physical.SystemDiskSizeGB = $result.Physical.DiskSizeGB }
        if ($null -eq (Get-TsField $sourcePhysical 'SystemDiskIops' $null)) { $result.Physical.SystemDiskIops = $result.Physical.DiskIops }
    }
    foreach ($key in 'DiskType', 'SystemDiskType') {
        if ($script:TsLegacyDisks.ContainsKey($result.Physical[$key])) { $result.Physical[$key] = $script:TsLegacyDisks[$result.Physical[$key]] }
    }
    $reference = Get-TsReference
    if (-not $script:TsFailures.Contains($result.Topology.Failure)) { throw "Topology.Failure : « $($result.Topology.Failure) » inconnu (None, OneServer, TwoServers, OneSite)." }
    if (-not $script:TsQueueVolumes.Contains($result.Storage.QueueVolume)) { throw "Storage.QueueVolume : « $($result.Storage.QueueVolume) » inconnu (Dedicated ou System)." }
    # The window and old files may use the French labels.
    foreach ($pair in @(@('Scope', $script:TsJournalScopes), @('Destination', $script:TsJournalDestinations))) {
        foreach ($key in $pair[1].Keys) { if ($pair[1][$key] -eq $result.Journaling[$pair[0]]) { $result.Journaling[$pair[0]] = $key } }
        if (-not $pair[1].Contains($result.Journaling[$pair[0]])) { throw "Journaling.$($pair[0]) : « $($result.Journaling[$pair[0]]) » inconnu ($(@($pair[1].Keys) -join ', '))." }
    }
    foreach ($key in $script:TsPeakRateUnits.Keys) { if ($script:TsPeakRateUnits[$key] -eq $result.Load.PeakRateUnit) { $result.Load.PeakRateUnit = $key } }
    if (-not $script:TsPeakRateUnits.Contains($result.Load.PeakRateUnit)) { throw "Load.PeakRateUnit : « $($result.Load.PeakRateUnit) » inconnu (PerHour ou PerSecond)." }
    if ($result.Load.WorkingHours -lt 1 -or $result.Load.WorkingHours -gt 24) { throw 'Load.WorkingHours : nombre d’’heures ouvrées entre 1 et 24.' }
    if ($result.Load.PeakHours -lt 1 -or $result.Load.PeakHours -gt $result.Load.WorkingHours) { throw 'Load.PeakHours : la pointe dure au moins une heure et au plus les heures ouvrées.' }
    if ($result.Load.OffHoursPercent -ge 100) { throw 'Load.OffHoursPercent : la part hors heures ouvrées doit rester inférieure à 100 %.' }
    if ($result.Load.WorkingHours -ge 24 -and $result.Load.OffHoursPercent -gt 0) { throw 'Load.OffHoursPercent : avec 24 heures ouvrées, il n’’y a pas de trafic hors heures ouvrées (0 %).' }
    if ($result.Journaling.Percent -gt 100) { throw 'Journaling.Percent : pourcentage supérieur à 100.' }
    if ($result.Journaling.Recipients -lt 1 -or $result.Journaling.Recipients -ne [Math]::Floor($result.Journaling.Recipients)) { throw 'Journaling.Recipients : nombre entier de destinations de journal, au moins 1.' }
    foreach ($key in 'QueueRaid', 'SystemRaid') {
        if (-not $reference.Raid.ContainsKey($result.Physical[$key])) { throw "Physical.$key : RAID « $($result.Physical[$key]) » inconnu ($(@($reference.Raid.Keys | Sort-Object) -join ', '))." }
    }
    foreach ($pair in @(@('DiskType', 'Transport'), @('SystemDiskType', 'System'))) {
        if (-not (Get-TsDiskCatalog -Name $result.Physical[$pair[0]] -Role $pair[1])) { throw "Physical.$($pair[0]) : disque « $($result.Physical[$pair[0]]) » inconnu ou incompatible avec l’usage $($pair[1])." }
    }
    foreach ($key in 'Sites', 'ServersPerSite', 'MinCores') {
        $group = if ($key -eq 'MinCores') { 'Compute' } else { 'Topology' }
        if ($result[$group][$key] -ne [Math]::Floor($result[$group][$key])) { throw "$group.$key : nombre entier attendu." }
    }
    $positive = @(
        @('Load', 'PeakHourPercent'), @('Load', 'BurstFactor'), @('Resilience', 'MessageExpirationHours'), @('Storage', 'MaxFillPercent'),
        @('Network', 'LinkMbps'), @('Network', 'MaxUtilizationPercent'), @('Compute', 'MaxCpuPercent'), @('Adjustment', 'CpuPercent'), @('Adjustment', 'IoPercent')
    )
    foreach ($pair in $positive) { if ($result[$pair[0]][$pair[1]] -le 0) { throw "$($pair[0]).$($pair[1]) : valeur positive attendue." } }
    foreach ($pair in @(@('Load', 'PeakHourPercent'), @('Load', 'TlsPercent'), @('Storage', 'MaxFillPercent'), @('Network', 'MaxUtilizationPercent'), @('Compute', 'MaxCpuPercent'))) {
        if ($result[$pair[0]][$pair[1]] -gt 100) { throw "$($pair[0]).$($pair[1]) : pourcentage supérieur à 100." }
    }
    if ($result.Load.MessagesPerSession -lt 1) { throw 'Load.MessagesPerSession : au moins un message par session SMTP.' }
    if ($result.Compute.MinCores -lt 1) { throw 'Compute.MinCores : au moins un processeur.' }
    if ($result.Compute.VcpuRatio -le 0) { throw 'Compute.VcpuRatio : nombre de vCPU par cœur physique positif (1 = 1:1, 2 = 2:1).' }
    if ($result.Compute.MemoryReservedPercent -gt 100) { throw 'Compute.MemoryReservedPercent : pourcentage supérieur à 100.' }
    if ($result.Load.TransportRules -ne [Math]::Floor($result.Load.TransportRules)) { throw 'Load.TransportRules : nombre entier attendu.' }
    foreach ($group in 'Load', 'Resilience', 'Journaling', 'Adjustment', 'Storage', 'Network', 'Compute', 'Physical') {
        foreach ($key in @($result[$group].Keys)) {
            $value = $result[$group][$key]
            if ($value -is [double]) {
                if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "$group.$key : nombre fini attendu." }
                if ($value -lt 0) { throw "$group.$key : valeur négative." }
            }
        }
    }

    $hasFlows = $false
    $flows = $null
    if ($Scenario -is [Collections.IDictionary]) {
        if ($Scenario.Contains('Flows')) { $hasFlows = $true; $flows = $Scenario['Flows'] }
    }
    elseif ($Scenario.PSObject.Properties['Flows']) { $hasFlows = $true; $flows = $Scenario.PSObject.Properties['Flows'].Value }
    if ($hasFlows) {
        # An empty list stays empty: no traffic is an error of the scenario, not the default traffic.
        $index = 0
        $result.Flows = @(foreach ($flow in @($flows)) { if ($null -ne $flow) { $index++; ConvertTo-TsFlow -Flow $flow -Index $index } })
    }
    $calibration = Get-TsField $Scenario 'Calibration' $null
    $result.Calibration = $null
    if ($calibration) { $result.Calibration = ConvertTo-TsCalibration -Calibration $calibration }
    return $result
}

function Import-TsScenario {
    <#
    .SYNOPSIS
        Reads a scenario (JSON). The calibration embedded in the file wins; otherwise CalibrationPath
        (relative to the scenario folder) is loaded when it exists.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $json = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $scenario = ConvertTo-TsScenario -Scenario $json
    if (-not $scenario.Calibration -and $scenario.CalibrationPath) {
        $calibrationPath = $scenario.CalibrationPath
        if (-not [IO.Path]::IsPathRooted($calibrationPath)) { $calibrationPath = Join-Path (Split-Path -Parent $full) $calibrationPath }
        if (Test-Path -LiteralPath $calibrationPath) { $scenario.Calibration = Import-TsCalibration -Path $calibrationPath }
    }
    return $scenario
}

function Export-TsScenario {
    <# Writes a scenario as JSON (UTF-8). The calibration is embedded: the file is self-contained. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Scenario, [Parameter(Mandatory = $true)][string]$Path)

    $complete = ConvertTo-TsScenario -Scenario $Scenario
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $complete -Depth 12), [Text.UTF8Encoding]::new($false))
    return (Get-Item -LiteralPath $Path)
}

function ConvertTo-TsLinearModel {
    <#
        A calibration model: value = Intercept + Slope × messages/s + PerMBps × MB/s + PerRuleMsg × messages/s ×
        rules + PerSession × sessions/s + PerTlsSession × TLS sessions/s + PerTlsMBps × MB/s over TLS. The terms
        that the steps did not measure are 0.
    #>
    param([AllowNull()][object]$Model, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Model) { return $null }
    $result = [ordered]@{
        Intercept = ConvertTo-TsNumber (Get-TsField $Model 'Intercept' 0) "Calibration $Name, ordonnée à l’origine"
        Slope     = ConvertTo-TsNumber (Get-TsField $Model 'Slope' 0) "Calibration $Name, pente"
    }
    foreach ($key in $script:TsModelTerms) { $result[$key] = ConvertTo-TsNumber (Get-TsField $Model $key 0) "Calibration $Name, $key" }
    $result.R2 = ConvertTo-TsNumber (Get-TsField $Model 'R2' 1) "Calibration $Name, R²"
    $result.Points = [int](ConvertTo-TsNumber (Get-TsField $Model 'Points' 0) "Calibration $Name, points")
    return $result
}

function ConvertTo-TsCalibration {
    <#
    .SYNOPSIS
        A typed calibration profile. Required: the server (logical processors) and the CPU model. Memory,
        IOPS and backlog models are optional: what is missing is reported as not computed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Calibration)

    $server = Get-TsField $Calibration 'Server' $null
    $models = Get-TsField $Calibration 'Models' $null
    if (-not $server -or -not $models) { throw 'Profil de calibration invalide : sections Server et Models attendues (Measure-TransportLoad.ps1 -Analyze).' }
    $logical = ConvertTo-TsNumber (Get-TsField $server 'LogicalProcessors' 0) 'Calibration, processeurs logiques'
    if ($logical -le 0) { throw 'Profil de calibration invalide : nombre de processeurs logiques du serveur de référence manquant.' }
    $cpu = ConvertTo-TsLinearModel (Get-TsField $models 'CpuPercent' $null) 'CPU'
    if (-not $cpu) { throw 'Profil de calibration invalide : modèle CpuPercent manquant.' }
    $backlog = Get-TsField $Calibration 'Backlog' $null
    $range = Get-TsField $Calibration 'Range' $null
    $retention = Get-TsField $Calibration 'Retention' $null
    $drain = Get-TsField $Calibration 'Drain' $null
    $role = [string](Get-TsField $Calibration 'Role' '')
    [ordered]@{
        SchemaVersion = 1
        Name          = [string](Get-TsField $Calibration 'Name' 'Calibration')
        Role          = $role
        # Profile shipped with the tool (lab measurements), used when the scenario has no profile of its own.
        Reference     = ConvertTo-TsBoolean (Get-TsField $Calibration 'Reference' $false) 'Calibration, profil de référence'
        Notes         = [string](Get-TsField $Calibration 'Notes' '')
        MeasuredAt    = [string](Get-TsField $Calibration 'MeasuredAt' '')
        Source        = [string](Get-TsField $Calibration 'Source' '')
        Server        = [ordered]@{
            Name               = [string](Get-TsField $server 'Name' '')
            LogicalProcessors  = $logical
            # Physical cores seen by the reference: fewer than the logical processors when they are hyper-threads (Azure vCPU).
            Cores              = ConvertTo-TsNumber (Get-TsField $server 'Cores' 0) 'Calibration, cœurs'
            MemoryGB           = ConvertTo-TsNumber (Get-TsField $server 'MemoryGB' 0) 'Calibration, mémoire'
            Virtual            = ConvertTo-TsBoolean (Get-TsField $server 'Virtual' $false) 'Calibration, virtuel'
            Model              = [string](Get-TsField $server 'Model' '')
            Processor          = [string](Get-TsField $server 'Processor' '')
            SpecIntRatePerCore = ConvertTo-TsNumber (Get-TsField $server 'SpecIntRatePerCore' 0) 'Calibration, SPECint par cœur'
            SpecIntNote        = [string](Get-TsField $server 'SpecIntNote' '')
            ExchangeVersion    = [string](Get-TsField $server 'ExchangeVersion' '')
        }
        MessageSizeKB = ConvertTo-TsNumber (Get-TsField $Calibration 'MessageSizeKB' 0) 'Calibration, taille des messages'
        MaxRate       = ConvertTo-TsNumber (Get-TsField $Calibration 'MaxRate' 0) 'Calibration, débit maximal mesuré'
        ResidenceSeconds = ConvertTo-TsNumber (Get-TsField $Calibration 'ResidenceSeconds' 0) 'Calibration, séjour en transit mesuré'
        Range         = [ordered]@{
            MinSizeKB         = ConvertTo-TsNumber (Get-TsField $range 'MinSizeKB' 0) 'Calibration, plus petite taille mesurée'
            MaxSizeKB         = ConvertTo-TsNumber (Get-TsField $range 'MaxSizeKB' 0) 'Calibration, plus grande taille mesurée'
            MaxMBps           = ConvertTo-TsNumber (Get-TsField $range 'MaxMBps' 0) 'Calibration, débit maximal mesuré en Mo/s'
            MaxRules          = ConvertTo-TsNumber (Get-TsField $range 'MaxRules' 0) 'Calibration, règles mesurées'
            MaxSessionsPerSec = ConvertTo-TsNumber (Get-TsField $range 'MaxSessionsPerSec' 0) 'Calibration, sessions par seconde mesurées'
            MaxJournalPerSec  = ConvertTo-TsNumber (Get-TsField $range 'MaxJournalPerSec' 0) 'Calibration, rapports de journal par seconde mesurés'
        }
        Models        = [ordered]@{
            CpuPercent         = $cpu
            TransportPrivateMB = ConvertTo-TsLinearModel (Get-TsField $models 'TransportPrivateMB' $null) 'mémoire EdgeTransport'
            UsedMemoryMB       = ConvertTo-TsLinearModel (Get-TsField $models 'UsedMemoryMB' $null) 'mémoire utilisée'
            QueueReadIops      = ConvertTo-TsLinearModel (Get-TsField $models 'QueueReadIops' $null) 'lectures'
            QueueWriteIops     = ConvertTo-TsLinearModel (Get-TsField $models 'QueueWriteIops' $null) 'écritures'
            QueueReadBps       = ConvertTo-TsLinearModel (Get-TsField $models 'QueueReadBps' $null) 'octets lus'
            QueueWriteBps      = ConvertTo-TsLinearModel (Get-TsField $models 'QueueWriteBps' $null) 'octets écrits'
            NetworkInBps       = ConvertTo-TsLinearModel (Get-TsField $models 'NetworkInBps' $null) 'réseau entrant'
            NetworkOutBps      = ConvertTo-TsLinearModel (Get-TsField $models 'NetworkOutBps' $null) 'réseau sortant'
        }
        # Corrections applied to the measured models (memory of the mailbox databases of the reference server).
        Corrections   = @(Get-TsField $Calibration 'Corrections' @())
        Validation    = @(Get-TsField $Calibration 'Validation' @())
        Retention     = $(if ($retention) {
                [ordered]@{
                    Factor      = ConvertTo-TsNumber (Get-TsField $retention 'Factor' 0) 'Calibration, croissance de mail.que par Mo traité'
                    GrowthMB    = ConvertTo-TsNumber (Get-TsField $retention 'GrowthMB' 0) 'Calibration, croissance de mail.que'
                    ProcessedMB = ConvertTo-TsNumber (Get-TsField $retention 'ProcessedMB' 0) 'Calibration, messages traités'
                    MaxQueue    = ConvertTo-TsNumber (Get-TsField $retention 'MaxQueue' 0) 'Calibration, file pendant la croissance'
                }
            }
            else { $null })
        # Drain after a backlog: CPU of the reference per message/s sent again from the queue (no reception, no antispam).
        Drain         = $(if ($drain -and [double](Get-TsField $drain 'CpuPercentPerMsg' 0) -gt 0) {
                [ordered]@{
                    CpuPercentPerMsg = ConvertTo-TsNumber (Get-TsField $drain 'CpuPercentPerMsg' 0) 'Calibration, CPU par message vidé'
                    Rate             = ConvertTo-TsNumber (Get-TsField $drain 'Rate' 0) 'Calibration, débit de vidange mesuré'
                    Messages         = ConvertTo-TsNumber (Get-TsField $drain 'Messages' 0) 'Calibration, messages vidés'
                    ReadIopsPerMsg   = ConvertTo-TsNumber (Get-TsField $drain 'ReadIopsPerMsg' 0) 'Calibration, lectures par message vidé'
                    WriteIopsPerMsg  = ConvertTo-TsNumber (Get-TsField $drain 'WriteIopsPerMsg' 0) 'Calibration, écritures par message vidé'
                    Measured         = ConvertTo-TsBoolean (Get-TsField $drain 'Measured' $true) 'Calibration, vidange mesurée'
                    Step             = [string](Get-TsField $drain 'Step' '')
                    Note             = [string](Get-TsField $drain 'Note' '')
                }
            }
            else { $null })
        Backlog       = $(if ($backlog) {
                [ordered]@{
                    Messages               = ConvertTo-TsNumber (Get-TsField $backlog 'Messages' 0) 'Calibration, messages du palier backlog'
                    EseOverheadFactor      = ConvertTo-TsNumber (Get-TsField $backlog 'EseOverheadFactor' 0) 'Calibration, facteur ESE'
                    MemoryKBPerQueued      = ConvertTo-TsNumber (Get-TsField $backlog 'MemoryKBPerQueued' 0) 'Calibration, mémoire par message en file'
                    MemoryBaseKB           = ConvertTo-TsNumber (Get-TsField $backlog 'MemoryBaseKB' 0) 'Calibration, mémoire fixe par message en file'
                    MemoryPerKB            = ConvertTo-TsNumber (Get-TsField $backlog 'MemoryPerKB' 0) 'Calibration, mémoire par Ko de message en file'
                    MessageSizeKB          = ConvertTo-TsNumber (Get-TsField $backlog 'MessageSizeKB' 0) 'Calibration, taille des messages du backlog'
                    MemoryReference        = [string](Get-TsField $backlog 'MemoryReference' '')
                    # Memory per queued message once Exchange has dehydrated the queue (content read again from mail.que).
                    DehydratedKBPerQueued  = ConvertTo-TsNumber (Get-TsField $backlog 'DehydratedKBPerQueued' 0) 'Calibration, mémoire par message déshydraté'
                    DehydrationMeasured    = ConvertTo-TsBoolean (Get-TsField $backlog 'DehydrationMeasured' $true) 'Calibration, déshydratation mesurée'
                    DehydrationNote        = [string](Get-TsField $backlog 'DehydrationNote' '')
                    EseNote                = [string](Get-TsField $backlog 'EseNote' '')
                    EseStep                = [string](Get-TsField $backlog 'EseStep' '')
                    QueueGrowthMB          = ConvertTo-TsNumber (Get-TsField $backlog 'QueueGrowthMB' 0) 'Calibration, croissance de mail.que'
                    TransportPrivateGrowthMB = ConvertTo-TsNumber (Get-TsField $backlog 'TransportPrivateGrowthMB' 0) 'Calibration, croissance mémoire'
                    Steps                  = @(Get-TsField $backlog 'Steps' @())
                }
            }
            else { $null })
        Steps         = @(Get-TsField $Calibration 'Steps' @())
    }
}

function Import-TsCalibration {
    <# Reads a calibration profile written by Measure-TransportLoad.ps1 -Analyze. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $json = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) | ConvertFrom-Json
    return (ConvertTo-TsCalibration -Calibration $json)
}

function Get-TsReferenceProfile {
    <#
    .SYNOPSIS
        Reference calibration profile of a role, shipped with the tool (data\Reference-<Role>.json): the lab
        measurements of REF-EDGE (Edge) and REF-MAILBOX (Mailbox). Used when a scenario has no profile of its own, so
        that a project without any Exchange server to measure can still be sized; a profile measured on a
        server of the customer replaces it, and the Adjustment group of the scenario adapts either of them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Edge', 'Mailbox')][string]$Role)

    # The JSON is read once; each call returns a new typed profile, so that no caller can change the reference.
    if (-not $script:TsReferenceProfiles) { $script:TsReferenceProfiles = @{} }
    if (-not $script:TsReferenceProfiles.ContainsKey($Role)) {
        $path = Join-Path $script:ToolRoot "data\Reference-$Role.json"
        $script:TsReferenceProfiles[$Role] = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    return (ConvertTo-TsCalibration -Calibration $script:TsReferenceProfiles[$Role])
}

function Get-TsProcessorCatalog {
    <#
    .SYNOPSIS
        Server processors with their SPEC CPU2017 integer rate (base) per core: median of the results published on
        spec.org for the processor (data\Processors.csv). Gives the performance per core of a host or a physical
        server to compare with the reference; Name filters by a part of the name.
    #>
    [CmdletBinding()]
    param([string]$Name)

    if (-not $script:TsProcessorCatalog) {
        $path = Join-Path $script:ToolRoot 'data\Processors.csv'
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $script:TsProcessorCatalog = @(Import-Csv -LiteralPath $path -Encoding UTF8 | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; SpecIntRatePerCore = [double]::Parse($_.SpecIntRatePerCore, $inv); CoresPerChip = [int]$_.CoresPerChip; Results = [int]$_.Results }
            })
    }
    if ($Name) { return @($script:TsProcessorCatalog | Where-Object { $_.Name -like "*$Name*" }) }
    return $script:TsProcessorCatalog
}
