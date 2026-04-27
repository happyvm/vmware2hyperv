# VMware to Hyper-V migration scripts

This repository contains PowerShell 7 scripts to orchestrate a **VMware → Hyper-V** migration workflow with Veeam backups and SCVMM operations.

All migration scripts are in the `powershell-migration/` folder, with the main entry point:

- `powershell-migration/run-migration.ps1`
- `powershell-migration/step3-MigrateVM.ps1` also maps a source `OperatingSystem` value to the matching SCVMM operating system when the batch CSV or CMDB extract provides it.

## Project workflow

The migration is split into 3 steps:

1. **step1**: tag VMware resources and create the Veeam backup job.
2. **step2**: stop source VMs, trigger backup, and send pre-migration email.
3. **step3**: perform VM migration to Hyper-V (parallel execution per VM).

The orchestrator can start from any step (`step1`, `step2`, `step3`) to resume after interruption.
If `step3` already restored the VM but failed during SCVMM network/OS/post-configuration, you can replay only that tail of `step3` with `-ForceNetworkConfigOnly`.

## Prerequisites

- PowerShell 7+
- Access to:
  - VMware vCenter
  - Veeam Backup & Replication
  - SCVMM / Hyper-V environment
- Required PowerShell modules available on the execution host (imported by scripts):
  - `VMware.PowerCLI` or `VCF.PowerCLI` (auto-detected) / `VMware.VimAutomation.Core`
  - `Veeam.Backup.PowerShell`
  - `VirtualMachineManager`
  - Hyper-V management cmdlets (`Hyper-V` module / RSAT Hyper-V tools on Windows hosts used for Live Migration)

> Notes:
> - If `VMware.PowerCLI`/`VCF.PowerCLI` is missing, scripts now attempt automatic installation in `CurrentUser` scope before failing.
> - During migration validation, scripts try to install/enable RSAT Hyper-V management tooling automatically when `Move-VM` is unavailable.

### Bootstrap PowerShell on Ubuntu

If `pwsh` is not available yet on your runner/host, install it with:

```bash
./scripts/install-powershell.sh
```

The script is idempotent: if PowerShell is already installed, it exits without changes.

## Configuration

Default configuration is stored in:

- `powershell-migration/config.psd1`

Update at least:

- Infrastructure endpoints (`VCenter`, `SCVMM`, `HyperV`, `Veeam`)
- Tag names (`Tags`)
- SMTP and recipients (`Smtp`, `Recipients`)
- Paths (`Paths`), especially:
  - `CsvFile`: input CSV with `VMName` and `Tag` columns, plus optional `OperatingSystem`
  - `CmdbExtractCsv`: optional CMDB extract CSV path used to enrich VMs with `OperatingSystem` values by matching `VMName`/`Name`
  - `LogDir`: logs output directory


### Configure SCVMM operating systems

If your batch CSV contains an `OperatingSystem` column, or your CMDB extract contains `OperatingSystem` / `Operating system` alongside `VMName` / `Name`, `step3-MigrateVM.ps1` can normalize that value, map it through `SCVMM.OperatingSystemMap`, and apply the matching SCVMM operating system with `Set-SCVirtualMachine`.

Example configuration in `powershell-migration/config.psd1`, aligned with the mapping currently used in SCVMM:

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

When `AllowedVmNetworkNames` / `AllowedVmSubnetNames` are configured, step3 limits SCVMM network discovery to those objects instead of parsing the full SCVMM inventory.

The source labels are normalized before lookup (case-insensitive, separators collapsed, and a leading `Microsoft` vendor prefix removed), so values such as `Windows_Server_2019`, `windows server 2019`, and `Microsoft Windows Server 2019` resolve to the same mapping key.

## Command usage

Run from repository root (or from `powershell-migration/` by adapting paths).

### Main orchestration command

```powershell
pwsh ./powershell-migration/run-migration.ps1 -Tag HypMig-lot-118
```

### Resume from a specific step

```powershell
pwsh ./powershell-migration/run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step2
pwsh ./powershell-migration/run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3
pwsh ./powershell-migration/run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3 -ForceNetworkConfigOnly
```

### Override recipient group for pre-migration mail

```powershell
pwsh ./powershell-migration/run-migration.ps1 -Tag HypMig-lot-118 -RecipientGroup internal
```

### Use a custom config file

```powershell
pwsh ./powershell-migration/run-migration.ps1 -Tag HypMig-lot-118 -ConfigFile ./powershell-migration/config.psd1
```

## Useful standalone commands

### Export VMware uptime data to CSV

```powershell
pwsh ./powershell-migration/step0-uptime_extract.ps1
```

Optional parameters:

```powershell
pwsh ./powershell-migration/step0-uptime_extract.ps1 -Tag HypMig-lot-118 -OutputCsvPath D:\Scripts\uptime_vm.csv
```

### Send pre-migration email only

```powershell
pwsh ./powershell-migration/stepx-premigration_mail.ps1 -tagName HypMig-lot-118 -recipientGroup internal
```


### Post-migration companion checks (SCVMM)

Run this script in parallel with `run-migration.ps1` (or just after) to loop until all VMs in the CSV are compliant on SCVMM:

- VM exists and is running
- NIC is connected
- Integration Services appear healthy
- High Availability is enabled in SCVMM
- SCVMM backup tag is present (`Tags.BackupTag`)
- guest IPv4 still matches the expected IP from CSV (`ExpectedIP` / `IP` / `IPAddress` columns)

```powershell
pwsh ./powershell-migration/step-XX-PostMigrationChecks.ps1 -Tag HypMig-lot-118
```

Useful options:

```powershell
pwsh ./powershell-migration/step-XX-PostMigrationChecks.ps1 -Tag HypMig-lot-118 -PollIntervalSeconds 120 -MaxIterations 30
pwsh ./powershell-migration/step-XX-PostMigrationChecks.ps1 -CsvFile D:\Scripts\lotissement.csv
```

`-MaxIterations 0` means infinite loop until every VM is compliant.

### Start migrated VMs + Integration Services / VMware Tools actions

Use `step-XX-StartVM.ps1` to:

- start each VM from `lotissement.csv` (optionally filtered by `-Tag`);
- list VM state + SCVMM configured operating system;
- mount an Integration Services ISO for Windows Server 2003/2008 (paths from `IntegrationServices.IsoByOsFamily` in config);
- try WinRM HTTPS then HTTP on Windows Server 2012+ VMs to upload and execute a VMware Tools removal script;
- loop on Integration Services health checks (SCVMM signals) until ready or timeout.

```powershell
pwsh ./powershell-migration/step-XX-StartVM.ps1 -Tag HypMig-lot-118
```

If OS is below 2012, or WinRM is unavailable for 2012+, the script reports that integration/manual cleanup actions must be done by hand.
You can tune integration checks with `StartVm.IntegrationPollIntervalSeconds` and `StartVm.IntegrationMaxIterations` in config (or via script parameters).

## Logs

Each script writes timestamped logs to the path configured in `Paths.LogDir`.

For orchestration runs, a global `run-migration-*.log` file is generated, plus per-VM logs for step3.

## Tests

Run Pester tests from repository root:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests"
```
