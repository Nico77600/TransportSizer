<#
    Transport Sizer - reference data.
    Author  : Nicolas Fabert
    Version : 1.10.0

    Every constant used by the engine lives here, with its source. Nothing in this file is a sizing
    result: CPU, memory and IOPS come from a calibration profile measured on a real server.
#>
@{
    SchemaVersion = 1

    Sources       = @{
        BackPressure       = 'Microsoft Learn - Understanding back pressure (Exchange 2016, 2019, SE), default values of EdgeTransport.exe.config'
        SystemRequirements = 'Microsoft Learn - Exchange Server 2019 and Subscription Edition system requirements'
        Virtualization     = 'Microsoft Learn - Exchange Server virtualization (hypervisor overhead)'
        Calculator         = 'Exchange Server Role Requirements Calculator 10.7 (sheets Variables, Tables, Storage Design, Role Requirements)'
        Lab                = 'Lab reference lab, REF-EDGE (Azure D2s_v5) and REF-MAILBOX, Exchange 2019: Get-TransportService, EdgeTransport.exe.config, folder sizes (2026-10-05)'
    }

    # Back pressure: LowToMedium thresholds (%), the level where Exchange starts rejecting mail.
    BackPressure  = @{
        DatabaseUsedSpace    = 96     # drive of mail.que
        UsedDiskSpaceQueue   = 89     # drive of the queue transaction logs
        UsedDiskSpaceData    = 89     # drive of TransportRoles\data (content conversion)
        PrivateBytes         = 72     # EdgeTransport.exe private bytes / physical memory
        SystemMemory         = 88     # memory used by all processes / physical memory
        CheckpointDepthMaxMB = 384    # DatabaseCheckPointDepthMax (also measured on REF-EDGE)
        LogReserveFactor     = 3      # high level of UsedDiskSpace keeps 3 x 384 MB = 1152 MB free
    }

    Exchange      = @{
        RecommendedMemoryGB   = @{ Edge = 64; Mailbox = 128 }   # information only, never a result
        MaxMemoryGB           = 256
        MaxCores              = 48
        PagefilePercent       = 25
        InstallFreeSpaceGB    = 30
        SystemFreeSpaceGB     = 0.2
        QueueFreeSpaceGB      = 0.5
        MaxQueueDatabaseGB    = 2000   # calculator, varMaxTransportDBSize
        DesignReadLatencyMs   = 20
        DesignWriteLatencyMs  = 10
        HypervisorOverheadPct = 10
        # Exchange Server supportability matrix: Exchange Server SE runs on Windows Server 2025, 2022 or 2019, Standard or
        # Datacenter; Server Core is the recommended installation option.
        OperatingSystem       = 'Windows Server 2025, 2022 ou 2019 (Standard ou Datacenter), installation Server Core recommandée'
    }

    # Virtualization of the transport servers (processor model of the engine).
    Virtualization = @{
        # Microsoft: a ratio of virtual processors to physical cores of 2:1 at most is supported, 1:1 recommended
        # (Exchange Server virtualization). Default: the most that is supported, the usual practice on shared clusters.
        DefaultVcpuRatio = 2
        MaxSupportedVcpuRatio = 2
        # Gain of hyper-threading on the SPEC CPU2017 integer rate: 5 systems measured with and without SMT (same
        # system, same cores) give 1.03 to 1.22, median 1.20 (spec.org, rint2017 results, October 2026).
        SmtGainPercent = 20
    }

    # Role Requirements Calculator 10.7, used for the comparison only.
    Calculator    = @{
        MessageQueueRate  = 0.5      # Variables!K56 'Percentage of Messages Queued'
        ShadowFactor      = 2        # Role Requirements!C187 'Shadow Effect'
        MaxCpuUtilization = 0.8      # Variables!B67
        MinOsVolumeGB     = 300      # Variables!K55
        IoOverhead        = 0.2
        SpecToMegacycles  = 547.08   # 2000 / 33.75 / 0.10832 (Role Requirements!C163)
    }

    # Lab measurements (REF-EDGE, Exchange 2019, quiet server).
    Lab           = @{
        EmptyMailQueGB         = 0.5    # mail.que = 503.9 MB
        TransportLogsEdgeGB    = 3.25   # sum of the *MaxDirectorySize of Get-TransportService REF-EDGE
        OtherTransportDataGB   = 0.04   # IpFilter + SenderReputation + Temp
        DatabaseMaxCacheSizeMB = 512
    }

    Raid          = @{
        'RAID-1'   = @{ WritePenalty = 2; RebuildOverhead = 0.35; Parity = 0; Mirror = $true }
        'RAID-1/0' = @{ WritePenalty = 2; RebuildOverhead = 0.35; Parity = 0; Mirror = $true }
        'RAID-5'   = @{ WritePenalty = 4; RebuildOverhead = 0.50; Parity = 1; Mirror = $false }
        'RAID-6'   = @{ WritePenalty = 6; RebuildOverhead = 0.50; Parity = 2; Mirror = $false }
    }

    # Manufacturer data shared with Mailbox Sizer; transport transfer sizes come from the calibration.
    Storage       = @{
        DatasheetIoKB   = 4
        ServerMinimumGB = @{ NearlineHdd = 8000; Ssd = 900 }
    }

    MemorySizesGB = @(8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512)
}
