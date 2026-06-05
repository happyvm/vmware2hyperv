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
