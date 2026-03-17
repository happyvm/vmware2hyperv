# VMware to Hyper-V migration scripts

This repository contains PowerShell 7 scripts to orchestrate a **VMware → Hyper-V** migration workflow with Veeam backups and SCVMM operations.

All scripts are in the `extracted/` folder, with the main entry point:

- `extracted/run-migration.ps1`

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
  - `CsvFile`: input CSV with `VMName` and `Tag` columns
  - `LogDir`: logs output directory

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
