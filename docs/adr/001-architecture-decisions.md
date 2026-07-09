# ADR-001: Architecture decisions for vmware2hyperv migration toolkit

- **Status**: accepted
- **Date**: 2026-07-09
- **Deciders**: vmware2hyperv maintainers
- **Technical story**: BEA-254 documentation review

---

## Context

The vmware2hyperv toolkit orchestrates VMware → Hyper-V migrations using Veeam Backup &
Replication as the transport layer and SCVMM as the target management plane. The project
faces several architectural constraints:

1. **Multi-product orchestration**: PowerShell scripts must interact with three independent
   management surfaces — VMware vCenter (PowerCLI), Veeam Backup & Replication
   (Veeam.Backup.PowerShell), and SCVMM (VirtualMachineManager).

2. **Module compatibility**: Veeam.Backup.PowerShell and VirtualMachineManager are
   Windows PowerShell 5.1 modules. Loading them directly into PowerShell 7 triggers
   .NET type-initializer errors (e.g. `Microsoft.VirtualManager.Utils.TraceProviders.IndigoLayer`).

3. **Batch parallelism**: Step 3 must migrate dozens of VMs concurrently while
   maintaining per-VM audit trails and supporting partial resumption after failures.

4. **Operational resumption**: Operators need to restart from any pipeline step
   after interruptions without re-running completed work.

---

## Decisions

### Decision 1: Three-step pipeline with step-level resumption

**What**: The migration is split into three discrete steps (step1 → step2 → step3),
each executable independently via `run-migration.ps1 -StartFrom {step1|step2|step3}`.

**Why**:
- Each step gates on the previous one's success (tagging → backup → recovery).
- Operators can resume from any step after transient failures.
- Step-level isolation keeps scripts focused and testable.
- The `-ForceNetworkConfigOnly` switch further decomposes step3 for SCVMM-only replays.

**Alternatives considered**:
- Single monolithic script → rejected: impossible to resume, hard to test, high blast radius.
- DAG-based task runner (e.g. PSFramework orchestration) → rejected: over-engineered for
  a linear pipeline; adds dependency complexity.

**Consequences**:
- Scripts must be idempotent. All step scripts check for pre-existing work before acting
  (e.g. step1 skips already-tagged VMs, step2 skips already-shut-down VMs).
- Configuration is shared via a single `config.psd1` imported at the top of each script.

---

### Decision 2: File-system queue with persistent workers for step3 parallelism

**What**: Step 3 uses a file-system queue (pending/processing/done/failed directories)
with N persistent `worker-step3.ps1` processes, rather than PowerShell Jobs, `ForEach-Object -Parallel`,
or Runspace pools.

**Why**:
- **Resilience**: If the orchestrator or a worker crashes, the file-system queue preserves
  state. Surviving workers continue processing; the orchestrator can resume by re-launching
  missing workers.
- **Auditability**: Each VM's task file is a permanent record of its migration attempt.
  Failed tasks can be inspected and re-enqueued manually.
- **Process isolation**: A crash in one worker (e.g. Veeam COM object corruption) does
  not take down other migrations.
- **Simpler than IPC**: No need for shared memory, synchronized hashtables, or IPC protocols.
  The file system is the message broker.

**Alternatives considered**:
- `Start-Job` / `Start-ThreadJob` → rejected: jobs are ephemeral; they don't survive a
  PowerShell session restart. State recovery after a crash is impossible.
- `ForEach-Object -Parallel` (PS 7) → rejected: single-process parallelism; a module crash
  in one thread can corrupt the entire runspace. No cross-runspace recovery.
- Message queue (RabbitMQ, MSMQ) → rejected: adds infrastructure dependency; file-system
  queue is zero-dependency and works on any Windows or Linux runner.
- Runspace pool with synchronized collection → rejected: complex state management;
  file-system queue is simpler and naturally durable.

**Consequences**:
- Queue directories must be writable by all worker processes.
- The `dispatch.complete` flag file signals the orchestrator that all tasks have been
  dispatched and all workers are idle.
- Workers are launched as separate `pwsh` processes via the orchestrator (not Start-Job).

---

### Decision 3: Three-tier module import strategy for PS7 compatibility

**What**: When running in PowerShell 7, scripts use a three-tier import strategy for
Windows-only management modules:

1. **Windows PowerShell compatibility session first** — for known-broken modules
   (`VirtualMachineManager`, `Veeam.Backup.PowerShell`, `FailoverClusters`). This avoids
   the type-initializer errors that occur when these modules load directly into PS7.
2. **`Import-Module -SkipEditionCheck` fallback** — when the compatibility session itself
   fails (e.g. on non-Windows runners or missing WinPS remoting)
3. **Direct import** — for modules that are PS7-compatible (e.g. VMware.PowerCLI,
   Hyper-V via compatibility)

This strategy is implemented in `Get-ModuleImportStrategies` (lib.ps1) and consumed by
`Import-RequiredModule`.

**Why**:
- Veeam and SCVMM modules are not PS7-native and will not be ported in the migration
  project's timeframe.
- Loading them directly into PS7 causes cryptic .NET type-initializer failures that are
  hard to debug.
- The compatibility session provides a stable bridge without requiring operators to
  switch between PS7 and Windows PowerShell manually.

**Alternatives considered**:
- Stay on Windows PowerShell 5.1 entirely → rejected: PS7 offers significant performance
  improvements for VMware PowerCLI operations and cross-platform scripting.
- Require operators to run different steps in different PowerShell versions → rejected:
  brittle, error-prone, and confusing in operational runbooks.
- Rewrite Veeam/SCVMM interactions to use REST APIs instead of PowerShell modules →
  rejected: Veeam and SCVMM REST APIs are incomplete and poorly documented; the PowerShell
  modules are the supported integration path.

**Consequences**:
- `$script:WindowsOnlyManagementModules` must be kept in sync with module compatibility
  testing results.
- On non-Windows runners, compatibility sessions are unavailable; scripts must handle
  this gracefully (fall back to `-SkipEditionCheck` with clear error messages).
- Auto-installation of missing modules (VMware.PowerCLI via `Install-Module`) is attempted
  before the import strategy is applied.

---

### Decision 4: Multi-cluster target mapping with fallback to default

**What**: `MigrationMappings.ClusterMappings` in config.psd1 maps VMware source clusters
to Hyper-V target clusters, hosts, and storage. If no mapping matches, scripts fall back
to the default `HyperV` configuration block.

**Why**:
- Large VMware estates often have multiple clusters that need to map to different
  Hyper-V clusters (e.g. prod → prod cluster, dev → dev cluster).
- Single-cluster configurations (the common case) should not require any mappings to work.
- The fallback ensures backward compatibility: existing config.psd1 files without
  `MigrationMappings` continue to work unchanged.

**Alternatives considered**:
- Separate config file per cluster pair → rejected: fragments configuration across
  multiple files; hard to track which mappings are active.
- DNS-based auto-discovery → rejected: DNS does not encode the semantic mapping
  between VMware and Hyper-V clusters.

**Consequences**:
- `Resolve-MigrationTarget` (lib.ps1) is the single function responsible for target
  resolution. All migration scripts use it rather than reading `$Config.HyperV` directly.

---

### Decision 5: VLAN resolution pipeline (VDS → Standard → ExtensionData → fallback)

**What**: The VLAN ID for a VM is resolved through a multi-layer pipeline:

1. Distributed Virtual Switch `VlanId` property
2. `VlanConfiguration` regex parsing (trunked VLANs)
3. Standard PortGroup network name matching
4. `ExtensionData.Config.Hardware.Device` backing info
5. Fallback: return the port group name as-is with a warning

**Why**:
- VMware environments vary widely in how VLANs are configured (VDS vs. standard switches,
  single vs. trunked VLANs, explicit vs. implicit tagging).
- A single resolution strategy fails silently in many real-world configurations.
- The layered approach tries the most specific/reliable method first and degrades
  gracefully through less reliable methods.

**Alternatives considered**:
- Require VLAN ID in the CSV → rejected: operators often don't know the VLAN ID at CSV
  creation time; it's environment-specific.
- Single VDS-only resolution → rejected: many environments still use standard switches.

**Consequences**:
- The resolution adds latency proportional to the number of port groups (sequential
  lookups through extension data).
- VLAN resolution failures produce clear warnings so operators can manually intervene.

---

## Related

- [README.md](../README.md) — project overview and workflow diagrams
- [config.psd1](../powershell-migration/config.psd1) — configuration reference
- [lib.ps1](../powershell-migration/lib.ps1) — shared function library
- [AUDIT-2026-07-09.md](../AUDIT-2026-07-09.md) — initial code and quality audit