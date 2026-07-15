# scripts — Utility Scripts

Two standalone PowerShell scripts for validating infrastructure readiness before and during a VMware → Hyper-V migration.

---

## Test-HyperVNodeReadiness.ps1

**Purpose:** Validate that a Windows Server machine meets all prerequisites to become a Hyper-V node and/or failover cluster member (WS 2022 / WS 2025).

Run this script **on each target Hyper-V host** before migration. It performs 13 check sections and produces a timestamped log and an optional HTML report.

### Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Domain Administrator or delegated account with read access to AD ACLs
- Must be run **locally on the node** being evaluated

### Configuration

Copy `hyperv-check.psd1` next to the script and fill in your environment values. The two required fields are:

| Field | Values | Description |
|-------|--------|-------------|
| `Mode` | `PreNode` / `PreCluster` / `Both` | Scope of checks to run |
| `StorageType` | `SAN` / `S2D` | Shared SAN (iSCSI/FC) or Storage Spaces Direct |

All other fields are optional and trigger additional checks when provided (cluster nodes, AD OU, DNS zone, infrastructure endpoints, NIC roles, security requirements, etc.).

If no config file is found, the script enters **interactive mode** and prompts for each value.

### Usage

```powershell
# Use the config file placed next to the script (recommended)
.\Test-HyperVNodeReadiness.ps1

# Explicit config file path
.\Test-HyperVNodeReadiness.ps1 -ConfigFile C:\Admin\hyperv-check.psd1

# Interactive mode (no config file needed)
.\Test-HyperVNodeReadiness.ps1
```

### Checks performed

| Section | What is validated |
|---------|-------------------|
| **A — OS** | Edition (Datacenter/Standard), build (WS2022/2025), pending reboot, Windows Update |
| **B — Platform security** | Secure Boot, TPM, BitLocker, VBS/Credential Guard, HVCI |
| **C — Hardware** | CPU virtualization (VT-x/AMD-V), SLAT, DEP, RAM sizing, logical processors |
| **D — Network** | NIC roles, static IPs, MTU/Jumbo frames, RDMA, SMB Direct, VMQ, RSS, PFC/DCB, IPv6 consistency, LBFO deprecation, DNS/gateway, WinRM |
| **E — Active Directory** | Domain membership, DC reachability, computer account, SPN, Live Migration Kerberos delegation, CredSSP |
| **F — DNS** | Forward/reverse resolution, AD SRV records, dynamic update |
| **G — Time sync** | W32TM status, Kerberos clock skew < 5 minutes |
| **H — Firewall** | Cluster/SMB/Live-Migration rules, critical TCP ports |
| **I — Storage** | SAN: MPIO, iSCSI/FC initiator, disk state, disk visibility across nodes — S2D: eligible drives, RDMA NICs, drive tiers |
| **J — Failover cluster** | Quorum, cross-node OS/domain/hotfix consistency, `Test-Cluster` validation, network segregation |
| **K — Service account** | Account enabled, local admin, AD OU permissions (CreateChild, Write All Properties), DNS scavenging, CNO/VCO pre-staging |
| **L — Event log health** | Last 24 h critical errors in System/Application, disk/storage drivers, network drivers, Hyper-V VMMS, Failover Clustering |
| **M — Port connectivity** | TCP/UDP reachability to DC, cluster nodes, witness, iSCSI targets, SCVMM |

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All checks passed (warnings are non-blocking) |
| `1` | One or more checks failed |

---

## Test-VeeamFlows.ps1

**Purpose:** Validate outbound network flows required by Veeam Backup & Replication 12.3 from the current machine, based on its role in the Veeam infrastructure.

Run this script **on each Veeam/infrastructure server** to confirm that required TCP/UDP ports are open before starting backup or migration operations.

### Requirements

- PowerShell 5.1 or PowerShell 7+
- No additional modules needed — uses only built-in `Test-NetConnection`

### Usage

```powershell
# Interactive: the script prompts for role and required endpoints
.\Test-VeeamFlows.ps1

# Non-interactive from a Hyper-V host
.\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ProxyServer px01 `
    -HyperVHosts hv02,hv03 -ExportCSV C:\Temp\flows.csv

# VBR server also acting as integrated proxy (VMware source → Hyper-V target)
.\Test-VeeamFlows.ps1 -Role VBRProxy -VCenterServer vcenter01 `
    -ESXiHosts esxi01,esxi02 -HyperVHosts hv01,hv02,hv03 `
    -SCVMMServer scvmm01 -SQLServer sql01

# Continuous mode — reruns every 2 minutes until Ctrl+C
.\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ContinuousIntervalMinutes 2
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Role` | No* | Machine role: `VBR`, `VBRProxy`, `Proxy`, `SCVMM`, `HyperV`. Prompted interactively if omitted. |
| `-VBRServer` | Role-dependent | FQDN or IP of the VBR server |
| `-ProxyServer` | Role-dependent | FQDN or IP of the off-host Veeam proxy |
| `-HyperVHosts` | Role-dependent | Array of Hyper-V host FQDNs or IPs |
| `-SCVMMServer` | Role-dependent | FQDN or IP of the SCVMM server |
| `-VCenterServer` | Role-dependent | FQDN or IP of vCenter (source VMware) |
| `-ESXiHosts` | Optional | Array of ESXi host FQDNs or IPs (needed for NBD/port 902 test in VBRProxy mode) |
| `-SQLServer` | Optional | FQDN or IP of the SQL Server instance |
| `-ExportCSV` | Optional | Path to write results as CSV |
| `-ContinuousIntervalMinutes` | Optional | Re-run interval in minutes (runs once if omitted) |

### Roles and flows tested

| Role | Outbound flows validated |
|------|--------------------------|
| **VBR** | vCenter (443, 80), Hyper-V hosts (135, 445, 5985/86, 6160-6163, 2500-3300, 6600), SCVMM (135, 445, 5985/86, 8100/01), ESXi (443, 902), SQL (1433, 1434), Proxy (2500-3300) |
| **VBRProxy** | Same as VBR minus separate proxy, plus ESXi NBD channel |
| **Proxy** | VBR server (2500-3300, 9401), Hyper-V hosts (135, 445, 5985/86, 6160-6163) |
| **SCVMM** | VBR (9392/9393), Hyper-V hosts (135, 445, 5985/86), SQL (1433, 1434) |
| **HyperV** | VBR (2500-3300, 6160-6163), Proxy (2500-3300), other Hyper-V hosts (6600 Live Migration) |

DNS resolution is tested for all target endpoints regardless of role.

### Output

Results are printed to the console with status (`OK`, `FAIL`), port, and measured latency for successful connections. Use `-ExportCSV` to save results for audit purposes.

---

## Configure-SCVMMWSUS.ps1

**Purpose:** Configure the products, classifications, and languages synchronized by a WSUS server integrated with SCVMM.

Use this script from an administrative shell on a server that has the SCVMM PowerShell module installed. By default, it replaces the existing WSUS selection with the recommended Hyper-V / SCVMM baseline; use `-AddOnly` to keep existing selections and add the recommended ones.

### Requirements

- Windows PowerShell 5.1
- Administrator shell
- SCVMM PowerShell module (`VirtualMachineManager`)
- A WSUS server already integrated with SCVMM

### Usage

```powershell
# Review the intended WSUS selection first
.\Configure-SCVMMWSUS.ps1 `
    -VMMServer scvmm01.contoso.local `
    -WSUSServer wsus01.contoso.local `
    -SCVMMVersion Both `
    -WhatIf

# Add the recommended products/classifications/languages without removing existing selections
.\Configure-SCVMMWSUS.ps1 `
    -VMMServer scvmm01.contoso.local `
    -SCVMMVersion 2025 `
    -AddOnly `
    -ForceFullCatalogImport
```

### Key parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-VMMServer` | Yes | SCVMM server that references the WSUS server |
| `-WSUSServer` | No* | WSUS server to configure; required when SCVMM has more than one integrated WSUS server |
| `-SCVMMVersion` | Yes | `None`, `2022`, `2025`, or `Both` |
| `-Languages` | No | WSUS language codes to synchronize; defaults to `en`, `fr` |
| `-AddOnly` | No | Preserve existing selections and append the recommended baseline |
| `-NoSynchronization` | No | Apply settings without starting WSUS synchronization |
| `-ForceFullCatalogImport` | No | Start synchronization with a full catalog import |

## Invoke-SCVMMHostPatchBaseline.ps1

**Purpose:** Automate the SCVMM-managed Hyper-V patching cycle from a scheduled task: synchronize the WSUS catalog managed by SCVMM, refresh a patch baseline, assign it to Hyper-V hosts, scan compliance in parallel, remediate hosts with SCVMM maintenance mode and Live Migration, then re-scan and report each host's final compliance state.

Run this script from an administrative shell or a Windows scheduled task on a management server with the SCVMM PowerShell module installed. By default, hosts are remediated one by one to preserve cluster capacity while SCVMM live-migrates workloads away from the host being patched.

Behavior designed for unattended runs:

- every step is timestamped on the console and, with `-LogFile`, appended to a log file (an unwritable path degrades to console-only with a single warning);
- a host whose compliance scan fails is excluded from remediation and counted as failed;
- a typo in `-VMHostNames` aborts the run instead of silently skipping the host;
- exit code `0` means no host failed, `1` means at least one host failed (or a fatal error occurred) — wire this into the scheduled task result monitoring.

### Requirements

- Windows PowerShell 5.1
- Administrator shell / scheduled task account with SCVMM rights to manage updates and hosts
- SCVMM PowerShell module (`VirtualMachineManager`)
- A WSUS server already integrated with SCVMM
- Hyper-V hosts managed by SCVMM, preferably clustered for Live Migration-based evacuation

### Usage

```powershell
# Dry run before creating the scheduled task
.\Invoke-SCVMMHostPatchBaseline.ps1 `
    -VMMServer scvmm01.contoso.local `
    -BaselineName 'Hyper-V Monthly Security Baseline' `
    -HostGroupName 'All Hosts\Production\Hyper-V' `
    -WhatIf

# Command line suitable for a Windows scheduled task action
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-SCVMMHostPatchBaseline.ps1 `
    -VMMServer scvmm01.contoso.local `
    -BaselineName 'Hyper-V Monthly Security Baseline' `
    -HostGroupName 'All Hosts\Production\Hyper-V' `
    -LogFile 'C:\Logs\HyperV-Patching.log' `
    -ContinueOnHostFailure

# Limit the maintenance window to selected hosts
.\Invoke-SCVMMHostPatchBaseline.ps1 `
    -VMMServer scvmm01.contoso.local `
    -BaselineName 'Hyper-V Monthly Security Baseline' `
    -HostGroupName 'All Hosts\Production\Hyper-V' `
    -VMHostNames hv01.contoso.local,hv02.contoso.local
```

### Key parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-VMMServer` | Yes | SCVMM server to connect to |
| `-BaselineName` | Yes | Baseline to create or refresh with current update candidates |
| `-HostGroupName` | Yes | SCVMM host group containing the Hyper-V hosts to patch |
| `-VMHostNames` | No | Optional allow-list of Hyper-V hosts to process |
| `-UpdateClassifications` | No | WSUS/SCVMM classifications to include; defaults to security, critical, rollup, and updates |
| `-IncludeUpdateTitleRegex` | No | Optional regex to keep only matching update titles |
| `-ExcludeUpdateTitleRegex` | No | Regex to exclude update titles; defaults to previews, language packs, and feature updates |
| `-LogFile` | No | Timestamped log file, recommended for scheduled runs |
| `-PollIntervalSeconds` | No | SCVMM job polling interval; defaults to 30 seconds |
| `-SkipSynchronization` | No | Reuse the existing catalog without starting WSUS synchronization |
| `-SkipRemediation` | No | Refresh baseline and scan compliance only, without patching hosts |
| `-SkipFinalComplianceScan` | No | Skip the post-remediation compliance re-scan and final state report |
| `-ContinueOnHostFailure` | No | Keep patching the remaining hosts when one host's remediation fails (sequential mode); failures still drive a failure exit code |
| `-ParallelRemediation` | No | Cluster-aware parallel remediation: hosts from different clusters run at the same time; within one cluster, batches honor the two limits below |
| `-MaxParallelHostsPerCluster` | No | Maximum simultaneous hosts per cluster in parallel mode (default 2) |
| `-MinimumClusterAvailableResourcePercent` | No | Minimum share of the whole cluster's capacity (all active members known to VMM) that must stay available during a batch (default 50). When the threshold cannot be met even with one host (single-node cluster), the script proceeds host by host with a warning |
| `-DismountIso` | No | Automatically eject ISO/host-drive media attached to running VMs before remediating their host — the classic Live Migration blocker. Without it, attached media are only reported as warnings |
| `-CentreonOutput` | No | Suppress console logs and emit a final Nagios/Centreon plugin line with perfdata; exit codes switch to plugin convention (see below) |

### Live Migration pre-checks

Right before remediation (on refreshed host data), each host goes through Live Migration
pre-checks. Blocking findings exclude the host from remediation and count as failures:
unreachable/degraded host, VMM agent not ready, host already in maintenance mode.
Non-blocking findings are logged as warnings: non-clustered host (VMs go to saved state,
no Live Migration), running non-highly-available VMs, and DVD media attached to running
VMs (fixable automatically with `-DismountIso`).

### Centreon integration

With `-CentreonOutput`, the script behaves as a Nagios/Centreon plugin: console logs are
suppressed (use `-LogFile` to keep them), the last stdout line is the plugin output with
perfdata (`targeted`, `remediated`, `failed`, `warnings`, `duration_min`), and the exit
code follows the plugin convention: `0`=OK, `1`=WARNING (cycle completed with warnings,
e.g. hosts still non-compliant after remediation), `2`=CRITICAL (host failure or fatal
error), `3`=UNKNOWN (baseline creation declined).

A patching cycle runs for hours, so do not wire it as a regular active check with a short
timeout. Recommended patterns:

- run the script from the Windows scheduled task with `-CentreonOutput 1> C:\Logs\patching.status`
  and have a lightweight Centreon check read that file (parse the leading `OK|WARNING|CRITICAL|UNKNOWN`
  token and alert on stale files), or
- submit the plugin line and exit code as a passive check result to Centreon at the end of the run.


---

## New-SCVMMContentLibrary.ps1

**Purpose:** Create or validate a SCVMM content library SMB share by copying NTFS and SMB permissions from an existing library share, then optionally registering the new share in SCVMM.

Run this script from an administrative shell with access to the source and destination file servers. Use `-WhatIf` before applying changes in production.

### Requirements

- Windows PowerShell 5.1
- Administrator shell
- SMB PowerShell cmdlets on the management host
- PowerShell Remoting / CIM access to source and destination file servers
- SCVMM PowerShell module (`VirtualMachineManager`) unless `-SkipVMMRegistration` is used

### Usage

```powershell
# Review the planned library creation and SCVMM registration
.\New-SCVMMContentLibrary.ps1 `
    -VMMServer scvmm01.contoso.local `
    -SourceLibraryShare \\lib01\MSSCVMMLibrary `
    -DestinationLibraryServer lib02.contoso.local `
    -DestinationLocalPath D:\SCVMM\ContentLibrary `
    -DestinationShareName SCVMMContentLibrary `
    -WhatIf

# Prepare the SMB share only, without registering it in SCVMM
.\New-SCVMMContentLibrary.ps1 `
    -VMMServer scvmm01.contoso.local `
    -SourceLibraryShare \\lib01\MSSCVMMLibrary `
    -DestinationLibraryServer lib02.contoso.local `
    -DestinationLocalPath D:\SCVMM\ContentLibrary `
    -DestinationShareName SCVMMContentLibrary `
    -SkipVMMRegistration
```

### Key parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-VMMServer` | Yes | SCVMM server used for library registration |
| `-SourceLibraryShare` | Yes | Existing UNC share used as the NTFS/SMB permission source |
| `-DestinationLibraryServer` | Yes | File server that will host the destination share |
| `-DestinationLocalPath` | Yes | Local folder path on the destination file server |
| `-DestinationShareName` | Yes | SMB share name to create or validate |
| `-ChildFolders` | No | Child folders to ensure under the library root; defaults to `ISO`, `Template` |
| `-CopyNtfsPermissions` | No | Copy the source root DACL to the destination root; defaults to `$true` |
| `-CopySmbPermissions` | No | Replace destination SMB permissions with source SMB permissions; defaults to `$true` |
| `-AddLibraryServerIfMissing` | No | Add the destination file server as a SCVMM Library Server if needed |
| `-SkipVMMRegistration` | No | Create/validate SMB resources only, without SCVMM registration |
