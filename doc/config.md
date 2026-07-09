# config.psd1 — Configuration centralisée

Fichier de configuration PowerShell Data File (`.psd1`) contenant tous les paramètres de la migration.

## Synopsis

```powershell
$Config = Import-PowerShellDataFile ".\config.psd1"
```

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

Le mapping OS est utilisé par `step3-MigrateVM.ps1` pour appliquer le bon OS SCVMM. Les labels source sont normalisés avant lookup (case-insensitive, séparateurs, préfixe `Microsoft`).

`AllowedVmNetworkNames` / `AllowedVmSubnetNames` limitent la découverte réseau SCVMM aux objets configurés.

### `HyperV`

```powershell
HyperV = @{
    Host1          = "hyperhost-a1.domain"
    Host2          = "hyperhost-a2.domain"
    Cluster        = "HypClusterNameA"
    ClusterStorage = "C:\ClusterStorage\Volume2"
}
```

Configuration par défaut. Peut être surchargée par `MigrationMappings.ClusterMappings`.

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

Mapping optionnel multi-cluster. Si aucun mapping ne correspond, le bloc `HyperV` par défaut est utilisé.

### `Veeam`

```powershell
Veeam = @{
    BackupRepo  = "Backup Repository Name"
    BackupProxy = "ProxyName"  # Optionnel
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
    Enabled = $true   # $false désactive l'envoi de tous les emails (pré-migration, uptime...)
}
```

### `Recipients`

```powershell
Recipients = @{
    internal  = @("admin@domain.local", "manager@domain.local")
    provider  = @("support@provider.com")
}
```

Groupes de destinataires pour les emails. Utilisé par `step2-ShutdownVM_StartBackupVeeam.ps1` (email pré-migration) via `-RecipientGroup`.

### `Paths`

```powershell
Paths = @{
    CsvFile        = "D:\Scripts\lotissement.csv"
    CmdbExtractCsv = "D:\Scripts\cmdb_extract.csv"  # Optionnel
    ExtractIpCsv   = "D:\Scripts\extract-ip.csv"
    LogDir         = "D:\Scripts\Logs"
}
```

- `CsvFile` : CSV batch avec `VMName` et `Tag`, plus optionnel `OperatingSystem`, `ExpectedIP`, `IP`, `IPAddress`
- `CmdbExtractCsv` : extrait CMDB optionnel pour enrichir les VMs avec `OperatingSystem`

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

Les mots de passe ne sont jamais stockés — demandés interactivement.

### `IntegrationServices`

```powershell
IntegrationServices = @{
    IsoByOsFamily = @{
        "2003" = "\\server\share\vmguest2003.iso"
        "2008" = "\\server\share\vmguest2008.iso"
    }
}
```

Chemins des ISO Integration Services par famille d'OS.

### `StartVm`

```powershell
StartVm = @{
    IntegrationPollIntervalSeconds = 30
    IntegrationMaxIterations       = 10
}
```

Réglages pour `step5-StartVM.ps1`.

## Voir aussi

- [README.md](../README.md) — Documentation complète
- [ADR-001](adr/001-architecture-decisions.md) — Décisions d'architecture
- [lib.ps1](lib.md) — Fonctions utilisant cette config