#Requires -Version 5.1
<#
    Transport Sizer - Pester tests (Pester 6).
    Author  : Nicolas Fabert
    Version : 1.10.0

    Run with Run-Tests.ps1 (Windows PowerShell 5.1 or PowerShell 7). The values checked are computed by
    hand in the comments: the engine must give the same numbers as the formulas of the report.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'TransportSizer.psd1') -Force
    $script:CalibrationPath = Join-Path $script:Root 'tests\data\Calibration-Test.json'
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('TransportSizerTests-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $script:Work -Force)
    function New-TestScenario {
        param([string]$Role = 'Edge', [hashtable]$Changes = @{})
        $s = Get-TsDefaultScenario -Role $Role
        # The formulas checked below are those of the worst moment: the space of delivered messages is tested apart.
        $s.Resilience.SpaceReclaimDays = 0
        foreach ($key in $Changes.Keys) {
            $parts = $key -split '\.'
            if ($parts.Count -eq 2) { $s[$parts[0]][$parts[1]] = $Changes[$key] } else { $s[$key] = $Changes[$key] }
        }
        return $s
    }
    function Get-Value { param($Result, [string]$Id) $Result.Values[$Id].Value }
}

AfterAll {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Microsoft calculator formula (Role Requirements C185-C189)' {
    It 'gives 214.6 GB for 10 000 mailboxes x 150 messages x 75 KB on 4 servers, Safety Net 2 days' {
        $ms = Get-TsMicrosoftQueueEstimate -MessagesPerDayPerServer 375000 -AverageSizeKB 75 -MessageExpirationDays 2 -SafetyNetDays 2
        [Math]::Round($ms.SizeGB, 1) | Should -Be 214.6
        $ms.Multiplier | Should -Be 4
    }
    It 'gives 107.3 GB with Safety Net 0 day and 53.6 GB without shadow nor queue' {
        [Math]::Round((Get-TsMicrosoftQueueEstimate -MessagesPerDayPerServer 375000 -AverageSizeKB 75 -MessageExpirationDays 2 -SafetyNetDays 0).SizeGB, 1) | Should -Be 107.3
        [Math]::Round((Get-TsMicrosoftQueueEstimate -MessagesPerDayPerServer 375000 -AverageSizeKB 75 -MessageExpirationDays 0 -SafetyNetDays 0 -Shadow $true).SizeGB, 1) | Should -Be 53.6
    }
}

Describe 'Scenarios' {
    It 'completes a partial scenario with the defaults of its role' {
        $s = ConvertTo-TsScenario -Scenario @{ Role = 'Mailbox'; Load = @{ GrowthPercent = '12,5' } }
        $s.Load.GrowthPercent | Should -Be 12.5
        $s.Load.PeakHourPercent | Should -Be 15
        $s.Flows.Count | Should -Be 3
        $s.Storage.ExchangeBinariesGB | Should -Be 15
    }
    It 'rejects a value that is not a number, in French' {
        { ConvertTo-TsScenario -Scenario @{ Load = @{ PeakHourPercent = 'abc' } } } | Should -Throw '*n’’est pas un nombre*'
    }
    It 'rejects an unknown role, a percentage above 100 and a negative value' {
        { ConvertTo-TsScenario -Scenario @{ Role = 'Hub' } } | Should -Throw '*Rôle inconnu*'
        { ConvertTo-TsScenario -Scenario @{ Storage = @{ MaxFillPercent = 120 } } } | Should -Throw '*supérieur à 100*'
        { ConvertTo-TsScenario -Scenario @{ Network = @{ ProtocolOverheadPercent = -1 } } } | Should -Throw '*négative*'
    }
    It 'accepts the French labels of the window for the direction of a flow' {
        $s = ConvertTo-TsScenario -Scenario @{ Flows = @(@{ Name = 'x'; Direction = 'Sortant'; MessagesPerDay = '1 000'; AverageSizeKB = 50 }) }
        $s.Flows[0].Direction | Should -Be 'Outbound'
        $s.Flows[0].MessagesPerDay | Should -Be 1000
    }
    It 'saves and reads back a scenario with its calibration embedded' {
        $s = New-TestScenario -Role Mailbox -Changes @{ Name = 'Aller-retour' }
        $s.Calibration = Import-TsCalibration -Path $script:CalibrationPath
        $path = Join-Path $script:Work 'roundtrip.json'
        [void](Export-TsScenario -Scenario $s -Path $path)
        $back = Import-TsScenario -Path $path
        $back.Name | Should -Be 'Aller-retour'
        $back.Role | Should -Be 'Mailbox'
        $back.Calibration.Name | Should -Be 'Profil de test (synthétique)'
        $back.Calibration.Models.CpuPercent.Slope | Should -Be 2.5
    }
    It 'loads every example scenario' {
        foreach ($file in Get-ChildItem (Join-Path $script:Root 'examples') -Filter '*.json' | Where-Object Name -notlike 'Calibration-*') {
            $s = Import-TsScenario -Path $file.FullName
            (Invoke-TsSizing -Scenario $s).Valid | Should -BeTrue -Because $file.Name
        }
    }
}

Describe 'Lab calibration profile (REF-EDGE, examples\Calibration-Reference-Edge.json)' {
    BeforeAll {
        $script:LabCalibration = Import-TsCalibration -Path (Join-Path $script:Root 'examples\Calibration-Reference-Edge.json')
        $script:LabResult = Invoke-TsSizing -Scenario (Import-TsScenario -Path (Join-Path $script:Root 'examples\Edge-Internet.json')) -Calibration $script:LabCalibration
    }
    It 'reads the measured models and the backlog step' {
        $script:LabCalibration.Role | Should -Be 'Edge'
        $script:LabCalibration.Models.CpuPercent.Slope | Should -Be 1.0227
        $script:LabCalibration.Backlog.MemoryKBPerQueued | Should -Be 63.488
        $script:LabCalibration.Backlog.EseOverheadFactor | Should -Be 0
    }
    It 'sizes the Internet Edge example: (3.191 + 1.0227 x 3) % of 2 processors, 63.5 KB per queued message' {
        $script:LabResult.Valid | Should -BeTrue
        [Math]::Round((Get-Value $script:LabResult 'cpu.refBusy'), 4) | Should -Be ([Math]::Round((3.191 + 1.0227 * 3) / 100 * 2, 4))
        [Math]::Round((Get-Value $script:LabResult 'mem.queuedMB'), 1) | Should -Be ([Math]::Round(72180 * 63.488 / 1024, 1))
        # The example asks 4 vCPU at least (1.7).
        $script:LabResult.Summary.Cores | Should -Be 4
        $script:LabResult.Summary.RamGB | Should -Be 12
    }
    It 'warns that the ESE factor was not measured and that some models are weak' {
        $codes = @($script:LabResult.Checks | ForEach-Object Code)
        $codes | Should -Contain 'EseNotCalibrated'
        $codes | Should -Contain 'WeakModel'
        $codes | Should -Not -Contain 'Extrapolation'
    }
    It 'marks a maximum rate far beyond the measured rate as extrapolated (16 physical cores)' {
        $r = Invoke-TsSizing -Scenario (Import-TsScenario -Path (Join-Path $script:Root 'examples\Edge-Physical.json')) -Calibration $script:LabCalibration
        $r.Values['res.max'].Note | Should -BeLike 'Extrapolé*'
        $script:LabResult.Values['res.max'].Note | Should -BeLike 'Extrapolé*'
        $script:LabResult.Summary.RateMaxExtrapolated | Should -BeTrue
    }
}

Describe 'Reference Edge profile (REF-EDGE factors, data\Reference-Edge.json)' {
    BeforeAll {
        $script:FactorCalibration = Import-TsCalibration -Path (Join-Path $script:Root 'data\Reference-Edge.json')
        $script:FactorResult = Invoke-TsSizing -Scenario (Import-TsScenario -Path (Join-Path $script:Root 'examples\Edge-Internet.json')) -Calibration $script:FactorCalibration
    }
    It 'measured every factor of the processor and the ESE factor on a new mail.que' {
        $cpu = $script:FactorCalibration.Models.CpuPercent
        foreach ($term in 'Slope', 'PerMBps', 'PerRuleMsg', 'PerSession', 'PerTlsSession', 'PerTlsMBps') { $cpu[$term] | Should -BeGreaterThan 0 -Because $term }
        $cpu.R2 | Should -BeGreaterThan 0.95
        $script:FactorCalibration.Backlog.EseOverheadFactor | Should -Be 1.245
        $script:FactorCalibration.Range.MaxRules | Should -Be 100
        $script:FactorCalibration.Models.QueueWriteIops.Intercept | Should -BeGreaterThan 5
    }
    It 'sizes the Internet Edge example with every term and the correction of the mix (3 msg/s of 75 KB, one TLS session per message)' {
        $cpu = $script:FactorCalibration.Models.CpuPercent
        $mbps = 3 * 75 / 1024
        $percent = $cpu.Intercept + $cpu.Slope * 3 + $cpu.PerMBps * $mbps + $cpu.PerSession * 3 + $cpu.PerTlsSession * 3 + $cpu.PerTlsMBps * $mbps
        [Math]::Round((Get-Value $script:FactorResult 'cpu.refModel'), 4) | Should -Be ([Math]::Round($percent / 100 * 2, 4))
        [Math]::Round((Get-Value $script:FactorResult 'cpu.validation'), 3) | Should -Be ([Math]::Round(22.982 / 18.6, 3))
        [Math]::Round($script:FactorResult.Summary.MailQueGB, 3) | Should -Be ([Math]::Round(0.5 + 72180 * 75 / 1048576 * 1.245 + 72000 * 75 / 1048576 * 1.245, 3))
        $script:FactorResult.Summary.QueueWriteMBps | Should -BeGreaterThan 0.1
        [Math]::Round((Get-Value $script:FactorResult 'queue.window'), 3) | Should -Be ([Math]::Round(72000 * 75 / 1048576 * 1.245, 3))
        @($script:FactorResult.Checks | ForEach-Object Code) | Should -Not -Contain 'SessionsNotCalibrated'
    }
    It 'warns beyond the 100 rules measured and costs 20 rules at about 6 points of the reference CPU' {
        $s = Import-TsScenario -Path (Join-Path $script:Root 'examples\Edge-Internet.json')
        $s.Load.TransportRules = 20
        $r = Invoke-TsSizing -Scenario $s -Calibration $script:FactorCalibration
        [Math]::Round((Get-Value $r 'cpu.term.PerRuleMsg'), 2) | Should -Be ([Math]::Round($script:FactorCalibration.Models.CpuPercent.PerRuleMsg * 60, 2))
        $s.Load.TransportRules = 200
        @((Invoke-TsSizing -Scenario $s -Calibration $script:FactorCalibration).Checks | ForEach-Object Code) | Should -Contain 'RulesExtrapolation'
    }
}

Describe 'Reference Mailbox profile (REF-MAILBOX, data\Reference-Mailbox.json)' {
    BeforeAll {
        $script:Mbx = Import-TsCalibration -Path (Join-Path $script:Root 'data\Reference-Mailbox.json')
    }
    It 'measured the cost of a message, of the size and of a journal report on a Mailbox server' {
        $script:Mbx.Role | Should -Be 'Mailbox'
        $script:Mbx.Server.LogicalProcessors | Should -Be 4
        $cpu = $script:Mbx.Models.CpuPercent
        [Math]::Round($cpu.Slope, 2) | Should -Be 3.19
        [Math]::Round($cpu.PerMBps, 2) | Should -Be 3.70
        [Math]::Round($cpu.PerJournal, 2) | Should -Be 1.89
        $script:Mbx.Range.MaxJournalPerSec | Should -BeGreaterThan 9
        [Math]::Round($script:Mbx.Backlog.MemoryKBPerQueued, 0) | Should -Be 58
        $script:Mbx.Retention.Factor | Should -Be 1.186
        # Memory of the mailbox databases of the lab (Store workers, 0.9 GB measured) left out of the used memory.
        $script:Mbx.Corrections.Count | Should -Be 1
        [Math]::Round($script:Mbx.Models.UsedMemoryMB.Intercept, 0) | Should -Be 12517
        # jnl-20 saturated the 4 processors: kept out of the fit, shown as validation.
        @($script:Mbx.Validation | Where-Object { $_.Label -eq 'jnl-20' -and $_.Saturated }).Count | Should -Be 1
    }
    It 'sizes the Mailbox relay example with journaling: reports as their own factor, ESE from Safety Net' {
        $s = Import-TsScenario -Path (Join-Path $script:Root 'examples\Mailbox-Relay.json')
        $s.Journaling.Enabled = $true
        $r = Invoke-TsSizing -Scenario $s -Calibration $script:Mbx
        $design = Get-Value $r 'load.designRate'
        [Math]::Round((Get-Value $r 'load.journalRate'), 6) | Should -Be ([Math]::Round($design / 2, 6))
        [Math]::Round((Get-Value $r 'cpu.term.PerJournal'), 4) | Should -Be ([Math]::Round($script:Mbx.Models.CpuPercent.PerJournal * $design / 2, 4))
        Get-Value $r 'queue.ese' | Should -Be 1.186
        @($r.Checks | ForEach-Object Code) | Should -Not -Contain 'CalibrationRole'
    }
}

Describe 'Generic reference profile and its adjustments' {
    It 'sizes a scenario without a profile with the reference of its role, and says it is generic' {
        $edge = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Edge)
        $edge.Summary.ProfileSource | Should -Be 'Reference'
        $edge.Summary.CalibrationName | Should -BeLike 'Référence Edge*'
        $edge.Summary.Cores | Should -Not -BeNullOrEmpty
        $edge.Summary.RamGB | Should -Not -BeNullOrEmpty
        @($edge.Checks | ForEach-Object Code) | Should -Contain 'ReferenceProfile'
        $mailbox = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Mailbox)
        $mailbox.Summary.CalibrationName | Should -BeLike 'Référence Mailbox*'
        @($mailbox.Checks | ForEach-Object Code) | Should -Contain 'ReferenceMemoryAtRest'
        # Without any profile on purpose (-Calibration $null): nothing generic is computed.
        $none = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Edge) -Calibration $null
        $none.Summary.ProfileSource | Should -Be 'None'
        $none.Summary.Cores | Should -BeNullOrEmpty
    }
    It 'prefers a profile measured at the customer and keeps the reference flag of a saved report' {
        $custom = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Edge) -Calibration (Import-TsCalibration -Path $script:CalibrationPath)
        $custom.Summary.ProfileSource | Should -Be 'Custom'
        @($custom.Checks | ForEach-Object Code) | Should -Not -Contain 'ReferenceProfile'
        $saved = Join-Path $script:Work 'reference-scenario.json'
        [void](Export-TsScenario -Scenario (Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Mailbox)).Scenario -Path $saved)
        (Invoke-TsSizing -Scenario (Import-TsScenario -Path $saved)).Summary.ProfileSource | Should -Be 'Reference'
    }
    It 'warns when the profile named by a scenario cannot be found, and uses the reference' {
        $path = Join-Path $script:Work 'missing-profile.json'
        $s = Get-TsDefaultScenario -Role Edge
        $s.CalibrationPath = 'Customer-EDGE-profile.json'
        [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $s -Depth 12), [Text.UTF8Encoding]::new($false))
        $r = Invoke-TsSizing -Scenario (Import-TsScenario -Path $path)
        $r.Summary.ProfileSource | Should -Be 'Reference'
        @($r.Checks | Where-Object { $_.Code -eq 'CalibrationMissing' -and $_.Level -eq 'Warning' }).Count | Should -Be 1
        # The reference itself, imported on purpose, is not a missing profile.
        $s.CalibrationPath = (Join-Path $script:Root 'data\Reference-Edge.json')
        [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $s -Depth 12), [Text.UTF8Encoding]::new($false))
        @((Invoke-TsSizing -Scenario (Import-TsScenario -Path $path)).Checks | ForEach-Object Code) | Should -Not -Contain 'CalibrationMissing'
    }
    It 'adapts the profile: processor × 1.5, I/O × 2, memory at rest of the customer' {
        $base = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Mailbox)
        $s = Get-TsDefaultScenario -Role Mailbox
        $s.Adjustment.CpuPercent = 150; $s.Adjustment.IoPercent = 200; $s.Adjustment.MemoryAtRestGB = 6
        $r = Invoke-TsSizing -Scenario $s
        [Math]::Round((Get-Value $r 'cpu.needed'), 6) | Should -Be ([Math]::Round(1.5 * (Get-Value $base 'cpu.needed'), 6))
        [Math]::Round((Get-Value $r 'io.front'), 6) | Should -Be ([Math]::Round(2 * (Get-Value $base 'io.front'), 6))
        [Math]::Round((Get-Value $r 'io.writeMBps'), 6) | Should -Be ([Math]::Round(2 * (Get-Value $base 'io.writeMBps'), 6))
        $intercept = (Get-TsReferenceProfile -Role Mailbox).Models.UsedMemoryMB.Intercept
        [Math]::Round((Get-Value $r 'mem.used') - (Get-Value $base 'mem.used'), 3) | Should -Be ([Math]::Round(6 * 1024 - $intercept, 3))
        Get-Value $r 'mem.atRest' | Should -Be 6
        $r.Summary.RamGB | Should -BeLessThan $base.Summary.RamGB
        @($r.Checks | ForEach-Object Code) | Should -Not -Contain 'ReferenceMemoryAtRest'
        $r.Values['res.cpuMax'].Value | Should -BeLessThan $base.Values['res.cpuMax'].Value
    }
    It 'refuses an adjustment of zero and returns a new reference each time' {
        $s = Get-TsDefaultScenario -Role Edge
        $s.Adjustment.CpuPercent = 0
        { ConvertTo-TsScenario -Scenario $s } | Should -Throw -ExpectedMessage '*Adjustment.CpuPercent*'
        $first = Get-TsReferenceProfile -Role Edge
        $first.Models.CpuPercent.Slope = 999
        (Get-TsReferenceProfile -Role Edge).Models.CpuPercent.Slope | Should -Not -Be 999
    }
}

Describe 'Edge Transport: no Safety Net, no shadow' {
    BeforeAll { $script:Edge = Invoke-TsSizing -Scenario (New-TestScenario -Role Edge) -Calibration $null }
    It 'spreads the traffic on the servers left (180 000 messages, 3 servers)' {
        $script:Edge.Summary.Alive | Should -Be 3
        $script:Edge.Summary.MessagesPerDayPerServer | Should -Be 60000
        $script:Edge.Summary.RateDesign | Should -Be 2.5
    }
    It 'counts transit and backlog only: mail.que = 0.5 + 60 150 x 75 KB / 1 048 576' {
        Get-Value $script:Edge 'queue.transit' | Should -Be 150
        Get-Value $script:Edge 'queue.backlog' | Should -Be 60000
        [Math]::Round($script:Edge.Summary.MailQueGB, 4) | Should -Be ([Math]::Round(0.5 + 60150 * 75 / 1048576, 4))
        ($script:Edge.QueueParts | Where-Object Id -eq 'safetynet').GB | Should -Be 0
        ($script:Edge.QueueParts | Where-Object Id -eq 'shadow').GB | Should -Be 0
    }
    It 'ignores the Safety Net and shadow settings and says so' {
        $other = Invoke-TsSizing -Scenario (New-TestScenario -Role Edge -Changes @{ 'Resilience.SafetyNetHoldTimeHours' = 500; 'Resilience.ShadowRedundancy' = $false }) -Calibration $null
        $other.Summary.MailQueGB | Should -Be $script:Edge.Summary.MailQueGB
        @($script:Edge.Checks | Where-Object Code -eq 'EdgeRule').Count | Should -Be 1
        $script:Edge.Values['queue.edgeRule'].Kind | Should -Be 'Rule'
    }
    It 'sizes the volumes: 120 GB system, 10 GB queue' {
        $script:Edge.Summary.SystemGB | Should -Be 120
        $script:Edge.Summary.QueueVolumeGB | Should -Be 10
        [Math]::Round((Get-Value $script:Edge 'queue.logs'), 3) | Should -Be 1.125
    }
    It 'gives the Microsoft calculator value with shadow and Safety Net for comparison (34.3 GB)' {
        [Math]::Round($script:Edge.Summary.MicrosoftQueueGB, 1) | Should -Be 34.3
    }
    It 'leaves CPU, memory and IOPS to the calibration' {
        $script:Edge.Summary.Cores | Should -BeNullOrEmpty
        $script:Edge.Summary.RamGB | Should -BeNullOrEmpty
        $script:Edge.Summary.Iops | Should -BeNullOrEmpty
        @($script:Edge.Checks | Where-Object Code -eq 'NoCalibration').Count | Should -Be 1
        ($script:Edge.Config | Where-Object Component -eq 'Processeur').Value | Should -Be 'À calibrer'
    }
}

Describe 'Mailbox (transport): Safety Net and shadow, even without mailboxes' {
    BeforeAll { $script:Mailbox = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox) -Calibration $null }
    It 'counts transit, backlog, Safety Net (2 days) and the shadow copies of all of them' {
        Get-Value $script:Mailbox 'queue.transit' | Should -Be 170
        Get-Value $script:Mailbox 'queue.backlog' | Should -Be 68000
        Get-Value $script:Mailbox 'queue.safetyNet' | Should -Be 136000
        Get-Value $script:Mailbox 'queue.shadow' | Should -Be 204170
        $script:Mailbox.Summary.QueueMessages | Should -Be 408340
        [Math]::Round($script:Mailbox.Summary.MailQueGB, 3) | Should -Be ([Math]::Round(0.5 + 28944100 / 1048576, 3))
    }
    It 'needs more queue than an Edge for the same traffic' {
        $edgeSame = Invoke-TsSizing -Scenario (New-TestScenario -Role Edge -Changes @{ Flows = (Get-TsDefaultScenario -Role Mailbox).Flows }) -Calibration $null
        $script:Mailbox.Summary.MailQueGB | Should -BeGreaterThan (2 * $edgeSame.Summary.MailQueGB)
    }
    It 'has no shadow copy with one server left, and warns' {
        $one = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Topology.Sites' = 1; 'Topology.ServersPerSite' = 1; 'Topology.Failure' = 'None' }) -Calibration $null
        Get-Value $one 'queue.shadow' | Should -Be 0
        Get-Value $one 'queue.shadowActive' | Should -BeFalse
        @($one.Checks | Where-Object Code -eq 'ShadowInactive').Count | Should -Be 1
    }
    It 'keeps the shadow copy in the AD site without a DAG: 2 sites x 1 server have no shadow' {
        $split = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Topology.Sites' = 2; 'Topology.ServersPerSite' = 1; 'Topology.Failure' = 'None' }) -Calibration $null
        $split.Summary.Alive | Should -Be 2
        Get-Value $split 'queue.shadowActive' | Should -BeFalse
        Get-Value $split 'queue.shadow' | Should -Be 0
        @($split.Checks | Where-Object Code -eq 'ShadowInactive').Count | Should -Be 1
        $dag = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Topology.Sites' = 2; 'Topology.ServersPerSite' = 1; 'Topology.Failure' = 'None'; 'Topology.Dag' = $true }) -Calibration $null
        Get-Value $dag 'queue.shadowActive' | Should -BeTrue
    }
    It 'sizes on the server that keeps shadow copies and warns about the server left alone in its site' {
        # 2 sites x 2, loss of one server: one site keeps 2 servers (shadow), the other keeps 1 (no shadow).
        Get-Value $script:Mailbox 'queue.shadowActive' | Should -BeTrue
        @($script:Mailbox.Checks | Where-Object Code -eq 'ShadowAlone').Count | Should -Be 1
        $site = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Topology.Failure' = 'OneSite' }) -Calibration $null
        Get-Value $site 'queue.shadowActive' | Should -BeTrue
        @($site.Checks | Where-Object Code -in 'ShadowAlone', 'ShadowInactive').Count | Should -Be 0
        $two = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Topology.Failure' = 'TwoServers' }) -Calibration $null
        Get-Value $two 'queue.shadowActive' | Should -BeTrue
        @($two.Checks | Where-Object Code -eq 'ShadowAlone').Count | Should -Be 1
    }
    It 'follows SafetyNetHoldTime, and the replay lag when it is longer' {
        $zero = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Resilience.SafetyNetHoldTimeHours' = 0 }) -Calibration $null
        Get-Value $zero 'queue.safetyNet' | Should -Be 0
        $lag = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Resilience.ReplayLagHours' = 72 }) -Calibration $null
        Get-Value $lag 'queue.safetyNetHold' | Should -Be 72
        Get-Value $lag 'queue.safetyNet' | Should -Be 204000
        @($lag.Checks | Where-Object Code -eq 'ReplayLag').Count | Should -Be 1
        Get-Value $lag 'ms.multiplier' | Should -Be (1 + 0.5 * 2 + 3)
    }
}

Describe 'Space of delivered messages (mail.que reclaimed once a day)' {
    It 'adds one day of traffic to the worst moment on an Edge: 0.5 + (60 150 + 60 000) x 75 KB / 1 048 576' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Resilience.SpaceReclaimDays' = 1 }) -Calibration $null
        [Math]::Round((Get-Value $r 'queue.window'), 4) | Should -Be ([Math]::Round(60000 * 75 / 1048576, 4))
        [Math]::Round($r.Summary.MailQueGB, 4) | Should -Be ([Math]::Round(0.5 + (60150 + 60000) * 75 / 1048576, 4))
        @($r.QueueParts | Where-Object Id -eq 'retained').Count | Should -Be 1
    }
    It 'counts the shadow copies received on a Mailbox server and says the rule was measured on an Edge' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Resilience.SpaceReclaimDays' = 2 }) -Calibration $null
        $mDay = Get-Value $r 'load.perServer'
        $avg = Get-Value $r 'load.avgSize'
        [Math]::Round((Get-Value $r 'queue.window'), 4) | Should -Be ([Math]::Round($mDay * 2 * $avg * 2 / 1048576, 4))
        @($r.Checks | ForEach-Object Code) | Should -Contain 'ReclaimMeasuredOnEdge'
    }
    It 'takes the measured growth per MB processed when it is above the ESE factor, and nothing with 0 day' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Retention = [ordered]@{ Factor = 1.5; GrowthMB = 3000; ProcessedMB = 2000; MaxQueue = 60 }
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Resilience.SpaceReclaimDays' = 1 }) -Calibration $cal
        [Math]::Round((Get-Value $r 'queue.window'), 4) | Should -Be ([Math]::Round(60000 * 75 / 1048576 * 1.5, 4))
        $r.Values['queue.window'].Kind | Should -Be 'Calibration'
        (Get-Value (Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $cal) 'queue.window') | Should -Be 0
    }
}

Describe 'Journaling (Mailbox role)' {
    It 'writes one report per journaled message and destination: 170 000 reports of the original size + 4 KB, held during an outage' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Journaling.Enabled' = $true }) -Calibration $null
        Get-Value $r 'journal.messages' | Should -Be 170000
        [Math]::Round((Get-Value $r 'journal.size'), 4) | Should -Be ([Math]::Round((100000 * 75 + 50000 * 75 + 20000 * 40) / 170000 + 4, 4))
        $r.Summary.MessagesPerDay | Should -Be (340000 * 1.2)
        $flow = @($r.Flows | Where-Object Name -like 'Rapports de journal*')
        $flow.Count | Should -Be 1
        $flow[0].Direction | Should -Be 'Outbound'
        $flow[0].Held | Should -BeTrue
        @($r.Checks | ForEach-Object Code) | Should -Contain 'JournalingExternal'
    }
    It 'follows the scope, the share and the destinations' {
        $external = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Journaling.Enabled' = $true; 'Journaling.Scope' = 'External' }) -Calibration $null
        Get-Value $external 'journal.messages' | Should -Be 150000
        $internal = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Journaling.Enabled' = $true; 'Journaling.Scope' = 'Internal'; 'Journaling.Percent' = 50; 'Journaling.Recipients' = 2; 'Journaling.Destination' = 'Internal' }) -Calibration $null
        Get-Value $internal 'journal.messages' | Should -Be 20000
        @($internal.Flows | Where-Object Name -like 'Rapports de journal*')[0].Direction | Should -Be 'Internal'
        @($internal.Checks | ForEach-Object Code) | Should -Not -Contain 'JournalingExternal'
    }
    It 'adds the reports to the queue and Safety Net, not to the shadow copies (none measured on REF-MAILBOX), and leaves them out of the backlog when not held' {
        $off = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox) -Calibration $null
        $on = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Journaling.Enabled' = $true }) -Calibration $null
        $notHeld = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Journaling.Enabled' = $true; 'Journaling.HeldDuringOutage' = $false }) -Calibration $null
        (Get-Value $on 'queue.safetyNet') | Should -Be (2 * (Get-Value $off 'queue.safetyNet'))
        (Get-Value $on 'queue.shadow') | Should -Be (Get-Value $off 'queue.shadow')
        (Get-Value $on 'net.shadow') | Should -Be (Get-Value $off 'net.shadow')
        (Get-Value $notHeld 'queue.backlog') | Should -Be (Get-Value $off 'queue.backlog')
        (Get-Value $on 'queue.backlog') | Should -Be (2 * (Get-Value $off 'queue.backlog'))
        @($notHeld.Checks | ForEach-Object Code) | Should -Contain 'JournalingNotHeld'
    }
    It 'costs the reports with the journal factor of a profile that measured it: no SMTP session, no MB received' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Models.CpuPercent.PerJournal = 3; $cal.Range.MaxJournalPerSec = 10
        $scenario = New-TestScenario -Role Mailbox -Changes @{ 'Journaling.Enabled' = $true; 'Journaling.Scope' = 'Internal'; 'Load.MessagesPerSession' = 2 }
        $r = Invoke-TsSizing -Scenario $scenario -Calibration $cal
        $design = Get-Value $r 'load.designRate'
        # 20 000 reports of internal messages among 190 000 messages per day.
        $share = 20000 / 190000
        [Math]::Round((Get-Value $r 'load.journalRate'), 6) | Should -Be ([Math]::Round($design * $share, 6))
        [Math]::Round((Get-Value $r 'load.smtpRate'), 6) | Should -Be ([Math]::Round($design * (1 - $share), 6))
        [Math]::Round((Get-Value $r 'load.sessions'), 6) | Should -Be ([Math]::Round($design * (1 - $share) / 2, 6))
        [Math]::Round((Get-Value $r 'cpu.term.PerJournal'), 6) | Should -Be ([Math]::Round(3 * $design * $share, 6))
        # Received volume: the 170 000 messages of the flows only.
        $smtpKB = (100000 * 75 + 50000 * 75 + 20000 * 40) / 170000
        [Math]::Round((Get-Value $r 'load.designMBps'), 6) | Should -Be ([Math]::Round($design * (1 - $share) * $smtpKB / 1024, 6))
        # Without the factor in the profile, the reports are messages like the others.
        $plain = Invoke-TsSizing -Scenario $scenario -Calibration (Import-TsCalibration -Path $script:CalibrationPath)
        $plain.Values.Contains('load.journalRate') | Should -BeFalse
        [Math]::Round((Get-Value $plain 'load.sessions'), 6) | Should -Be ([Math]::Round($design / 2, 6))
        # The models without a journal term (queue IOPS here) keep the whole load: the reports are never free.
        Get-Value $r 'io.write' | Should -Be (Get-Value $plain 'io.write')
        # A journal step without a journal term in the CPU model does not split the load.
        $dropped = Import-TsCalibration -Path $script:CalibrationPath
        $dropped.Range.MaxJournalPerSec = 10
        (Invoke-TsSizing -Scenario $scenario -Calibration $dropped).Values.Contains('load.journalRate') | Should -BeFalse
    }
    It 'is written by the Mailbox servers: an Edge scenario keeps its traffic and says so' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Journaling.Enabled' = $true }) -Calibration $null
        $r.Summary.MessagesPerDay | Should -Be 180000
        $r.Values.Contains('journal.messages') | Should -BeFalse
        @($r.Checks | ForEach-Object Code) | Should -Contain 'JournalingOnMailbox'
    }
    It 'accepts the French labels of the window and refuses an unknown scope or no destination' {
        (ConvertTo-TsScenario -Scenario @{ Role = 'Mailbox'; Journaling = @{ Scope = 'Messages internes'; Destination = 'Boîte de journalisation interne' } }).Journaling.Scope | Should -Be 'Internal'
        { ConvertTo-TsScenario -Scenario @{ Role = 'Mailbox'; Journaling = @{ Scope = 'Partout' } } } | Should -Throw '*Journaling.Scope*'
        { ConvertTo-TsScenario -Scenario @{ Role = 'Mailbox'; Journaling = @{ Recipients = 0 } } } | Should -Throw '*Journaling.Recipients*'
    }
}

Describe 'Working day and peak rate' {
    It 'sizes 2 million messages a day with a measured peak of 300 000 messages per hour over 2 hours, 10 working hours' {
        $s = New-TestScenario -Changes @{ 'Load.WorkingHours' = 10; 'Load.OffHoursPercent' = 15; 'Load.PeakHours' = 2; 'Load.PeakRate' = 300000; 'Load.PeakRateUnit' = 'PerHour'; 'Resilience.OutageHours' = 4 }
        $s.Flows = @([ordered]@{ Name = 'Entrant'; Direction = 'Inbound'; MessagesPerDay = 1400000; AverageSizeKB = 75; FanOut = 1; HeldDuringOutage = $true }, [ordered]@{ Name = 'Sortant'; Direction = 'Outbound'; MessagesPerDay = 600000; AverageSizeKB = 75; FanOut = 1; HeldDuringOutage = $true })
        $r = Invoke-TsSizing -Scenario $s -Calibration $null
        # 300 000 ÷ 2 000 000 = 15 % of the day in each peak hour; 2 000 000 × 1.2 ÷ 3 servers = 800 000 per server.
        Get-Value $r 'load.peakShare' | Should -Be 15
        [Math]::Round((Get-Value $r 'load.designRate'), 6) | Should -Be ([Math]::Round(800000 * 0.15 / 3600, 6))
        [Math]::Round((Get-Value $r 'load.workingRate'), 6) | Should -Be ([Math]::Round(800000 * 0.85 / 10 / 3600, 6))
        # 4 h: 2 peak hours at 15 % + 2 hours at (85 − 30) ÷ 8 = 6.875 %.
        [Math]::Round((Get-Value $r 'queue.fraction'), 6) | Should -Be ([Math]::Round(0.30 + 2 * 0.06875, 6))
        $r.Summary.RateWorking | Should -Be (Get-Value $r 'load.workingRate')
        # The same peak in messages per second.
        $s.Load.PeakRate = 300000 / 3600; $s.Load.PeakRateUnit = 'PerSecond'
        [Math]::Round((Get-Value (Invoke-TsSizing -Scenario $s -Calibration $null) 'load.designRate'), 6) | Should -Be ([Math]::Round(800000 * 0.15 / 3600, 6))
    }
    It 'drains with the traffic of the working hours, not the average of 24 hours' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration (Import-TsCalibration -Path $script:CalibrationPath)
        $max = $r.Values['res.max'].Value
        [Math]::Round((Get-Value $r 'res.drain'), 6) | Should -Be ([Math]::Round((Get-Value $r 'queue.backlog') / (($max - (Get-Value $r 'load.workingRate')) * 3600), 6))
    }
    It 'sizes the processors to drain the queue of the outage within the target, at the drain cost measured by the profile' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Drain = [ordered]@{ CpuPercentPerMsg = 0.5; Rate = 1000; Messages = 50000; Step = 'drain'; Note = ''; ReadIopsPerMsg = 0; WriteIopsPerMsg = 0 }
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.MinCores' = 1; 'Compute.EvenVcpu' = $false; 'Resilience.DrainTargetHours' = 0.25 }) -Calibration $cal
        # 60 000 messages in 15 min = 66.7 msg/s; working hours: 6 + 2.5 x rate % of 2 processors.
        $busy = 6 + 2.5 * (Get-Value $r 'load.workingRate')
        [Math]::Round((Get-Value $r 'res.busyWorking'), 6) | Should -Be ([Math]::Round($busy, 6))
        $needed = ($busy + 0.5 * 60000 / 900) / 100 * 2
        [Math]::Round((Get-Value $r 'res.drainCores'), 6) | Should -Be ([Math]::Round($needed, 6))
        $r.Summary.Cores | Should -Be ([Math]::Ceiling($needed / 0.8))
        $rate = ($r.Summary.Cores * 0.8 / 2 * 100 - $busy) / 0.5
        [Math]::Round((Get-Value $r 'res.drainCpuRate'), 6) | Should -Be ([Math]::Round($rate, 6))
        [Math]::Round($r.Summary.DrainHours, 6) | Should -Be ([Math]::Round(60000 / ($rate * 3600), 6))
        $r.Summary.DrainHours | Should -BeLessOrEqual 0.25
        # The drain measured by the profile caps the rate: more cores would not drain faster.
        $cal.Drain.Rate = 20
        $c = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.MinCores' = 1; 'Compute.EvenVcpu' = $false; 'Resilience.DrainTargetHours' = 0.25 }) -Calibration $cal
        [Math]::Round($c.Summary.DrainHours, 6) | Should -Be ([Math]::Round(60000 / (20 * 3600), 6))
        [Math]::Round((Get-Value $c 'res.drainCores'), 6) | Should -Be ([Math]::Round(($busy + 0.5 * 20) / 100 * 2, 6))
        @($c.Checks | ForEach-Object Code) | Should -Contain 'DrainSlow'
        $cal.Drain.Rate = 1000
        # Without a target, the peak alone sizes the processors.
        (Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.MinCores' = 1; 'Compute.EvenVcpu' = $false; 'Resilience.DrainTargetHours' = 0 }) -Calibration $cal).Summary.Cores | Should -Be 1
        # A physical server with fewer cores than the target needs is warned.
        $p = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.Cores' = 1; 'Compute.MinCores' = 1; 'Resilience.DrainTargetHours' = 0.1 }) -Calibration $cal
        @($p.Checks | ForEach-Object Code) | Should -Contain 'DrainCoresShort'
    }
    It 'rounds the virtual processors up to an even number, 4 at least, and keeps the processors of a scenario written before 1.7' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        # 35 msg/s: (6 + 2.5 x 35) % of 2 processors = 1.87 core, 3 vCPU at 80 %.
        $changes = @{ 'Load.BurstFactor' = 14; 'Compute.MinCores' = 1; 'Resilience.DrainTargetHours' = 0 }
        (Invoke-TsSizing -Scenario (New-TestScenario -Changes $changes) -Calibration $cal).Summary.Cores | Should -Be 4
        $changes['Compute.EvenVcpu'] = $false
        (Invoke-TsSizing -Scenario (New-TestScenario -Changes $changes) -Calibration $cal).Summary.Cores | Should -Be 3
        (Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $cal).Summary.Cores | Should -Be 4
        $old = ConvertTo-TsScenario -Scenario ([pscustomobject]@{ Role = 'Edge'; Compute = [pscustomobject]@{ MaxCpuPercent = 80; MinCores = 2 }; Resilience = [pscustomobject]@{ OutageHours = 24 } })
        $old.Compute.MinCores | Should -Be 2
        $old.Compute.EvenVcpu | Should -BeFalse
        $old.Resilience.DrainTargetHours | Should -Be 0
        { ConvertTo-TsScenario -Scenario @{ Compute = @{ MinCores = 0 } } } | Should -Throw '*au moins un processeur*'
    }
    It 'keeps the result of a scenario written before 1.6: day of 24 hours, one peak hour' {
        $old = [pscustomobject]@{ Role = 'Edge'; Load = [pscustomobject]@{ GrowthPercent = 20; PeakHourPercent = 4.2; BurstFactor = 1 } }
        $s = ConvertTo-TsScenario -Scenario $old
        $s.Load.WorkingHours | Should -Be 24
        $s.Load.OffHoursPercent | Should -Be 0
        $s.Load.PeakHours | Should -Be 1
        $r = Invoke-TsSizing -Scenario $s -Calibration $null
        [Math]::Round($r.Summary.RateDesign, 6) | Should -Be ([Math]::Round(150000 * 1.2 / 3 * 0.042 / 3600, 6))
        @($r.Checks | ForEach-Object Code) | Should -Not -Contain 'PeakBelowWorkingAverage'
        $old.Load.PeakHourPercent = 50
        (Invoke-TsSizing -Scenario $old -Calibration $null).Valid | Should -BeTrue
    }
    It 'checks the shape of the day' {
        $tooLong = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.PeakHours' = 7; 'Load.PeakHourPercent' = 15 }) -Calibration $null
        @($tooLong.Checks | Where-Object { $_.Code -eq 'PeakTooLong' -and $_.Level -eq 'Error' }).Count | Should -Be 1
        $low = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.PeakHourPercent' = 6 }) -Calibration $null
        @($low.Checks | ForEach-Object Code) | Should -Contain 'PeakBelowWorkingAverage'
        [Math]::Round($low.Summary.PeakHourPercent, 6) | Should -Be 9
        $slow = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.PeakRate' = 1000 }) -Calibration $null
        @($slow.Checks | Where-Object { $_.Code -eq 'PeakHour' -and $_.Level -eq 'Error' }).Count | Should -Be 1
        { ConvertTo-TsScenario -Scenario (New-TestScenario -Changes @{ 'Load.WorkingHours' = 24; 'Load.OffHoursPercent' = 10 }) } | Should -Throw -ExpectedMessage '*OffHoursPercent*'
        { ConvertTo-TsScenario -Scenario (New-TestScenario -Changes @{ 'Load.PeakHours' = 12 }) } | Should -Throw -ExpectedMessage '*PeakHours*'
        { ConvertTo-TsScenario -Scenario (New-TestScenario -Changes @{ 'Load.PeakRateUnit' = 'msg/s' }) } | Should -Not -Throw
        $uniform = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.WorkingHours' = 24; 'Load.OffHoursPercent' = 0; 'Load.PeakHours' = 1; 'Load.PeakHourPercent' = 100 / 24 }) -Calibration $null
        $uniform.Valid | Should -BeTrue
        [Math]::Round((Get-Value $uniform 'load.workingRate'), 6) | Should -Be ([Math]::Round((Get-Value $uniform 'load.avgRate'), 6))
    }
}

Describe 'Backlog of an outage' {
    It 'takes the worst window of the working day: 6 h = 2 h of peak at 15 % + 4 h at 7.5 % = 0.6 day, 30 h = 1.6 days' {
        # Default day: 10 working hours, 10 % outside them, 2 peak hours at 15 %: the 8 other working hours carry (90 − 30) ÷ 8 = 7.5 % each.
        [Math]::Round((Get-Value (Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Resilience.OutageHours' = 6 }) -Calibration $null) 'queue.fraction'), 6) | Should -Be 0.6
        [Math]::Round((Get-Value (Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Resilience.OutageHours' = 30 }) -Calibration $null) 'queue.fraction'), 6) | Should -Be 1.6
        # A peak of 6 hours: the whole window at 15 %.
        [Math]::Round((Get-Value (Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Resilience.OutageHours' = 6; 'Load.PeakHours' = 6 }) -Calibration $null) 'queue.fraction'), 6) | Should -Be 0.9
    }
    It 'stops at the message expiration' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Resilience.OutageHours' = 72 }) -Calibration $null
        Get-Value $r 'queue.outage' | Should -Be 48
        Get-Value $r 'queue.fraction' | Should -Be 2
        @($r.Checks | Where-Object Code -eq 'OutageCapped').Count | Should -Be 1
    }
    It 'only holds the flows marked as held' {
        $s = New-TestScenario
        $s.Flows[1].HeldDuringOutage = $false
        Get-Value (Invoke-TsSizing -Scenario $s -Calibration $null) 'queue.backlog' | Should -Be 40000
    }
}

Describe 'Invalid scenarios' {
    It 'refuses the loss of a site with one site' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Topology.Sites' = 1; 'Topology.Failure' = 'OneSite' }) -Calibration $null
        $r.Valid | Should -BeFalse
        @($r.Checks | Where-Object Code -eq 'SiteFailure').Count | Should -Be 1
    }
    It 'refuses a peak hour below the hourly average and a scenario without traffic' {
        (Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.PeakHourPercent' = 3 }) -Calibration $null).Valid | Should -BeFalse
        (Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Flows = @() }) -Calibration $null).Valid | Should -BeFalse
    }
}

Describe 'Calibration models' {
    BeforeAll {
        $script:Calibration = Import-TsCalibration -Path $script:CalibrationPath
        $script:Calibrated = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $script:Calibration
    }
    It 'sizes the processor: (6 + 2.5 x 2.5) % of 2 processors = 0.245 core, 4 vCPU minimum' {
        [Math]::Round((Get-Value $script:Calibrated 'cpu.refBusy'), 3) | Should -Be 0.245
        $script:Calibrated.Summary.Cores | Should -Be 4
        [Math]::Round($script:Calibrated.Summary.CpuUtilization, 5) | Should -Be 0.06125
        # (4 x 0.8 / 2 x 100 - 6) / 2.5
        [Math]::Round($script:Calibrated.Values['res.cpuMax'].Value, 2) | Should -Be 61.6
    }
    It 'sizes the memory under the back pressure thresholds, queued messages included' {
        [Math]::Round((Get-Value $script:Calibrated 'mem.queuedMB'), 2) | Should -Be ([Math]::Round(60150 * 3.07 / 1024, 2))
        [Math]::Round((Get-Value $script:Calibrated 'mem.byUsed'), 3) | Should -Be ([Math]::Round((4225 + 60150 * 3.07 / 1024) / 0.88 / 1024, 3))
        $script:Calibrated.Summary.RamGB | Should -Be 8
        Get-Value $script:Calibrated 'mem.pagefile' | Should -Be 2
        @($script:Calibrated.Checks | ForEach-Object Code) | Should -Contain 'DehydrationNotCalibrated'
    }
    It 'counts the queue of the outage dehydrated when the profile measured it, and says which threshold dehydrates first' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Backlog.DehydratedKBPerQueued = 1.0
        $r = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $cal
        # 150 messages in transit kept whole, 60 000 of the outage dehydrated.
        [Math]::Round((Get-Value $r 'mem.queuedMB'), 4) | Should -Be ([Math]::Round((150 * 3.07 + 60000 * 1.0) / 1024, 4))
        Get-Value $r 'mem.perDehydrated' | Should -Be 1
        @($r.Checks | ForEach-Object Code) | Should -Not -Contain 'DehydrationNotCalibrated'
        # 500 KB whole, 50 KB dehydrated: 12 GB; the memory of all processes reaches 88 % first (Edge at rest: 3.9 GB besides EdgeTransport).
        $cal.Backlog.MemoryKBPerQueued = 500; $cal.Backlog.DehydratedKBPerQueued = 50
        $r = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $cal
        $r.Summary.RamGB | Should -Be 12
        [Math]::Round((Get-Value $r 'mem.hydrated'), 3) | Should -Be ([Math]::Round((0.88 * 12288 - (4225 + 150 * 500 / 1024)) * 1024 / 500, 3))
        @($r.Checks | ForEach-Object Code) | Should -Contain 'Dehydration'
        @($r.Checks | ForEach-Object Code) | Should -Not -Contain 'DehydrationRejects'
        # With 32 GB, EdgeTransport reaches 72 % before the whole server reaches 88 %: refusals while it dehydrates.
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.MinRamGB' = 32 }) -Calibration $cal
        @($r.Checks | ForEach-Object Code) | Should -Contain 'DehydrationRejects'
    }
    It 'applies the ESE factor to mail.que and adds the pagefile to the system volume' {
        [Math]::Round($script:Calibrated.Summary.MailQueGB, 4) | Should -Be ([Math]::Round(0.5 + 60150 * 75 / 1048576 * 1.16, 4))
        Get-Value $script:Calibrated 'sto.systemContent' | Should -Be 91.25
    }
    It 'gives the IOPS of the queue volume: (1.5 + 14.25) x 1.2 = 18.9' {
        [Math]::Round($script:Calibrated.Summary.Iops, 2) | Should -Be 18.9
    }
    It 'scales the CPU with the performance per core and the hypervisor' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Server.SpecIntRatePerCore = 10
        $cal.Server.Virtual = $false
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.TargetSpecIntRatePerCore' = 20 }) -Calibration $cal
        [Math]::Round((Get-Value $r 'cpu.needed'), 4) | Should -Be ([Math]::Round(0.245 * 0.5 * 1.1, 4))
    }
    It 'warns when the design rate is beyond 1.5 times the highest measured rate' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Topology.Sites' = 1; 'Topology.ServersPerSite' = 1; 'Topology.Failure' = 'None'; 'Load.PeakHourPercent' = 100; 'Load.PeakHours' = 1; 'Load.OffHoursPercent' = 0 }) -Calibration $script:Calibration
        @($r.Checks | Where-Object Code -eq 'Extrapolation').Count | Should -Be 1
    }
    It 'warns when the profile was measured on another role' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox) -Calibration $script:Calibration
        @($r.Checks | Where-Object Code -eq 'CalibrationRole').Count | Should -Be 1
    }
    It 'adds the cost of the size, the rules, the sessions and TLS: 2.5 msg/s of 75 KB, 50 rules, 2 messages per session, 50 % TLS' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Models.CpuPercent.PerMBps = 1.5; $cal.Models.CpuPercent.PerRuleMsg = 0.004; $cal.Models.CpuPercent.PerSession = 0.6; $cal.Models.CpuPercent.PerTlsSession = 1.2
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.TransportRules' = 50; 'Load.TlsPercent' = 50; 'Load.MessagesPerSession' = 2 }) -Calibration $cal
        $mbps = 2.5 * 75 / 1024
        $percent = 6 + 2.5 * 2.5 + 1.5 * $mbps + 0.004 * 2.5 * 50 + 0.6 * 1.25 + 1.2 * 1.25 * 0.5
        [Math]::Round((Get-Value $r 'cpu.refBusy'), 4) | Should -Be ([Math]::Round($percent / 100 * 2, 4))
        [Math]::Round((Get-Value $r 'cpu.term.PerRuleMsg'), 3) | Should -Be 0.5
        [Math]::Round((Get-Value $r 'cpu.term.PerTlsSession'), 3) | Should -Be 0.75
        Get-Value $r 'load.sessions' | Should -Be 1.25
        $r.Values['cpu.refModel'].Computation | Should -BeLike '*0,004 × 125*'
        Get-Value $r 'cpu.validation' | Should -Be 1
        # Maximum rate: every factor follows the rate.
        $perMessage = ($percent - 6) / 2.5
        [Math]::Round($r.Values['res.cpuMax'].Value, 2) | Should -Be ([Math]::Round((4 * 0.8 / 2 * 100 - 6) / $perMessage, 2))
    }
    It 'applies the gap of a validation step measured above the prediction, never below, and not from a saturated step' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Validation = @(
            [pscustomobject]@{ Label = 'mix-10'; Saturated = $false; CpuPercent = [pscustomobject]@{ Measured = 24; Predicted = 20 } }
            [pscustomobject]@{ Label = 'rules100-10'; Saturated = $true; CpuPercent = [pscustomobject]@{ Measured = 97; Predicted = 50 } }
            [pscustomobject]@{ Label = 'other'; Saturated = $false; CpuPercent = [pscustomobject]@{ Measured = 10; Predicted = 12 } }
        )
        $r = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $cal
        Get-Value $r 'cpu.validation' | Should -Be 1.2
        [Math]::Round((Get-Value $r 'cpu.refBusy'), 4) | Should -Be ([Math]::Round(0.245 * 1.2, 4))
        [Math]::Round($r.Values['res.cpuMax'].Value, 2) | Should -Be ([Math]::Round((160 / 1.2 - 6) / 2.5, 2))
    }
    It 'counts the memory of a queued message from its size and gives the write throughput of the queue' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Backlog.MemoryBaseKB = 60; $cal.Backlog.MemoryPerKB = 0.01
        $cal.Models.QueueWriteBps = [ordered]@{ Intercept = 1048576; Slope = 0; PerMBps = 2097152; PerRuleMsg = 0; PerSession = 0; PerTlsSession = 0; PerTlsMBps = 0; R2 = 1; Points = 5 }
        $r = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $cal
        Get-Value $r 'mem.perQueued' | Should -Be 60.75
        [Math]::Round((Get-Value $r 'mem.queuedMB'), 2) | Should -Be ([Math]::Round(60150 * 60.75 / 1024, 2))
        [Math]::Round($r.Summary.QueueWriteMBps, 4) | Should -Be ([Math]::Round((1 + 2 * 2.5 * 75 / 1024) * 1.2, 4))
        ($r.Config | Where-Object Component -like 'Disque file*').Detail | Should -BeLike '*Mo/s en écriture*'
    }
    It 'warns when the size or the rules of the scenario are beyond the measured range' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Models.CpuPercent.PerMBps = 1.5; $cal.Models.CpuPercent.PerRuleMsg = 0.004
        $cal.Range.MinSizeKB = 10; $cal.Range.MaxSizeKB = 40; $cal.Range.MaxRules = 20
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.TransportRules' = 50 }) -Calibration $cal
        @($r.Checks | ForEach-Object Code) | Should -Contain 'SizeExtrapolation'
        @($r.Checks | ForEach-Object Code) | Should -Contain 'RulesExtrapolation'
        $old = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Load.TransportRules' = 5 }) -Calibration $script:Calibration
        @($old.Checks | ForEach-Object Code) | Should -Contain 'RulesNotCalibrated'
        @($old.Checks | ForEach-Object Code) | Should -Contain 'SessionsNotCalibrated'
    }
}

Describe 'Physical servers' {
    BeforeAll { $script:Calibration = Import-TsCalibration -Path $script:CalibrationPath }
    It 'computes the RAID layout: RAID-5, 100 reads and 200 writes on 165 IOPS disks' {
        InModuleScope TransportSizer {
            $layout = Get-TsRaidLayout -CapacityGB 1000 -ReadIops 100 -WriteIops 200 -Raid 'RAID-5' -DiskIops 165 -DiskSizeGB 1200 -IoOverhead 0.2
            [Math]::Round($layout.BackendIops, 1) | Should -Be 2160
            $layout.DisksForIops | Should -Be 14
            $layout.TotalDisks | Should -Be 14
            $layout.Label | Should -Be 'RAID-5 (13+1)'
        }
    }
    It 'turns RAID-1 into RAID-1/0 when one disk is not enough' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.SystemDiskSizeGB' = 146; 'Storage.OsGB' = 400 }) -Calibration $script:Calibration
        $r.Summary.SystemRaid.Layout | Should -Be 'RAID-1/0'
        @($r.Checks | Where-Object Code -eq 'RaidUpgraded').Count | Should -Be 1
    }
    It 'warns about RAID-5 on 7.2K disks and about too few cores' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.DiskType' = '7.2K RPM SAS 3.5"'; 'Physical.QueueRaid' = 'RAID-5'; 'Physical.Cores' = 1; 'Compute.MinCores' = 1 }) -Calibration $script:Calibration
        @($r.Checks | Where-Object Code -eq 'RaidSlowDisks').Count | Should -Be 1
        $big = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.Cores' = 1; 'Load.PeakHourPercent' = 100; 'Load.PeakHours' = 1; 'Load.OffHoursPercent' = 0; 'Topology.Sites' = 1; 'Topology.ServersPerSite' = 1; 'Topology.Failure' = 'None' }) -Calibration $script:Calibration
        @($big.Checks | Where-Object Code -eq 'CoresShort').Count | Should -Be 1
    }
    It 'sizes the physical example: 16 cores, RAID-1 system and queue' {
        $s = Import-TsScenario -Path (Join-Path $script:Root 'examples\Edge-Physical.json')
        $r = Invoke-TsSizing -Scenario $s -Calibration $script:Calibration
        $r.Summary.Cores | Should -Be 16
        $r.Summary.SystemRaid.TotalDisks | Should -Be 2
        $r.Summary.QueueRaid.TotalDisks | Should -Be 2
    }
}

Describe 'Manufacturer disk catalogue and transport I/O sizes' {
    It 'loads sourced manufacturer models and reference classes, without calculator IOPS' {
        $models = @(Get-TsDiskCatalog | Where-Object { -not $_.Generic })
        $models.Count | Should -BeGreaterThan 20
        foreach ($model in $models) {
            $model.Source | Should -Match 'https://'
            $model.Checked | Should -Not -BeNullOrEmpty
        }
        (Get-TsReference).ContainsKey('DiskTypes') | Should -BeFalse
        $ssd = Get-TsDiskCatalog -Name 'SSD SAS usage mixte (3 DWPD)'
        $ssd.Reference | Should -Be 'KIOXIA PM7-V · SSD SAS 24G 3 DWPD'
        $ssd.RandomIops | Should -Be 320000
        $ssd.SizesGB | Should -Contain 1600
        $ssd.Source | Should -Match 'kioxia.com'
        $hdd = Get-TsDiskCatalog -Name 'HDD NL-SAS 7,2K 3,5 pouces'
        $hdd.RandomIops | Should -Be 220
        ($hdd.SizesGB | Measure-Object -Minimum).Minimum | Should -Be 8000
        (Get-TsDiskCatalog -Role Transport | ForEach-Object Name) | Should -Not -Contain 'M.2 NVMe de démarrage (BOSS-N1, NS204i)'
        (Get-TsDiskCatalog -Role System | ForEach-Object Name) | Should -Contain 'M.2 NVMe de démarrage (BOSS-N1, NS204i)'
    }
    It 'adapts HDD transfer time to the actual block size, including the Mailbox 32 KB reference case' {
        InModuleScope TransportSizer {
            $disk = Get-TsDiskCatalog -Name 'HDD NL-SAS 7,2K 3,5 pouces'
            (Get-TsDiskPerformance $disk -IoSizeKB 4).Iops | Should -Be 220
            (Get-TsDiskPerformance $disk -IoSizeKB 32).Iops | Should -Be 215
            (Get-TsDiskPerformance $disk -IoSizeKB 128).Iops | Should -Be ([Math]::Floor(1 / (1 / 220 + 124 * 1024 / 291e6)))
        }
    }
    It 'caps SSD IOPS by the write throughput for larger transport transfers and accepts measured overrides' {
        InModuleScope TransportSizer {
            $disk = Get-TsDiskCatalog -Name 'SSD SAS usage mixte (3 DWPD)'
            (Get-TsDiskPerformance $disk -IoSizeKB 4).Iops | Should -Be 320000
            (Get-TsDiskPerformance $disk -IoSizeKB 128).Iops | Should -Be ([Math]::Floor(3400e6 / (128 * 1024)))
            (Get-TsDiskPerformance $disk -IoSizeKB 128 -DiskIops 1234).Iops | Should -Be 1234
        }
    }
    It 'does not invent IOPS for a manufacturer that publishes none' {
        (Get-TsDiskCatalog -Name 'Toshiba AL15SE · SAS 10K 2,5 pouces').RandomIops | Should -Be 0
        $s = New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.DiskType' = '10K RPM SAS 2.5"' }
        $r = Invoke-TsSizing $s
        $r.Summary.QueueRaid.PerformanceKnown | Should -BeFalse
        @($r.Checks.Code) | Should -Contain 'DiskIopsMissing'
        ($r.Config | Where-Object Component -like 'Disques file*').Status | Should -Be 'partial'
    }
    It 'selects the smallest capacity among RAID layouts with the fewest disks' {
        InModuleScope TransportSizer {
            $disk = Get-TsDiskCatalog -Name 'SSD SAS usage mixte (3 DWPD)'
            $small = Select-TsRaidDisks $disk -CapacityGB 100 -Raid 'RAID-1'
            $small.TotalDisks | Should -Be 2
            $small.DiskSizeGB | Should -Be 1600
            $large = Select-TsRaidDisks $disk -CapacityGB 2000 -Raid 'RAID-1'
            $large.TotalDisks | Should -Be 2
            $large.DiskSizeGB | Should -Be 3200
            $large.Models | Should -Contain 'KIOXIA PM7-V · SSD SAS 24G 3 DWPD'
        }
    }
    It 'imports all historical disk labels and preserves a shared legacy hardware choice' {
        InModuleScope TransportSizer {
            foreach ($name in $script:TsLegacyDisks.Keys) {
                $s = ConvertTo-TsScenario @{ Physical = @{ DiskType = $name; DiskSizeGB = 960; SsdIops = 12345 } }
                $s.Physical.DiskType | Should -Be $script:TsLegacyDisks[$name]
                $s.Physical.SystemDiskType | Should -Be $s.Physical.DiskType
                $s.Physical.SystemDiskSizeGB | Should -Be 960
                $s.Physical.DiskIops | Should -Be 12345
                $s.Physical.SystemDiskIops | Should -Be 12345
            }
        }
    }
    It 'uses actual capacity members for generic HDD transfer bandwidth before automatic RAID selection' {
        InModuleScope TransportSizer {
            $disk = Get-TsDiskCatalog -Name 'HDD NL-SAS 7,2K 3,5 pouces'
            $fixed = Select-TsRaidDisks $disk -CapacityGB 100 -Raid 'RAID-1' -WriteIops 65 -IoOverhead 0.2 -IoSizeKB 1024 -SizeGB 8000
            $actual = Select-TsRaidDisks (Get-TsDiskCatalog -Name 'Seagate Exos 7E10 · NL-SAS 7,2K 3,5 pouces') -CapacityGB 100 -Raid 'RAID-1' -WriteIops 65 -IoOverhead 0.2 -IoSizeKB 1024 -SizeGB 8000
            $fixed.SequentialMBps | Should -Be 255
            $fixed.TotalDisks | Should -Be 4
            $fixed.DiskIops | Should -Be $actual.DiskIops
            $auto = Select-TsRaidDisks $disk -CapacityGB 100 -Raid 'RAID-1' -WriteIops 65 -IoOverhead 0.2 -IoSizeKB 1024
            $auto.TotalDisks | Should -Be 2
            $auto.DiskSizeGB | Should -BeGreaterThan 8000
            $auto.IopsBasis | Should -BeLike '*modèle le plus lent*'
        }
    }
    It 'keeps explicit modern system disks and gives new IOPS overrides precedence over the legacy field' {
        $s = ConvertTo-TsScenario @{ Physical = @{ DiskType = 'SSD / NVMe'; SsdIops = 12345; DiskIops = 0; SystemDiskSizeGB = 480; SystemDiskType = 'M.2 NVMe de démarrage (BOSS-N1, NS204i)' } }
        $s.Physical.DiskIops | Should -Be 0
        $s.Physical.SystemDiskSizeGB | Should -Be 480
        $s.Physical.SystemDiskType | Should -Be 'M.2 NVMe de démarrage (BOSS-N1, NS204i)'
    }
    It 'rejects incompatible disks, negative overrides, non-finite numbers and unprotected RAID' {
        { ConvertTo-TsScenario @{ Physical = @{ DiskType = 'Micron 7450 PRO M.2 · NVMe 1 DWPD (démarrage)' } } } | Should -Throw '*incompatible*'
        { ConvertTo-TsScenario @{ Physical = @{ DiskIops = -1 } } } | Should -Throw '*négative*'
        { ConvertTo-TsScenario @{ Physical = @{ DiskSizeGB = [double]::NaN } } } | Should -Throw '*fini*'
        { ConvertTo-TsScenario @{ Physical = @{ IoSizeKB = [double]::PositiveInfinity } } } | Should -Throw '*fini*'
        { ConvertTo-TsScenario @{ Physical = @{ QueueRaid = 'RAID-0' } } } | Should -Throw '*inconnu*'
    }
    It 'sizes independent system and queue disks and exposes their sources in both reports' {
        $s = New-TestScenario -Changes @{ Deployment = 'Physical' }
        $r = Invoke-TsSizing $s
        $r.Summary.SystemRaid.DiskName | Should -Be $s.Physical.SystemDiskType
        $r.Summary.SystemRaid.DiskSizeGB | Should -Be 480
        $r.Summary.QueueRaid.DiskSizeGB | Should -Be 1600
        $r.Summary.QueueRaid.PerformanceKnown | Should -BeTrue
        $r.Values['io.queue.iops'].Source | Should -Match 'kioxia.com'
        $r.Values['io.system.iops'].Source | Should -Match 'micron.com'
        $files = Export-TsReport $r -OutputPath $script:Work
        $back = Invoke-TsSizing (Import-TsScenario $files.Scenario)
        $back.Summary.QueueRaid.DiskIops | Should -Be $r.Summary.QueueRaid.DiskIops
        foreach ($path in $files.Html, $files.Synthesis) {
            $html = [IO.File]::ReadAllText($path)
            $data = [regex]::Match($html, '<script type="application/json" id="data">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json
            $data.Summary.SystemRaid.DiskName | Should -Be $s.Physical.SystemDiskType
            $data.Summary.QueueRaid.DiskName | Should -Be $s.Physical.DiskType
        }
    }
    It 'derives mean physical transfer sizes from transport models and the selected RAID write penalty' {
        $s = New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.QueueRaid' = 'RAID-5' }
        $cal = Get-TsReferenceProfile Edge
        $r = Invoke-TsSizing $s -Calibration $cal
        $bytes = ($r.Values['io.readMBps'].Value + 4 * $r.Summary.QueueWriteMBps) * 1048576 / 1.2
        $ops = $r.Values['io.read'].Value + 4 * $r.Values['io.write'].Value
        [Math]::Round($r.Summary.QueueRaid.IoSizeKB, 8) | Should -Be ([Math]::Round($bytes / $ops / 1024, 8))
        $r.Summary.QueueRaid.IoSizeKB | Should -Not -Be 32
        $s.Adjustment.IoPercent = 200
        $twice = Invoke-TsSizing $s -Calibration $cal
        [Math]::Round($twice.Summary.QueueRaid.IoSizeKB, 8) | Should -Be ([Math]::Round($r.Summary.QueueRaid.IoSizeKB, 8))
        $twice.Summary.QueueRaid.BackendIops | Should -Be ($r.Summary.QueueRaid.BackendIops * 2)
    }
    It 'uses manual transfer sizes and HDD IOPS overrides without changing the measured traffic demand' {
        $s = New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.DiskType' = 'WD Ultrastar DC HC580 · NL-SAS 7,2K 3,5 pouces'; 'Physical.IoSizeKB' = 32 }
        $r = Invoke-TsSizing $s
        $r.Summary.QueueRaid.DiskIops | Should -Be 215
        $s.Physical.DiskIops = 99
        $override = Invoke-TsSizing $s
        $override.Summary.QueueRaid.DiskIops | Should -Be 99
        $override.Summary.Iops | Should -Be $r.Summary.Iops
        $override.Summary.QueueRaid.IopsBasis | Should -BeLike 'IOPS saisies*'
    }
    It 'marks old profiles without byte models as incomplete instead of assuming mailbox block sizes' {
        $s = New-TestScenario -Changes @{ Deployment = 'Physical' }
        $r = Invoke-TsSizing $s -Calibration (Import-TsCalibration $script:CalibrationPath)
        @($r.Checks.Code) | Should -Contain 'DiskIoSizeMissing'
        $r.Summary.QueueRaid.PerformanceKnown | Should -BeFalse
        $s.Physical.IoSizeKB = 64
        $manual = Invoke-TsSizing $s -Calibration (Import-TsCalibration $script:CalibrationPath)
        $manual.Summary.QueueRaid.PerformanceKnown | Should -BeTrue
        @($manual.Checks.Code) | Should -Not -Contain 'DiskIoSizeMissing'
    }
    It 'uses only the system disk when the queue shares the system and warns about boot SSD endurance' {
        $s = New-TestScenario -Changes @{ Deployment = 'Physical'; 'Storage.QueueVolume' = 'System'; 'Physical.SystemDiskIops' = 777; 'Physical.DiskIops' = 1 }
        $r = Invoke-TsSizing $s
        $r.Summary.QueueRaid | Should -BeNullOrEmpty
        $r.Summary.QueueVolumeGB | Should -BeNullOrEmpty
        $r.Summary.SystemRaid.DiskIops | Should -Be 777
        $r.Values['io.diskIops'].Value | Should -Be 777
        @($r.Checks.Code) | Should -Contain 'DiskEndurance'
    }
    It 'retains custom capacities and flags them instead of silently selecting a catalogue model' {
        $s = New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.DiskSizeGB' = 1234 }
        $r = Invoke-TsSizing $s
        $r.Summary.QueueRaid.DiskSizeGB | Should -Be 1234
        @($r.Checks.Code) | Should -Contain 'DiskSizeOffCatalog'
        $r.Summary.QueueRaid.Models.Count | Should -Be 0
    }
    It 'flags RAID-5 layouts wider than seven disks' {
        $s = New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.QueueRaid' = 'RAID-5'; 'Physical.DiskIops' = 1 }
        $r = Invoke-TsSizing $s
        $r.Summary.QueueRaid.TotalDisks | Should -BeGreaterThan 7
        @($r.Checks.Code) | Should -Contain 'RaidTooWide'
    }
}

Describe 'Network' {
    It 'puts an inbound flow on both cards of an Edge: 4.17 msg/s x 100 KB = 3.58 Mbit/s' {
        $s = New-TestScenario -Changes @{ 'Topology.Sites' = 1; 'Topology.ServersPerSite' = 1; 'Topology.Failure' = 'None'; 'Load.GrowthPercent' = 0 }
        $s.Flows = @(@{ Name = 'in'; Direction = 'Inbound'; MessagesPerDay = 100000; AverageSizeKB = 100; FanOut = 1; HeldDuringOutage = $true })
        $r = Invoke-TsSizing -Scenario $s -Calibration $null
        $expected = 100000 * 0.15 / 3600 * 100 * 1024 * 8 / 1e6 * 1.05
        [Math]::Round((Get-Value $r 'net.extIn'), 4) | Should -Be ([Math]::Round($expected, 4))
        [Math]::Round((Get-Value $r 'net.intOut'), 4) | Should -Be ([Math]::Round($expected, 4))
        Get-Value $r 'net.extOut' | Should -Be 0
    }
    It 'adds the shadow copies on a Mailbox server' {
        $s = New-TestScenario -Role Mailbox -Changes @{ 'Topology.Sites' = 1; 'Topology.ServersPerSite' = 2; 'Topology.Failure' = 'None'; 'Load.GrowthPercent' = 0 }
        $s.Flows = @(@{ Name = 'in'; Direction = 'Inbound'; MessagesPerDay = 100000; AverageSizeKB = 100; FanOut = 1; HeldDuringOutage = $true })
        $r = Invoke-TsSizing -Scenario $s -Calibration $null
        $expected = 2 * 50000 * 0.15 / 3600 * 100 * 1024 * 8 / 1e6 * 1.05
        [Math]::Round((Get-Value $r 'net.in'), 4) | Should -Be ([Math]::Round($expected, 4))
        [Math]::Round((Get-Value $r 'net.out'), 4) | Should -Be ([Math]::Round($expected, 4))
    }
}

Describe 'Report' {
    BeforeAll {
        $s = New-TestScenario -Role Mailbox -Changes @{ Name = 'Rapport <b>&test</b>' }
        $script:Result = Invoke-TsSizing -Scenario $s -Calibration (Import-TsCalibration -Path $script:CalibrationPath)
        $script:Files = Export-TsReport -Result $script:Result -OutputPath $script:Work
        $script:Html = [IO.File]::ReadAllText($script:Files.Html, [Text.Encoding]::UTF8)
    }
    It 'writes the HTML report, the JSON result and the scenario' {
        Test-Path -LiteralPath $script:Files.Html | Should -BeTrue
        Test-Path -LiteralPath $script:Files.Json | Should -BeTrue
        (Import-TsScenario -Path $script:Files.Scenario).Name | Should -Be 'Rapport <b>&test</b>'
    }
    It 'replaces both markers and encodes the title' {
        $script:Html | Should -Not -Match '\{\{(TITLE|DATA)\}\}'
        $script:Html | Should -Match '<title>Rapport &lt;b&gt;&amp;test&lt;/b&gt;'
    }
    It 'embeds the result as JSON that the page can read' {
        $match = [regex]::Match($script:Html, '<script type="application/json" id="data">(.*?)</script>', 'Singleline')
        $match.Success | Should -BeTrue
        $match.Groups[1].Value | Should -Not -Match '</'
        $data = $match.Groups[1].Value | ConvertFrom-Json
        $data.Summary.Role | Should -Be 'Mailbox'
        @($data.Sections).Count | Should -BeGreaterThan 6
        $data.PSObject.Properties['Values'] | Should -BeNullOrEmpty
    }
    It 'writes the customer summary with the same data, self-contained, linked to the technical report' {
        Test-Path -LiteralPath $script:Files.Synthesis | Should -BeTrue
        $summary = [IO.File]::ReadAllText($script:Files.Synthesis, [Text.Encoding]::UTF8)
        $summary | Should -Not -Match '\{\{(TITLE|DATA)\}\}'
        $summary | Should -Match '<title>Rapport &lt;b&gt;&amp;test&lt;/b&gt; (·|&#183;) Synth(è|&#232;)se</title>'
        $summary | Should -Match 'href="TransportSizer.html"'
        $script:Html | Should -Match 'href="TransportSizer-Synthese.html"'
        # No external resource, no network call, no storage: it opens offline and in the OneDrive preview.
        $summary | Should -Not -Match '<script[^>]+src=|<link |@import|url\(https?:|fetch\(|XMLHttpRequest|localStorage|sessionStorage'
        $data = [regex]::Match($summary, '<script type="application/json" id="data">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json
        $data.Summary.Servers | Should -Be $script:Result.Summary.Servers
        $data.Summary.OperatingSystem | Should -BeLike 'Windows Server 2025*'
    }
    It 'explains every value: formula or kind for each line' {
        foreach ($section in $script:Result.Sections) {
            foreach ($value in $section.Values) {
                $value.Kind | Should -BeIn @('Input', 'Computed', 'Microsoft', 'Lab', 'Assumption', 'Calibration', 'Rule')
                if ($value.Kind -eq 'Computed' -and $value.Value -isnot [string] -and $value.Id -notin 'ms.perServer', 'ms.ours', 'res.backlog') { $value.Formula | Should -Not -BeNullOrEmpty -Because $value.Id }
            }
        }
    }
}

Describe 'Command line' {
    It 'sizes an example with a calibration and writes the report' {
        $result = & (Join-Path $script:Root 'Invoke-TransportSizer.ps1') -Scenario (Join-Path $script:Root 'examples\Edge-Internet.json') -Calibration $script:CalibrationPath -OutputPath $script:Work -PassThru 6>$null
        $result.Valid | Should -BeTrue
        $result.Summary.Calibrated | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Work -Directory -Filter 'TransportSizer_Edge-Transport-Internet*').Count | Should -BeGreaterThan 0
    }
}

Describe 'Exchange Log Report import' {
    BeforeAll {
        # A detailed report of two full days (48 h), written like Exchange Log Report: ';', UTF-8 with BOM, quoted
        # fields with the delimiter, doubled quotes and line breaks (routes, transcripts).
        function Write-ElrCsv {
            param([string]$Path, [string[]]$Header, [object[]]$Rows)
            $quote = { param($v) $t = [string]$v; if ($t -match '[;"\r\n]') { '"' + $t.Replace('"', '""') + '"' } else { $t } }
            $lines = @($Header -join ';') + @(foreach ($row in $Rows) { ($row | ForEach-Object { & $quote $_ }) -join ';' })
            [IO.File]::WriteAllText($Path, ($lines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))
        }
        $script:ElrHeader = @('First event', 'Last event', 'Duration', 'Status', 'Sender', 'Recipients', 'Recipient count', 'Delivered', 'Failed', 'Subject', 'Size (KB)', 'Direction', 'Servers', 'Events', 'SMTP sessions', 'Message ID', 'Route')
        $script:NewElrMessage = {
            param([string]$Time, [string]$Status, [string]$Recipients, [int]$Count, $Size, [string]$Direction, [string]$Sender = 'app@fabrikam.test')
            @($Time, $Time, '1 s', $Status, $Sender, $Recipients, $Count, $Count, 0, 'Test; "quoted"', $Size, $Direction, 'REF-MAILBOX > EXMBX2', 'RECEIVE > DELIVER', 2, "<$([guid]::NewGuid())@test>", "$Time | REF-MAILBOX | SMTP Receive (Hub) | Accepted`n$Time | REF-MAILBOX | Tracking | RECEIVE")
        }
        $rows = [Collections.Generic.List[object]]::new()
        $rows.Add((& $script:NewElrMessage '2026-10-01 00:00:05' 'Delivered' 'u1@contoso.com' 1 50 'Incoming'))
        for ($i = 0; $i -lt 9; $i++) { $rows.Add((& $script:NewElrMessage ('2026-10-01 09:0{0}:00' -f $i) 'Delivered' 'u1@contoso.com' 1 50 'Incoming')) }
        for ($i = 0; $i -lt 6; $i++) { $rows.Add((& $script:NewElrMessage ('2026-10-01 10:0{0}:00' -f $i) 'Relayed' 'a@fabrikam.test (Sent); b@fabrikam.test (Sent); c@northwind.test (Sent)' 3 100 'Originating')) }
        for ($i = 0; $i -lt 4; $i++) { $rows.Add((& $script:NewElrMessage ('2026-10-01 11:0{0}:00' -f $i) 'Delivered' 'u1@contoso.com; u2@contoso.com' 2 20 'Originating')) }
        $rows.Add((& $script:NewElrMessage '2026-10-01 12:00:00' 'Relayed' 'archive@vault.example (Sent)' 1 104 'Originating' 'MicrosoftExchange329e71ec88ae4615bbc36ab6ce41109e@contoso.com'))
        $rows.Add((& $script:NewElrMessage '2026-10-01 13:00:00' 'Rejected (SMTP)' 'x@contoso.com (Rejected)' 1 '' 'Incoming (SMTP)'))
        $rows.Add((& $script:NewElrMessage '2026-10-01 13:01:00' 'Rejected (SMTP)' 'y@contoso.com (Rejected)' 1 '' 'Incoming (SMTP)'))
        for ($i = 0; $i -lt 6; $i++) { $rows.Add((& $script:NewElrMessage ('2026-10-02 14:0{0}:00' -f $i) 'Delivered' 'u1@contoso.com' 1 50 'Incoming')) }
        $rows.Add((& $script:NewElrMessage '2026-10-02 15:00:00' 'Delivered' 'u1@contoso.com; u2@contoso.com' 2 20 'Originating'))
        $rows.Add((& $script:NewElrMessage '2026-10-02 23:59:00' 'Delivered' 'u1@contoso.com; u2@contoso.com' 2 20 'Originating'))
        $script:ElrRows = $rows.ToArray()

        $script:ElrReports = Join-Path $script:Work 'elr-reports'
        $script:ElrMailbox = Join-Path $script:ElrReports 'EXLAB_Detailed_202610030800_080000'
        [void](New-Item -ItemType Directory -Path $script:ElrMailbox -Force)
        Write-ElrCsv (Join-Path $script:ElrMailbox 'EXLAB-Messages.csv') $script:ElrHeader $script:ElrRows
        $sessionHeader = @('Time', 'End', 'Server', 'Direction', 'Role', 'Connector', 'Remote', 'Local', 'HELO', 'TLS', 'Authentication', 'Mail from', 'Recipient count', 'Recipients', 'Message ID', 'Status', 'Response', 'Session ID', 'Transcript')
        $session = { param($Server, $Direction, $Role, $Tls, $Status, $Id) @('2026-10-01 09:00:00', '', $Server, $Direction, $Role, 'Default', '10.0.0.1:1000', '10.0.0.2:25', 'mail.test', $Tls, 'Anonymous', 'a@b.c', 1, 'u1@contoso.com', '<m@test>', $Status, '250 2.6.0 "queued"; ok', $Id, "S: 220 ready`nC: EHLO mail.test; x") }
        # Hub: S1 3 messages over TLS, S2 1 message without TLS, S3 refused over TLS -> 4 / 2 = 2 messages per session, 2 / 3 TLS.
        $sessions = @(
            (& $session 'REF-MAILBOX' 'Receive' 'Hub' 'TLS 1.2' 'Accepted' 'S1'), (& $session 'REF-MAILBOX' 'Receive' 'Hub' 'TLS 1.2' 'Accepted' 'S1'), (& $session 'REF-MAILBOX' 'Receive' 'Hub' 'TLS 1.2' 'Accepted' 'S1')
            (& $session 'REF-MAILBOX' 'Receive' 'Hub' 'No' 'Accepted' 'S2'), (& $session 'EXMBX2' 'Receive' 'Hub' 'TLS 1.2' 'Rejected' 'S3')
            (& $session 'REF-MAILBOX' 'Receive' 'FrontEnd' 'TLS 1.2' 'Accepted' 'F1'), (& $session 'REF-MAILBOX' 'Send' 'Hub' 'TLS 1.2' 'Sent' 'X1')
        )
        Write-ElrCsv (Join-Path $script:ElrMailbox 'EXLAB-SmtpSessions.csv') $sessionHeader $sessions
        # An older detailed report in the same folder: the most recent one is taken.
        $older = Join-Path $script:ElrReports 'EXLAB_Detailed_202609010800_080000'
        [void](New-Item -ItemType Directory -Path $older -Force)
        Write-ElrCsv (Join-Path $older 'EXLAB-Messages.csv') $script:ElrHeader @($script:ElrRows[0])
        (Get-Item (Join-Path $older 'EXLAB-Messages.csv')).LastWriteTime = (Get-Date).AddDays(-30)
    }
    It 'turns a detailed report into flows: 16 inbound, 6 outbound (2 domains), 6 internal messages over 48 h' {
        $r = Import-TsLogReport -Path $script:ElrMailbox
        $r.Role | Should -Be 'Mailbox'
        $r.Hours | Should -Be 48
        $r.Messages | Should -Be 28
        $r.Refused | Should -Be 2
        $r.JournalReports | Should -Be 1
        $flows = @{}; foreach ($f in $r.Flows) { $flows[$f.Direction] = $f }
        $flows.Inbound.MessagesPerDay | Should -Be 8
        $flows.Inbound.AverageSizeKB | Should -Be 50
        $flows.Outbound.MessagesPerDay | Should -Be 3
        $flows.Outbound.AverageSizeKB | Should -Be 100
        $flows.Outbound.FanOut | Should -Be 2
        $flows.Internal.MessagesPerDay | Should -Be 3
        $flows.Internal.AverageSizeKB | Should -Be 20
        # Busiest hour 09:00 (9 messages) / 14 messages per day.
        $r.PeakHour.Hour | Should -Be '2026-10-01 09:00'
        $r.Load.PeakHourPercent | Should -Be 64.3
        # Hours of the day above the hourly average (28 ÷ 24): 09, 10, 11 and 14; 3 messages outside them; peak hour 09 alone.
        $r.Load.PeakRate | Should -Be 9
        $r.Load.PeakRateUnit | Should -Be 'PerHour'
        $r.Load.WorkingHours | Should -Be 4
        $r.Load.OffHoursPercent | Should -Be 11
        $r.Load.PeakHours | Should -Be 1
        ($r.Directions | Where-Object Direction -eq 'Outbound').RecipientsPerMessage | Should -Be 3
        $r.Warnings -join ' ' | Should -BeLike '*1 rapport(s) de journal exclus*'
    }
    It 'measures the receive sessions of the transport service (Hub before FrontEnd): 2 messages per session, 67 % TLS' {
        $r = Import-TsLogReport -Path (Join-Path $script:ElrMailbox 'EXLAB-SmtpSessions.csv')
        $r.Sessions.Role | Should -Be 'Hub'
        $r.Sessions.Sessions | Should -Be 3
        $r.Load.MessagesPerSession | Should -Be 2
        $r.Load.TlsPercent | Should -Be 67
    }
    It 'takes the busiest complete day on demand and the latest report of a folder of reports' {
        $r = Import-TsLogReport -Path $script:ElrReports -Day Busiest
        $r.Source | Should -Be $script:ElrMailbox
        $r.BusiestDay | Should -Be '2026-10-01'
        @($r.Flows | ForEach-Object { $_.MessagesPerDay }) -join ',' | Should -Be '10,6,4'
        $r.Load.PeakHourPercent | Should -Be 45
    }
    It 'reads an Edge report: every Originating message goes out, nothing is internal' {
        $edge = Join-Path $script:Work 'elr-edge'
        [void](New-Item -ItemType Directory -Path $edge -Force)
        $rows = @(
            (& $script:NewElrMessage '2026-10-01 08:00:00' 'Relayed' 'u1@contoso.com (Sent)' 1 40 'Incoming'),
            (& $script:NewElrMessage '2026-10-01 08:10:00' 'Failed' 'x@fabrikam.test (Failed)' 1 60 'Originating')
        )
        Write-ElrCsv (Join-Path $edge 'ExchangeLogs-Messages.csv') $script:ElrHeader $rows
        Write-ElrCsv (Join-Path $edge 'ExchangeLogs-SmtpDestinations.csv') @('Remote address', 'Sent') @(, @('mx.fabrikam.test', 1))
        $r = Import-TsLogReport -Path $edge
        $r.Role | Should -Be 'Edge'
        @($r.Flows | ForEach-Object { $_.Direction }) -join ',' | Should -Be 'Inbound,Outbound'
        $r.Flows[0].Name | Should -Be 'Entrant Internet (ELR)'
    }
    It 'keeps an imported office day valid when the share outside working hours is rounded up' {
        # 6 office hours of 25 messages and 37 messages outside them per day: 19.8 % outside, stored as 20 %; 6 peak
        # hours at 25 ÷ 187 = 13.4 % would carry 80.2 % > 80 %: the import keeps 5 peak hours.
        $office = Join-Path $script:Work 'elr-office'
        [void](New-Item -ItemType Directory -Path $office -Force)
        $rows = [Collections.Generic.List[object]]::new()
        foreach ($date in '2026-10-05', '2026-10-06') {
            foreach ($hour in 9..14) { for ($i = 0; $i -lt 25; $i++) { $rows.Add((& $script:NewElrMessage ('{0} {1:00}:{2:00}:00' -f $date, $hour, $i) 'Delivered' 'u1@contoso.com' 1 50 'Incoming')) } }
            $offHours = @(0..8) + @(15..23)
            foreach ($hour in $offHours) { for ($i = 0; $i -lt 2; $i++) { $rows.Add((& $script:NewElrMessage ('{0} {1:00}:{2:00}:00' -f $date, $hour, $i) 'Delivered' 'u1@contoso.com' 1 50 'Incoming')) } }
            $rows.Add((& $script:NewElrMessage ('{0} 23:30:00' -f $date) 'Delivered' 'u1@contoso.com' 1 50 'Incoming'))
        }
        Write-ElrCsv (Join-Path $office 'EXLAB-Messages.csv') $script:ElrHeader $rows.ToArray()
        $r = Import-TsLogReport -Path $office -Role Mailbox
        $r.Load.WorkingHours | Should -Be 6
        $r.Load.OffHoursPercent | Should -Be 20
        $r.Load.PeakHours | Should -Be 5
        $s = Update-TsScenarioFromLogReport -Scenario (Get-TsDefaultScenario -Role Mailbox) -LogReport $r
        (Invoke-TsSizing -Scenario $s -Calibration $null).Valid | Should -BeTrue
    }
    It 'refuses a usage report and explains how to get the detailed one' {
        $usage = Join-Path $script:Work 'elr-usage'
        [void](New-Item -ItemType Directory -Path $usage -Force)
        Write-ElrCsv (Join-Path $usage 'EXLAB-Daily.csv') @('Day', 'Server', 'Messages') @(, @('2026-10-01', 'REF-MAILBOX', 10))
        { Import-TsLogReport -Path $usage } | Should -Throw -ExpectedMessage '*-ReportType Detailed*'
    }
    It 'puts the traffic in a scenario and keeps the other inputs' {
        $s = Get-TsDefaultScenario -Role Mailbox
        $s.Load.GrowthPercent = 35
        $r = Import-TsLogReport -Path $script:ElrMailbox
        $u = Update-TsScenarioFromLogReport -Scenario $s -LogReport $r
        @($u.Flows).Count | Should -Be 3
        $u.Load.GrowthPercent | Should -Be 35
        $u.Load.PeakHourPercent | Should -Be 64.3
        $u.Load.PeakRate | Should -Be 9
        $u.Load.WorkingHours | Should -Be 4
        $u.Load.PeakHours | Should -Be 1
        $u.Load.MessagesPerSession | Should -Be 2
        $u.Load.TlsPercent | Should -Be 67
        $u.Notes | Should -BeLike '*Exchange Log Report*'
        (Invoke-TsSizing -Scenario $u).Valid | Should -BeTrue
    }
    It 'sizes a report from the command line and saves the scenario' {
        $saved = Join-Path $script:Work 'elr-scenario.json'
        $result = & (Join-Path $script:Root 'Invoke-TransportSizer.ps1') -LogReport $script:ElrMailbox -OutputPath $script:Work -SaveScenario $saved -PassThru 6>$null
        $result.Valid | Should -BeTrue
        $result.Scenario.Role | Should -Be 'Mailbox'
        (Import-TsScenario -Path $saved).Flows.Count | Should -Be 3
    }
    It 'imports a report in the window' {
        InModuleScope TransportSizer -Parameters @{ Path = $script:ElrMailbox } {
            param($Path)
            [void](New-TsSizerForm -Theme Light)
            $script:Gui.Controls.Role.SelectedIndex = 1
            $lines = Import-TsGuiLogReport -Path $Path
            $lines[0] | Should -BeLike 'Exchange Log Report*'
            $script:Gui.Table.Rows.Count | Should -Be 3
            $script:Gui.Controls.PeakHour.Text | Should -Be '64,3'
            $script:Gui.Controls.PeakRate.Text | Should -Be '9'
            $script:Gui.Controls.WorkingHours.Text | Should -Be '4'
            $script:Gui.Controls.PeakRateUnit.SelectedItem | Should -Be 'msg/h'
            $script:Gui.Controls.PeakHour.IsEnabled | Should -BeFalse
            $script:Gui.Controls.DaySummary.Text | Should -BeLike 'Par serveur*débit de pointe mesuré*'
            $script:Gui.Controls.PerSession.Text | Should -Be '2'
            (Read-TsGuiScenario).Scenario.Notes | Should -BeLike '*Exchange Log Report*'
            $script:Gui.Result.Valid | Should -BeTrue
            $script:Gui = $null
        }
    }
}

Describe 'Virtualization: vCPU ratio, SPECint and memory reservation' {
    BeforeAll {
        $script:Cal18 = Import-TsCalibration -Path $script:CalibrationPath
        # Reference: 2 logical processors on 1 core (Azure vCPU), (6 + 2.5 x 2.5) % = 0.245 logical processor busy.
    }
    It 'counts a vCPU as 1 / max(ratio, 1 + SMT gain) of a core and a logical processor of the reference as half its core' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $script:Cal18
        Get-Value $r 'cpu.vcpuShare' | Should -Be 50
        [Math]::Round((Get-Value $r 'cpu.spec'), 6) | Should -Be 1
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.VcpuRatio' = 1 }) -Calibration $script:Cal18
        [Math]::Round((Get-Value $r 'cpu.vcpuShare'), 4) | Should -Be ([Math]::Round(100 / 1.2, 4))
        [Math]::Round((Get-Value $r 'cpu.needed'), 6) | Should -Be ([Math]::Round(0.245 * 0.5 * 1.2, 6))
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.VcpuRatio' = 1; 'Compute.SmtGainPercent' = 0 }) -Calibration $script:Cal18
        [Math]::Round((Get-Value $r 'cpu.needed'), 6) | Should -Be ([Math]::Round(0.245 * 0.5, 6))
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.VcpuRatio' = 3 }) -Calibration $script:Cal18
        [Math]::Round((Get-Value $r 'cpu.needed'), 6) | Should -Be ([Math]::Round(0.245 * 1.5, 6))
        @($r.Checks | ForEach-Object Code) | Should -Contain 'VcpuRatioUnsupported'
    }
    It 'compares the SPECint per core of the reference and of the host, and counts a physical core whole' {
        $cal = Import-TsCalibration -Path $script:CalibrationPath
        $cal.Server.SpecIntRatePerCore = 8
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.TargetSpecIntRatePerCore' = 4 }) -Calibration $cal
        # 8 x 1 / 2 = 4 per logical processor of the reference; 4 x 50 % = 2 per vCPU of the host.
        Get-Value $r 'cpu.perLpRef' | Should -Be 4
        Get-Value $r 'cpu.perUnit' | Should -Be 2
        [Math]::Round((Get-Value $r 'cpu.needed'), 6) | Should -Be ([Math]::Round(0.245 * 2, 6))
        # Physical server of 40 cores and 400 SPECint: 10 per core; the reference was virtual (÷ 1.1).
        $p = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Deployment = 'Physical'; 'Physical.SpecIntRate2017' = 400; 'Physical.Cores' = 40 }) -Calibration $cal
        [Math]::Round((Get-Value $p 'cpu.needed'), 6) | Should -Be ([Math]::Round(0.245 * 4 / 10 / 1.1, 6))
        # A physical server without its sheet uses the SPECint per core entered.
        $p = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Deployment = 'Physical'; 'Compute.TargetSpecIntRatePerCore' = 8 }) -Calibration $cal
        [Math]::Round((Get-Value $p 'cpu.needed'), 6) | Should -Be ([Math]::Round(0.245 * 0.5 / 1.1, 6))
        # A virtual reference without hyper-threading: a vCPU had its core, single thread (÷ 1.2).
        $cal.Server.Cores = 2
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.TargetSpecIntRatePerCore' = 8 }) -Calibration $cal
        [Math]::Round((Get-Value $r 'cpu.perLpRef'), 6) | Should -Be ([Math]::Round(8 / 1.2, 6))
    }
    It 'ships a catalog of processors and the SPECint of the reference servers' {
        $catalog = Get-TsProcessorCatalog
        $catalog.Count | Should -BeGreaterThan 60
        (Get-TsProcessorCatalog -Name 'Gold 6140').SpecIntRatePerCore | Should -Be 5.14
        foreach ($role in 'Edge', 'Mailbox') {
            $ref = Get-TsReferenceProfile -Role $role
            $ref.Server.SpecIntRatePerCore | Should -Be 8.5
            $ref.Server.Cores | Should -Be ($ref.Server.LogicalProcessors / 2)
            $ref.Server.SpecIntNote | Should -BeLike '*8580*'
        }
    }
    It 'gives the memory to reserve on the host and warns below it' {
        $r = Invoke-TsSizing -Scenario (New-TestScenario) -Calibration $script:Cal18
        $normal = Get-Value $r 'mem.normal'; $minimum = Get-Value $r 'mem.reserveMin'
        $minimum | Should -Be ([Math]::Ceiling([Math]::Max((Get-Value $r 'mem.byPrivate'), (Get-Value $r 'mem.byUsed'))))
        $normal | Should -BeLessThan $minimum
        Get-Value $r 'mem.reserved' | Should -Be $r.Summary.RamGB
        @($r.Checks | Where-Object { $_.Code -like 'Memory*' }).Count | Should -Be 0
        $codes = { param($percent) @((Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.MemoryReservedPercent' = $percent }) -Calibration $script:Cal18).Checks | ForEach-Object Code) }
        & $codes 90 | Should -Contain 'MemoryNotReserved'
        & $codes ([Math]::Floor(($minimum - 0.2) / 8 * 100)) | Should -Contain 'MemoryReserveOutage'
        # Between the need and its rounding up: the check and the target configuration agree (below the minimum).
        $percent = [Math]::Ceiling(([Math]::Max((Get-Value $r 'mem.byPrivate'), (Get-Value $r 'mem.byUsed')) + 0.01) / 8 * 100)
        $between = Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ 'Compute.MemoryReservedPercent' = $percent }) -Calibration $script:Cal18
        if ((Get-Value $between 'mem.reserved') -lt $minimum) {
            @($between.Checks | ForEach-Object Code) | Should -Contain 'MemoryReserveOutage'
            ($between.Config | Where-Object Component -eq 'Mémoire').Status | Should -Be 'warning'
        }
        & $codes 100 | Should -Not -Contain 'MemoryReserveOutage'
        & $codes ([Math]::Floor(($normal - 0.2) / 8 * 100)) | Should -Contain 'MemoryReserveNormal'
        (Invoke-TsSizing -Scenario (New-TestScenario -Changes @{ Deployment = 'Physical' }) -Calibration $script:Cal18).Values.Contains('mem.reserved') | Should -BeFalse
    }
    It 'keeps the processors of a scenario written before 1.8 and checks the new values' {
        $old = ConvertTo-TsScenario -Scenario ([pscustomobject]@{ Role = 'Edge'; Compute = [pscustomobject]@{ MaxCpuPercent = 80; MinCores = 4; EvenVcpu = $true } })
        $old.Compute.VcpuRatio | Should -Be 2
        $old.Compute.MemoryReservedPercent | Should -Be 100
        { ConvertTo-TsScenario -Scenario @{ Compute = @{ VcpuRatio = 0 } } } | Should -Throw '*vCPU par cœur*'
        { ConvertTo-TsScenario -Scenario @{ Compute = @{ MemoryReservedPercent = 120 } } } | Should -Throw '*supérieur à 100*'
    }
}

Describe 'Window' {
    It 'refreshes queue and system capacities independently and preserves imported custom sizes' {
        InModuleScope TransportSizer {
            $s = Get-TsDefaultScenario
            $s.Deployment = 'Physical'
            $s.Physical.DiskSizeGB = 1234
            $s.Physical.SystemDiskSizeGB = 987
            $form = New-TsSizerForm -Scenario $s -Theme Light
            $read = Read-TsGuiScenario
            $read.Scenario.Physical.DiskSizeGB | Should -Be 1234
            $read.Scenario.Physical.SystemDiskSizeGB | Should -Be 987
            $script:Gui.Controls.DiskType.SelectedItem = 'SSD NVMe usage mixte (3 DWPD)'
            $script:Gui.Controls.DiskSize.Text | Should -Be '0'
            $script:Gui.Controls.SystemDiskSize.Text | Should -Be '987'
            $script:Gui.Controls.DiskSize.Items | Should -Contain '1600'
            $script:Gui.Controls.QueueVolume.SelectedItem = $script:TsQueueVolumes.System
            $script:Gui.Controls.DiskIops.IsEnabled | Should -BeFalse
            $script:Gui.Controls.SystemDiskIops.IsEnabled | Should -BeTrue
            $script:Gui.Controls.IoSizeKB.IsEnabled | Should -BeTrue
            Update-TsGuiResult
            $script:Gui.Result.Summary.QueueRaid | Should -BeNullOrEmpty
            $script:Gui.Controls.QueueVolume.SelectedItem = $script:TsQueueVolumes.Dedicated
            $script:Gui.Controls.DiskIops.IsEnabled | Should -BeTrue
            $script:Gui.Controls.DiskType.SelectedItem = 'Toshiba AL15SE · SAS 10K 2,5 pouces'
            $script:Gui.Controls.DiskCatalogInfo.Text | Should -BeLike '*non publiées*'
            $script:Gui = $null
        }
    }
    It 'builds the window with the scenario and its result' {
        InModuleScope TransportSizer -Parameters @{ CalibrationPath = $script:CalibrationPath } {
            param($CalibrationPath)
            $s = Get-TsDefaultScenario -Role Edge
            $s.Calibration = Import-TsCalibration -Path $CalibrationPath
            $form = New-TsSizerForm -Scenario $s -Theme Light
            $form.Table.Rows.Count | Should -Be 2
            $form.Tiles.Cpu.Value.Text | Should -Be '4 vCPU'
            $form.Tiles.Ram.Value.Text | Should -Be '8 Go'
            # A processor of the list gives its SPECint per core.
            $script:Gui.Controls.TargetProcessor.SelectedItem = 'Intel Xeon Gold 6140'
            $script:Gui.Controls.TargetSpec.Text | Should -Be '5,14'
            $read = Read-TsGuiScenario
            $read.Scenario.Compute.TargetProcessor | Should -Be 'Intel Xeon Gold 6140'
            $read.Scenario.Compute.TargetSpecIntRatePerCore | Should -Be 5.14
            $script:Gui.Controls.Report.IsEnabled | Should -BeTrue
            $script:Gui.Controls.MailboxPanel.IsEnabled | Should -BeFalse
            $script:Gui = $null
        }
    }
    It 'marks an invalid field in red and blocks the report' {
        InModuleScope TransportSizer {
            $form = New-TsSizerForm -Theme Light
            $script:Gui.Controls.Growth.Text = 'beaucoup'
            Update-TsGuiResult
            $script:Gui.Controls.Report.IsEnabled | Should -BeFalse
            @($form.Checks | Where-Object { $_.Text -like 'Croissance*' }).Count | Should -Be 1
            $script:Gui.Controls.Growth.BorderBrush | Should -Be ($script:Gui.Form.TryFindResource('TsCritical'))
            $script:Gui = $null
        }
    }
    It 'switches to the Mailbox role and recalculates with a new flow' {
        InModuleScope TransportSizer {
            $form = New-TsSizerForm -Theme Light
            $before = $script:Gui.Result.Summary.MessagesPerDay
            $script:Gui.Controls.Role.SelectedIndex = 1
            Add-TsGuiFlow -Flow @{ Name = 'Applications'; Direction = 'Internal'; MessagesPerDay = 10000; AverageSizeKB = 30; FanOut = 1; HeldDuringOutage = $true }
            Update-TsGuiResult
            $script:Gui.Role | Should -Be 'Mailbox'
            $script:Gui.Controls.MailboxPanel.IsEnabled | Should -BeTrue
            $script:Gui.Controls.BinariesGB.Text | Should -Be '15'
            $script:Gui.Result.Summary.Role | Should -Be 'Mailbox'
            $script:Gui.Result.Summary.MessagesPerDay | Should -Be ($before + 12000)
            $script:Gui = $null
        }
    }
    It 'turns journaling on in the window and doubles the messages of the external flows' {
        InModuleScope TransportSizer {
            $form = New-TsSizerForm -Theme Light
            $script:Gui.Controls.Role.SelectedIndex = 1
            Update-TsGuiResult
            $before = $script:Gui.Result.Summary.MessagesPerDay
            $script:Gui.Controls.JournalScope.IsEnabled | Should -BeFalse
            $script:Gui.Controls.JournalEnabled.IsChecked = $true
            Update-TsGuiState
            $script:Gui.Controls.JournalScope.IsEnabled | Should -BeTrue
            $script:Gui.Controls.JournalScope.SelectedItem = 'Messages externes'
            $script:Gui.Controls.JournalRecipients.Text = '2'
            Update-TsGuiResult
            $read = Read-TsGuiScenario
            $read.Scenario.Journaling.Scope | Should -Be 'External'
            $read.Scenario.Journaling.Recipients | Should -Be 2
            $external = @($read.Scenario.Flows | Where-Object { $_.Direction -in 'Inbound', 'Outbound', 'Entrant', 'Sortant' } | ForEach-Object { [double]$_.MessagesPerDay } | Measure-Object -Sum).Sum
            [Math]::Round($script:Gui.Result.Summary.MessagesPerDay, 0) | Should -Be ([Math]::Round($before + $external * 2 * 1.2, 0))
            $script:Gui.Controls.Role.SelectedIndex = 0
            Update-TsGuiState
            $script:Gui.Controls.JournalPanel.IsEnabled | Should -BeFalse
            $script:Gui = $null
        }
    }
    It 'shows the reference profile of the role, follows the role, and comes back to it after an imported profile' {
        InModuleScope TransportSizer -Parameters @{ CalibrationPath = $script:CalibrationPath } {
            param($CalibrationPath)
            $form = New-TsSizerForm -Theme Light
            $script:Gui.Controls.CalibrationStatus.Text | Should -BeLike 'Référence Edge*générique*'
            $form.Tiles.Cpu.Value.Text | Should -Not -Be 'À calibrer'
            $script:Gui.Controls.RemoveCalibration.IsEnabled | Should -BeFalse
            $script:Gui.Controls.Role.SelectedIndex = 1
            Update-TsGuiResult
            $script:Gui.Controls.CalibrationStatus.Text | Should -BeLike '*Référence Mailbox*'
            $script:Gui.Result.Summary.ProfileSource | Should -Be 'Reference'
            $script:Gui.Controls.MemoryAtRest.Text = '6'
            Update-TsGuiResult
            $script:Gui.Result.Values['mem.atRest'].Value | Should -Be 6
            Set-TsGuiCalibration -Calibration (Import-TsCalibration -Path $CalibrationPath) -Path $CalibrationPath
            Update-TsGuiResult
            $script:Gui.Result.Summary.ProfileSource | Should -Be 'Custom'
            $script:Gui.Controls.RemoveCalibration.IsEnabled | Should -BeTrue
            Set-TsGuiCalibration -Calibration $null
            Update-TsGuiResult
            $script:Gui.Result.Summary.ProfileSource | Should -Be 'Reference'
            $script:Gui = $null
        }
    }
    It 'writes the same report as the command line' {
        InModuleScope TransportSizer -Parameters @{ Work = $script:Work } {
            param($Work)
            [void](New-TsSizerForm -Theme Dark -OutputPath $Work)
            $script:Gui.Controls.Physical.IsChecked = $true
            Update-TsGuiState
            $script:Gui.Controls.PhysicalCard.Visibility | Should -Be 'Visible'
            $files = Invoke-TsGuiReport -NoOpen
            Test-Path -LiteralPath $files.Html | Should -BeTrue
            Test-Path -LiteralPath $files.Synthesis | Should -BeTrue
            $script:Gui.Controls.OpenSynthesis.IsEnabled | Should -BeTrue
            $script:Gui.LastSynthesis | Should -Be $files.Synthesis
            (Import-TsScenario -Path $files.Scenario).Deployment | Should -Be 'Physical'
            $script:Gui = $null
        }
    }
}

Describe 'Calibration scripts' {
    BeforeAll {
        function Start-TestSmtpSink {
            <# Local SMTP server that accepts every message, or answers 421 4.4.2 at the end of DATA (-Throttle). #>
            param([switch]$Throttle, [int]$SessionMessages = 0)
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $state = [hashtable]::Synchronized(@{ Messages = 0; Stop = $false; Headers = 0; Throttle = [bool]$Throttle; SessionMessages = $SessionMessages; Sessions = 0; Bytes = 0; Attachments = 0 })
            $ps = [PowerShell]::Create()
            [void]$ps.AddScript({
                    param($Listener, $State)
                    while (-not $State.Stop) {
                        if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 20; continue }
                        $client = $Listener.AcceptTcpClient()
                        $State.Sessions++
                        $stream = $client.GetStream()
                        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII)
                        $writer = [IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII)
                        $writer.AutoFlush = $true
                        $writer.Write("220 sink`r`n")
                        $inSession = 0
                        while ($true) {
                            $line = $reader.ReadLine()
                            if ($null -eq $line) { break }
                            if ($line -like 'EHLO*') { $writer.Write("250-sink`r`n250 OK`r`n") }
                            elseif ($line -eq 'RSET' -and $State.SessionMessages -gt 0 -and $inSession -ge $State.SessionMessages) {
                                $writer.Write("421 4.4.1 Connection timed out. Total session duration: 00:05:00`r`n"); break
                            }
                            elseif ($line -eq 'DATA') {
                                $writer.Write("354 go`r`n")
                                while (($data = $reader.ReadLine()) -ne '.') {
                                    $State.Bytes += $data.Length + 2
                                    if ($data -like 'X-TransportSizer-Calibration:*') { $State.Headers++ }
                                    if ($data -like 'Content-Disposition: attachment*') { $State.Attachments++ }
                                }
                                if ($State.Throttle) { $writer.Write("421 4.4.2 Message submission rate for this client has exceeded the configured limit`r`n"); break }
                                $State.Messages++
                                $inSession++
                                $writer.Write("250 queued`r`n")
                            }
                            elseif ($line -eq 'QUIT') { $writer.Write("221 bye`r`n"); break }
                            else { $writer.Write("250 OK`r`n") }
                        }
                        $client.Close()
                    }
                }).AddArgument($listener).AddArgument($state)
            [pscustomobject]@{ Listener = $listener; State = $state; PowerShell = $ps; Handle = $ps.BeginInvoke(); Port = $listener.LocalEndpoint.Port }
        }
        function Stop-TestSmtpSink {
            param($Sink)
            $Sink.State.Stop = $true
            [void]$Sink.PowerShell.EndInvoke($Sink.Handle)
            $Sink.PowerShell.Dispose()
            $Sink.Listener.Stop()
        }
    }
    It 'fits the models and the backlog factors from measured steps (Measure-TransportLoad.ps1 -Analyze)' {
        $folder = Join-Path $script:Work 'steps'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $metrics = @('CpuPercent', 'TransportCpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'AvailableMB', 'QueueReadIops', 'QueueWriteIops', 'ReadLatencyMs', 'WriteLatencyMs', 'NetworkInBps', 'NetworkOutBps', 'ReceivedPerSec', 'SentPerSec', 'QueueLength', 'MailQueMB')
        $server = @{ Name = 'LAB-EDGE'; LogicalProcessors = 4; Cores = 2; MemoryGB = 16; MemoryMB = 16384; Virtual = $true; Model = 'Microsoft Corporation Virtual Machine'; Processor = 'Test CPU' }
        $steps = @(@{ Label = 'idle'; Kind = 'Idle'; Rate = 0 }, @{ Label = 'load-04'; Kind = 'Load'; Rate = 4 }, @{ Label = 'load-08'; Kind = 'Load'; Rate = 8 }, @{ Label = 'load-16'; Kind = 'Load'; Rate = 16 }, @{ Label = 'backlog'; Kind = 'Backlog'; Rate = 0 })
        foreach ($step in $steps) {
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add((@('Timestamp', 'Elapsed') + $metrics) -join ',')
            for ($i = 0; $i -lt 24; $i++) {
                $r = $step.Rate
                $private = 300 + 5 * $r
                if ($step.Kind -eq 'Backlog') { $private = 300 + 2 * $i }
                $values = @{ CpuPercent = 4 + 3 * $r; TransportCpuPercent = 1 + 2 * $r; TransportPrivateMB = $private; UsedMemoryMB = 6000 + 12 * $r; AvailableMB = 10384 - 12 * $r
                    QueueReadIops = 0.2 + 0.5 * $r; QueueWriteIops = 2 + 5 * $r; ReadLatencyMs = 1; WriteLatencyMs = 1; NetworkInBps = 1000 + 80000 * $r; NetworkOutBps = 1000 + 79000 * $r
                    ReceivedPerSec = $r; SentPerSec = $r; QueueLength = 0; MailQueMB = 500 }
                $row = @((Get-Date).AddSeconds($i * 5).ToString('yyyy-MM-ddTHH:mm:ss'), ($i * 5)) + @($metrics | ForEach-Object { ([double]$values[$_]).ToString([Globalization.CultureInfo]::InvariantCulture) })
                $lines.Add($row -join ',')
            }
            [IO.File]::WriteAllLines((Join-Path $folder "$($step.Label).csv"), $lines)
            $meta = [ordered]@{ Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $step.Label; Kind = $step.Kind; Role = 'Edge'; Server = $server; ExchangeVersion = '15.02.1748.010'
                Start = '2026-10-06T10:00:00'; DurationSeconds = 120; WarmupSeconds = 20; SampleIntervalSeconds = 5; MailQue = @{ StartMB = 500; EndMB = $(if ($step.Kind -eq 'Backlog') { 2200 } else { 500 }) }
                BacklogMessages = $(if ($step.Kind -eq 'Backlog') { 20000 } else { 0 }); MessageSizeKB = 75 }
            [IO.File]::WriteAllText((Join-Path $folder "$($step.Label).json"), (ConvertTo-Json $meta -Depth 5))
        }
        $profilePath = Join-Path $script:Work 'Calibration-Analyze.json'
        $profile = & (Join-Path $script:Root 'calibration\Measure-TransportLoad.ps1') -Analyze -OutputPath $folder -ProfilePath $profilePath -Name 'Analyse de test' -SpecIntRatePerCore 9.5 6>$null
        $profile.Models.CpuPercent.Slope | Should -Be 3
        $profile.Models.CpuPercent.Intercept | Should -Be 4
        $profile.Models.CpuPercent.R2 | Should -Be 1
        $profile.Models.QueueWriteIops.Slope | Should -Be 5
        $profile.MaxRate | Should -Be 16
        $profile.Backlog.EseOverheadFactor | Should -Be ([Math]::Round(1700 * 1024 / (20000 * 75), 3))
        $profile.Backlog.MemoryKBPerQueued | Should -BeGreaterThan 0
        $imported = Import-TsCalibration -Path $profilePath
        $imported.Server.SpecIntRatePerCore | Should -Be 9.5
        (Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Edge) -Calibration $imported).Summary.Cores | Should -Be 4
    }
    It 'takes the memory per queued message from the slope during injection and refuses an ESE factor from one growth increment' {
        $folder = Join-Path $script:Work 'steps-backlog'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $metrics = @('CpuPercent', 'TransportCpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'AvailableMB', 'QueueReadIops', 'QueueWriteIops', 'ReadLatencyMs', 'WriteLatencyMs', 'NetworkInBps', 'NetworkOutBps', 'ReceivedPerSec', 'SentPerSec', 'QueueLength', 'MailQueMB')
        $server = @{ Name = 'LAB-EDGE'; LogicalProcessors = 2; Cores = 1; MemoryGB = 8; MemoryMB = 8192; Virtual = $true; Model = 'Virtual Machine'; Processor = 'Test CPU' }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        foreach ($step in @(@{ Label = 'idle'; Kind = 'Idle'; Rate = 0 }, @{ Label = 'load-05'; Kind = 'Load'; Rate = 5 }, @{ Label = 'backlog'; Kind = 'Backlog'; Rate = 20 })) {
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add((@('Timestamp', 'Elapsed') + $metrics) -join ',')
            for ($i = 0; $i -lt 60; $i++) {
                $r = $step.Rate; $queue = 0.0; $mailQue = 768.0; $private = 400 + 30 * $r
                if ($step.Kind -eq 'Backlog') {
                    if ($i -lt 50) { $queue = 100.0 * $i } else { $queue = 5000.0; $r = 0 }
                    if ($i -ge 25) { $mailQue = 1024.0 }
                    $private = 1000 + 0.062 * $queue
                    # Memory left by a heavy step before, then a garbage collection (REF-MAILBOX): not part of the line.
                    if ($i -lt 5) { $private = 1600 }
                }
                $values = @{ CpuPercent = 3 + $r; TransportCpuPercent = $r; TransportPrivateMB = $private; UsedMemoryMB = 3000; AvailableMB = 5000; QueueReadIops = 0.2; QueueWriteIops = 5 + $r
                    ReadLatencyMs = 1; WriteLatencyMs = 1; NetworkInBps = 80000 * $r; NetworkOutBps = 80000 * $r; ReceivedPerSec = $r; SentPerSec = 0; QueueLength = $queue; MailQueMB = $mailQue }
                $lines.Add((@((Get-Date).AddSeconds($i * 5).ToString('yyyy-MM-ddTHH:mm:ss'), ($i * 5)) + @($metrics | ForEach-Object { ([double]$values[$_]).ToString($inv) })) -join ',')
            }
            [IO.File]::WriteAllLines((Join-Path $folder "$($step.Label).csv"), $lines)
            $meta = [ordered]@{ Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $step.Label; Kind = $step.Kind; Role = 'Edge'; Server = $server; ExchangeVersion = '15.02'
                Start = '2026-10-06T10:00:00'; DurationSeconds = 300; WarmupSeconds = 0; SampleIntervalSeconds = 5; MailQue = @{ StartMB = 768; EndMB = 1024 }
                BacklogMessages = $(if ($step.Kind -eq 'Backlog') { 5000 } else { 0 }); MessageSizeKB = 75 }
            [IO.File]::WriteAllText((Join-Path $folder "$($step.Label).json"), (ConvertTo-Json $meta -Depth 5))
        }
        $profile = & (Join-Path $script:Root 'calibration\Measure-TransportLoad.ps1') -Analyze -OutputPath $folder -ProfilePath (Join-Path $script:Work 'Calibration-Backlog.json') -WarningAction SilentlyContinue 6>$null
        [Math]::Round($profile.Backlog.MemoryKBPerQueued, 2) | Should -Be ([Math]::Round(0.062 * 1024, 2))
        $profile.Backlog.MemoryReference | Should -BeLike 'pente*'
        $profile.Backlog.TransportPrivateGrowthMB | Should -Be 310
        $profile.Backlog.EseOverheadFactor | Should -Be 0
        $profile.Backlog.QueueIncrementMB | Should -Be 256
        $profile.Backlog.EseNote | Should -BeLike '*incrément*'
        $r = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Edge) -Calibration (Import-TsCalibration -Path (Join-Path $script:Work 'Calibration-Backlog.json'))
        @($r.Checks | Where-Object { $_.Code -eq 'EseNotCalibrated' -and $_.Message -like '*incrément*' }).Count | Should -Be 1
    }
    It 'detects the dehydration of a long backlog and measures the CPU of a drain step' {
        $folder = Join-Path $script:Work 'steps-dehydration'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $metrics = @('CpuPercent', 'TransportCpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'AvailableMB', 'QueueReadIops', 'QueueWriteIops', 'ReadLatencyMs', 'WriteLatencyMs', 'NetworkInBps', 'NetworkOutBps', 'ReceivedPerSec', 'SentPerSec', 'QueueLength', 'MailQueMB')
        $server = @{ Name = 'LAB-EDGE'; LogicalProcessors = 2; Cores = 1; MemoryGB = 8; MemoryMB = 8192; Virtual = $true; Model = 'Virtual Machine'; Processor = 'Test CPU' }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        foreach ($step in @(@{ Label = 'idle'; Kind = 'Idle'; Rate = 0 }, @{ Label = 'load-05'; Kind = 'Load'; Rate = 5 }, @{ Label = 'load-10'; Kind = 'Load'; Rate = 10 }, @{ Label = 'backlog'; Kind = 'Backlog'; Rate = 50 }, @{ Label = 'drain'; Kind = 'Drain'; Rate = 0 })) {
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add((@('Timestamp', 'Elapsed') + $metrics) -join ',')
            for ($i = 0; $i -lt 60; $i++) {
                $r = $step.Rate; $sent = 0.0; $queue = 0.0; $private = 400 + 30 * $r
                if ($step.Kind -eq 'Backlog') {
                    # 61.4 KB per queued message, then Exchange dehydrates at 20 000 messages: 20.5 KB per message kept.
                    $queue = 500.0 * $i
                    $private = $(if ($queue -lt 20000) { 1000 + 0.06 * $queue } else { 1400 + 0.06 * ($queue - 20000) })
                    # Memory left by a heavy step before, freed by a garbage collection: not a dehydration.
                    if ($i -lt 3) { $private = 1600 }
                }
                if ($step.Kind -eq 'Drain') { $sent = 50.0; $queue = 30000 - 500.0 * $i; $private = 1500 }
                $values = @{ CpuPercent = 3 + $r + 0.25 * $sent; TransportCpuPercent = $r; TransportPrivateMB = $private; UsedMemoryMB = 3000; AvailableMB = 5000; QueueReadIops = 0.2 + $sent; QueueWriteIops = 5 + $r
                    ReadLatencyMs = 1; WriteLatencyMs = 1; NetworkInBps = 80000 * $r; NetworkOutBps = 80000 * ($r + $sent); ReceivedPerSec = $r; SentPerSec = $sent; QueueLength = $queue; MailQueMB = 768 }
                $lines.Add((@((Get-Date).AddSeconds($i * 5).ToString('yyyy-MM-ddTHH:mm:ss'), ($i * 5)) + @($metrics | ForEach-Object { ([double]$values[$_]).ToString($inv) })) -join ',')
            }
            [IO.File]::WriteAllLines((Join-Path $folder "$($step.Label).csv"), $lines)
            $meta = [ordered]@{ Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $step.Label; Kind = $step.Kind; Role = 'Edge'; Server = $server; ExchangeVersion = '15.02'
                Start = '2026-10-07T18:00:00'; DurationSeconds = 300; WarmupSeconds = 0; SampleIntervalSeconds = 5; MailQue = @{ StartMB = 768; EndMB = 768 }
                BacklogMessages = $(if ($step.Kind -eq 'Backlog') { 29500 } else { 0 }); MessageSizeKB = 75 }
            [IO.File]::WriteAllText((Join-Path $folder "$($step.Label).json"), (ConvertTo-Json $meta -Depth 5))
        }
        $path = Join-Path $script:Work 'Calibration-Dehydration.json'
        $profile = & (Join-Path $script:Root 'calibration\Measure-TransportLoad.ps1') -Analyze -OutputPath $folder -ProfilePath $path -WarningAction SilentlyContinue 6>$null
        [Math]::Round($profile.Backlog.MemoryKBPerQueued, 2) | Should -Be ([Math]::Round(0.06 * 1024, 2))
        [Math]::Round($profile.Backlog.DehydratedKBPerQueued, 2) | Should -Be ([Math]::Round(400 * 1024 / 20000, 2))
        $profile.Backlog.DehydrationNote | Should -BeLike '*20000 messages*'
        $profile.Drain.CpuPercentPerMsg | Should -Be 0.25
        $profile.Drain.Rate | Should -Be 50
        $profile.Drain.Messages | Should -Be 15000
        # One read per message sent: the dehydrated content is read again from mail.que.
        $profile.Drain.ReadIopsPerMsg | Should -Be 1
        $profile.Drain.WriteIopsPerMsg | Should -Be 0
        $r = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Edge) -Calibration (Import-TsCalibration -Path $path)
        Get-Value $r 'res.drainCost' | Should -Be 0.25
        $r.Values['res.drainCost'].Kind | Should -Be 'Calibration'
        [Math]::Round((Get-Value $r 'mem.perDehydrated'), 2) | Should -Be 20.48
    }
    It 'measures the journal reports as a factor of their own and counts them in the growth of mail.que (Mailbox)' {
        $folder = Join-Path $script:Work 'steps-journal'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $metrics = @('CpuPercent', 'TransportCpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'AvailableMB', 'QueueReadIops', 'QueueWriteIops', 'ReadLatencyMs', 'WriteLatencyMs', 'NetworkInBps', 'NetworkOutBps',
            'ReceivedPerSec', 'SentPerSec', 'QueueLength', 'MailQueMB', 'MessageBytesPerSec', 'JournalReportsPerSec', 'DatabaseMemoryMB')
        $server = @{ Name = 'LAB-MBX'; LogicalProcessors = 4; Cores = 2; MemoryGB = 16; MemoryMB = 16384; Virtual = $true; Model = 'Virtual Machine'; Processor = 'Test CPU' }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        # CPU % = 3.6 + 3.2 x msg/s + 3.7 x MB/s + 1.9 x reports/s; mail.que grows by 1.2 MB per MB stored (messages and reports).
        $steps = @(
            @{ Label = 'idle'; Kind = 'Idle'; Rate = 0; Size = 0; Journal = 0 }
            @{ Label = 's075-05'; Kind = 'Load'; Rate = 5; Size = 75; Journal = 0 }
            @{ Label = 's075-10'; Kind = 'Load'; Rate = 10; Size = 75; Journal = 0 }
            @{ Label = 's075-20'; Kind = 'Load'; Rate = 20; Size = 75; Journal = 0 }
            @{ Label = 's500-04'; Kind = 'Load'; Rate = 4; Size = 500; Journal = 0 }
            @{ Label = 'jnl-10'; Kind = 'Load'; Rate = 10; Size = 75; Journal = 10 }
        )
        $mailQue = 20000.0; $samples = 120; $interval = 5; $processedTotal = 0.0; $minute = 0
        foreach ($step in $steps) {
            $bytes = $step.Rate * $step.Size * 1024
            $processedMB = $samples * $interval * ($bytes + $step.Journal * $step.Size * 1024) / 1MB
            if ($step.Kind -eq 'Load') { $processedTotal += $processedMB }
            $growth = $(if ($step.Kind -eq 'Load') { 1.2 * $processedMB } else { 0 })
            $start = $mailQue
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add((@('Timestamp', 'Elapsed') + $metrics) -join ',')
            for ($i = 0; $i -lt $samples; $i++) {
                $r = $step.Rate; $mbps = $bytes / 1MB
                $values = @{ CpuPercent = 3.6 + 3.2 * $r + 3.7 * $mbps + 1.9 * $step.Journal; TransportCpuPercent = 2 * $r; TransportPrivateMB = 900 + 8 * $r; UsedMemoryMB = 13000; AvailableMB = 3000
                    QueueReadIops = 1; QueueWriteIops = 6 + 25 * $mbps; ReadLatencyMs = 1; WriteLatencyMs = 1; NetworkInBps = $bytes; NetworkOutBps = 2 * $bytes; ReceivedPerSec = $r; SentPerSec = 2 * $r
                    QueueLength = 0; MailQueMB = $start + $growth * $i / ($samples - 1); MessageBytesPerSec = $bytes; JournalReportsPerSec = $step.Journal; DatabaseMemoryMB = 900 }
                $lines.Add((@((Get-Date).AddSeconds($i * $interval).ToString('yyyy-MM-ddTHH:mm:ss'), ($i * $interval)) + @($metrics | ForEach-Object { ([double]$values[$_]).ToString($inv) })) -join ',')
            }
            $mailQue = $start + $growth
            [IO.File]::WriteAllLines((Join-Path $folder "$($step.Label).csv"), $lines)
            $minute += 15
            $meta = [ordered]@{ Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $step.Label; Kind = $step.Kind; Role = 'Mailbox'; Server = $server; ExchangeVersion = '15.02'
                Start = ([datetime]'2026-10-06T10:00:00').AddMinutes($minute).ToString('s'); DurationSeconds = $samples * $interval; WarmupSeconds = 0; SampleIntervalSeconds = $interval
                MailQue = @{ StartMB = $start; EndMB = $mailQue }; BacklogMessages = 0; MessageSizeKB = $step.Size }
            [IO.File]::WriteAllText((Join-Path $folder "$($step.Label).json"), (ConvertTo-Json $meta -Depth 5))
        }
        $path = Join-Path $script:Work 'Calibration-Journal.json'
        $profile = & (Join-Path $script:Root 'calibration\Measure-TransportLoad.ps1') -Analyze -OutputPath $folder -ProfilePath $path -WarningAction SilentlyContinue 6>$null
        [Math]::Round($profile.Models.CpuPercent.PerJournal, 3) | Should -Be 1.9
        [Math]::Round($profile.Models.CpuPercent.Slope, 3) | Should -Be 3.2
        $profile.Range.MaxJournalPerSec | Should -Be 10
        [Math]::Round($profile.Retention.ProcessedMB, 0) | Should -Be ([Math]::Round($processedTotal, 0))
        # Memory of the mailbox databases (Store workers) left out of the used memory: 13 000 − 900 MB.
        [Math]::Round($profile.Models.UsedMemoryMB.Intercept, 0) | Should -Be 12100
        @($profile.Corrections)[0].DeltaMB | Should -Be -900
        (Import-TsCalibration -Path $path).Corrections.Count | Should -Be 1
        # A step of an older collector (no database memory): the memory is left out of no step, and the analysis says so.
        $older = Join-Path $script:Work 'steps-journal-older'
        [void](New-Item -ItemType Directory -Path $older -Force)
        $csv = @(Get-Content (Join-Path $folder 's075-10.csv'))
        $columns = $csv[0] -split ','
        $drop = [Array]::IndexOf($columns, 'DatabaseMemoryMB')
        $csv | ForEach-Object { $parts = [Collections.Generic.List[string]]($_ -split ','); $parts.RemoveAt($drop); $parts -join ',' } | Set-Content -LiteralPath (Join-Path $older 's075-12.csv')
        $meta = Get-Content (Join-Path $folder 's075-10.json') -Raw | ConvertFrom-Json
        $meta.Label = 's075-12'; $meta.Start = '2026-10-06T12:00:00'
        [IO.File]::WriteAllText((Join-Path $older 's075-12.json'), (ConvertTo-Json $meta -Depth 5))
        $mixed = & (Join-Path $script:Root 'calibration\Measure-TransportLoad.ps1') -Analyze -OutputPath $folder -IncludePath $older -ProfilePath (Join-Path $script:Work 'Calibration-Mixed.json') -WarningVariable mixedWarnings -WarningAction SilentlyContinue 6>$null
        @($mixed.Corrections).Count | Should -Be 0
        [Math]::Round($mixed.Models.UsedMemoryMB.Intercept, 0) | Should -Be 13000
        ($mixedWarnings -join ' ') | Should -BeLike '*Store workers*'
        $profile.Retention.Factor | Should -Be 1.2
        # Mailbox profile: Safety Net keeps every message, the growth per MB stored is the ESE factor of the queue.
        $r = Invoke-TsSizing -Scenario (New-TestScenario -Role Mailbox -Changes @{ 'Journaling.Enabled' = $true }) -Calibration (Import-TsCalibration -Path $path)
        Get-Value $r 'queue.ese' | Should -Be 1.2
        $r.Values['queue.ese'].Kind | Should -Be 'Calibration'
        @($r.Checks | ForEach-Object Code) | Should -Not -Contain 'EseNotCalibrated'
        [Math]::Round((Get-Value $r 'load.journalRate'), 6) | Should -Be ([Math]::Round((Get-Value $r 'load.designRate') / 2, 6))
    }
    It 'separates the cost of the size, the rules, the sessions and TLS, and predicts the mix kept out of the fit' {
        $folder = Join-Path $script:Work 'steps-factors'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $metrics = @('CpuPercent', 'TransportCpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'AvailableMB', 'QueueReadIops', 'QueueWriteIops', 'ReadLatencyMs', 'WriteLatencyMs', 'NetworkInBps', 'NetworkOutBps',
            'ReceivedPerSec', 'SentPerSec', 'QueueLength', 'MailQueMB', 'MessageBytesPerSec', 'ConnectionsPerSec', 'TlsConnectionsPerSec', 'ConnectionsCurrent', 'TlsConnectionsCurrent', 'QueueReadBps', 'QueueWriteBps')
        $server = @{ Name = 'LAB-EDGE'; LogicalProcessors = 2; Cores = 1; MemoryGB = 8; MemoryMB = 8192; Virtual = $true; Model = 'Virtual Machine'; Processor = 'Test CPU' }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $steps = @(
            @{ Label = 'idle'; Kind = 'Idle'; Rate = 0; Size = 0; Rules = 0; Sessions = 0; Tls = 0 }
            @{ Label = 's010k-10'; Kind = 'Load'; Rate = 10; Size = 10; Rules = 0; Sessions = 0.03; Tls = 0 }
            @{ Label = 's010k-25'; Kind = 'Load'; Rate = 25; Size = 10; Rules = 0; Sessions = 0.08; Tls = 0 }
            @{ Label = 's500k-10'; Kind = 'Load'; Rate = 10; Size = 500; Rules = 0; Sessions = 0.03; Tls = 0 }
            @{ Label = 's2m-05'; Kind = 'Load'; Rate = 5; Size = 2000; Rules = 0; Sessions = 0.02; Tls = 0 }
            @{ Label = 'rules025-10'; Kind = 'Load'; Rate = 10; Size = 75; Rules = 25; Sessions = 0.03; Tls = 0 }
            @{ Label = 'rules100-10'; Kind = 'Load'; Rate = 10; Size = 75; Rules = 100; Sessions = 0.03; Tls = 0 }
            @{ Label = 'sess1-10'; Kind = 'Load'; Rate = 10; Size = 75; Rules = 0; Sessions = 10; Tls = 0 }
            @{ Label = 'tls1-10'; Kind = 'Load'; Rate = 10; Size = 75; Rules = 0; Sessions = 10; Tls = 10 }
            @{ Label = 'mix-10'; Kind = 'Load'; Rate = 10; Size = 242; Rules = 0; Sessions = 0.03; Tls = 0 }
        )
        foreach ($step in $steps) {
            $mbps = $step.Rate * $step.Size / 1024
            $cpu = 3 + 0.8 * $step.Rate + 1.5 * $mbps + 0.004 * $step.Rate * $step.Rules + 0.6 * $step.Sessions + 1.2 * $step.Tls
            $read = @{ 'idle' = 2; 's010k-10' = 14; 's010k-25' = 30; 's500k-10' = 60; 's2m-05' = 95; 'mix-10' = 40 }
            $values = @{ CpuPercent = $cpu; TransportCpuPercent = $cpu - 2; TransportPrivateMB = 600 + 10 * $step.Rate; UsedMemoryMB = 3000; AvailableMB = 5192; QueueReadIops = $(if ($read.ContainsKey($step.Label)) { $read[$step.Label] } else { 14 }); QueueWriteIops = 10 + 0.5 * $step.Rate
                ReadLatencyMs = 1; WriteLatencyMs = 1; NetworkInBps = 1000 + 1100 * 1024 * $mbps; NetworkOutBps = 1000 + 1100 * 1024 * $mbps; ReceivedPerSec = $step.Rate; SentPerSec = $step.Rate; QueueLength = 0; MailQueMB = 512
                MessageBytesPerSec = $step.Rate * $step.Size * 1024; ConnectionsPerSec = $step.Sessions; TlsConnectionsPerSec = $step.Tls; ConnectionsCurrent = 20; TlsConnectionsCurrent = $(if ($step.Tls -gt 0) { 20 } else { 0 })
                QueueReadBps = 0; QueueWriteBps = 1000 + 2 * 1048576 * $mbps }
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add((@('Timestamp', 'Elapsed') + $metrics) -join ',')
            for ($i = 0; $i -lt 12; $i++) { $lines.Add((@((Get-Date).AddSeconds($i * 5).ToString('yyyy-MM-ddTHH:mm:ss'), ($i * 5)) + @($metrics | ForEach-Object { ([double]$values[$_]).ToString($inv) })) -join ',') }
            [IO.File]::WriteAllLines((Join-Path $folder "$($step.Label).csv"), $lines)
            $meta = [ordered]@{ Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $step.Label; Kind = $step.Kind; Role = 'Edge'; Server = $server; ExchangeVersion = '15.02'
                Start = '2026-10-06T10:00:00'; DurationSeconds = 60; WarmupSeconds = 0; SampleIntervalSeconds = 5; MailQue = @{ StartMB = 512; EndMB = 512 }; BacklogMessages = 0; MessageSizeKB = $step.Size; TransportRules = $step.Rules }
            [IO.File]::WriteAllText((Join-Path $folder "$($step.Label).json"), (ConvertTo-Json $meta -Depth 5))
        }
        # Two backlog steps: 75 KB (63.5 KB of memory per queued message) and 1 000 KB (71.7 KB), the second on a new mail.que.
        foreach ($backlog in @(@{ Label = 'backlog'; Size = 75; MBPerQueued = 0.062; Messages = 5000; MailQue = @(768, 1024) }, @{ Label = 'backlog-1m'; Size = 1000; MBPerQueued = 0.07; Messages = 2500; MailQue = @(512, 3328) })) {
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add((@('Timestamp', 'Elapsed') + $metrics) -join ',')
            for ($i = 0; $i -lt 60; $i++) {
                $queue = [Math]::Min(1.0, $i / 50) * $backlog.Messages
                $r = $(if ($i -lt 50) { $backlog.Messages / 250 } else { 0 })
                $mailQue = $backlog.MailQue[0] + 256 * [Math]::Floor(($backlog.MailQue[1] - $backlog.MailQue[0]) / 256 * [Math]::Min(1.0, $i / 50))
                $values = @{ CpuPercent = 3 + $r; TransportCpuPercent = $r; TransportPrivateMB = 1000 + $backlog.MBPerQueued * $queue; UsedMemoryMB = 3000; AvailableMB = 5192; QueueReadIops = 0.2; QueueWriteIops = 5
                    ReadLatencyMs = 1; WriteLatencyMs = 1; NetworkInBps = 0; NetworkOutBps = 0; ReceivedPerSec = $r; SentPerSec = 0; QueueLength = $queue; MailQueMB = $mailQue
                    MessageBytesPerSec = $r * $backlog.Size * 1024; ConnectionsPerSec = 0; TlsConnectionsPerSec = 0; ConnectionsCurrent = 0; TlsConnectionsCurrent = 0; QueueReadBps = 0; QueueWriteBps = 0 }
                $lines.Add((@((Get-Date).AddSeconds($i * 5).ToString('yyyy-MM-ddTHH:mm:ss'), ($i * 5)) + @($metrics | ForEach-Object { ([double]$values[$_]).ToString($inv) })) -join ',')
            }
            [IO.File]::WriteAllLines((Join-Path $folder "$($backlog.Label).csv"), $lines)
            $meta = [ordered]@{ Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $backlog.Label; Kind = 'Backlog'; Role = 'Edge'; Server = $server; ExchangeVersion = '15.02'
                Start = '2026-10-06T10:00:00'; DurationSeconds = 300; WarmupSeconds = 0; SampleIntervalSeconds = 5; MailQue = @{ StartMB = $backlog.MailQue[0]; EndMB = $backlog.MailQue[1] }
                BacklogMessages = $backlog.Messages; MessageSizeKB = $backlog.Size; TransportRules = 0 }
            [IO.File]::WriteAllText((Join-Path $folder "$($backlog.Label).json"), (ConvertTo-Json $meta -Depth 5))
        }
        $profile = & (Join-Path $script:Root 'calibration\Measure-TransportLoad.ps1') -Analyze -OutputPath $folder -ProfilePath (Join-Path $script:Work 'Calibration-Factors.json') -Validate 'mix-10' -WarningAction SilentlyContinue 6>$null
        $cpu = $profile.Models.CpuPercent
        [Math]::Round($cpu.Intercept, 3) | Should -Be 3
        [Math]::Round($cpu.Slope, 3) | Should -Be 0.8
        [Math]::Round($cpu.PerMBps, 3) | Should -Be 1.5
        [Math]::Round($cpu.PerRuleMsg, 4) | Should -Be 0.004
        [Math]::Round($cpu.PerSession, 3) | Should -Be 0.6
        [Math]::Round($cpu.PerTlsSession, 3) | Should -Be 1.2
        $cpu.R2 | Should -Be 1
        $profile.Models.QueueWriteBps.Contains('PerMBps') | Should -BeTrue
        [Math]::Round($profile.Models.QueueWriteBps.PerMBps / 1048576, 3) | Should -Be 2
        $profile.Models.TransportPrivateMB.Contains('PerMBps') | Should -BeFalse
        # Large messages pull the intercept of the reads below zero: it becomes the value measured at rest.
        $profile.Models.QueueReadIops.Intercept | Should -Be 2
        $profile.Models.QueueReadIops.InterceptFromIdle | Should -BeTrue
        $profile.Models.QueueReadIops.PerMBps | Should -BeGreaterThan 0
        $profile.Validation[0].Label | Should -Be 'mix-10'
        [Math]::Round($profile.Validation[0].CpuPercent.Predicted, 2) | Should -Be ([Math]::Round(3 + 8 + 1.5 * 10 * 242 / 1024 + 0.6 * 0.03, 2))
        $profile.Range.MaxSizeKB | Should -Be 2000
        $profile.Range.MaxRules | Should -Be 100
        [Math]::Round($profile.Backlog.MemoryPerKB, 5) | Should -Be ([Math]::Round((0.07 - 0.062) * 1024 / 925, 5))
        [Math]::Round($profile.Backlog.MemoryBaseKB, 2) | Should -Be ([Math]::Round(0.062 * 1024 - (0.07 - 0.062) * 1024 / 925 * 75, 2))
        $profile.Backlog.EseStep | Should -Be 'backlog-1m'
        $profile.Backlog.EseOverheadFactor | Should -Be ([Math]::Round(2816 * 1024 / (2500 * 1000), 3))
        $imported = Import-TsCalibration -Path (Join-Path $script:Work 'Calibration-Factors.json')
        $imported.Models.CpuPercent.PerRuleMsg | Should -Be 0.004
        $imported.Backlog.MemoryPerKB | Should -BeGreaterThan 0
    }
    It 'keeps background connections out of the model and anchors a negative intercept on the idle step' {
        $folder = Join-Path $script:Work 'steps-noise'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $metrics = @('CpuPercent', 'TransportCpuPercent', 'TransportPrivateMB', 'UsedMemoryMB', 'AvailableMB', 'QueueReadIops', 'QueueWriteIops', 'ReadLatencyMs', 'WriteLatencyMs', 'NetworkInBps', 'NetworkOutBps',
            'ReceivedPerSec', 'SentPerSec', 'QueueLength', 'MailQueMB', 'MessageBytesPerSec', 'ConnectionsPerSec', 'TlsConnectionsPerSec', 'ConnectionsCurrent', 'TlsConnectionsCurrent', 'QueueReadBps', 'QueueWriteBps')
        $server = @{ Name = 'LAB-EDGE'; LogicalProcessors = 2; Cores = 1; MemoryGB = 8; MemoryMB = 8192; Virtual = $true; Model = 'Virtual Machine'; Processor = 'Test CPU' }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        # Size steps only, sessions kept open: the connections per second are background noise (0.08 to 0.32/s),
        # one stray TLS connection, and a CPU that the large messages pull below zero at the origin.
        $steps = @(
            @{ Label = 'idle'; Kind = 'Idle'; Rate = 0; Size = 0; Sessions = 0.08; Tls = 0; Cpu = 0.5 }
            @{ Label = 's010k-10'; Kind = 'Load'; Rate = 10; Size = 10; Sessions = 0.18; Tls = 0; Cpu = 4 }
            @{ Label = 's010k-25'; Kind = 'Load'; Rate = 25; Size = 10; Sessions = 0.32; Tls = 0; Cpu = 14 }
            @{ Label = 's075k-10'; Kind = 'Load'; Rate = 10; Size = 75; Sessions = 0.18; Tls = 0; Cpu = 6 }
            @{ Label = 's500k-05'; Kind = 'Load'; Rate = 5; Size = 500; Sessions = 0.14; Tls = 0; Cpu = 25 }
            @{ Label = 's2m-03'; Kind = 'Load'; Rate = 3; Size = 2000; Sessions = 0.12; Tls = 0.003; Cpu = 60 }
        )
        foreach ($step in $steps) {
            $values = @{ CpuPercent = $step.Cpu; TransportCpuPercent = $step.Cpu; TransportPrivateMB = 600; UsedMemoryMB = 3000; AvailableMB = 5192; QueueReadIops = 1; QueueWriteIops = 5 + $step.Rate
                ReadLatencyMs = 1; WriteLatencyMs = 1; NetworkInBps = 1000; NetworkOutBps = 1000; ReceivedPerSec = $step.Rate; SentPerSec = $step.Rate; QueueLength = 0; MailQueMB = 512
                MessageBytesPerSec = $step.Rate * $step.Size * 1024; ConnectionsPerSec = $step.Sessions; TlsConnectionsPerSec = $step.Tls; ConnectionsCurrent = 40; TlsConnectionsCurrent = $(if ($step.Tls -gt 0) { 1 } else { 0 }); QueueReadBps = 0; QueueWriteBps = 0 }
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add((@('Timestamp', 'Elapsed') + $metrics) -join ',')
            for ($i = 0; $i -lt 12; $i++) { $lines.Add((@((Get-Date).AddSeconds($i * 5).ToString('yyyy-MM-ddTHH:mm:ss'), ($i * 5)) + @($metrics | ForEach-Object { ([double]$values[$_]).ToString($inv) })) -join ',') }
            [IO.File]::WriteAllLines((Join-Path $folder "$($step.Label).csv"), $lines)
            $meta = [ordered]@{ Tool = 'TransportSizer.Calibration'; SchemaVersion = 1; Label = $step.Label; Kind = $step.Kind; Role = 'Edge'; Server = $server; ExchangeVersion = '15.02'
                Start = '2026-10-06T10:00:00'; DurationSeconds = 60; WarmupSeconds = 0; SampleIntervalSeconds = 5; MailQue = @{ StartMB = 512; EndMB = 512 }; BacklogMessages = 0; MessageSizeKB = $step.Size; TransportRules = 0 }
            [IO.File]::WriteAllText((Join-Path $folder "$($step.Label).json"), (ConvertTo-Json $meta -Depth 5))
        }
        $profile = & (Join-Path $script:Root 'calibration\Measure-TransportLoad.ps1') -Analyze -OutputPath $folder -ProfilePath (Join-Path $script:Work 'Calibration-Noise.json') -WarningAction SilentlyContinue 6>$null
        $cpu = $profile.Models.CpuPercent
        $cpu.Contains('PerSession') | Should -BeFalse
        $cpu.Contains('PerTlsSession') | Should -BeFalse
        $cpu.Contains('PerTlsMBps') | Should -BeFalse
        $cpu.InterceptFromIdle | Should -BeTrue
        $cpu.Intercept | Should -Be 0.5
        $cpu.PerMBps | Should -BeGreaterThan 0
        $r = Invoke-TsSizing -Scenario (Import-TsScenario -Path (Join-Path $script:Root 'examples\Edge-Internet.json')) -Calibration (Import-TsCalibration -Path (Join-Path $script:Work 'Calibration-Noise.json'))
        $r.Summary.Cores | Should -Be 4
        @($r.Checks | ForEach-Object Code) | Should -Contain 'SessionsNotCalibrated'
    }
    It 'sends the load at the rate asked (Send-TransportTestLoad.ps1 against a local SMTP sink)' {
        $sink = Start-TestSmtpSink
        try {
            $log = & (Join-Path $script:Root 'calibration\Send-TransportTestLoad.ps1') -SmtpServer '127.0.0.1' -Port $sink.Port -From 'calib@contoso.test' -To 'sink@contoso.test' -Rates 10 -StepSeconds 4 -PauseSeconds 0 -MessageSizeKB 8 -Connections 1 6>$null
        }
        finally { Stop-TestSmtpSink $sink }
        $log.Failed | Should -Be 0
        $log.Throttled | Should -Be 0
        $log.Sent | Should -BeGreaterOrEqual 24
        $log.Sent | Should -BeLessOrEqual 45
        $sink.State.Messages | Should -Be $log.Sent
        $sink.State.Headers | Should -Be $log.Sent
    }
    It 'reconnects without counting a failure when the server ends the session between two messages (421 4.4.1)' {
        $sink = Start-TestSmtpSink -SessionMessages 5
        try {
            $log = & (Join-Path $script:Root 'calibration\Send-TransportTestLoad.ps1') -SmtpServer '127.0.0.1' -Port $sink.Port -From 'calib@contoso.test' -To 'sink@contoso.test' -Rates 10 -StepSeconds 3 -PauseSeconds 0 -MessageSizeKB 1 -Connections 1 6>$null
        }
        finally { Stop-TestSmtpSink $sink }
        $log.Failed | Should -Be 0
        $log.Reconnects | Should -BeGreaterThan 2
        $log.Sent | Should -BeGreaterOrEqual 20
        $sink.State.Messages | Should -Be $log.Sent
    }
    It 'sends a mix of attachments, one session per message, and reports the average size' {
        $sink = Start-TestSmtpSink
        try {
            $log = & (Join-Path $script:Root 'calibration\Send-TransportTestLoad.ps1') -SmtpServer '127.0.0.1' -Port $sink.Port -From 'calib@contoso.test' -To 'sink@contoso.test' -Rates 10 -StepSeconds 3 -PauseSeconds 0 `
                -MessageSizeKB 2 -AttachmentKB 0, 40 -AttachmentWeight 1, 1 -MessagesPerSession 1 -Connections 1 6>$null
        }
        finally { Stop-TestSmtpSink $sink }
        $log.Failed | Should -Be 0
        $log.Sent | Should -BeGreaterOrEqual 15
        $log.SessionsOpened | Should -Be $log.Sent
        $sink.State.Sessions | Should -Be $log.Sent
        $sink.State.Attachments | Should -BeGreaterThan 0
        $sink.State.Attachments | Should -BeLessThan $log.Sent
        # 40 KB of file = 54.7 KB of base64 in lines of 76 characters.
        $expected = (2.0 * $log.Sent + 40 * 4 / 3 * 78 / 76 * $sink.State.Attachments) / $log.Sent
        $log.AverageKB | Should -BeGreaterThan ($expected * 0.95)
        $log.AverageKB | Should -BeLessThan ($expected * 1.1 + 1)
        [Math]::Abs($sink.State.Bytes / 1024 / $log.Sent - $log.AverageKB) | Should -BeLessThan 0.5
    }
    It 'counts the 4.4.2 replies of a receive connector rate limit apart' {
        $sink = Start-TestSmtpSink -Throttle
        try {
            $log = & (Join-Path $script:Root 'calibration\Send-TransportTestLoad.ps1') -SmtpServer '127.0.0.1' -Port $sink.Port -From 'calib@contoso.test' -To 'sink@contoso.test' -Rates 4 -StepSeconds 2 -PauseSeconds 0 -MessageSizeKB 1 -Connections 1 6>$null
        }
        finally { Stop-TestSmtpSink $sink }
        $log.Sent | Should -Be 0
        $log.Throttled | Should -BeGreaterThan 0
        $log.Throttled | Should -Be $log.Failed
    }
    It 'resolves relative paths against the PowerShell location' {
        Push-Location -LiteralPath $script:Work
        try {
            $result = Invoke-TsSizing -Scenario (Get-TsDefaultScenario -Role Edge) -Calibration $null
            $files = Export-TsReport -Result $result -OutputPath '.\relatif'
            $files.Html | Should -BeLike (Join-Path $script:Work 'relatif\*')
            Test-Path -LiteralPath $files.Html | Should -BeTrue
            [void](Export-TsScenario -Scenario (Get-TsDefaultScenario -Role Edge) -Path '.\relatif.json')
            Test-Path -LiteralPath (Join-Path $script:Work 'relatif.json') | Should -BeTrue
        }
        finally { Pop-Location }
    }
}
