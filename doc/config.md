# config.psd1 — Centralized configuration

PowerShell Data File (`.psd1`) containing all migration settings.

## Synopsis

```powershell
# Direct load (template values only):
$Config = Import-PowerShellDataFile ".\config.psd1"

# Load with local overrides (used by all pipeline scripts):
. .\lib.ps1
$Config = Import-MigrationConfig -ConfigFile ".\config.psd1"
```

## config.psd1 vs config.local.psd1

`config.psd1` is the **versioned template**: it contains all known keys with sample values (`vcenter.domain.local`, `D:\Scripts\...`). Developers update it whenever a script requires a new configuration value.

`config.local.psd1` (next to `config.psd1`, missing by default, never versioned — see `.gitignore`) contains the **real environment values**. `Import-MigrationConfig` (`lib.ps1`) loads `config.psd1`, then merges `config.local.psd1` over it (key by key, recursively) when it exists.

This separation prevents `git pull` from overwriting customized values, and makes it easy to detect when an updated script introduces a new expected key: it appears in `config.psd1` (template) but remains absent from `config.local.psd1` until it has been filled in.

To generate or complete `config.local.psd1` interactively instead of editing it manually, see [configure-migration.ps1](configure-migration.md). It is also triggered automatically by `run-migration.ps1` when no argument is provided.

## Sections

### `VCenter`

```powershell
VCenter = @{
    Server = "vcenter.domain.local"
}
```

### `SCVMM`

```powershell
SCVMM = @{
    Server = "scvmm.domain.local"
    Network = @{
        PortClassificationName = "PC_VMNetwork"
        LogicalSwitchName      = "LS_SET_VMNetwork"
        AllowedVmNetworkNames  = @("VMNetwork-1816", "VMNetwork-2001")
        AllowedVmSubnetNames   = @("Subnet-1816", "Subnet-2001")
    }
    OperatingSystemMap = @{
        "Windows Server 2025 Datacenter"               = "Windows Server 2025 Datacenter"
        "Windows Server 2022 Datacenter Azure Edition" = "Windows Server 2022 Datacenter"
        "Windows Server 2012 Standard"                 = "64-bit edition of Windows Server 2012 Standard"
        "CentOS Linux 7"                               = "CentOS Linux 7 (64 bit)"
        # ...
    }
}
```

The OS mapping is used by `step3-MigrateVM.ps1` to apply the correct SCVMM OS. Source labels are normalized before lookup (case-insensitive, separators, `Microsoft` prefix).

`AllowedVmNetworkNames` / `AllowedVmSubnetNames` limit SCVMM network discovery to configured objects.

### `HyperV`

```powershell
HyperV = @{
    Host1          = "hyperhost-a1.domain"
    Host2          = "hyperhost-a2.domain"
    Cluster        = "HypClusterNameA"
    ClusterStorage = "C:\ClusterStorage\Volume2"
}
```

Default configuration. Can be overridden by `MigrationMappings.ClusterMappings`.

### `MigrationMappings`

```powershell
MigrationMappings = @{
    ClusterMappings = @(
        @{
            VMwareCluster  = "VmwareClusterA"
            HyperVCluster  = "HypClusterNameA"
            Host1          = "hyperhost-a1.domain"
            Host2          = "hyperhost-a2.domain"
            ClusterStorage = "C:\ClusterStorage\Volume2"
        },
        @{
            VMwareCluster  = "VmwareClusterB"
            HyperVCluster  = "HypClusterNameB"
            Host1          = "hyperhost-b1.domain"
            Host2          = "hyperhost-b2.domain"
            ClusterStorage = "C:\ClusterStorage\Volume3"
        }
    )
}
```

Optional multi-cluster mapping. If no mapping matches, the default `HyperV` block is used.

### `Veeam`

```powershell
Veeam = @{
    BackupRepo  = "Backup Repository Name"
    BackupProxy = "ProxyName"  # Optional
}
```

### `Tags`

```powershell
Tags = @{
    Category  = "MigrationLot"
    BackupTag = "BackupTagName"
}
```

### `Smtp`

```powershell
Smtp = @{
    Server  = "smtp.domain.local"
    Port    = 25
    From    = "migration@domain.local"
    Enabled = $true   # $false disables all outgoing email (pre-migration, uptime, etc.)
}
```

### `Recipients`

```powershell
Recipients = @{
    internal  = @("admin@domain.local", "manager@domain.local")
    provider  = @("support@provider.com")
}
```

Recipient groups for email notifications. Used by `step2-ShutdownVM_StartBackupVeeam.ps1` (pre-migration email) via `-RecipientGroup`.

### `Paths`

```powershell
Paths = @{
    CsvFile        = "D:\Scripts\batch.csv"
    CmdbExtractCsv = "D:\Scripts\cmdb_extract.csv"  # Optional
    ExtractIpCsv   = "D:\Scripts\extract-ip.csv"    # Optional
    LogDir         = "D:\Scripts\Logs"
}
```

- `CsvFile`: batch CSV with `VMName` and `Tag`, plus optional `OperatingSystem`, `ExpectedIP`, `IP`, `IPAddress`
- `CmdbExtractCsv`: optional CMDB extract used to enrich VMs with `OperatingSystem`
- `ExtractIpCsv`: optional expected-IP CSV (columns `VMName`/`Name` + `IP`/`IPAddress`/`ExpectedIP`), used by `step4-StartVM.ps1` to validate the guest IP after migration. If missing, this check is simply skipped.

### `Orchestrator`

```powershell
Orchestrator = @{
    Step3MaxParallelJobs      = 5
    Step3JobStartupDelaySec   = 2
    InstantRecoveryStartDelaySec = 2
}
```

### `Precheck`

```powershell
Precheck = @{
    InputCsv            = "D:\Scripts\input.csv"
    WindowsCredentials  = @(
        @{ Label = "ADMIN-01"; UserName = "DOMAIN\admin"; Enabled = $true }
    )
    LinuxCredential     = @{
        Label    = "LINUX-ADMIN-01"
        UserName = "root"
        Enabled  = $true
    }
    UptimeThresholdDays  = 45
}
```

Passwords are never stored — they are requested interactively.

### `IntegrationServices`

```powershell
IntegrationServices = @{
    IsoByOsFamily = @{
        "2003" = "\\server\share\vmguest2003.iso"
        "2008" = "\\server\share\vmguest2008.iso"
    }
}
```

Integration Services ISO paths by OS family.

### `StartVm`

```powershell
StartVm = @{
    IntegrationPollIntervalSeconds = 30
    IntegrationMaxIterations       = 0   # 0 = unlimited
    InventoryBatchThreshold        = 25  # automatic threshold for SCVMM inventory
}
```

Settings for `step4-StartVM.ps1`. `IntegrationMaxIterations = 0` makes the script loop until all VMs are compliant (network, IP, Integration Services, HA, backup tag). Interrupt with Ctrl+C to stop waiting without affecting VMs that were already started. A positive value caps the number of iterations. `InventoryBatchThreshold` automatically selects the SCVMM inventory strategy: lots up to the threshold use targeted name lookups (avoids enumerating all SCVMM VMs), while lots above the threshold use one indexed full inventory pass (avoids too many per-VM calls).

## See also

- [README.md](../README.md) — Complete documentation
- [ADR-001](adr/001-architecture-decisions.md) — Architecture decisions
- [lib.ps1](lib.md) — Functions that use this configuration
