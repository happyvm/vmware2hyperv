# VMware to Hyper-V migration scripts

This repository contains PowerShell 7 scripts to orchestrate a **VMware → Hyper-V** migration workflow with Veeam backups and SCVMM operations.

All scripts are in the `extracted/` folder, with the main entry point:

- `extracted/run-migration.ps1`
- `extracted/step3-MigrateVM.ps1` now also maps a source `OperatingSystem` value to the matching SCVMM operating system when the CSV and config provide it.

## Project workflow

The migration is split into 3 steps:

1. **step1**: tag VMware resources and create the Veeam backup job.
2. **step2**: stop source VMs, trigger backup, and send pre-migration email.
3. **step3**: perform VM migration to Hyper-V (parallel execution per VM).

The orchestrator can start from any step (`step1`, `step2`, `step3`) to resume after interruption.

## Prerequisites

- PowerShell 7+
- Access to:
  - VMware vCenter
  - Veeam Backup & Replication
  - SCVMM / Hyper-V environment
- Required PowerShell modules available on the execution host (imported by scripts):
  - `VMware.PowerCLI` / `VMware.VimAutomation.Core`
  - `Veeam.Backup.PowerShell`
  - `VirtualMachineManager`

## Configuration

Default configuration is stored in:

- `extracted/config.psd1`

Update at least:

- Infrastructure endpoints (`VCenter`, `SCVMM`, `HyperV`, `Veeam`)
- Tag names (`Tags`)
- SMTP and recipients (`Smtp`, `Recipients`)
- Paths (`Paths`), especially:
  - `CsvFile`: input CSV with `VMName`, `Tag`, and optional `OperatingSystem` columns
  - `LogDir`: logs output directory


### Configure SCVMM operating systems

If your CSV (or CMDB export) contains an `OperatingSystem` column, `step3-MigrateVM.ps1` can normalize that value, map it through `SCVMM.OperatingSystemMap`, and apply the matching SCVMM operating system with `Set-SCVirtualMachine`.

Example configuration in `extracted/config.psd1`, aligned with the mapping currently used in SCVMM:

```powershell
SCVMM = @{
    Server = "scvmm.domain.local"
    Network = @{
        PortClassificationName = "PC_VMNetwork"
        LogicalSwitchName      = "LS_SET_VMNetwork"
    }
    OperatingSystemMap = @{
        "Windows Server 2025 Datacenter"                = "Windows Server 2025 Datacenter"
        "Windows Server 2022 Datacenter Azure Edition"  = "Windows Server 2022 Datacenter"
        "Windows Server 2012 Standard"                  = "64-bit edition of Windows Server 2012 Standard"
        "Windows Server 2008 R2 Enterprise"             = "64-bit edition of Windows Server 2008 R2 Enterprise"
        "Windows Server 2003 R2 Enterprise x64 Edition" = "Windows Server 2003 Enterprise x64 Edition"
        "Red Hat Enterprise Linux ES 7.9"               = "Red Hat Enterprise Linux 7 (64 bit)"
        "Red Hat Enterprise Linux 8.10"                 = "Red Hat Enterprise Linux 8 (64 bit)"
        "Red Hat Enterprise Linux 9.4"                  = "Red Hat Enterprise Linux 9 (64 bit)"
        "CentOS Linux 7"                                = "CentOS Linux 7 (64 bit)"
    }
}
```

The source labels are normalized before lookup (case-insensitive, separators collapsed), so values such as `Windows_Server_2019` and `windows server 2019` resolve to the same mapping key.

## Command usage

Run from repository root (or from `extracted/` by adapting paths).

### Main orchestration command

```powershell
pwsh ./extracted/run-migration.ps1 -Tag HypMig-lot-118
```

### Resume from a specific step

```powershell
pwsh ./extracted/run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step2
pwsh ./extracted/run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3
```

### Override recipient group for pre-migration mail

```powershell
pwsh ./extracted/run-migration.ps1 -Tag HypMig-lot-118 -RecipientGroup internal
```

### Use a custom config file

```powershell
pwsh ./extracted/run-migration.ps1 -Tag HypMig-lot-118 -ConfigFile ./extracted/config.psd1
```

## Useful standalone commands

### Export VMware uptime data to CSV

```powershell
pwsh ./extracted/step0-uptime_extract.ps1
```

Optional parameters:

```powershell
pwsh ./extracted/step0-uptime_extract.ps1 -Tag HypMig-lot-118 -OutputCsvPath D:\Scripts\uptime_vm.csv
```

### Send pre-migration email only

```powershell
pwsh ./extracted/stepx-premigration_mail.ps1 -tagName HypMig-lot-118 -recipientGroup internal
```

## Logs

Each script writes timestamped logs to the path configured in `Paths.LogDir`.

For orchestration runs, a global `run-migration-*.log` file is generated, plus per-VM logs for step3.
