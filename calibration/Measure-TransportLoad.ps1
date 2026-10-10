<#
.SYNOPSIS
    Transport Sizer - calibration: measures a transport server under load and builds the calibration profile.

.DESCRIPTION
    Two modes.

    -Collect (default), on the Exchange server to measure (Edge Transport or Mailbox), Windows PowerShell
    5.1, no Exchange module needed: samples the performance counters during one step and writes
    <Label>.csv (one row per sample) and <Label>.json (server, step, counters, totals) in OutputPath.
        Idle      no load: what the server consumes at rest
        Load      steady SMTP load sent by Send-TransportTestLoad.ps1 from another computer
        Backlog   messages accumulated in a suspended queue (Suspend-Queue), to measure the growth of
                  mail.que and of the memory per queued message; a backlog long enough to put the memory under
                  pressure also measures the memory of a dehydrated message
        Drain     the queue of a backlog sent again once the next hop is back (Resume-Queue, Retry-Queue),
                  no new load: the CPU of a message sent from the queue

    -Analyze, anywhere: reads every step of a folder, averages each step after its warm-up, fits the
    models of CPU, memory, IOPS, disk throughput and network (least squares, value = intercept + Σ
    coefficient × load factor), derives the backlog factors, and writes the calibration profile imported by
    the window (Importer un profil) or by Invoke-TransportSizer.ps1 -Calibration. Load factors of a step:
    messages/s, MB/s of messages (size), messages/s × transport rules, SMTP sessions opened per second,
    TLS negotiations per second and MB/s received over TLS. A factor enters a model only when the steps make
    it vary independently of the others (steps at several sizes, with rules, with short or TLS sessions), and
    no coefficient is negative.

    Protocol (see README): one Idle step, then Load steps at 4 rates or more (for example 2, 5, 10 and
    20 messages/s, 10 minutes each), the highest close to the design rate; optionally a Backlog step.
    The messages carry the header X-TransportSizer-Calibration: a transport rule can delete them after
    the measured server, so that no mailbox grows.

.PARAMETER Label
    Name of the step (file name), for example idle, load-05, backlog.

.PARAMETER Kind
    Idle, Load, Backlog or Drain.

.PARAMETER DurationSeconds
    Duration of the step, warm-up included.

.PARAMETER WarmupSeconds
    Samples of the first seconds are kept in the CSV but left out of the averages.

.PARAMETER BacklogMessages
    Backlog step: number of messages accumulated during the step (Get-Queue MessageCount).

.PARAMETER MessageSizeKB
    Size of the test messages (Send-TransportTestLoad.ps1 -MessageSizeKB).

.PARAMETER TransportRules
    Transport rules active during the step: Edge rules on an Edge Transport server (Get-TransportRule on the
    Edge), transport rules of the organization on a Mailbox server. -1 (default): not given, counted as 0.

.PARAMETER OutputPath
    Folder of the steps (Collect) or of the steps to analyse (Analyze).

.PARAMETER Analyze
    Builds the profile from the steps of OutputPath.

.PARAMETER ProfilePath
    Profile written by Analyze. Default: OutputPath\Calibration-<server>.json.

.PARAMETER Name
    Name of the profile. Default: <server> <date>.

.PARAMETER SpecIntRatePerCore
    SPECint_rate2017 of the reference server divided by its cores (0 = unknown).

.PARAMETER IncludePath
    Other folders of steps of the same server, analysed with the steps of OutputPath.

.PARAMETER Validate
    Labels of steps kept out of the fit (for example a mix of sizes): the profile gives what the models predict
    for them next to what was measured.

.EXAMPLE
    .\Measure-TransportLoad.ps1 -Label idle -Kind Idle -DurationSeconds 300
    .\Measure-TransportLoad.ps1 -Label load-10 -Kind Load -DurationSeconds 660 -MessageSizeKB 75
    On the Exchange server, while Send-TransportTestLoad.ps1 -Rates 10 -StepSeconds 660 runs elsewhere.

.EXAMPLE
    .\Measure-TransportLoad.ps1 -Analyze -OutputPath C:\TransportSizerCalibration -Name 'REF-EDGE lab'

.NOTES
    Author  : Nicolas Fabert
    Version : 1.9.0
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Collect')]
param(
    [Parameter(ParameterSetName = 'Collect', Mandatory = $true)][ValidatePattern('^[\w\-.]+$')][string]$Label,
    [Parameter(ParameterSetName = 'Collect')][ValidateSet('Idle', 'Load', 'Backlog', 'Drain')][string]$Kind = 'Load',
    [Parameter(ParameterSetName = 'Collect')][ValidateRange(30, 86400)][int]$DurationSeconds = 600,
    [Parameter(ParameterSetName = 'Collect')][ValidateRange(1, 60)][int]$SampleIntervalSeconds = 5,
    [Parameter(ParameterSetName = 'Collect')][ValidateRange(0, 3600)][int]$WarmupSeconds = 60,
    [Parameter(ParameterSetName = 'Collect')][ValidateRange(0, 10000000)][int]$BacklogMessages = 0,
    [Parameter(ParameterSetName = 'Collect')][ValidateRange(0, 102400)][double]$MessageSizeKB = 0,
    [Parameter(ParameterSetName = 'Collect')][ValidateRange(-1, 100000)][int]$TransportRules = -1,
    [string]$OutputPath = (Join-Path $env:SystemDrive 'TransportSizerCalibration'),
    [Parameter(ParameterSetName = 'Analyze', Mandatory = $true)][switch]$Analyze,
    [Parameter(ParameterSetName = 'Analyze')][string]$ProfilePath,
    [Parameter(ParameterSetName = 'Analyze')][string]$Name,
    [Parameter(ParameterSetName = 'Analyze')][ValidateRange(0, 1000)][double]$SpecIntRatePerCore = 0,
    [Parameter(ParameterSetName = 'Analyze')][string[]]$IncludePath,
    [Parameter(ParameterSetName = 'Analyze')][string[]]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# .NET resolves relative paths against the process folder, not the PowerShell location.
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($ProfilePath) { $ProfilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath) }
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:Metrics = @('CpuPercent', 'TransportCpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'AvailableMB', 'QueueReadIops', 'QueueWriteIops', 'ReadLatencyMs', 'WriteLatencyMs',
    'NetworkInBps', 'NetworkOutBps', 'ReceivedPerSec', 'SentPerSec', 'QueueLength', 'MailQueMB',
    'MessageBytesPerSec', 'ConnectionsPerSec', 'TlsConnectionsPerSec', 'ConnectionsCurrent', 'TlsConnectionsCurrent', 'QueueReadBps', 'QueueWriteBps', 'JournalReportsPerSec',
    'DatabaseMemoryMB')

function Get-TsxExchangeInfo {
    <# Role, installation folder, queue folder and version of the local Exchange server. #>
    $setup = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' -ErrorAction SilentlyContinue
    $install = $env:ExchangeInstallPath
    if (-not $install -and $setup) { $install = $setup.MsiInstallPath }
    if (-not $install) { throw 'Exchange Server n''est pas installé sur ce serveur (ExchangeInstallPath introuvable).' }
    $role = 'Mailbox'
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\EdgeTransportRole') { $role = 'Edge' }
    $queue = Join-Path $install 'TransportRoles\data\Queue'
    $config = Join-Path $install 'Bin\EdgeTransport.exe.config'
    if (Test-Path -LiteralPath $config) {
        [xml]$xml = Get-Content -LiteralPath $config -Raw
        $node = $xml.SelectSingleNode("/configuration/appSettings/add[@key='QueueDatabasePath']")
        if ($node -and $node.value) { $queue = [Environment]::ExpandEnvironmentVariables($node.value) }
    }
    $version = ''
    $exsetup = Join-Path $install 'Bin\ExSetup.exe'
    if (Test-Path -LiteralPath $exsetup) { $version = (Get-Item -LiteralPath $exsetup).VersionInfo.ProductVersion }
    [pscustomobject]@{ InstallPath = $install; Role = $role; QueuePath = $queue; MailQue = (Join-Path $queue 'mail.que'); Drive = (Split-Path -Qualifier $queue); Version = $version }
}

function Get-TsxServerInfo {
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $processors = @(Get-CimInstance -ClassName Win32_Processor)
    $cores = 0
    foreach ($p in $processors) { $cores += [int]$p.NumberOfCores }
    $model = '{0} {1}' -f $system.Manufacturer, $system.Model
    [pscustomobject]@{
        Name              = $env:COMPUTERNAME
        LogicalProcessors = [int]$system.NumberOfLogicalProcessors
        Cores             = $cores
        MemoryGB          = [Math]::Round($system.TotalPhysicalMemory / 1GB, 2)
        MemoryMB          = [Math]::Round($system.TotalPhysicalMemory / 1MB, 0)
        Virtual           = [bool]($model -match 'Virtual|VMware|KVM|HVM|Xen|QEMU|Hyper-V|Parallels')
        Model             = $model.Trim()
        Processor         = (($processors | ForEach-Object { $_.Name.Trim() }) | Select-Object -Unique) -join ', '
    }
}

function Get-TsxCounterPlan {
    <# The counters to sample on this server: the ones that exist, by metric. #>
    param([Parameter(Mandatory = $true)][string]$Drive)

    $wanted = [ordered]@{
        CpuPercent          = @('\Processor(_Total)\% Processor Time')
        TransportCpuPercent = @('\Process(EdgeTransport)\% Processor Time')
        TransportPrivateMB  = @('\Process(EdgeTransport)\Private Bytes')
        AvailableMB         = @('\Memory\Available MBytes')
        QueueReadIops       = @("\LogicalDisk($Drive)\Disk Reads/sec")
        QueueWriteIops      = @("\LogicalDisk($Drive)\Disk Writes/sec")
        ReadLatencyMs       = @("\LogicalDisk($Drive)\Avg. Disk sec/Read")
        WriteLatencyMs      = @("\LogicalDisk($Drive)\Avg. Disk sec/Write")
        NetworkInBps        = @('\Network Interface(*)\Bytes Received/sec')
        NetworkOutBps       = @('\Network Interface(*)\Bytes Sent/sec')
        ReceivedPerSec      = @('\MSExchangeTransport SMTPReceive(_total)\Messages Received/sec', '\MSExchangeTransport SmtpReceive(*)\Messages Received/sec')
        SentPerSec          = @('\MSExchangeTransport SmtpSend(_total)\Messages Sent/sec', '\MSExchangeTransport SmtpSend(*)\Messages Sent/sec')
        # Alternatives separated by | are summed: internal and external delivery queues.
        QueueLength         = @('\MSExchangeTransport Queues(_total)\Aggregate Delivery Queue Length (All Queues)',
            '\MSExchangeTransport Queues(_total)\Internal Aggregate Delivery Queue Length (All Internal Queues)|\MSExchangeTransport Queues(_total)\External Aggregate Delivery Queue Length (All External Queues)')
        # Size of the messages, SMTP sessions opened (new TCP connection, EHLO) and TLS negotiations received.
        MessageBytesPerSec    = @('\MSExchangeTransport SMTPReceive(_total)\Message Bytes Received/sec', '\MSExchangeTransport SmtpReceive(*)\Message Bytes Received/sec')
        ConnectionsPerSec     = @('\MSExchangeTransport SMTPReceive(_total)\Connections Created/sec', '\MSExchangeTransport SmtpReceive(*)\Connections Created/sec')
        TlsConnectionsPerSec  = @('\MSExchangeTransport SMTPReceive(_total)\TLS Connections Created/sec', '\MSExchangeTransport SmtpReceive(*)\TLS Connections Created/sec')
        ConnectionsCurrent    = @('\MSExchangeTransport SMTPReceive(_total)\Connections Current', '\MSExchangeTransport SmtpReceive(*)\Connections Current')
        TlsConnectionsCurrent = @('\MSExchangeTransport SMTPReceive(_total)\TLS Connections Current', '\MSExchangeTransport SmtpReceive(*)\TLS Connections Current')
        QueueReadBps          = @("\LogicalDisk($Drive)\Disk Read Bytes/sec")
        QueueWriteBps         = @("\LogicalDisk($Drive)\Disk Write Bytes/sec")
        # Mailbox role: journal reports written by the Journaling agent (not received over SMTP).
        JournalReportsPerSec  = @('\MSExchange Journaling Agent\Journal Reports Created/sec', '\MSExchange Journaling Agent(*)\Journal Reports Created/sec')
        # Mailbox role: memory of the mailbox database copies of the server (Store worker processes, ESE cache
        # included), left out of the used memory by the analysis: a transport-only server has no database.
        DatabaseMemoryMB      = @('\Process(Microsoft.Exchange.Store.Worker*)\Working Set - Private')
    }
    $plan = [ordered]@{}
    foreach ($metric in $wanted.Keys) {
        foreach ($candidate in $wanted[$metric]) {
            $paths = @($candidate -split '\|')
            $ok = $true
            foreach ($path in $paths) {
                $sample = Get-Counter -Counter $path -MaxSamples 1 -ErrorAction SilentlyContinue
                if (-not $sample -or @($sample.CounterSamples).Count -eq 0) { $ok = $false; break }
            }
            if ($ok) { $plan[$metric] = $candidate; break }
        }
    }
    return $plan
}

function Get-TsxTotals {
    <# Cumulated SMTP counters (messages received and sent since the start of the service). #>
    $totals = @{ Received = $null; Sent = $null }
    foreach ($pair in @(@('Received', '\MSExchangeTransport SMTPReceive(*)\Messages Received Total'), @('Sent', '\MSExchangeTransport SmtpSend(*)\Messages Sent Total'))) {
        $sample = Get-Counter -Counter $pair[1] -MaxSamples 1 -ErrorAction SilentlyContinue
        if ($sample) {
            $values = @($sample.CounterSamples | Where-Object { $_.InstanceName -ne '_total' })
            $sum = 0.0
            foreach ($v in $values) { $sum += $v.CookedValue }
            $totals[$pair[0]] = $sum
        }
    }
    return $totals
}

function ConvertTo-TsxRow {
    <# One CSV row: the metrics of one sample, sums over the instances of a wildcard counter. #>
    param([Parameter(Mandatory = $true)][object]$Sample, [Parameter(Mandatory = $true)][Collections.IDictionary]$Plan, [double]$Elapsed, [double]$MemoryMB, [double]$LogicalProcessors, [string]$MailQue)

    $row = [ordered]@{ Timestamp = $Sample.Timestamp.ToString('yyyy-MM-ddTHH:mm:ss'); Elapsed = [Math]::Round($Elapsed, 1) }
    foreach ($metric in $script:Metrics) { $row[$metric] = '' }
    foreach ($metric in $Plan.Keys) {
        $values = @()
        foreach ($path in @($Plan[$metric] -split '\|')) {
            $pattern = '*' + $path.ToLowerInvariant()
            $matched = @($Sample.CounterSamples | Where-Object { $_.Path.ToLowerInvariant() -like $pattern })
            if ($path -match '\(\*\)') { $matched = @($matched | Where-Object { $_.InstanceName -ne '_total' }) }
            $values += $matched
        }
        if ($values.Count -eq 0) { continue }
        $sum = 0.0
        if ($metric -in 'NetworkInBps', 'NetworkOutBps') {
            # Accelerated networking (Azure, SR-IOV) shows each card twice: the synthetic adapter and its
            # virtual function. The same bytes can appear on one or on both: keep the larger of the two sums.
            $function = 0.0; $other = 0.0
            foreach ($v in $values) {
                if ($v.InstanceName -match 'azure network adapter|mellanox|connectx|virtual function|mana') { $function += $v.CookedValue } else { $other += $v.CookedValue }
            }
            $sum = [Math]::Max($function, $other)
        }
        else { foreach ($v in $values) { $sum += $v.CookedValue } }
        switch ($metric) {
            'TransportCpuPercent' { $sum = $sum / [Math]::Max(1.0, $LogicalProcessors) }
            'TransportPrivateMB' { $sum = $sum / 1MB }
            'DatabaseMemoryMB' { $sum = $sum / 1MB }
            'ReadLatencyMs' { $sum = $sum * 1000 }
            'WriteLatencyMs' { $sum = $sum * 1000 }
        }
        $row[$metric] = $sum
    }
    if ($row.AvailableMB -ne '') { $row.UsedMemoryMB = $MemoryMB - [double]$row.AvailableMB }
    if (Test-Path -LiteralPath $MailQue) { $row.MailQueMB = (Get-Item -LiteralPath $MailQue).Length / 1MB }
    foreach ($metric in $script:Metrics) {
        if ($row[$metric] -is [double]) { $row[$metric] = $row[$metric].ToString('0.####', $script:Invariant) }
    }
    return [pscustomobject]$row
}

function Invoke-TsxCollect {
    $exchange = Get-TsxExchangeInfo
    $server = Get-TsxServerInfo
    if (-not (Test-Path -LiteralPath $OutputPath)) { [void](New-Item -ItemType Directory -Path $OutputPath -Force) }
    $csvPath = Join-Path $OutputPath "$Label.csv"
    $jsonPath = Join-Path $OutputPath "$Label.json"
    $plan = Get-TsxCounterPlan -Drive $exchange.Drive
    $missing = @('CpuPercent', 'ReceivedPerSec' | Where-Object { -not $plan.Contains($_) })
    if ($missing) { throw ('Compteurs indispensables introuvables : {0}.' -f ($missing -join ', ')) }
    Write-Host ('Palier {0} ({1}) sur {2} [{3}] : {4} s, un échantillon toutes les {5} s, {6} compteurs.' -f $Label, $Kind, $server.Name, $exchange.Role, $DurationSeconds, $SampleIntervalSeconds, $plan.Count)
    $mailQueStart = $null
    if (Test-Path -LiteralPath $exchange.MailQue) { $mailQueStart = (Get-Item -LiteralPath $exchange.MailQue).Length / 1MB }
    $totalsStart = Get-TsxTotals
    $start = Get-Date
    $samples = [Math]::Max(1.0, [int][Math]::Floor($DurationSeconds / $SampleIntervalSeconds))
    $rows = [Collections.Generic.List[object]]::new()
    $writer = [IO.StreamWriter]::new($csvPath, $false, [Text.UTF8Encoding]::new($false))
    try {
        $writer.WriteLine((@('Timestamp', 'Elapsed') + $script:Metrics) -join ',')
        $counterPaths = @(foreach ($value in $plan.Values) { $value -split '\|' })
        # Under a saturated processor the samples come late: the step stops at its planned end, not after a number of samples.
        $endAt = $start.AddSeconds($DurationSeconds + $SampleIntervalSeconds / 2)
        try {
            Get-Counter -Counter $counterPaths -SampleInterval $SampleIntervalSeconds -MaxSamples $samples -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Timestamp -gt $endAt) { throw [OperationCanceledException]::new('fin du palier') }
                $row = ConvertTo-TsxRow -Sample $_ -Plan $plan -Elapsed ($_.Timestamp - $start).TotalSeconds -MemoryMB $server.MemoryMB -LogicalProcessors $server.LogicalProcessors -MailQue $exchange.MailQue
                $rows.Add($row)
                $writer.WriteLine((@($row.PSObject.Properties | ForEach-Object { $_.Value }) -join ','))
                $writer.Flush()
            }
        }
        catch [OperationCanceledException] { }
    }
    finally { $writer.Dispose() }
    $end = Get-Date
    $totalsEnd = Get-TsxTotals
    $mailQueEnd = $null
    if (Test-Path -LiteralPath $exchange.MailQue) { $mailQueEnd = (Get-Item -LiteralPath $exchange.MailQue).Length / 1MB }
    $metadata = [ordered]@{
        Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $Label; Kind = $Kind; Role = $exchange.Role
        Server = $server; ExchangeVersion = $exchange.Version; QueuePath = $exchange.QueuePath; Drive = $exchange.Drive
        Start = $start.ToString('o'); End = $end.ToString('o'); DurationSeconds = [Math]::Round(($end - $start).TotalSeconds, 1)
        WarmupSeconds = $WarmupSeconds; SampleIntervalSeconds = $SampleIntervalSeconds; Samples = $rows.Count; Counters = $plan
        Totals = [ordered]@{ ReceivedStart = $totalsStart.Received; ReceivedEnd = $totalsEnd.Received; SentStart = $totalsStart.Sent; SentEnd = $totalsEnd.Sent }
        MailQue = [ordered]@{ StartMB = $mailQueStart; EndMB = $mailQueEnd }
        BacklogMessages = $BacklogMessages; MessageSizeKB = $MessageSizeKB; TransportRules = $TransportRules
    }
    [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $metadata -Depth 6), [Text.UTF8Encoding]::new($false))
    Write-Host ('Terminé : {0} échantillons, {1} et {2}.' -f $rows.Count, $csvPath, $jsonPath)
    [pscustomobject]@{ Label = $Label; Csv = $csvPath; Json = $jsonPath; Samples = $rows.Count }
}

function Get-TsxAverage {
    param([object[]]$Rows, [string]$Metric)
    $values = @(foreach ($row in $Rows) {
            if (-not $row.PSObject.Properties[$Metric]) { continue }
            $text = [string]$row.$Metric
            if ($text -ne '') { [double]::Parse($text, $script:Invariant) }
        })
    if ($values.Count -eq 0) { return $null }
    return ($values | Measure-Object -Average).Average
}

function Get-TsxRegression {
    <# Least squares y = a + b x, with R². Null with fewer than two distinct x. #>
    param([double[]]$X, [double[]]$Y, [int]$Digits = 4)
    $n = $X.Count
    if ($n -lt 2) { return $null }
    $mx = ($X | Measure-Object -Average).Average
    $my = ($Y | Measure-Object -Average).Average
    $sxx = 0.0; $sxy = 0.0; $syy = 0.0
    for ($i = 0; $i -lt $n; $i++) { $dx = $X[$i] - $mx; $dy = $Y[$i] - $my; $sxx += $dx * $dx; $sxy += $dx * $dy; $syy += $dy * $dy }
    if ($sxx -le 0) { return $null }
    $slope = $sxy / $sxx
    $intercept = $my - $slope * $mx
    $ssr = 0.0
    for ($i = 0; $i -lt $n; $i++) { $e = $Y[$i] - ($intercept + $slope * $X[$i]); $ssr += $e * $e }
    $r2 = 1.0
    if ($syy -gt 0) { $r2 = 1 - $ssr / $syy }
    [ordered]@{ Intercept = [Math]::Round($intercept, $Digits); Slope = [Math]::Round($slope, $Digits); R2 = [Math]::Round($r2, 4); Points = $n }
}

# Load factors of a step and the key of their coefficient in the profile. The value of a model is
# Intercept + Σ coefficient × factor.
$script:Factors = [ordered]@{
    Rate        = 'Slope'          # messages/s: fixed cost of a message
    MBps        = 'PerMBps'        # MB/s of messages: cost of the size
    RulesRate   = 'PerRuleMsg'     # messages/s × transport rules
    Sessions    = 'PerSession'     # SMTP sessions opened per second
    TlsSessions = 'PerTlsSession'  # TLS negotiations per second
    TlsMBps     = 'PerTlsMBps'     # MB/s received over TLS
    JournalRate = 'PerJournal'     # journal reports written per second (Mailbox role)
}

function Get-TsxSolution {
    <# Least squares, with an intercept unless -NoIntercept: Gauss-Jordan on the normal equations. Null when singular. #>
    param([double[]]$Y, [object[]]$Columns, [switch]$NoIntercept)
    $offset = $(if ($NoIntercept) { 0 } else { 1 })
    $k = $Columns.Count + $offset
    if ($k -eq 0) { return , [double[]]@() }
    $n = $Y.Count
    $m = @(for ($i = 0; $i -lt $k; $i++) { , [double[]]::new($k + 1) })
    for ($i = 0; $i -lt $n; $i++) {
        $row = [double[]]::new($k)
        if (-not $NoIntercept) { $row[0] = 1.0 }
        for ($c = $offset; $c -lt $k; $c++) { $row[$c] = ([double[]]$Columns[$c - $offset])[$i] }
        for ($a = 0; $a -lt $k; $a++) {
            for ($b = 0; $b -lt $k; $b++) { $m[$a][$b] += $row[$a] * $row[$b] }
            $m[$a][$k] += $row[$a] * $Y[$i]
        }
    }
    for ($p = 0; $p -lt $k; $p++) {
        $best = $p
        for ($r = $p + 1; $r -lt $k; $r++) { if ([Math]::Abs($m[$r][$p]) -gt [Math]::Abs($m[$best][$p])) { $best = $r } }
        if ([Math]::Abs($m[$best][$p]) -lt 1e-12) { return $null }
        if ($best -ne $p) { $t = $m[$p]; $m[$p] = $m[$best]; $m[$best] = $t }
        $pivot = $m[$p][$p]
        for ($c = 0; $c -le $k; $c++) { $m[$p][$c] = $m[$p][$c] / $pivot }
        for ($r = 0; $r -lt $k; $r++) {
            if ($r -eq $p) { continue }
            $f = $m[$r][$p]
            if ($f -ne 0) { for ($c = 0; $c -le $k; $c++) { $m[$r][$c] -= $f * $m[$p][$c] } }
        }
    }
    $solution = [double[]]::new($k)
    for ($i = 0; $i -lt $k; $i++) { $solution[$i] = $m[$i][$k] }
    return , $solution
}

function Get-TsxFit {
    <#
        Model of one metric over the load steps: value = Intercept + Σ coefficient × factor. A factor enters only
        when it varies independently of the factors already in (residual of its centred values after projection
        on them above 10 %): with steps at one message size, the size cannot be told from the rate and stays out.
        A coefficient below zero has no physical meaning: its factor leaves and the model is fitted again.
    #>
    param([object[]]$Points, [string]$Metric, [string[]]$Factors = @($script:Factors.Keys))
    $rows = @($Points | Where-Object { $null -ne $_.$Metric })
    $n = $rows.Count
    if ($n -lt 2) { return $null }
    $y = [double[]]@($rows | ForEach-Object { [double]$_.$Metric })
    # A factor must have been exercised by the steps, not only carried by background noise: sizes at least two
    # times apart, a step with transport rules, a step with at least one new session (or TLS negotiation) per two
    # messages, a step mostly in TLS. Background connections of an idle server never pass these tests.
    $loaded = @($rows | Where-Object { [double]$_.Rate -gt 1 })
    $exercised = @{
        Rate        = $true
        MBps        = [bool]($loaded.Count -ge 2 -and (@($loaded | ForEach-Object { [double]$_.SizeKB }) | Measure-Object -Maximum).Maximum -ge 2 * [Math]::Max(1.0, (@($loaded | ForEach-Object { [double]$_.SizeKB }) | Measure-Object -Minimum).Minimum))
        RulesRate   = [bool](@($loaded | Where-Object { [double]$_.Rules -gt 0 }).Count -gt 0)
        Sessions    = [bool](@($loaded | Where-Object { [double]$_.Sessions -ge 0.5 * [double]$_.Rate }).Count -gt 0)
        TlsSessions = [bool](@($loaded | Where-Object { [double]$_.TlsSessions -ge 0.5 * [double]$_.Rate }).Count -gt 0)
        TlsMBps     = [bool](@($loaded | Where-Object { [double]$_.MBps -gt 0 -and [double]$_.TlsMBps -ge 0.5 * [double]$_.MBps }).Count -gt 0)
        JournalRate = [bool](@($loaded | Where-Object { [double]$_.JournalRate -ge 0.5 * [double]$_.Rate }).Count -gt 0)
    }
    $columns = @{}
    foreach ($factor in $Factors) { $columns[$factor] = [double[]]@($rows | ForEach-Object { [double]$_.$factor }) }
    $kept = [Collections.Generic.List[string]]::new()
    $basis = [Collections.Generic.List[double[]]]::new()
    foreach ($factor in $Factors) {
        if ($exercised.ContainsKey($factor) -and -not $exercised[$factor]) { continue }
        if ($kept.Count + 2 -gt $n - 1 -and $kept.Count -gt 0) { break }
        $x = $columns[$factor]
        $mean = ($x | Measure-Object -Average).Average
        $v = [double[]]@($x | ForEach-Object { $_ - $mean })
        $norm0 = [Math]::Sqrt((($v | ForEach-Object { $_ * $_ }) | Measure-Object -Sum).Sum)
        if ($norm0 -le 1e-9) { continue }
        foreach ($q in $basis) {
            $dot = 0.0
            for ($i = 0; $i -lt $n; $i++) { $dot += $v[$i] * $q[$i] }
            for ($i = 0; $i -lt $n; $i++) { $v[$i] -= $dot * $q[$i] }
        }
        $norm = [Math]::Sqrt((($v | ForEach-Object { $_ * $_ }) | Measure-Object -Sum).Sum)
        if ($norm / $norm0 -lt 0.1) { continue }
        $basis.Add([double[]]@($v | ForEach-Object { $_ / $norm }))
        $kept.Add($factor)
    }
    $solution = $null
    while ($true) {
        $solution = Get-TsxSolution -Y $y -Columns @($kept | ForEach-Object { , $columns[$_] })
        if ($null -eq $solution) { if ($kept.Count -eq 0) { return $null }; $kept.RemoveAt($kept.Count - 1); continue }
        $worst = -1
        for ($i = 0; $i -lt $kept.Count; $i++) { if ($solution[$i + 1] -le 1e-9 -and ($worst -lt 0 -or $solution[$i + 1] -lt $solution[$worst + 1])) { $worst = $i } }
        if ($worst -lt 0) { break }
        $kept.RemoveAt($worst)
    }
    # A negative intercept (pulled down by the steps of large messages) would give less than the server at rest
    # for a small load: the model then goes through the idle step, y − y(idle) = Σ b × (x − x(idle)), so that the
    # background connections of the idle server do not matter.
    $fixed = $false
    if ($solution[0] -lt 0) {
        $idleRows = @(for ($i = 0; $i -lt $n; $i++) { if ($rows[$i].Kind -eq 'Idle') { $i } })
        if ($idleRows.Count -gt 0) {
            $base = (@($idleRows | ForEach-Object { $y[$_] }) | Measure-Object -Average).Average
            $origin = @{}
            foreach ($factor in $Factors) { $origin[$factor] = (@($idleRows | ForEach-Object { $columns[$factor][$_] }) | Measure-Object -Average).Average }
            $shifted = [double[]]@($y | ForEach-Object { $_ - $base })
            $centred = @{}
            foreach ($factor in $Factors) { $o = $origin[$factor]; $centred[$factor] = [double[]]@($columns[$factor] | ForEach-Object { $_ - $o }) }
            while ($true) {
                $slopes = Get-TsxSolution -Y $shifted -Columns @($kept | ForEach-Object { , $centred[$_] }) -NoIntercept
                if ($null -eq $slopes) { $kept.RemoveAt($kept.Count - 1); continue }
                $worst = -1
                for ($i = 0; $i -lt $kept.Count; $i++) { if ($slopes[$i] -le 1e-9 -and ($worst -lt 0 -or $slopes[$i] -lt $slopes[$worst])) { $worst = $i } }
                if ($worst -lt 0) { break }
                $kept.RemoveAt($worst)
            }
            $intercept = $base
            for ($i = 0; $i -lt $kept.Count; $i++) { $intercept -= $slopes[$i] * $origin[$kept[$i]] }
            $solution = [double[]](@($intercept) + @($slopes))
            $fixed = $true
        }
    }
    $my = ($y | Measure-Object -Average).Average
    $ssr = 0.0; $syy = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $fit = $solution[0]
        for ($c = 0; $c -lt $kept.Count; $c++) { $fit += $solution[$c + 1] * $columns[$kept[$c]][$i] }
        $ssr += ($y[$i] - $fit) * ($y[$i] - $fit); $syy += ($y[$i] - $my) * ($y[$i] - $my)
    }
    $r2 = 1.0
    if ($syy -gt 0) { $r2 = 1 - $ssr / $syy }
    $model = [ordered]@{ Intercept = [Math]::Round($solution[0], 4); Slope = 0.0 }
    for ($c = 0; $c -lt $kept.Count; $c++) { $model[$script:Factors[$kept[$c]]] = [Math]::Round($solution[$c + 1], 6) }
    $model.R2 = [Math]::Round($r2, 4)
    $model.Points = $n
    $model.Factors = @($kept)
    if ($fixed) { $model.InterceptFromIdle = $true }
    return $model
}

function Get-TsxPrediction {
    param([Collections.IDictionary]$Model, [object]$Step)
    $value = [double]$Model.Intercept
    foreach ($factor in $script:Factors.Keys) {
        $key = $script:Factors[$factor]
        if ($Model.Contains($key)) { $value += [double]$Model[$key] * [double]$Step.$factor }
    }
    return $value
}

function Get-TsxBacklog {
    <# Memory per queued message and growth of mail.que during one backlog step. #>
    param([object]$Step, [Collections.IDictionary]$Models)
    $growthMB = 0.0
    if ($null -ne $Step.MailQueStartMB -and $null -ne $Step.MailQueEndMB) { $growthMB = $Step.MailQueEndMB - $Step.MailQueStartMB }
    $privateGrowth = 0.0
    $kbPerQueued = 0.0
    $memoryReference = 'début du palier'
    $fit = $Step.QueuedMemoryFit
    if ($fit -and $fit.R2 -ge 0.8 -and $fit.Slope -gt 0) {
        $kbPerQueued = $fit.Slope * 1024
        $memoryReference = 'pente pendant l''injection (R² {0})' -f $fit.R2
        $privateGrowth = $fit.Slope * $Step.BacklogMessages
    }
    elseif ($null -ne $Step.PrivateEndMB) {
        # The end of the step has no load: compare with the memory of the load model at that rate, not with
        # the start of the step, which includes the cost of the injection itself.
        if ($Models.Contains('TransportPrivateMB')) {
            $endRate = 0.0
            if ($null -ne $Step.EndRate) { $endRate = [double]$Step.EndRate }
            $privateGrowth = $Step.PrivateEndMB - ($Models.TransportPrivateMB.Intercept + $Models.TransportPrivateMB.Slope * $endRate)
            $memoryReference = 'modèle de charge'
        }
        elseif ($null -ne $Step.PrivateStartMB) { $privateGrowth = $Step.PrivateEndMB - $Step.PrivateStartMB }
        $kbPerQueued = [Math]::Max(0.0, $privateGrowth) * 1024 / $Step.BacklogMessages
    }
    $ese = 0.0
    $eseNote = ''
    $increment = $Step.MailQueIncrementMB
    if ($growthMB -le 0 -or $Step.SizeKB -le 0) {
        $eseNote = 'mail.que n''a pas grossi (espace libre interne)'
        Write-Warning ('{0} : mail.que n''a pas grossi pendant le palier backlog (espace libre interne) : facteur ESE non calculé, injecter davantage de messages.' -f $Step.Label)
    }
    elseif ($increment -and $growthMB -lt 4 * $increment) {
        # A growth of one to three increments says more about the free space already in the file than
        # about the size of the messages: the factor would be wrong by up to one increment.
        $eseNote = 'croissance de {0} Mo, soit {1} incrément(s) de {2} Mo : trop faible pour mesurer le facteur' -f [Math]::Round($growthMB, 0), [Math]::Round($growthMB / $increment, 1), [Math]::Round($increment, 0)
        Write-Warning ("{0} : facteur ESE non retenu : $eseNote. Injecter au moins {1} Mo de messages de plus." -f $Step.Label, [Math]::Round(8 * $increment, 0))
    }
    else { $ese = $growthMB * 1024 / ($Step.BacklogMessages * $Step.SizeKB) }
    [ordered]@{
        Label = $Step.Label; Messages = $Step.BacklogMessages; SizeKB = [Math]::Round($Step.SizeKB, 1); QueueGrowthMB = [Math]::Round($growthMB, 1); QueueIncrementMB = $increment
        EseOverheadFactor = [Math]::Round($ese, 3); EseNote = $eseNote; TransportPrivateGrowthMB = [Math]::Round($privateGrowth, 1); MemoryKBPerQueued = [Math]::Round($kbPerQueued, 3)
        MemoryReference = $memoryReference; MemoryFitted = [bool]($fit -and $fit.R2 -ge 0.8 -and $fit.Slope -gt 0)
        DehydratedKBPerQueued = $(if ($Step.PSObject.Properties['Dehydration'] -and $Step.Dehydration) { $Step.Dehydration.KBPerQueued } else { 0.0 })
        DehydrationNote = $(if ($Step.PSObject.Properties['Dehydration'] -and $Step.Dehydration) { 'palier {0} : déshydratation à {1} messages en file, mémoire privée {2} → {3} Mo' -f $Step.Label, $Step.Dehydration.Queue, $Step.Dehydration.PrivateBeforeMB, $Step.Dehydration.PrivateAfterMB } else { '' })
    }
}

function Invoke-TsxAnalyze {
    $folders = @($OutputPath) + @($IncludePath | Where-Object { $_ } | ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) })
    $steps = [Collections.Generic.List[object]]::new()
    $metadataList = @()
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) { throw "Dossier introuvable : $folder" }
        foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.json' | Sort-Object Name) {
            $meta = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if (-not $meta.PSObject.Properties['Tool'] -or $meta.Tool -ne 'TransportSizer.Calibration') { continue }
            $csv = Join-Path $folder ($meta.Label + '.csv')
            if (-not (Test-Path -LiteralPath $csv)) { Write-Warning "CSV manquant pour le palier $($meta.Label)."; continue }
            $rows = @(Import-Csv -LiteralPath $csv)
            $kept = @($rows | Where-Object { [double]::Parse($_.Elapsed, $script:Invariant) -ge $meta.WarmupSeconds })
            if ($kept.Count -eq 0) { $kept = $rows }
            # A load step keeps the samples with load: under a saturated processor the collector can run past the
            # end of the load, and these idle samples would lower the averages.
            if ($meta.Kind -eq 'Load') {
                $active = @($kept | Where-Object { $_.PSObject.Properties['ReceivedPerSec'] -and $_.ReceivedPerSec -ne '' -and [double]::Parse($_.ReceivedPerSec, $script:Invariant) -gt 0.5 })
                if ($active.Count -ge 3) { $kept = $active }
            }
            $step = [ordered]@{ Label = $meta.Label; Kind = $meta.Kind; DurationSeconds = $meta.DurationSeconds; Samples = $kept.Count }
            foreach ($metric in $script:Metrics) { $step[$metric] = Get-TsxAverage -Rows $kept -Metric $metric }
            $step.UsedMemoryWithDatabasesMB = $step.UsedMemoryMB
            $rate = $step.ReceivedPerSec
            if ($meta.Kind -eq 'Idle' -and $null -eq $rate) { $rate = 0 }
            $step.Rate = $rate
            # Load factors. Size: bytes of messages received ÷ messages received, else the size given to the step.
            $rows4Size = $kept
            if ($meta.Kind -eq 'Backlog') { $rows4Size = @($rows | Where-Object { $_.PSObject.Properties['ReceivedPerSec'] -and $_.ReceivedPerSec -ne '' -and [double]::Parse($_.ReceivedPerSec, $script:Invariant) -gt 1 }) }
            $bytes = Get-TsxAverage -Rows $rows4Size -Metric 'MessageBytesPerSec'
            $received = Get-TsxAverage -Rows $rows4Size -Metric 'ReceivedPerSec'
            $sizeKB = 0.0
            if ($null -ne $bytes -and $null -ne $received -and $received -gt 0.5 -and $bytes -gt 0) { $sizeKB = $bytes / $received / 1024 }
            elseif ($meta.PSObject.Properties['MessageSizeKB'] -and [double]$meta.MessageSizeKB -gt 0) { $sizeKB = [double]$meta.MessageSizeKB }
            if ($null -eq $rate -or $rate -le 0) { $sizeKB = $(if ($meta.Kind -eq 'Backlog') { $sizeKB } else { 0.0 }) }
            $rules = 0
            if ($meta.PSObject.Properties['TransportRules'] -and [int]$meta.TransportRules -gt 0) { $rules = [int]$meta.TransportRules }
            $r = 0.0
            if ($null -ne $rate) { $r = [double]$rate }
            $step.SizeKB = $sizeKB
            $step.MBps = $r * $sizeKB / 1024
            $step.Rules = $rules
            $step.RulesRate = $r * $rules
            $step.Sessions = $(if ($null -ne $step.ConnectionsPerSec) { [double]$step.ConnectionsPerSec } else { 0.0 })
            $step.TlsSessions = $(if ($null -ne $step.TlsConnectionsPerSec) { [double]$step.TlsConnectionsPerSec } else { 0.0 })
            $tlsShare = 0.0
            if ($null -ne $step.ConnectionsCurrent -and $null -ne $step.TlsConnectionsCurrent -and $step.ConnectionsCurrent -gt 0) { $tlsShare = [Math]::Min(1.0, $step.TlsConnectionsCurrent / $step.ConnectionsCurrent) }
            $step.TlsMBps = $step.MBps * $tlsShare
            $step.JournalRate = $(if ($null -ne $step.JournalReportsPerSec) { [double]$step.JournalReportsPerSec } else { 0.0 })
            $step.Validation = [bool]($Validate -contains $meta.Label)
            $step.Main = [bool]($folder -eq $OutputPath)
            $step.Start = [string]$meta.Start
            # mail.que at the first and last sample, and the megabytes of messages received during the step.
            $mailQueRows = @($rows | Where-Object { $_.MailQueMB -ne '' })
            $step.MailQueFirstMB = $(if ($mailQueRows.Count) { [double]::Parse($mailQueRows[0].MailQueMB, $script:Invariant) } else { $null })
            $step.MailQueLastMB = $(if ($mailQueRows.Count) { [double]::Parse($mailQueRows[-1].MailQueMB, $script:Invariant) } else { $null })
            # Messages received, plus the journal reports written on the server (Mailbox role): about the size of the
            # message they carry, they are stored in mail.que like the messages.
            $processed = 0.0
            foreach ($row in $rows) {
                if (-not ($row.PSObject.Properties['MessageBytesPerSec'] -and $row.MessageBytesPerSec -ne '')) { continue }
                $bytes = [double]::Parse($row.MessageBytesPerSec, $script:Invariant)
                $processed += $bytes * $meta.SampleIntervalSeconds
                if ($row.PSObject.Properties['JournalReportsPerSec'] -and $row.JournalReportsPerSec -ne '' -and $row.ReceivedPerSec -ne '') {
                    $received = [double]::Parse($row.ReceivedPerSec, $script:Invariant)
                    if ($received -gt 0) { $processed += [double]::Parse($row.JournalReportsPerSec, $script:Invariant) * $bytes / $received * $meta.SampleIntervalSeconds }
                }
            }
            $step.ProcessedMB = $processed / 1MB
            # A saturated processor caps the measure: the step says the load costs at least that much, it stays out
            # of the fit and is shown with the validation steps.
            $step.Saturated = [bool]($meta.Kind -eq 'Load' -and $null -ne $step.CpuPercent -and $step.CpuPercent -ge 95)
            if ($meta.Kind -eq 'Drain') {
                # Samples where the queue is being sent again: CPU, messages sent and received (new load, if any).
                $sending = @($rows | Where-Object { $_.PSObject.Properties['SentPerSec'] -and $_.SentPerSec -ne '' -and $_.CpuPercent -ne '' -and [double]::Parse($_.SentPerSec, $script:Invariant) -gt 1 })
                $step.DrainSamples = $sending.Count
                $step.DrainCpu = Get-TsxAverage -Rows $sending -Metric 'CpuPercent'
                $step.DrainSent = Get-TsxAverage -Rows $sending -Metric 'SentPerSec'
                $step.DrainReceived = $(if ($sending.Count) { [double](Get-TsxAverage -Rows $sending -Metric 'ReceivedPerSec') } else { 0.0 })
                $step.DrainMessages = [Math]::Round([double](@($sending | ForEach-Object { [double]::Parse($_.SentPerSec, $script:Invariant) * $meta.SampleIntervalSeconds }) | Measure-Object -Sum).Sum, 0)
                $step.DrainReadIops = Get-TsxAverage -Rows $sending -Metric 'QueueReadIops'
                $step.DrainWriteIops = Get-TsxAverage -Rows $sending -Metric 'QueueWriteIops'
            }
            if ($meta.Kind -eq 'Backlog') {
                $count = [Math]::Max(1.0, [int][Math]::Floor($kept.Count / 5))
                $first = @($rows | Select-Object -First $count)
                $last = @($rows | Select-Object -Last $count)
                $step.PrivateStartMB = Get-TsxAverage -Rows $first -Metric 'TransportPrivateMB'
                $step.PrivateEndMB = Get-TsxAverage -Rows $last -Metric 'TransportPrivateMB'
                $step.EndRate = Get-TsxAverage -Rows $last -Metric 'ReceivedPerSec'
                $step.MailQueStartMB = $meta.MailQue.StartMB
                $step.MailQueEndMB = $meta.MailQue.EndMB
                $step.BacklogMessages = $meta.BacklogMessages
                $step.MessageSizeKB = $meta.MessageSizeKB
                # Memory per queued message: slope of the EdgeTransport memory against the queue length while the
                # messages arrive at a steady rate (the load itself is then constant).
                $injection = @($rows | Where-Object { $_.ReceivedPerSec -ne '' -and $_.QueueLength -ne '' -and $_.TransportPrivateMB -ne '' -and [double]::Parse($_.ReceivedPerSec, $script:Invariant) -gt 1 })
                $priv = [double[]]@($injection | ForEach-Object { [double]::Parse($_.TransportPrivateMB, $script:Invariant) })
                $queue = [double[]]@($injection | ForEach-Object { [double]::Parse($_.QueueLength, $script:Invariant) })
                # Dehydration: under memory pressure Exchange drops the content of the queued messages from memory while
                # the queue keeps growing (REF-EDGE 2026-10-07: 5.07 down to 2.85 GB at 93 700 messages). The baseline is the
                # lowest memory before the first dehydration: a garbage collection early in the step falls below it and is
                # not a dehydration.
                # A dehydration takes 40 to 90 s: the drop is measured against the highest memory of the last 6 samples.
                $step.Dehydration = $null
                $base = 0; $firstDehydration = -1; $drops = @()
                for ($i = 1; $i -lt $injection.Count; $i++) {
                    if ($firstDehydration -lt 0 -and $priv[$i - 1] -lt $priv[$base]) { $base = $i - 1 }
                    $from = [Math]::Max($base, $i - 6)
                    $peak = ($priv[$from..($i - 1)] | Measure-Object -Maximum).Maximum
                    if ($priv[$i] -lt 0.8 * $peak -and $queue[$i] -ge $queue[$i - 1] -and $queue[$i] - $queue[$base] -gt 1000 -and $priv[$i] -gt $priv[$base]) {
                        if ($firstDehydration -lt 0) { $firstDehydration = $i }
                        $drops += $i
                    }
                }
                if ($firstDehydration -ge 0) {
                    # Whole messages: the growth from the baseline up to the first fall of 5 % below the highest memory
                    # (the first dehydration, even partial).
                    $end = $firstDehydration; $top = $priv[$base]
                    for ($i = $base + 1; $i -lt $firstDehydration; $i++) {
                        if ($priv[$i] -lt 0.95 * $top) { $end = $i; break }
                        $top = [Math]::Max($top, $priv[$i])
                    }
                    $injection = @($injection[$base..($end - 1)])
                }
                else {
                    # A garbage collection early in the step (memory left by a previous heavy step, REF-MAILBOX 2026-10-06:
                    # 2.27 GB down to 1.58 GB after 70 s) breaks the line: keep the samples after the last drop of 10 %.
                    for ($i = $injection.Count - 1; $i -ge 1; $i--) {
                        if ($priv[$i] -lt 0.9 * $priv[$i - 1]) { $injection = @($injection[$i..($injection.Count - 1)]); break }
                    }
                }
                $step.QueuedMemoryFit = $null
                if ($injection.Count -ge 10) {
                    $step.QueuedMemoryFit = Get-TsxRegression -X ([double[]]@($injection | ForEach-Object { [double]::Parse($_.QueueLength, $script:Invariant) })) -Y ([double[]]@($injection | ForEach-Object { [double]::Parse($_.TransportPrivateMB, $script:Invariant) })) -Digits 7
                }
                # Memory kept per dehydrated message: above the memory without queued messages (the intercept of the line
                # of whole messages, else the baseline sample), after the deepest drop.
                $fit = $step.QueuedMemoryFit
                $empty = $(if ($fit -and $fit.R2 -ge 0.8 -and $fit.Slope -gt 0) { [double]$fit.Intercept } elseif ($drops.Count) { $priv[$base] } else { 0.0 })
                $emptyQueue = $(if ($fit -and $fit.R2 -ge 0.8 -and $fit.Slope -gt 0) { 0.0 } elseif ($drops.Count) { $queue[$base] } else { 0.0 })
                foreach ($i in $drops) {
                    $kept = ($priv[$i] - $empty) * 1024 / ($queue[$i] - $emptyQueue)
                    if ($kept -le 0) { continue }
                    if ($null -eq $step.Dehydration -or $kept -lt $step.Dehydration.KBPerQueued) {
                        $step.Dehydration = [ordered]@{ Queue = [Math]::Round($queue[$i], 0); PrivateBeforeMB = [Math]::Round($priv[$i - 1], 0); PrivateAfterMB = [Math]::Round($priv[$i], 0); KBPerQueued = [Math]::Round($kept, 3) }
                    }
                }
                # mail.que grows by fixed increments: the smallest step between two sizes seen during the step.
                $sizes = @($rows | Where-Object { $_.MailQueMB -ne '' } | ForEach-Object { [double]::Parse($_.MailQueMB, $script:Invariant) } | Sort-Object -Unique)
                $step.MailQueIncrementMB = $null
                for ($i = 1; $i -lt $sizes.Count; $i++) {
                    $delta = $sizes[$i] - $sizes[$i - 1]
                    if ($delta -gt 0 -and ($null -eq $step.MailQueIncrementMB -or $delta -lt $step.MailQueIncrementMB)) { $step.MailQueIncrementMB = $delta }
                }
            }
            $steps.Add([pscustomobject]$step)
            $metadataList += $meta
        }
    }
    if ($steps.Count -eq 0) { throw "Aucun palier de calibration dans $($folders -join ', ')." }
    $loadSteps = @($steps | Where-Object { $_.Kind -in 'Idle', 'Load' -and $null -ne $_.Rate -and -not $_.Validation -and -not $_.Saturated })
    # Memory of the mailbox databases of the server (Store workers): not transport, left out of the used memory of
    # every step, or of none when some steps did not measure it (collector before 1.6, counter missing): a jump of the
    # memory between steps would be absorbed by the load terms of the model.
    $databaseCorrection = $null
    $withDatabase = @($steps | Where-Object { $null -ne $_.DatabaseMemoryMB -and $_.DatabaseMemoryMB -gt 0 })
    if ($withDatabase.Count -gt 0) {
        $missing = @($steps | Where-Object { $null -ne $_.UsedMemoryMB -and -not ($null -ne $_.DatabaseMemoryMB -and $_.DatabaseMemoryMB -gt 0) })
        if ($missing.Count -gt 0) {
            Write-Warning ('Mémoire des bases de boîtes (Store workers) mesurée sur {0} palier(s) seulement, pas sur {1} : elle n’’est retirée d’’aucun palier. Refaire ces paliers avec le collecteur 1.6 ou plus récent.' -f $withDatabase.Count, (($missing | ForEach-Object Label) -join ', '))
        }
        else {
            foreach ($step in $steps) { if ($null -ne $step.UsedMemoryMB) { $step.UsedMemoryMB = $step.UsedMemoryMB - $step.DatabaseMemoryMB } }
            $databaseCorrection = [ordered]@{
                Model = 'UsedMemoryMB'; DeltaMB = [Math]::Round(-(@($withDatabase | ForEach-Object { [double]$_.DatabaseMemoryMB }) | Measure-Object -Average).Average, 0)
                Source = 'Mesuré pendant chaque palier (Store workers)'
                Reason = 'Mémoire des copies de bases de boîtes du serveur de référence (processus Microsoft.Exchange.Store.Worker, cache ESE compris), retirée de la mémoire utilisée de chaque palier : un serveur de transport seul n’’a pas de base.'
            }
        }
    }
    if (@($loadSteps | Select-Object -ExpandProperty Rate -Unique).Count -lt 2) { throw 'Il faut au moins deux paliers Idle ou Load à des débits différents.' }

    # The processor depends on every factor. Memory, disk and network depend on the messages and their size: the
    # other factors would only absorb the slow drift of the memory over the hours of the steps.
    $models = [ordered]@{}
    foreach ($metric in 'CpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'QueueReadIops', 'QueueWriteIops', 'QueueReadBps', 'QueueWriteBps', 'NetworkInBps', 'NetworkOutBps') {
        $factors = $(if ($metric -eq 'CpuPercent') { @($script:Factors.Keys) } else { @('Rate', 'MBps', 'JournalRate') })
        $model = Get-TsxFit -Points $loadSteps -Metric $metric -Factors $factors
        if ($model) { $models[$metric] = $model }
    }
    if (-not $models.Contains('CpuPercent')) { throw 'Modèle CPU impossible : vérifier les paliers.' }

    # Steps kept out of the fit: what the models predict for them.
    $validation = @(foreach ($step in @($steps | Where-Object { $_.Validation -or $_.Saturated })) {
            $entry = [ordered]@{ Label = $step.Label; Rate = [Math]::Round([double]$step.Rate, 3); SizeKB = [Math]::Round($step.SizeKB, 1); Rules = $step.Rules; Saturated = $step.Saturated }
            foreach ($metric in 'CpuPercent', 'TransportPrivateMB', 'QueueWriteIops', 'QueueWriteBps') {
                if ($models.Contains($metric) -and $null -ne $step.$metric) {
                    $entry[$metric] = [ordered]@{ Measured = [Math]::Round([double]$step.$metric, 3); Predicted = [Math]::Round((Get-TsxPrediction -Model $models[$metric] -Step $step), 3) }
                }
            }
            $entry
        })

    $backlog = $null
    # Growth of mail.que with the volume processed, queue almost empty: from the first load step of the main folder
    # where mail.que grew (free space of the database used up) to the last one.
    $retention = $null
    $chain = @($steps | Where-Object { $_.Main -and $_.Kind -eq 'Load' -and $null -ne $_.MailQueFirstMB -and $_.ProcessedMB -gt 0 } | Sort-Object { [datetime]$_.Start })
    $firstGrowth = -1
    for ($i = 0; $i -lt $chain.Count; $i++) { if ($chain[$i].MailQueLastMB -gt $chain[$i].MailQueFirstMB) { $firstGrowth = $i; break } }
    if ($firstGrowth -ge 0) {
        $part = @($chain[$firstGrowth..($chain.Count - 1)])
        $growth = $part[-1].MailQueLastMB - $part[0].MailQueFirstMB
        $processedMB = (@($part | ForEach-Object { $_.ProcessedMB }) | Measure-Object -Sum).Sum
        $queued = (@($part | ForEach-Object { [double]$_.QueueLength }) | Measure-Object -Maximum).Maximum
        if ($processedMB -gt 1024 -and $growth -gt 0) {
            $retention = [ordered]@{
                GrowthMB = [Math]::Round($growth, 0); ProcessedMB = [Math]::Round($processedMB, 0); Factor = [Math]::Round($growth / $processedMB, 3); Steps = $part.Count
                FirstStep = $part[0].Label; LastStep = $part[-1].Label; MaxQueue = [Math]::Round($queued, 0)
            }
            Write-Host ('mail.que : +{0} Mo pour {1} Mo de messages traités ({2} Mo par Mo), file moyenne ≤ {3} messages.' -f $retention.GrowthMB, $retention.ProcessedMB, $retention.Factor, $retention.MaxQueue)
        }
    }
    $backlogResults = @(foreach ($step in @($steps | Where-Object { $_.Kind -eq 'Backlog' -and $_.BacklogMessages -gt 0 })) { Get-TsxBacklog -Step $step -Models $models })
    if ($backlogResults.Count -gt 0) {
        # Memory per queued message: the highest of the steps where the slope was measured (else of all steps).
        $fitted = @($backlogResults | Where-Object { $_.MemoryFitted })
        $reference = @($(if ($fitted.Count) { $fitted } else { $backlogResults }) | Sort-Object { [double]$_.MemoryKBPerQueued } -Descending)[0]
        $last = $backlogResults[-1]
        $backlog = [ordered]@{
            Messages = $reference.Messages; QueueGrowthMB = $last.QueueGrowthMB; QueueIncrementMB = $last.QueueIncrementMB; EseOverheadFactor = $last.EseOverheadFactor; EseNote = $last.EseNote
            TransportPrivateGrowthMB = $reference.TransportPrivateGrowthMB; MemoryKBPerQueued = $reference.MemoryKBPerQueued; MemoryReference = ('{0}, palier {1}' -f $reference.MemoryReference, $reference.Label); MessageSizeKB = $reference.SizeKB
        }
        # ESE factor: the step with the most data among those where mail.que grew enough.
        $ese = @($backlogResults | Where-Object { $_.EseOverheadFactor -gt 0 } | Sort-Object { $_.Messages * $_.SizeKB } -Descending) | Select-Object -First 1
        if ($ese) { $backlog.EseOverheadFactor = $ese.EseOverheadFactor; $backlog.EseNote = ''; $backlog.QueueGrowthMB = $ese.QueueGrowthMB; $backlog.EseStep = $ese.Label }
        # Dehydrated message: the highest cost of the steps where Exchange dehydrated the queue.
        $dehydrated = @($backlogResults | Where-Object { $_.DehydratedKBPerQueued -gt 0 } | Sort-Object { [double]$_.DehydratedKBPerQueued } -Descending) | Select-Object -First 1
        if ($dehydrated) {
            $backlog.DehydratedKBPerQueued = $dehydrated.DehydratedKBPerQueued; $backlog.DehydrationNote = $dehydrated.DehydrationNote
            Write-Host ('Déshydratation : {0} Ko par message en file ({1}).' -f $dehydrated.DehydratedKBPerQueued, $dehydrated.DehydrationNote)
        }
        # Memory per queued message against the size: a straight line through the fitted steps of different sizes.
        $memory = @($backlogResults | Where-Object { $_.MemoryFitted -and $_.SizeKB -gt 0 })
        if ($memory.Count -ge 2) {
            $small = (@($memory | ForEach-Object { [double]$_.SizeKB }) | Measure-Object -Minimum).Minimum
            $large = (@($memory | ForEach-Object { [double]$_.SizeKB }) | Measure-Object -Maximum).Maximum
            if ($large -ge 2 * $small) {
                $line = Get-TsxRegression -X ([double[]]@($memory | ForEach-Object { $_.SizeKB })) -Y ([double[]]@($memory | ForEach-Object { $_.MemoryKBPerQueued })) -Digits 8
                if ($line) {
                    $perKB = [Math]::Max(0.0, $line.Slope)
                    $base = $(if ($line.Slope -ge 0) { [Math]::Max(0.0, $line.Intercept) } else { (@($memory | ForEach-Object { [double]$_.MemoryKBPerQueued }) | Measure-Object -Average).Average })
                    $backlog.MemoryBaseKB = [Math]::Round($base, 3)
                    $backlog.MemoryPerKB = [Math]::Round($perKB, 5)
                    $backlog.MemoryReference = 'pentes pendant l''injection de {0} paliers ({1})' -f $memory.Count, (@($memory | ForEach-Object { '{0} Ko : {1} Ko' -f [Math]::Round($_.SizeKB, 0), [Math]::Round($_.MemoryKBPerQueued, 1) }) -join ', ')
                }
            }
        }
        $backlog.Steps = $backlogResults
    }
    # Drain: CPU above the idle server and the new load received meanwhile, per message/s sent from the queue.
    $drain = $null
    $drainStep = @($steps | Where-Object { $_.Kind -eq 'Drain' -and $_.DrainSamples -ge 3 -and $_.DrainSent -gt 1 } | Sort-Object { [double]$_.DrainMessages } -Descending) | Select-Object -First 1
    if ($drainStep -and $models.Contains('CpuPercent')) {
        $cpuModel = $models.CpuPercent
        $receivedCpu = [double]$cpuModel.Slope * [double]$drainStep.DrainReceived
        $perMessage = ([double]$drainStep.DrainCpu - [double]$cpuModel.Intercept - $receivedCpu) / [double]$drainStep.DrainSent
        if ($perMessage -gt 0) {
            # Reads and writes of the queue volume per message sent, above the idle server: a dehydrated message is read again.
            $perIo = {
                param($name, $value)
                if ($null -eq $value -or -not $models.Contains($name)) { return 0.0 }
                [Math]::Round([Math]::Max(0.0, ([double]$value - [double]$models[$name].Intercept - [double]$models[$name].Slope * [double]$drainStep.DrainReceived) / [double]$drainStep.DrainSent), 3)
            }
            $drain = [ordered]@{
                CpuPercentPerMsg = [Math]::Round($perMessage, 4); Rate = [Math]::Round([double]$drainStep.DrainSent, 1); Messages = $drainStep.DrainMessages; Step = $drainStep.Label
                ReadIopsPerMsg = (& $perIo 'QueueReadIops' $drainStep.DrainReadIops); WriteIopsPerMsg = (& $perIo 'QueueWriteIops' $drainStep.DrainWriteIops)
                Note = ('{0} % de CPU à {1} msg/s renvoyés (à vide {2} %).' -f [Math]::Round([double]$drainStep.DrainCpu, 1), [Math]::Round([double]$drainStep.DrainSent, 1), [Math]::Round([double]$cpuModel.Intercept, 1))
            }
            Write-Host ('Vidange : {0} % de CPU par message/s renvoyé ({1}).' -f $drain.CpuPercentPerMsg, $drain.Note)
        }
    }

    $first = $metadataList[0]
    $loaded = @($loadSteps | Where-Object { $_.Rate -gt 0.5 })
    # Measured range: the fitted steps and the saturated ones (observed, at least as costly as predicted).
    $rangeSteps = @($loadSteps) + @($steps | Where-Object { $_.Saturated })
    $size = 0.0
    if ($loaded.Count -gt 0) { $size = (@($loaded | ForEach-Object { $_.SizeKB }) | Measure-Object -Average).Average }
    if (-not $Name) { $Name = '{0} {1}' -f $first.Server.Name, ([datetime]$first.Start).ToString('yyyy-MM-dd') }
    $calibration = [ordered]@{
        SchemaVersion = 1
        Name          = $Name
        Role          = $first.Role
        MeasuredAt    = ([datetime]$first.Start).ToString('yyyy-MM-dd')
        Source        = 'Measure-TransportLoad.ps1 -Analyze, {0} palier(s)' -f $steps.Count
        Server        = [ordered]@{
            Name = $first.Server.Name; LogicalProcessors = $first.Server.LogicalProcessors; Cores = $first.Server.Cores; MemoryGB = $first.Server.MemoryGB
            Virtual = $first.Server.Virtual; Model = $first.Server.Model; Processor = $first.Server.Processor; SpecIntRatePerCore = $SpecIntRatePerCore; ExchangeVersion = $first.ExchangeVersion
        }
        MessageSizeKB = [Math]::Round($size, 1)
        MaxRate       = [Math]::Round((@($loadSteps | ForEach-Object { $_.Rate }) | Measure-Object -Maximum).Maximum, 3)
        # Little's law: messages in the delivery queues ÷ messages received per second, the longest of the steps.
        ResidenceSeconds = [Math]::Round([double](@($loadSteps | Where-Object { $_.Rate -gt 1 -and $null -ne $_.QueueLength } | ForEach-Object { $_.QueueLength / $_.Rate }) + @(0.0) | Measure-Object -Maximum).Maximum, 1)
        Range         = [ordered]@{
            MinSizeKB = $(if ($loaded.Count) { [Math]::Round((@($loaded | ForEach-Object { $_.SizeKB }) | Measure-Object -Minimum).Minimum, 1) } else { 0 })
            MaxSizeKB = $(if ($loaded.Count) { [Math]::Round((@($loaded | ForEach-Object { $_.SizeKB }) | Measure-Object -Maximum).Maximum, 1) } else { 0 })
            MaxMBps = [Math]::Round((@($rangeSteps | ForEach-Object { $_.MBps }) | Measure-Object -Maximum).Maximum, 3)
            MaxRules = (@($rangeSteps | ForEach-Object { $_.Rules }) | Measure-Object -Maximum).Maximum
            MaxSessionsPerSec = [Math]::Round((@($rangeSteps | ForEach-Object { $_.Sessions }) | Measure-Object -Maximum).Maximum, 3)
            # Journal reports are a factor of their own only when steps journaled the load and the CPU model kept the
            # term (Mailbox role); the steps of the fit only (not the saturated ones).
            MaxJournalPerSec = $(if ($models.Contains('CpuPercent') -and $models.CpuPercent.Contains('PerJournal') -and [double]$models.CpuPercent.PerJournal -gt 0) {
                    [Math]::Round([double](@($loadSteps | Where-Object { [double]$_.Rate -gt 0 -and [double]$_.JournalRate -ge 0.5 * [double]$_.Rate } | ForEach-Object { [double]$_.JournalRate }) + @(0.0) | Measure-Object -Maximum).Maximum, 3)
                }
                else { 0 })
        }
        Models        = $models
        Corrections   = @(if ($databaseCorrection) { $databaseCorrection })
        Validation    = $validation
        Retention     = $retention
        Backlog       = $backlog
        Drain         = $drain
        Steps         = @($steps | ForEach-Object {
                $s = $_
                $out = [ordered]@{}
                foreach ($p in $s.PSObject.Properties) { $out[$p.Name] = $(if ($p.Value -is [double]) { [Math]::Round($p.Value, 3) } else { $p.Value }) }
                $out
            })
    }
    if (-not $ProfilePath) { $ProfilePath = Join-Path $OutputPath ('Calibration-{0}.json' -f $first.Server.Name) }
    [IO.File]::WriteAllText($ProfilePath, (ConvertTo-Json -InputObject $calibration -Depth 8), [Text.UTF8Encoding]::new($false))
    $cpu = $models.CpuPercent
    $terms = @(foreach ($factor in $script:Factors.Keys) { $key = $script:Factors[$factor]; if ($cpu.Contains($key) -and $cpu[$key] -ne 0) { '{0} × {1}' -f $cpu[$key], $factor } })
    Write-Host ('Profil : {0} ({1} paliers, CPU % = {2} + {3}, R² {4})' -f $ProfilePath, $steps.Count, $cpu.Intercept, ($terms -join ' + '), $cpu.R2)
    foreach ($v in $validation) { if ($v.Contains('CpuPercent')) { Write-Host ('Validation {0} : CPU mesuré {1} %, prédit {2} %' -f $v.Label, $v.CpuPercent.Measured, $v.CpuPercent.Predicted) } }
    return [pscustomobject]$calibration
}

if ($Analyze) { Invoke-TsxAnalyze } else { Invoke-TsxCollect }
