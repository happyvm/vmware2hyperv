# step4-StartVM.ps1 — VM startup and post-migration validation

Starts migrated VMs and loops until they are fully compliant.

## Synopsis

```powershell
.\step4-StartVM.ps1 -Tag HypMig-lot-118
.\step4-StartVM.ps1 -Tag HypMig-lot-118 -IntegrationMaxIterations 20
.\step4-StartVM.ps1 `
    -Tag HypMig-lot-118 `
    -RequireExpectedIp `
    -IntegrationMaxIterations 20
```

## Description

Automatically run by [run-migration.ps1](run-migration.md) after the manual validation pause that follows step3. It can also be rerun standalone, or through `run-migration.ps1 -StartFrom step4`.

This script automatically uses the lowest-cost SCVMM inventory strategy for the lot size (targeted lookups for small lots, indexed full inventory for large lots) and combines in one pass what used to be split between VM startup and a separate post-migration validation step (`step5-PostMigrationChecks.ps1`, removed). It:

- Starts VMs listed in the batch CSV in a single SCVMM session (`Start-SCVirtualMachine`), instead of opening one session per VM
- Attempts WinRM (HTTPS, then HTTP) on Windows Server 2012+ to upload and run the VMware Tools removal script; for older OS versions (2003/2008), or when WinRM fails, it reports a manual action
- Loops until each VM is **compliant**, meaning:
  - it is started and its network adapter is connected
  - its guest IPv4 address matches the expected IP (`Paths.ExtractIpCsv`, when available, or strictly when `-RequireExpectedIp` is used)
  - Integration Services are operational (heartbeat, time sync, data exchange, guest agent)
  - SCVMM High Availability is enabled
  - the post-migration backup tag (`Tags.BackupTag`) is present
- By default the loop is **unlimited** (`-IntegrationMaxIterations 0`): it continues until full compliance or manual interruption (Ctrl+C). VMs that were already started are not affected by the interruption. A positive value caps the number of iterations; in that case, the script exits with code 2 if any VM remains non-compliant at the end.

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ConfigFile` | string | `config.psd1` | Configuration file |
| `-CsvFile` | string | `Config.Paths.CsvFile` | Batch CSV |
| `-ExtractIpCsvFile` | string | `Config.Paths.ExtractIpCsv` | Expected-IP CSV. Missing file is ignored by default and blocking with `-RequireExpectedIp`. |
| `-RequireExpectedIp` | switch | `$false` | Strict mode: missing CSV, missing VM entry, or invalid expected IPv4 leaves the VM non-compliant (missing CSV exits immediately). |
| `-Tag` | string | — | Tag used to filter VMs |
| `-LogFile` | string | auto-generated | Log file |
| `-IntegrationPollIntervalSeconds` | int | `30` | Interval between compliance checks |
| `-IntegrationMaxIterations` | int | `0` | Maximum iterations (`0` = unlimited) |
| `-WinRmRetryDelaySeconds` | int | `15` | Delay between WinRM attempts |
| `-WinRmMaxAttempts` | int | `20` | Maximum WinRM attempts |

## Execution flow

```
For each VM in the CSV (filtered by Tag):
├─ Retrieve SCVMM inventory in batch (state, configured OS, network, HA, tag, IP)
├─ Start non-running VMs in batch (Start-SCVirtualMachine)
├─ If OS ≥ 2012:
│  ├─ Try WinRM HTTPS, then HTTP
│  ├─ Upload and run the VMware Tools removal script
│  └─ If WinRM is unavailable → report a manual action
├─ If OS < 2012 or unknown → report a manual action
└─ Compliance loop (until IntegrationMaxIterations, or unlimited when 0):
   ├─ Started + connected NIC + expected IP + Integration Services OK + HA + backup tag
   └─ Remove the VM from the tracking table as soon as it is compliant
```

## Expected IP validation

By default, step4 remains backward compatible: if `extract-ip.csv` is missing, it logs a warning and skips expected-IP validation; if a VM has no expected IP row, validation is skipped for that VM. With `-RequireExpectedIp`, the CSV must exist and each VM in the lot must have a valid IPv4 expected address. Missing or invalid expected IPs are reported as static configuration errors and are not retried as if SCVMM could fix them.

The CSV parser trims VM names and IP values, accepts the existing VM-name and IP column variants, stores VM keys case-insensitively, and accepts only syntactically valid IPv4 addresses. IPv6 and malformed values generate warnings that include the VM name, invalid IP value, and CSV path.

SCVMM-reported addresses are normalized before comparison: each value is converted to text, trimmed, deduplicated, and validated as IPv4. APIPA addresses (`169.254.0.0/16`) are kept in diagnostics but are never considered a match for a normal expected IP. The comparison is exact (`10.0.0.1` does not match `10.0.0.10`).

The IP status is explicit in logs and the summary CSV via `ExpectedIP`, `CurrentIPs`, `IPMatches`, `IPValidationStatus`, and `IPValidationDetails`. Possible statuses are `Matched`, `Mismatch`, `MissingExpectedIP`, `InvalidExpectedIP`, `ValidationSkipped`, and `NoGuestIPReported`.

To avoid stale SCVMM guest-IP data without overloading large batches, each poll uses the normal inventory path. Every fifth poll, only VMs still failing due to `Mismatch` or `NoGuestIPReported` are force-refreshed with `Read-SCVirtualMachine -Force`. Static configuration failures such as `MissingExpectedIP` and `InvalidExpectedIP` are not force-refreshed.

## Dashboard

At each iteration, the script refreshes only VMs that are still non-compliant. Depending on `StartVm.InventoryBatchThreshold`, it uses either targeted name lookups or an indexed full SCVMM inventory, then displays the remaining non-compliant VMs with their issues (`NIC not connected`, `unexpected IP`, `Integration Services not OK`, `HA not enabled`, `backup tag missing`, `not started`).

## Output summary

A `step4-startvm-summary-{yyyyMMdd-HHmmss}.csv` file is exported to `Paths.LogDir`, with one `Compliant` column per VM and details for each criterion (network, IP, Integration Services, HA, backup tag). The IP columns include at least `ExpectedIP`, `CurrentIPs`, `IPMatches`, `IPValidationStatus`, and `IPValidationDetails`.

## Logs

```
{LogDir}/step4-startvm{-Tag}-{yyyyMMdd-HHmmss}.log
{LogDir}/step4-startvm-summary-{yyyyMMdd-HHmmss}.csv
```

## Dependencies

- `lib.ps1`
- `config.psd1` — sections `SCVMM`, `Tags`, `Paths`, `RemoteActions`, `StartVm`
- `VirtualMachineManager` module

## See also

- [run-migration.ps1](run-migration.md) — Orchestrator, runs this step after step3
- [step6-CleanupVmware.ps1](step6-CleanupVmware.md) — VMware cleanup
