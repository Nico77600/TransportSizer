<#
    Transport Sizer - manufacturer disk catalogue and physical storage.
    Catalogue and reference classes shared with Mailbox Sizer (data\Disks.csv).
#>

$script:TsDiskCatalog = $null
$script:TsLegacyDisks = @{
    '7.2K RPM SAS 3.5"' = 'HDD NL-SAS 7,2K 3,5 pouces'; '7.2K RPM SATA 3.5"' = 'HDD NL-SAS 7,2K 3,5 pouces'
    '7.2K RPM SAS 2.5"' = 'HDD NL-SAS 7,2K 3,5 pouces'; '7.2K RPM SATA 2.5"' = 'HDD NL-SAS 7,2K 3,5 pouces'
    '10K RPM SAS 2.5"' = 'Toshiba AL15SE · SAS 10K 2,5 pouces'; '15K RPM SAS 2.5"' = 'Toshiba AL15SE · SAS 10K 2,5 pouces'
    '10K RPM FC/SCSI/SAS 3.5"' = 'Toshiba AL15SE · SAS 10K 2,5 pouces'; '15K RPM FC/SCSI/SAS 3.5"' = 'Toshiba AL15SE · SAS 10K 2,5 pouces'
    'SSD / NVMe' = 'SSD SAS usage mixte (3 DWPD)'
}

function Get-TsDiskCatalog {
    <#
    .SYNOPSIS
        Manufacturer specifications and generic classes backed by an explicit reference model.
    .DESCRIPTION
        RandomIops is the 4 KB reference budget, not a transport measurement. Mechanical disks use
        short-queue mixed IOPS; SSDs use the published random write figure. The sizing corrects this
        budget for the transport transfer size. Missing figures remain unknown (0), never invented.
    #>
    [CmdletBinding()]
    param([string]$Name, [ValidateSet('', 'System', 'Transport', 'Database', 'Mcdb')][string]$Role = '', [string]$Category)

    if (-not $script:TsDiskCatalog) {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $minimum = (Get-TsReference).Storage.ServerMinimumGB
        $text = { param($Row, [string]$Column) if ($Row.PSObject.Properties[$Column] -and [string]$Row.$Column -ne '') { [string]$Row.$Column } else { $null } }
        $number = { param($Row, [string]$Column) $v = & $text $Row $Column; if ($null -ne $v) { [double]::Parse($v, $inv) } else { $null } }
        $family = { param([string]$Interface) ($Interface -split ' ')[0] }
        $disks = @(Import-Csv -LiteralPath (Join-Path $script:ToolRoot 'data\Disks.csv') -Encoding UTF8 | ForEach-Object {
                $row = $_
                $lff = $row.FormFactor -like '3,5*'
                $sheet = @(if (& $text $row 'SizesGB') { $row.SizesGB -split ';' | ForEach-Object { [double]::Parse($_, $inv) } })
                $floor = $(if ($row.Class -eq 'HDD' -and $lff) { [double]$minimum.NearlineHdd } elseif ($row.Class -in 'SSD', 'NVMe') { [double]$minimum.Ssd } else { 0.0 })
                # A transport queue is protected by RAID, not the mailbox DAG's JBOD rules.
                $roles = @($row.Roles -split ';')
                if ($row.Class -eq 'HDD') { $roles = @($roles + @('System', 'Transport') | Select-Object -Unique) }
                [pscustomobject]@{
                    Name = $row.Name; Manufacturer = $row.Manufacturer; Generic = $row.Manufacturer -eq 'Générique'; Category = $row.Category
                    Reference = & $text $row 'Reference'; Members = @(); Models = & $text $row 'Models'; Class = $row.Class; FormFactor = $row.FormFactor; Interface = $row.Interface
                    Rpm = [int]$row.Rpm; Dwpd = & $number $row 'Dwpd'; DatasheetSizesGB = $sheet; SizesGB = @($sheet | Where-Object { $_ -ge $floor - 1e-9 })
                    SequentialMBps = & $number $row 'SequentialMBps'; DatasheetReadIops = & $number $row 'DatasheetReadIops'; DatasheetWriteIops = & $number $row 'DatasheetWriteIops'
                    IopsCondition = & $text $row 'IopsCondition'; DatasheetMixedIops = & $number $row 'DatasheetMixedIops'; MixedQueueDepth = & $number $row 'MixedQueueDepth'
                    MixedCondition = & $text $row 'MixedCondition'; RandomIops = 0.0; IopsBasis = 'non publié par le fabricant'
                    Roles = $roles; Ssd = $row.Class -ne 'HDD'; Lff = $lff; Status = & $text $row 'Status'; Source = & $text $row 'Source'; Checked = & $text $row 'Checked'; Note = $row.Note
                }
            })
        $models = @($disks | Where-Object { -not $_.Generic })
        foreach ($d in $models) {
            if ($d.Ssd -and $null -ne $d.DatasheetWriteIops) {
                $d.RandomIops = [double]$d.DatasheetWriteIops
                $d.IopsBasis = 'écriture aléatoire 4 Ko de la fiche : {0}. Valeur constructeur, pas une mesure de transport.' -f $d.IopsCondition
            }
            elseif (-not $d.Ssd -and $null -ne $d.DatasheetMixedIops) {
                $d.RandomIops = [double]$d.DatasheetMixedIops
                $d.IopsBasis = '{0} IOPS en {1} ; latence moyenne de la fiche : {2} ms (file ÷ IOPS).' -f (Fn $d.RandomIops 0), $d.MixedCondition, (Fn ($d.MixedQueueDepth / $d.RandomIops * 1000) 1)
            }
        }
        foreach ($g in @($disks | Where-Object { $_.Generic })) {
            $r = $models | Where-Object { $_.Name -eq $g.Reference } | Select-Object -First 1
            if (-not $r) { throw ('data\Disks.csv : modèle de référence « {0} » de « {1} » introuvable.' -f $g.Reference, $g.Name) }
            $members = @($models | Where-Object { $_.Category -eq $g.Name -and (& $family $_.Interface) -eq (& $family $r.Interface) -and $_.Dwpd -eq $r.Dwpd })
            $g.Members = @($members | ForEach-Object { $_.Name })
            $g.SizesGB = @($members | ForEach-Object { $_.SizesGB } | Sort-Object -Unique)
            $g.DatasheetSizesGB = @($members | ForEach-Object { $_.DatasheetSizesGB } | Sort-Object -Unique)
            foreach ($p in 'Dwpd', 'SequentialMBps', 'DatasheetReadIops', 'DatasheetWriteIops', 'IopsCondition', 'DatasheetMixedIops', 'MixedQueueDepth', 'MixedCondition', 'RandomIops', 'IopsBasis', 'Status', 'Source', 'Checked') { $g.$p = $r.$p }
            $g.IopsBasis = '{0} : {1}' -f $r.Name, $r.IopsBasis
            $g.Note = '{0} Modèle de référence : {1}.' -f $g.Note, $r.Name
            if (-not $r.Ssd) {
                foreach ($m in @($models | Where-Object { $_.Category -eq $g.Name -and -not $_.Ssd -and $null -eq $_.DatasheetMixedIops })) {
                    $m.RandomIops = $r.RandomIops
                    $m.IopsBasis = 'hypothèse du modèle de référence {0} (ce modèle ne publie pas d’’IOPS mixtes à file courte) : {1}' -f $r.Name, $r.IopsBasis
                }
            }
        }
        $script:TsDiskCatalog = $disks
    }
    $list = $script:TsDiskCatalog
    if ($Role) { $list = @($list | Where-Object { $_.Roles -contains $Role }) }
    if ($Category) { $list = @($list | Where-Object { $_.Category -eq $Category }) }
    if ($Name) { return ($list | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
    return $list
}

function Get-TsDiskPerformance {
    param([Parameter(Mandatory = $true)][object]$Disk, [double]$IoSizeKB = 4, [double]$DiskIops = 0)

    if ($DiskIops -gt 0) {
        return [pscustomobject]@{ Iops = $DiskIops; Basis = 'IOPS saisies, mesurées pour la charge de transport ; remplacent l’’estimation de la fiche.' }
    }
    $sheetKB = [double](Get-TsReference).Storage.DatasheetIoKB
    $ioKB = [Math]::Max($sheetKB, $IoSizeKB)
    $iops = [double]$Disk.RandomIops
    $basis = $Disk.IopsBasis
    if ($iops -gt 0 -and $Disk.SequentialMBps -gt 0) {
        if ($Disk.Ssd) {
            $iops = [Math]::Floor([Math]::Min($iops, $Disk.SequentialMBps * 1e6 / ($ioKB * 1024)))
            $basis += ' Plafond de conception : min(IOPS 4 Ko, débit d’’écriture ÷ taille d’’E/S), {0} Ko → {1} IOPS. À confirmer sur le contrôleur et le modèle exact.' -f (Fn $ioKB 1), (Fn $iops 0)
        }
        else {
            $extraSeconds = ($ioKB - $sheetKB) * 1024 / ($Disk.SequentialMBps * 1e6)
            $iops = [Math]::Floor(1 / (1 / $iops + $extraSeconds))
            $basis += ' Adaptation des transferts : 1 ÷ (1 ÷ IOPS 4 Ko + ({0} − {1}) Ko ÷ {2} Mo/s) = {3} IOPS.' -f (Fn $ioKB 1), (Fn $sheetKB 0), (Fn $Disk.SequentialMBps 0), (Fn $iops 0)
        }
    }
    [pscustomobject]@{ Iops = $iops; Basis = $basis }
}

function Select-TsRaidDisks {
    <# Fewest physical disks; among equal layouts keep the smallest catalogue capacity. #>
    param(
        [Parameter(Mandatory = $true)][object]$Disk,
        [Parameter(Mandatory = $true)][double]$CapacityGB,
        [Parameter(Mandatory = $true)][string]$Raid,
        [double]$ReadIops = 0, [double]$WriteIops = 0,
        [double]$SizeGB = 0, [double]$DiskIops = 0, [double]$IoOverhead = 0, [double]$IoSizeKB = 4
    )
    $sizes = @(if ($SizeGB -gt 0) { $SizeGB } else { $Disk.SizesGB | Sort-Object })
    if (-not $sizes.Count) { throw ('Aucune capacité serveur dans le catalogue pour « {0} ».' -f $Disk.Name) }
    $best = $null; $bestPerformance = $null; $bestModels = @(); $bestSequential = $null
    foreach ($size in $sizes) {
        $candidate = $Disk
        $members = @()
        if ($Disk.Generic) {
            $members = @($Disk.Members | ForEach-Object { Get-TsDiskCatalog -Name $_ } | Where-Object { $_.SizesGB -contains $size })
            if ($members.Count) {
                # The reference's large disk may not exist at this capacity. Keep the slowest actual member.
                $candidate = $Disk.PSObject.Copy()
                $candidate.SequentialMBps = ($members | Measure-Object -Property SequentialMBps -Minimum).Minimum
            }
        }
        $performance = Get-TsDiskPerformance -Disk $candidate -IoSizeKB $IoSizeKB -DiskIops $DiskIops
        if ($Disk.Generic -and $members.Count -and $DiskIops -le 0) {
            $performance.Basis += ' Débit retenu pour {0} Go : {1} Mo/s, modèle le plus lent de la classe dans cette capacité.' -f (Fn $size 0), (Fn $candidate.SequentialMBps 0)
        }
        $layout = Get-TsRaidLayout -CapacityGB $CapacityGB -ReadIops $ReadIops -WriteIops $WriteIops -Raid $Raid -DiskIops $performance.Iops -DiskSizeGB $size -IoOverhead $IoOverhead
        if ($null -eq $best -or $layout.TotalDisks -lt $best.TotalDisks) {
            $best = $layout; $bestPerformance = $performance; $bestModels = @($members | ForEach-Object { $_.Name }); $bestSequential = $candidate.SequentialMBps
        }
    }
    $best | Add-Member -NotePropertyMembers @{
        DiskName = $Disk.Name; IopsBasis = $bestPerformance.Basis; IoSizeKB = $IoSizeKB; Source = $Disk.Source
        Checked = $Disk.Checked; Reference = $Disk.Reference; Models = $bestModels; PerformanceKnown = $bestPerformance.Iops -gt 0; SequentialMBps = $bestSequential
        TooWide = $Raid -eq 'RAID-5' -and $best.TotalDisks -gt 7
    }
    return $best
}
