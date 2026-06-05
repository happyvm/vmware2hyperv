#Requires -Version 5.1
<#
.SYNOPSIS
    Validate OS readiness for a future Hyper-V node (WS2022/2025) and/or failover cluster.

.DESCRIPTION
    Runs a comprehensive set of checks derived from Microsoft documentation:
      A. OS edition (Datacenter/Standard) and build — targets WS2022 and WS2025 only
      B. Hardware: CPU virtualization, SLAT, DEP, RAM, Hyper-V/Failover-Clustering features
      C. Network: NIC count, static IPs, RDMA (S2D), DNS, WinRM
      D. Active Directory: domain membership, DC reachability, computer account, SPN, CredSSP
      E. DNS: forward/reverse resolution, AD SRV records, dynamic update
      F. Time synchronization (W32TM, Kerberos < 5 minutes)
      G. Firewall: cluster/SMB/Live-Migration rules and critical TCP ports
      H. Storage — mode-specific:
            SAN : MPIO required, iSCSI/FC initiator, disk visibility across nodes
            S2D : Datacenter edition, physical disks eligible, bus type, no shared SAS,
                  RDMA NICs, SMB Direct, drive tier inventory
      I. Failover Cluster: quorum recommendation, cross-node OS/domain consistency,
         Test-Cluster validation, network segregation
      J. Service account & OU AD permissions:
            account exists and is enabled, local admin on this node,
            CreateChild (computer) on target OU, Write All Properties on computer objects,
            CreateChild (dnsNode) on DNS zone, prestaged CNO/VCO check

    Modes:
      PreNode     — Validate this machine as a standalone Hyper-V host
      PreCluster  — Validate this machine and remote nodes for failover clustering
      Both        — Run all checks (default)

    Exit codes:
      0 = All checks passed (or only warnings)
      1 = One or more checks failed

.PARAMETER Mode
    Validation scope: PreNode | PreCluster | Both

.PARAMETER StorageType
    Storage architecture: SAN | S2D
    SAN = external shared storage via iSCSI or Fibre Channel (MPIO required)
    S2D = Storage Spaces Direct, internal disks only, Datacenter edition required

.PARAMETER ClusterNodes
    FQDNs or IPs of the other cluster nodes. This local node is always included.

.PARAMETER WitnessShare
    UNC path of the file share witness (e.g. \\fileserver\witness). Optional but
    required for even-node clusters to validate quorum.

.PARAMETER ServiceAccount
    SAMAccountName of the service/admin account that will create the cluster
    (e.g. svc_cluster or CORP\svc_cluster). Used in section J.

.PARAMETER ClusterOU
    Distinguished Name of the OU where cluster objects (CNO, VCOs) will be created
    (e.g. OU=Clusters,OU=Servers,DC=corp,DC=local). Used in section J.

.PARAMETER ClusterName
    Planned NetBIOS name of the cluster (e.g. CLHYPERV01). If provided, the script
    checks for a prestaged CNO and validates its state. Used in section J.

.PARAMETER LogFile
    Path for the text log file. Defaults to .\HyperV-Readiness-<timestamp>.log.

.PARAMETER HtmlReportPath
    If provided, an HTML summary report is written to this path.

.PARAMETER SkipClusterValidation
    Skip the long-running Test-Cluster cmdlet during PreCluster checks.

.EXAMPLE
    # Validate a single node against SAN storage
    .\Test-HyperVNodeReadiness.ps1 -Mode PreNode -StorageType SAN `
        -ServiceAccount svc_cluster -ClusterOU "OU=Clusters,DC=corp,DC=local"

.EXAMPLE
    # Full 3-node S2D cluster validation with HTML report
    .\Test-HyperVNodeReadiness.ps1 -Mode Both -StorageType S2D `
        -ClusterNodes node2.corp.local,node3.corp.local `
        -ServiceAccount CORP\svc_cluster `
        -ClusterOU "OU=HyperV,OU=Servers,DC=corp,DC=local" `
        -ClusterName CLHYPERV01 `
        -WitnessShare \\fs01\clusterwitness `
        -HtmlReportPath C:\Reports\readiness.html

.NOTES
    Must be run as Domain Administrator or delegated account with read access to AD ACLs.
    References:
      - https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/system-requirements-for-hyper-v-on-windows
      - https://learn.microsoft.com/en-us/windows-server/failover-clustering/clustering-requirements
      - https://learn.microsoft.com/en-us/windows-server/failover-clustering/manage-cluster-quorum
      - https://learn.microsoft.com/en-us/windows-server/failover-clustering/configure-ad-accounts
      - https://learn.microsoft.com/en-us/azure-stack/hci/concepts/storage-spaces-direct-overview
#>

[CmdletBinding()]
param(
    [ValidateSet('PreNode', 'PreCluster', 'Both')]
    [string]$Mode = 'Both',

    [ValidateSet('SAN', 'S2D')]
    [string]$StorageType = 'SAN',

    [string[]]$ClusterNodes = @(),

    [string]$WitnessShare = '',

    [string]$ServiceAccount = '',

    [string]$ClusterOU = '',

    [string]$ClusterName = '',

    [string]$LogFile = ".\HyperV-Readiness-$(Get-Date -Format 'yyyyMMdd-HHmmss').log",

    [string]$HtmlReportPath = '',

    [switch]$SkipClusterValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ────────────────────────────────────────────────────────────

$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'FAIL', 'SECTION')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = switch ($Level) {
        'OK'      { '[  OK  ]' }
        'WARN'    { '[ WARN ]' }
        'FAIL'    { '[ FAIL ]' }
        'SECTION' { '[======]' }
        default   { '[ INFO ]' }
    }
    $line = "$ts $prefix $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    $color = switch ($Level) {
        'OK'      { 'Green' }
        'WARN'    { 'Yellow' }
        'FAIL'    { 'Red' }
        'SECTION' { 'Cyan' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Add-Result {
    param(
        [string]$Category,
        [string]$Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO', 'SKIP')]
        [string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Category = $Category
        Check    = $Check
        Status   = $Status
        Detail   = $Detail
    })
    $logLevel = switch ($Status) {
        'PASS' { 'OK' }
        'WARN' { 'WARN' }
        'FAIL' { 'FAIL' }
        'SKIP' { 'INFO' }
        default { 'INFO' }
    }
    Write-Log "$Check — $Detail" -Level $logLevel
}

function Section([string]$Title) {
    Write-Log '' -Level INFO
    Write-Log "──── $Title ────" -Level SECTION
}

#endregion

#region ── A. OS Compatibility ────────────────────────────────────────────────

function Test-OSCompatibility {
    Section 'A. OS Compatibility'
    $cat = 'OS'

    $os      = Get-CimInstance -ClassName Win32_OperatingSystem
    $caption = $os.Caption
    $build   = [int]$os.BuildNumber
    $arch    = $os.OSArchitecture

    Add-Result $cat 'OS Caption' 'INFO' $caption

    # 64-bit
    if ($arch -match '64') {
        Add-Result $cat 'Architecture 64-bit' 'PASS' $arch
    } else {
        Add-Result $cat 'Architecture 64-bit' 'FAIL' "Found: $arch — Hyper-V requires 64-bit"
    }

    # Target: WS2022 (build 20348) or WS2025 (build 26100+)
    # https://learn.microsoft.com/en-us/windows-server/get-started/windows-server-release-info
    $isWS2022 = $build -ge 20348 -and $build -lt 26100
    $isWS2025 = $build -ge 26100
    if ($isWS2022) {
        Add-Result $cat 'OS version (WS2022/2025 target)' 'PASS' "Windows Server 2022 — build $build"
    } elseif ($isWS2025) {
        Add-Result $cat 'OS version (WS2022/2025 target)' 'PASS' "Windows Server 2025 — build $build"
    } elseif ($build -ge 14393) {
        Add-Result $cat 'OS version (WS2022/2025 target)' 'WARN' "Build $build is supported by Hyper-V but not the targeted WS2022/2025 — upgrade recommended"
    } else {
        Add-Result $cat 'OS version (WS2022/2025 target)' 'FAIL' "Build $build < 14393 — Windows Server 2016 is the absolute minimum"
    }

    # Edition check
    $isDatacenter = $caption -match 'Datacenter'
    $isStandard   = $caption -match 'Standard'
    if ($isDatacenter) {
        Add-Result $cat 'OS edition' 'PASS' "Datacenter — full Hyper-V + S2D support"
    } elseif ($isStandard) {
        if ($StorageType -eq 'S2D') {
            Add-Result $cat 'OS edition' 'FAIL' "Standard edition detected — Storage Spaces Direct (S2D) requires Datacenter edition"
        } else {
            Add-Result $cat 'OS edition' 'PASS' "Standard — note: limited to 2 running Hyper-V VMs (Datacenter recommended for production)"
        }
    } elseif ($caption -match 'Server') {
        Add-Result $cat 'OS edition' 'WARN' "Unrecognized Server edition: $caption"
    } else {
        Add-Result $cat 'OS edition' 'FAIL' "$caption is not a Windows Server edition"
    }

    # Pending reboot
    $pendingReboot  = $false
    $rebootReasons  = @()
    $cbsPath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $wuPath   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
    $pfroPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

    if (Test-Path "$cbsPath\RebootPending")  { $pendingReboot = $true; $rebootReasons += 'CBS' }
    if (Test-Path "$wuPath\RebootRequired")  { $pendingReboot = $true; $rebootReasons += 'Windows Update' }
    try {
        $pfro = Get-ItemProperty $pfroPath -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($pfro -and $pfro.PendingFileRenameOperations) { $pendingReboot = $true; $rebootReasons += 'PendingFileRename' }
    } catch {}

    if ($pendingReboot) {
        Add-Result $cat 'No pending reboot' 'FAIL' "Reboot required ($($rebootReasons -join ', ')) — must reboot before installing Hyper-V / Failover-Clustering"
    } else {
        Add-Result $cat 'No pending reboot' 'PASS' 'No reboot pending'
    }

    # Windows Update — last successful search
    try {
        $wu        = New-Object -ComObject Microsoft.Update.AutoUpdate
        $lastSearch = $wu.Results.LastSearchSuccessDate
        if ($null -eq $lastSearch) {
            Add-Result $cat 'Windows Update last search' 'WARN' 'No recorded search — verify critical updates are applied'
        } else {
            $daysAgo = (New-TimeSpan -Start $lastSearch -End (Get-Date)).Days
            $level   = if ($daysAgo -gt 30) { 'WARN' } else { 'PASS' }
            Add-Result $cat 'Windows Update last search' $level "Last search: $($lastSearch.ToString('yyyy-MM-dd')) ($daysAgo days ago)"
        }
    } catch {
        Add-Result $cat 'Windows Update last search' 'SKIP' 'COM object unavailable (Server Core or non-interactive context)'
    }
}

#endregion

#region ── B. Hardware & Virtualization Support ───────────────────────────────

function Test-HardwareRequirements {
    Section 'B. Hardware & Virtualization Support'
    $cat = 'Hardware'

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    Add-Result $cat 'Server model' 'INFO' "Manufacturer: $($cs.Manufacturer), Model: $($cs.Model)"

    # RAM — 4 GB minimum, 32 GB+ for production Hyper-V, 64 GB+ recommended for S2D
    $ramGB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $ramWarnGB = if ($StorageType -eq 'S2D') { 64 } else { 32 }
    if ($ramGB -lt 4) {
        Add-Result $cat 'RAM (minimum 4 GB)' 'FAIL' "${ramGB} GB installed — minimum 4 GB required"
    } elseif ($ramGB -lt $ramWarnGB) {
        Add-Result $cat 'RAM (minimum 4 GB)' 'WARN' "${ramGB} GB installed — ${ramWarnGB} GB+ recommended for production $StorageType"
    } else {
        Add-Result $cat 'RAM (minimum 4 GB)' 'PASS' "${ramGB} GB installed"
    }

    # CPU count / logical processors
    $procs     = @(Get-CimInstance -ClassName Win32_Processor)
    $logCores  = ($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    Add-Result $cat 'Logical processors' 'INFO' "$($procs.Count) socket(s), $logCores logical core(s)"

    # Virtualization features
    try {
        $vtEnabled   = $false
        $slatSupport = $false
        $depEnabled  = $false
        foreach ($proc in $procs) {
            if ($proc.VirtualizationFirmwareEnabled)     { $vtEnabled   = $true }
            if ($proc.DataExecutionPrevention_Available) { $depEnabled  = $true }
            if ($proc.PSObject.Properties['SecondLevelAddressTranslationExtensions'] -and
                $proc.SecondLevelAddressTranslationExtensions) { $slatSupport = $true }
        }
        $vtStatus = if ($vtEnabled)   { 'PASS' } else { 'FAIL' }
        $depStatus= if ($depEnabled)  { 'PASS' } else { 'FAIL' }
        $slatStatus=if ($slatSupport) { 'PASS' } else { 'WARN' }
        Add-Result $cat 'Hardware virtualization (VT-x/AMD-V) enabled in BIOS'   $vtStatus   $(if ($vtEnabled)   { 'VirtualizationFirmwareEnabled = True' } else { 'False — enable in BIOS/UEFI' })
        Add-Result $cat 'Hardware DEP/NX'                                          $depStatus  $(if ($depEnabled)  { 'Available' } else { 'Not available — required for Hyper-V' })
        Add-Result $cat 'SLAT (Intel EPT / AMD RVI)'                               $slatStatus $(if ($slatSupport) { 'Supported' } else { 'Not reported via WMI — verify CPU datasheet' })
    } catch {
        Add-Result $cat 'Processor virtualization features' 'WARN' "WMI query failed: $_"
    }

    # Windows features via ServerManager
    try {
        Import-Module ServerManager -ErrorAction Stop
        foreach ($feat in @('Hyper-V', 'Failover-Clustering', 'Hyper-V-Tools', 'RSAT-Clustering')) {
            $f = Get-WindowsFeature -Name $feat -ErrorAction SilentlyContinue
            if ($f) {
                $level = switch ($f.InstallState) {
                    'Installed' { 'PASS' }
                    'Available' { 'PASS' }
                    default     { 'WARN' }
                }
                Add-Result $cat "Feature: $feat" $level "State: $($f.InstallState)"
            }
        }
        if ($StorageType -eq 'S2D') {
            $dataDedup = Get-WindowsFeature -Name 'FS-Data-Deduplication' -ErrorAction SilentlyContinue
            if ($dataDedup) {
                $level = if ($dataDedup.InstallState -eq 'Installed') { 'PASS' } else { 'INFO' }
                Add-Result $cat 'Feature: FS-Data-Deduplication (optional, S2D)' $level "State: $($dataDedup.InstallState)"
            }
        }
    } catch {
        Add-Result $cat 'Windows features' 'SKIP' "ServerManager module unavailable: $_"
    }
}

#endregion

#region ── C. Network Configuration ──────────────────────────────────────────

function Test-NetworkConfiguration {
    Section 'C. Network Configuration'
    $cat = 'Network'

    $adapters     = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    $adapterCount = $adapters.Count

    # S2D requires RDMA NICs — minimum 2 dedicated 10 GbE+ for SMB Direct
    $minNics = if ($StorageType -eq 'S2D') { 4 } else { 2 }
    $nicLevel= if ($adapterCount -ge $minNics) { 'PASS' } elseif ($adapterCount -ge 2) { 'WARN' } else { 'FAIL' }
    Add-Result $cat "NIC count (minimum $minNics for $StorageType)" $nicLevel "$adapterCount active NIC(s)"

    foreach ($nic in $adapters) {
        $ipCfg = Get-NetIPConfiguration -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $ipCfg) { continue }

        $ipv4 = $ipCfg.IPv4Address
        if (-not $ipv4) {
            Add-Result $cat "NIC '$($nic.Name)' IPv4" 'WARN' 'No IPv4 address — expected on cluster traffic NICs'
            continue
        }

        $addr   = $ipv4.IPAddress
        $prefix = $ipv4.PrefixLength

        # Static IP required on all cluster nodes
        $dhcp = (Get-NetIPInterface -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4).Dhcp -eq 'Enabled'
        if ($dhcp) {
            Add-Result $cat "NIC '$($nic.Name)' static IP" 'FAIL' "IP $addr/$prefix via DHCP — all cluster NIC IPs must be static"
        } else {
            Add-Result $cat "NIC '$($nic.Name)' static IP" 'PASS' "$addr/$prefix"
        }

        # Link speed
        $speedGbps = [math]::Round($nic.LinkSpeed / 1000000000, 0)
        if ($StorageType -eq 'S2D' -and $speedGbps -lt 10) {
            Add-Result $cat "NIC '$($nic.Name)' link speed" 'FAIL' "${speedGbps} Gbps — S2D requires minimum 10 GbE (25 GbE+ recommended)"
        } elseif ($speedGbps -lt 1) {
            Add-Result $cat "NIC '$($nic.Name)' link speed" 'WARN' "${speedGbps} Gbps — low speed for cluster traffic"
        } else {
            Add-Result $cat "NIC '$($nic.Name)' link speed" 'INFO' "${speedGbps} Gbps"
        }

        # DNS servers configured
        $dns = $ipCfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 }
        if ($dns -and $dns.ServerAddresses) {
            Add-Result $cat "NIC '$($nic.Name)' DNS servers" 'PASS' ($dns.ServerAddresses -join ', ')
        }

        # Default gateway — record for multi-gateway warning
        if ($ipCfg.IPv4DefaultGateway) {
            Add-Result $cat "NIC '$($nic.Name)' gateway" 'INFO' $ipCfg.IPv4DefaultGateway.NextHop
        }
    }

    # RDMA (required for S2D SMB Direct, strongly recommended otherwise)
    try {
        $rdmaAdapters = @(Get-NetAdapterRDMA -ErrorAction Stop | Where-Object { $_.Enabled })
        if ($StorageType -eq 'S2D') {
            if ($rdmaAdapters.Count -ge 2) {
                Add-Result $cat 'RDMA adapters (S2D SMB Direct)' 'PASS' "$($rdmaAdapters.Count) RDMA-enabled NIC(s): $($rdmaAdapters.Name -join ', ')"
            } elseif ($rdmaAdapters.Count -eq 1) {
                Add-Result $cat 'RDMA adapters (S2D SMB Direct)' 'WARN' "Only 1 RDMA NIC — minimum 2 recommended for redundant SMB Direct (S2D)"
            } else {
                Add-Result $cat 'RDMA adapters (S2D SMB Direct)' 'WARN' "No RDMA-enabled NICs — SMB Direct / RDMA strongly recommended for S2D performance"
            }
        } else {
            $rdmaInfo = if ($rdmaAdapters.Count -gt 0) { "$($rdmaAdapters.Count) RDMA NIC(s) — beneficial for Live Migration" } else { 'None detected' }
            Add-Result $cat 'RDMA adapters' 'INFO' $rdmaInfo
        }
    } catch {
        Add-Result $cat 'RDMA adapters' 'SKIP' "Get-NetAdapterRDMA failed: $_"
    }

    # SMB Direct (required for S2D maximum performance)
    if ($StorageType -eq 'S2D') {
        try {
            $smbDirect = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMBDirect
            $level = if ($smbDirect) { 'PASS' } else { 'WARN' }
            Add-Result $cat 'SMB Direct (S2D)' $level "EnableSMBDirect = $smbDirect"
        } catch {
            Add-Result $cat 'SMB Direct (S2D)' 'SKIP' "SmbServerConfiguration unavailable: $_"
        }
    }

    # Multiple default gateways
    $allGateways = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if ($allGateways.Count -gt 1) {
        Add-Result $cat 'Multiple default gateways' 'WARN' "$($allGateways.Count) default routes — verify asymmetric routing does not break cluster heartbeat"
    }

    # DNS suffix
    $dnsSuffix    = (Get-DnsClientGlobalSetting).SuffixSearchList
    $domainSuffix = (Get-CimInstance Win32_ComputerSystem).Domain
    $allSuffixes  = (@($dnsSuffix) + @($domainSuffix) | Select-Object -Unique | Where-Object { $_ }) -join ', '
    if ($allSuffixes) {
        Add-Result $cat 'DNS suffix search list' 'PASS' $allSuffixes
    } else {
        Add-Result $cat 'DNS suffix search list' 'WARN' 'No DNS suffix — FQDN resolution for cluster objects may fail'
    }

    # WinRM
    $winrm = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    $level = if ($winrm -and $winrm.Status -eq 'Running') { 'PASS' } else { 'WARN' }
    Add-Result $cat 'WinRM service' $level $(if ($winrm) { $winrm.Status } else { 'Not found' })
}

#endregion

#region ── D. Active Directory ───────────────────────────────────────────────

function Test-ActiveDirectory {
    Section 'D. Active Directory'
    $cat = 'ActiveDirectory'

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem

    if (-not $cs.PartOfDomain) {
        Add-Result $cat 'Domain membership' 'FAIL' "Not domain-joined — all cluster nodes must be in the same AD domain"
        return
    }
    Add-Result $cat 'Domain membership' 'PASS' "Member of: $($cs.Domain)"

    # AD connectivity
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        Add-Result $cat 'AD domain reachable' 'PASS' "Domain: $($domain.Name), Forest: $($domain.Forest.Name)"
        Add-Result $cat 'AD domain functional level' 'INFO' $domain.DomainMode.ToString()
    } catch {
        Add-Result $cat 'AD domain reachable' 'FAIL' "LDAP bind failed: $_"
        return
    }

    # Writable DC
    try {
        $dc = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().FindDomainController()
        Add-Result $cat 'Writable domain controller reachable' 'PASS' "DC: $($dc.Name)"
    } catch {
        Add-Result $cat 'Writable domain controller reachable' 'FAIL' "Cannot locate writable DC: $_"
    }

    # Computer account exists
    try {
        $searcher = [adsisearcher]"(&(objectCategory=computer)(name=$($env:COMPUTERNAME)))"
        $searcher.PropertiesToLoad.AddRange([string[]]@('distinguishedname', 'serviceprincipalname', 'operatingsystem'))
        $result = $searcher.FindOne()
        if ($result) {
            $dn   = $result.Properties['distinguishedname'][0]
            $osprop = $result.Properties['operatingsystem']
            Add-Result $cat 'Computer account in AD' 'PASS' $dn
            if ($osprop) { Add-Result $cat 'Computer AD OS attribute' 'INFO' $osprop[0] }

            # HOST SPN
            $spns     = $result.Properties['serviceprincipalname']
            $hostSpns = $spns | Where-Object { $_ -match '^HOST/' }
            if ($hostSpns) {
                Add-Result $cat 'HOST SPN registered' 'PASS' ($hostSpns -join '; ')
            } else {
                Add-Result $cat 'HOST SPN registered' 'WARN' 'No HOST SPN — may cause Kerberos failures for cluster communications'
            }
        } else {
            Add-Result $cat 'Computer account in AD' 'FAIL' "Computer object '$($env:COMPUTERNAME)' not found in AD"
        }
    } catch {
        Add-Result $cat 'Computer account in AD' 'WARN' "ADSI query failed: $_"
    }

    # CredSSP (required for Kerberos delegation in Live Migration)
    try {
        $credSSP = Get-WSManCredSSP -ErrorAction SilentlyContinue
        if ($credSSP -and $credSSP[0] -match 'enabled') {
            Add-Result $cat 'CredSSP delegation (Live Migration)' 'PASS' 'Client-side CredSSP enabled'
        } else {
            Add-Result $cat 'CredSSP delegation (Live Migration)' 'WARN' 'CredSSP not enabled — configure if using Kerberos-based Live Migration'
        }
    } catch {
        Add-Result $cat 'CredSSP delegation (Live Migration)' 'SKIP' 'WSMan query unavailable'
    }
}

#endregion

#region ── E. DNS Resolution ──────────────────────────────────────────────────

function Test-DNSResolution {
    Section 'E. DNS Resolution'
    $cat = 'DNS'

    $fqdn = [System.Net.Dns]::GetHostEntry('').HostName

    # Forward resolution — own FQDN
    try {
        $ips = ([System.Net.Dns]::GetHostAddresses($fqdn) | ForEach-Object { $_.ToString() }) -join ', '
        Add-Result $cat "Forward DNS: $fqdn" 'PASS' "-> $ips"
    } catch {
        Add-Result $cat "Forward DNS: $fqdn" 'FAIL' "Cannot resolve own FQDN — $_"
    }

    # Reverse (PTR) for each NIC IP
    $nicIPs = @(Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -ne 'Loopback Pseudo-Interface 1' })
    foreach ($nicIP in $nicIPs) {
        $ip = $nicIP.IPAddress
        try {
            $ptr = [System.Net.Dns]::GetHostEntry($ip)
            Add-Result $cat "Reverse DNS (PTR): $ip" 'PASS' "-> $($ptr.HostName)"
        } catch {
            Add-Result $cat "Reverse DNS (PTR): $ip" 'WARN' "No PTR record — cluster CNO name registration may fail for this IP"
        }
    }

    # AD DNS SRV records
    $domainName = (Get-CimInstance Win32_ComputerSystem).Domain
    if ($domainName -and $domainName -ne 'WORKGROUP') {
        foreach ($srv in @("_ldap._tcp.$domainName", "_kerberos._tcp.$domainName", "_ldap._tcp.dc._msdcs.$domainName")) {
            try {
                $r = Resolve-DnsName -Name $srv -Type SRV -ErrorAction Stop
                Add-Result $cat "AD SRV: $srv" 'PASS' "$($r.Count) record(s)"
            } catch {
                Add-Result $cat "AD SRV: $srv" 'FAIL' "Not found — AD DNS misconfigured"
            }
        }

        # SOA — verify zone exists and dynamic updates are possible
        try {
            $soa = Resolve-DnsName -Name $domainName -Type SOA -ErrorAction Stop
            Add-Result $cat "DNS SOA: $domainName" 'PASS' "Primary NS: $($soa[0].PrimaryServer)"
        } catch {
            Add-Result $cat "DNS SOA: $domainName" 'WARN' "SOA query failed — verify DNS zone allows dynamic updates (required for CNO registration)"
        }
    }
}

#endregion

#region ── F. Time Synchronization ───────────────────────────────────────────

function Test-TimeSync {
    Section 'F. Time Synchronization'
    $cat = 'TimeSync'

    $w32tm = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    if (-not $w32tm -or $w32tm.Status -ne 'Running') {
        Add-Result $cat 'Windows Time service (W32TM)' 'FAIL' "Status: $($w32tm.Status) — run: w32tm /config /syncfromflags:domhier /update && net start W32Time"
        return
    }
    Add-Result $cat 'Windows Time service (W32TM)' 'PASS' 'Running'

    try {
        $src = (& w32tm /query /source 2>&1) -join ''
        Add-Result $cat 'NTP source' 'INFO' $src
    } catch {
        Add-Result $cat 'NTP source' 'WARN' "w32tm /query /source failed: $_"
    }

    try {
        $status     = & w32tm /query /status 2>&1
        $offsetLine = $status | Where-Object { $_ -match 'offset|décalage' } | Select-Object -First 1
        if ($offsetLine -and $offsetLine -match '([+-]?\d+[\.,]\d+)\s*s') {
            $offsetSec = [math]::Abs([double]($Matches[1] -replace ',', '.'))
            if ($offsetSec -lt 60) {
                Add-Result $cat 'Time offset vs DC (Kerberos limit: 300s)' 'PASS' "${offsetSec}s"
            } elseif ($offsetSec -lt 300) {
                Add-Result $cat 'Time offset vs DC (Kerberos limit: 300s)' 'WARN' "${offsetSec}s — approaching Kerberos 5-minute limit"
            } else {
                Add-Result $cat 'Time offset vs DC (Kerberos limit: 300s)' 'FAIL' "${offsetSec}s — exceeds limit — cluster Kerberos authentication will fail"
            }
        } else {
            Add-Result $cat 'Time offset' 'INFO' ($offsetLine.Trim())
        }
    } catch {
        Add-Result $cat 'Time offset' 'WARN' "w32tm /query /status failed: $_"
    }

    Add-Result $cat 'System time (UTC)' 'INFO' (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
}

#endregion

#region ── G. Firewall ────────────────────────────────────────────────────────

function Test-FirewallRules {
    Section 'G. Firewall & Required Ports'
    $cat = 'Firewall'

    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in $profiles) {
            Add-Result $cat "FW profile: $($p.Name)" 'INFO' $(if ($p.Enabled) { 'Enabled' } else { 'Disabled' })
        }
    } catch {
        Add-Result $cat 'Firewall profiles' 'SKIP' "NetFirewallProfile unavailable: $_"
    }

    # Key built-in rules required for cluster
    $requiredRules = @(
        'Failover Clusters (RPC)',
        'Failover Clusters (RPC-EPMAP)',
        'Windows Management Instrumentation (DCOM-In)',
        'File and Printer Sharing (SMB-In)',
        'Remote Event Log Management (RPC)'
    )
    foreach ($name in $requiredRules) {
        $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $rule) {
            Add-Result $cat "FW rule: $name" 'WARN' 'Not found — may be covered by GPO or named differently'
        } elseif ($rule.Enabled -eq 'True') {
            Add-Result $cat "FW rule: $name" 'PASS' 'Enabled'
        } else {
            Add-Result $cat "FW rule: $name" 'FAIL' 'Rule exists but is DISABLED'
        }
    }

    # Hyper-V Live Migration rule group
    $hvRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -match 'Hyper-V' -and $_.Direction -eq 'Inbound' })
    if ($hvRules.Count -gt 0) {
        $enabled = ($hvRules | Where-Object { $_.Enabled -eq 'True' }).Count
        $level   = if ($enabled -eq $hvRules.Count) { 'PASS' } else { 'WARN' }
        Add-Result $cat 'Hyper-V Live Migration rules' $level "$enabled / $($hvRules.Count) inbound rules enabled"
    } else {
        Add-Result $cat 'Hyper-V Live Migration rules' 'SKIP' 'Rules not found — Hyper-V role may not be installed yet'
    }

    # S2D-specific: SMB storage traffic ports
    if ($StorageType -eq 'S2D') {
        $smbRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayGroup -match 'File and Printer Sharing' -and $_.Direction -eq 'Inbound' })
        if ($smbRules.Count -gt 0) {
            $enabled = ($smbRules | Where-Object { $_.Enabled -eq 'True' }).Count
            Add-Result $cat 'S2D SMB storage rules (File and Printer Sharing)' $(if ($enabled -ge 1) { 'PASS' } else { 'FAIL' }) "$enabled / $($smbRules.Count) inbound rules enabled"
        }
    }

    # Critical local port liveness (loopback)
    $ports = @(
        @{ Port = 135;  Desc = 'RPC Endpoint Mapper' },
        @{ Port = 445;  Desc = 'SMB' },
        @{ Port = 3343; Desc = 'Cluster Service' }
    )
    foreach ($p in $ports) {
        try {
            $tcp    = [System.Net.Sockets.TcpClient]::new()
            $ar     = $tcp.BeginConnect('127.0.0.1', $p.Port, $null, $null)
            $ok     = $ar.AsyncWaitHandle.WaitOne(1000, $false)
            $tcp.Close()
            $level  = if ($ok) { 'PASS' } else { 'WARN' }
            $detail = if ($ok) { 'Listening' } else { 'Not listening — service may be stopped or port blocked by FW' }
            Add-Result $cat "Port $($p.Port)/TCP ($($p.Desc))" $level $detail
        } catch {
            Add-Result $cat "Port $($p.Port)/TCP ($($p.Desc))" 'WARN' "Test failed: $_"
        }
    }
}

#endregion

#region ── H. Storage ────────────────────────────────────────────────────────

function Test-Storage {
    Section "H. Storage ($StorageType)"
    $cat = 'Storage'

    # System drive — applies to both SAN and S2D
    $sysDrive = $env:SystemDrive
    $osDisk   = Get-PSDrive -Name ($sysDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($osDisk) {
        $freeGB  = [math]::Round($osDisk.Free / 1GB, 1)
        $totalGB = [math]::Round(($osDisk.Used + $osDisk.Free) / 1GB, 1)
        $pct     = if ($totalGB -gt 0) { [math]::Round($osDisk.Free / ($osDisk.Used + $osDisk.Free) * 100, 0) } else { 0 }
        $level   = if ($freeGB -lt 10) { 'FAIL' } elseif ($pct -lt 20) { 'WARN' } else { 'PASS' }
        Add-Result $cat "OS drive free space ($sysDrive)" $level "${freeGB} GB free / ${totalGB} GB total ($pct%)"
    }

    # Volume health
    $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.FileSystem })
    foreach ($vol in $volumes) {
        if ($vol.HealthStatus -ne 'Healthy') {
            Add-Result $cat "Volume $($vol.DriveLetter): health" 'FAIL' $vol.HealthStatus
        } else {
            $fsLevel = if ($vol.FileSystem -notin @('NTFS', 'ReFS', 'CSV')) { 'WARN' } else { 'PASS' }
            $freeGB  = [math]::Round($vol.SizeRemaining / 1GB, 1)
            Add-Result $cat "Volume $($vol.DriveLetter): $($vol.FileSystem)" $fsLevel "${freeGB} GB free — $($vol.HealthStatus)"
        }
    }

    if ($StorageType -eq 'SAN') {
        # ── SAN ────────────────────────────────────────────────────────────────

        # MPIO — required for SAN multi-path
        try {
            $mpio = Get-WindowsFeature -Name 'Multipath-IO' -ErrorAction SilentlyContinue
            if ($mpio) {
                $level = if ($mpio.InstallState -eq 'Installed') { 'PASS' } else { 'FAIL' }
                Add-Result $cat 'SAN: MPIO feature (Multipath-IO)' $level "State: $($mpio.InstallState)"
            }
        } catch {
            Add-Result $cat 'SAN: MPIO feature' 'SKIP' "ServerManager unavailable: $_"
        }

        # MPIO path count per disk (should be > 1 for redundancy)
        try {
            $mpioPaths = Get-MSDSMSupportedHW -ErrorAction SilentlyContinue
            if ($mpioPaths) {
                Add-Result $cat 'SAN: MPIO supported hardware entries' 'INFO' "$($mpioPaths.Count) entry/entries"
            } else {
                Add-Result $cat 'SAN: MPIO supported hardware entries' 'WARN' 'No MPIO DSM entries — vendor DSM may not be installed'
            }
        } catch {
            Add-Result $cat 'SAN: MPIO paths' 'SKIP' "MPIO cmdlets unavailable — run from Windows with Multipath-IO installed"
        }

        # iSCSI Initiator
        $iscsiSvc = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
        if ($iscsiSvc) {
            $level = if ($iscsiSvc.Status -eq 'Running') { 'PASS' } else { 'WARN' }
            Add-Result $cat 'SAN: iSCSI Initiator service (MSiSCSI)' $level "Status: $($iscsiSvc.Status)"
        }

        # iSCSI connected sessions
        try {
            $sessions = @(Get-IscsiSession -ErrorAction Stop)
            if ($sessions.Count -gt 0) {
                Add-Result $cat 'SAN: iSCSI sessions' 'PASS' "$($sessions.Count) active session(s) — Target(s): $(($sessions.TargetNodeAddress | Select-Object -Unique) -join ', ')"
            } else {
                Add-Result $cat 'SAN: iSCSI sessions' 'WARN' 'No active iSCSI sessions — connect to SAN target before cluster creation'
            }
        } catch {
            Add-Result $cat 'SAN: iSCSI sessions' 'SKIP' "iSCSI cmdlets unavailable or no iSCSI initiator: $_"
        }

        # FC HBA detection via WMI
        try {
            $hbas = @(Get-CimInstance -Namespace root\wmi -ClassName MSFC_FCAdapterHBAAttributes -ErrorAction Stop)
            if ($hbas.Count -gt 0) {
                $wwpns = $hbas | ForEach-Object { ($_.NodeWWN | ForEach-Object { '{0:X2}' -f $_ }) -join ':' }
                Add-Result $cat 'SAN: Fibre Channel HBA(s)' 'PASS' "$($hbas.Count) HBA(s) — WWNs: $($wwpns -join ', ')"
            } else {
                Add-Result $cat 'SAN: Fibre Channel HBA(s)' 'INFO' 'No FC HBA detected via WMI (normal if iSCSI-only SAN)'
            }
        } catch {
            Add-Result $cat 'SAN: Fibre Channel HBA(s)' 'SKIP' "FC WMI class unavailable: $_"
        }

        # Shared disks visible (at least 1 disk beyond OS drives)
        try {
            $allDisks   = @(Get-Disk -ErrorAction Stop)
            $sharedDisks= @($allDisks | Where-Object { $_.BusType -in @('iSCSI', 'Fibre Channel', 'SAS', 'Fibrechannel') -or $_.IsSystem -eq $false })
            if ($sharedDisks.Count -gt 0) {
                Add-Result $cat 'SAN: Shared disk(s) visible' 'PASS' "$($sharedDisks.Count) non-OS disk(s) visible"
            } else {
                Add-Result $cat 'SAN: Shared disk(s) visible' 'WARN' 'No SAN disk(s) detected — connect LUNs and rescan before creating cluster'
            }
        } catch {
            Add-Result $cat 'SAN: Disk visibility' 'SKIP' "Get-Disk failed: $_"
        }

    } else {
        # ── S2D ────────────────────────────────────────────────────────────────

        # Datacenter edition is REQUIRED for S2D — already checked in section A but enforce here
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        if ($os.Caption -notmatch 'Datacenter') {
            Add-Result $cat 'S2D: Datacenter edition required' 'FAIL' "$($os.Caption) — S2D is not supported on Standard edition"
        } else {
            Add-Result $cat 'S2D: Datacenter edition required' 'PASS' $os.Caption
        }

        # Physical disks eligible for S2D (CanPool = true)
        try {
            $allDisks     = @(Get-PhysicalDisk -ErrorAction Stop)
            $poolableDisks= @($allDisks | Where-Object { $_.CanPool })
            $systemDisks  = @($allDisks | Where-Object { $_.Usage -eq 'Journal' -or $_.BusType -eq 'USB' })

            Add-Result $cat 'S2D: Total physical disks' 'INFO' "$($allDisks.Count) total, $($poolableDisks.Count) poolable (S2D-eligible)"

            if ($poolableDisks.Count -lt 2) {
                Add-Result $cat 'S2D: Minimum 2 poolable disks per node' 'FAIL' "Only $($poolableDisks.Count) poolable disk(s) — minimum 2 required per node"
            } else {
                Add-Result $cat 'S2D: Minimum 2 poolable disks per node' 'PASS' "$($poolableDisks.Count) poolable disk(s)"
            }

            # Disk type inventory
            $nvme = @($poolableDisks | Where-Object { $_.BusType -eq 'NVMe' })
            $ssd  = @($poolableDisks | Where-Object { $_.BusType -in @('SATA', 'SAS') -and $_.MediaType -eq 'SSD' })
            $hdd  = @($poolableDisks | Where-Object { $_.MediaType -eq 'HDD' })
            Add-Result $cat 'S2D: Drive tier inventory' 'INFO' "NVMe: $($nvme.Count), SSD: $($ssd.Count), HDD: $($hdd.Count)"

            # Supported configurations per Microsoft docs
            if ($nvme.Count -ge 2 -and $ssd.Count -eq 0 -and $hdd.Count -eq 0) {
                Add-Result $cat 'S2D: Drive configuration' 'PASS' 'All-NVMe — supported (fastest)'
            } elseif ($ssd.Count -ge 2 -and $hdd.Count -eq 0 -and $nvme.Count -eq 0) {
                Add-Result $cat 'S2D: Drive configuration' 'PASS' 'All-SSD — supported'
            } elseif ($nvme.Count -ge 1 -and $ssd.Count -ge 1 -and $hdd.Count -eq 0) {
                Add-Result $cat 'S2D: Drive configuration' 'PASS' 'NVMe (cache) + SSD (capacity) — supported'
            } elseif ($ssd.Count -ge 1 -and $hdd.Count -ge 1) {
                Add-Result $cat 'S2D: Drive configuration' 'PASS' "SSD (cache) + HDD (capacity) — supported ($($ssd.Count) SSD, $($hdd.Count) HDD)"
            } elseif ($hdd.Count -ge 4) {
                Add-Result $cat 'S2D: Drive configuration' 'WARN' "All-HDD — supported but performance limited; minimum 4 HDD per node required for all-HDD config"
            } else {
                Add-Result $cat 'S2D: Drive configuration' 'WARN' "Unusual drive mix — verify against S2D requirements"
            }

            # Shared SAS check — S2D must NOT share SAS expanders between nodes
            $sasBusDisks = @($allDisks | Where-Object { $_.BusType -eq 'SAS' })
            if ($sasBusDisks.Count -gt 0) {
                Add-Result $cat 'S2D: SAS drives detected' 'WARN' "$($sasBusDisks.Count) SAS disk(s) — verify HBA is in JBOD/pass-through mode (no RAID) and SAS expanders are NOT shared between nodes"
            }

            # Boot/OS drive should not be poolable
            $osDisk2 = @($allDisks | Where-Object { $_.IsSystem -or $_.IsBoot })
            foreach ($d in $osDisk2) {
                if ($d.CanPool) {
                    Add-Result $cat "S2D: OS disk ($($d.FriendlyName)) poolable?" 'WARN' "OS/boot disk appears poolable — S2D should not include the OS disk in the pool"
                }
            }

        } catch {
            Add-Result $cat 'S2D: Physical disk enumeration' 'WARN' "Get-PhysicalDisk failed: $_"
        }

        # Storage Bus Layer binding (shows disks claimed by S2D driver)
        try {
            $sbl = @(Get-StorageBusBinding -ErrorAction Stop)
            if ($sbl.Count -gt 0) {
                Add-Result $cat 'S2D: Storage Bus Layer bindings' 'INFO' "$($sbl.Count) disk(s) bound to StorageBusLayer (S2D driver)"
            } else {
                Add-Result $cat 'S2D: Storage Bus Layer bindings' 'INFO' 'No SBL bindings yet — S2D not enabled (expected on a new node)'
            }
        } catch {
            Add-Result $cat 'S2D: Storage Bus Layer' 'SKIP' "Get-StorageBusBinding unavailable: $_"
        }

        # ReFS recommended for S2D CSVs
        $nonRefsVols = @($volumes | Where-Object { $_.FileSystem -notin @('ReFS', 'NTFS', 'CSV') })
        if ($nonRefsVols.Count -eq 0) {
            Add-Result $cat 'S2D: Volume filesystem (ReFS/NTFS)' 'PASS' 'All volumes on ReFS or NTFS'
        }
    }
}

#endregion

#region ── I. Cluster Pre-validation ─────────────────────────────────────────

function Test-ClusterReadiness {
    param([string[]]$Nodes)

    Section 'I. Failover Cluster Pre-validation'
    $cat = 'Cluster'

    $localNode = $env:COMPUTERNAME
    $allNodes  = @($localNode) + $Nodes | Select-Object -Unique
    $nodeCount = $allNodes.Count

    Add-Result $cat 'Cluster node count' 'INFO' "$nodeCount node(s): $($allNodes -join ', ')"

    # S2D minimum 2 nodes
    if ($StorageType -eq 'S2D' -and $nodeCount -lt 2) {
        Add-Result $cat 'S2D: Minimum 2 nodes' 'FAIL' "S2D requires at least 2 nodes — specify -ClusterNodes"
    }

    # Quorum recommendation — Microsoft guidance
    $quorumRec = switch -Wildcard ($nodeCount) {
        1       { 'N/A — single node (no cluster)' }
        2       { 'Node and File Share Majority — 2 nodes always need a witness (disk or file share)' }
        { [int]$_ % 2 -eq 1 -and [int]$_ -ge 3 } { "Node Majority — $nodeCount votes (odd count, no witness needed)" }
        { [int]$_ % 2 -eq 0 -and [int]$_ -ge 4 } { "Node and Disk Majority or File Share Majority — $nodeCount nodes (even count, witness required)" }
        default { 'Node Majority' }
    }
    $qLevel = if ($nodeCount -ge 3 -and $nodeCount % 2 -eq 1) { 'PASS' } else { 'WARN' }
    Add-Result $cat 'Quorum recommendation' $qLevel $quorumRec

    # Witness connectivity
    if ($WitnessShare -ne '') {
        $accessible = Test-Path $WitnessShare -ErrorAction SilentlyContinue
        $level      = if ($accessible) { 'PASS' } else { 'FAIL' }
        Add-Result $cat "File share witness: $WitnessShare" $level $(if ($accessible) { 'Accessible' } else { "Cannot access UNC path — verify share permissions and network connectivity" })
    } elseif ($nodeCount -eq 2 -or ($nodeCount % 2 -eq 0)) {
        Add-Result $cat 'File share witness' 'WARN' "Node count ($nodeCount) requires a witness — specify -WitnessShare to validate"
    }

    # Cross-node: reachability, OS version, domain
    $nodeOsVersions = @{ $localNode = [System.Environment]::OSVersion.Version.ToString() }
    foreach ($node in $Nodes) {
        if (-not (Test-Connection -ComputerName $node -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
            Add-Result $cat "Node $node: reachable" 'FAIL' "Ping failed — node must be reachable before joining cluster"
            continue
        }
        Add-Result $cat "Node $node: reachable" 'PASS' 'Ping OK'

        try {
            $rOS = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $node -ErrorAction Stop
            $rCS = Get-CimInstance -ClassName Win32_ComputerSystem  -ComputerName $node -ErrorAction Stop
            $nodeOsVersions[$node] = $rOS.Version

            Add-Result $cat "Node $node: OS" 'INFO' "$($rOS.Caption) build $($rOS.BuildNumber)"

            $localDomain = (Get-CimInstance Win32_ComputerSystem).Domain
            if ($rCS.Domain -eq $localDomain) {
                Add-Result $cat "Node $node: domain" 'PASS' $rCS.Domain
            } else {
                Add-Result $cat "Node $node: domain" 'FAIL' "Domain mismatch: $($rCS.Domain) vs $localDomain"
            }
        } catch {
            Add-Result $cat "Node $node: WMI/CIM" 'WARN' "Remote CIM unavailable: $_ — ensure WinRM is running"
        }
    }

    $distinctVersions = $nodeOsVersions.Values | Select-Object -Unique
    if ($distinctVersions.Count -eq 1) {
        Add-Result $cat 'OS version consistency (all nodes)' 'PASS' "All nodes: $($distinctVersions[0])"
    } elseif ($distinctVersions.Count -gt 1) {
        $nodeList = ($nodeOsVersions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        Add-Result $cat 'OS version consistency (all nodes)' 'FAIL' "Version mismatch: $nodeList — all nodes must run the same Windows Server build"
    }

    # Failover-Clustering feature on remote nodes
    foreach ($node in $Nodes) {
        try {
            $state = Invoke-Command -ComputerName $node -ScriptBlock {
                Import-Module ServerManager; (Get-WindowsFeature 'Failover-Clustering').InstallState
            } -ErrorAction Stop
            $level = if ($state -eq 'Installed') { 'PASS' } else { 'WARN' }
            Add-Result $cat "Node $node: Failover-Clustering feature" $level "State: $state"
        } catch {
            Add-Result $cat "Node $node: Failover-Clustering feature" 'SKIP' "Remote query failed: $_"
        }
    }

    # Network segregation
    $activeNics = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    $minNics    = if ($StorageType -eq 'S2D') { 4 } else { 3 }
    if ($activeNics.Count -ge $minNics) {
        Add-Result $cat "Network segregation ($($activeNics.Count) NICs)" 'PASS' "Enough NICs for management / cluster heartbeat / live migration$(if ($StorageType -eq 'S2D') { ' / S2D storage' })"
    } elseif ($activeNics.Count -ge 2) {
        Add-Result $cat "Network segregation ($($activeNics.Count) NICs)" 'WARN' "Microsoft recommends $minNics+ separate networks for $StorageType"
    } else {
        Add-Result $cat "Network segregation ($($activeNics.Count) NIC)" 'FAIL' "Cannot segregate cluster traffic with only 1 NIC"
    }

    # Test-Cluster
    if (-not $SkipClusterValidation) {
        if (Get-Module -Name FailoverClusters -ListAvailable -ErrorAction SilentlyContinue) {
            Import-Module FailoverClusters -ErrorAction SilentlyContinue
            try {
                Write-Log "Running Test-Cluster on: $($allNodes -join ', ') (may take several minutes)..." -Level INFO
                $rpt        = Join-Path $env:TEMP "ClusterValidation-$(Get-Date -Format 'yyyyMMdd-HHmmss').htm"
                $validation = Test-Cluster -Node $allNodes -ReportName $rpt -ErrorAction Stop
                $failed  = ($validation | Where-Object { $_.Status -eq 'Failed'  }).Count
                $warned  = ($validation | Where-Object { $_.Status -eq 'Warning' }).Count
                $passed  = ($validation | Where-Object { $_.Status -eq 'Successful' }).Count
                $level   = if ($failed -eq 0) { 'PASS' } else { 'FAIL' }
                Add-Result $cat 'Test-Cluster validation' $level "$passed passed, $warned warnings, $failed failures — report: $rpt"
            } catch {
                Add-Result $cat 'Test-Cluster validation' 'WARN' "Run failed: $_"
            }
        } else {
            Add-Result $cat 'Test-Cluster validation' 'SKIP' 'FailoverClusters module not available — install Failover-Clustering feature first'
        }
    } else {
        Add-Result $cat 'Test-Cluster validation' 'SKIP' 'Skipped via -SkipClusterValidation'
    }
}

#endregion

#region ── J. Service Account & OU AD Permissions ────────────────────────────

function Test-ServiceAccountPermissions {
    Section 'J. Service Account & OU Permissions'
    $cat = 'ServiceAccount'

    if ($ServiceAccount -eq '') {
        Add-Result $cat 'Service account check' 'SKIP' 'No -ServiceAccount specified — skipping section J'
        return
    }

    # Normalize sAMAccountName (strip domain prefix if present)
    $samName = $ServiceAccount -replace '^.*\\', ''
    Add-Result $cat 'Service account' 'INFO' "Checking: $ServiceAccount (samAccountName: $samName)"

    # ── J.1 Account exists and is enabled ────────────────────────────────────
    $acctEntry = $null
    try {
        $searcher = [adsisearcher]"(&(objectCategory=person)(objectClass=user)(samAccountName=$samName))"
        $searcher.PropertiesToLoad.AddRange([string[]]@('distinguishedname', 'useraccountcontrol', 'memberof', 'mail', 'objectsid'))
        $acctEntry = $searcher.FindOne()
    } catch {
        Add-Result $cat 'Account lookup' 'FAIL' "ADSI query failed: $_ — run as domain user with read access to AD"
        return
    }

    if (-not $acctEntry) {
        Add-Result $cat 'Account exists in AD' 'FAIL' "No AD account found for samAccountName '$samName'"
        return
    }

    $acctDN  = $acctEntry.Properties['distinguishedname'][0]
    $uac     = [int]$acctEntry.Properties['useraccountcontrol'][0]
    $disabled= ($uac -band 0x0002) -ne 0
    Add-Result $cat 'Account exists in AD' 'PASS' $acctDN
    if ($disabled) {
        Add-Result $cat 'Account enabled' 'FAIL' "Account is DISABLED (UAC flag 0x0002 set) — enable before cluster creation"
    } else {
        Add-Result $cat 'Account enabled' 'PASS' 'Account is enabled'
    }

    # Password never expires — warn (service accounts should have very long or no expiry)
    $pwdNeverExpires = ($uac -band 0x10000) -ne 0
    if (-not $pwdNeverExpires) {
        Add-Result $cat 'Account password policy' 'WARN' "Password expiry enabled — service accounts for cluster should have 'Password never expires' or managed password (gMSA)"
    } else {
        Add-Result $cat 'Account password policy' 'PASS' 'Password never expires'
    }

    # Resolve account SID (used for ACL matching)
    $acctSid = $null
    try {
        $sidBytes = $acctEntry.Properties['objectsid'][0]
        $acctSid  = [System.Security.Principal.SecurityIdentifier]::new([byte[]]$sidBytes, 0)
        Add-Result $cat 'Account SID' 'INFO' $acctSid.Value
    } catch {
        Add-Result $cat 'Account SID' 'WARN' "Could not parse SID: $_"
    }

    # Collect account's group SIDs (for ACL resolution — transitive via tokenGroups)
    $accountSids = [System.Collections.Generic.HashSet[string]]::new()
    if ($acctSid) { [void]$accountSids.Add($acctSid.Value) }
    try {
        $acctDE = [System.DirectoryServices.DirectoryEntry]"LDAP://$acctDN"
        $acctDE.psbase.RefreshCache([string[]]@('tokenGroups'))
        foreach ($tokenSidBytes in $acctDE.Properties['tokenGroups']) {
            $sid = [System.Security.Principal.SecurityIdentifier]::new([byte[]]$tokenSidBytes, 0)
            [void]$accountSids.Add($sid.Value)
        }
        Add-Result $cat "Account transitive group membership" 'INFO' "$($accountSids.Count) SIDs (account + all groups)"
    } catch {
        Add-Result $cat 'Account group membership (tokenGroups)' 'WARN' "tokenGroups refresh failed: $_ — ACL checks may be incomplete"
    }

    # ── J.2 Local administrator on this node ─────────────────────────────────
    try {
        $localAdmins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)
        $isLocalAdmin = $localAdmins | Where-Object {
            ($_.ObjectClass -eq 'User'  -and $_.Name -match [regex]::Escape($samName)) -or
            ($_.ObjectClass -eq 'Group' -and $accountSids.Count -gt 0)
        }
        if ($isLocalAdmin) {
            Add-Result $cat "Local admin on $($env:COMPUTERNAME)" 'PASS' "Found in local Administrators group"
        } else {
            Add-Result $cat "Local admin on $($env:COMPUTERNAME)" 'FAIL' "'$samName' is NOT in local Administrators — the account creating the cluster must be local admin on all nodes"
        }
    } catch {
        Add-Result $cat "Local admin on $($env:COMPUTERNAME)" 'WARN' "Get-LocalGroupMember failed: $_ — verify manually"
    }

    # ── J.3 OU permissions ────────────────────────────────────────────────────
    if ($ClusterOU -eq '') {
        Add-Result $cat 'OU permission check' 'SKIP' 'No -ClusterOU specified — specify the OU DN where CNO/VCOs will be created'
    } else {
        # Verify OU exists
        try {
            $ouEntry = [System.DirectoryServices.DirectoryEntry]"LDAP://$ClusterOU"
            $ouName  = $ouEntry.Name
            if (-not $ouName) { throw "OU entry empty" }
            Add-Result $cat 'Target OU exists' 'PASS' "OU: $ClusterOU"
        } catch {
            Add-Result $cat 'Target OU exists' 'FAIL' "Cannot bind to OU '$ClusterOU': $_ — verify the DN is correct"
            # Cannot test ACLs without a valid OU
            return
        }

        # Read DACL on the OU
        try {
            $adSecurity  = $ouEntry.psbase.ObjectSecurity
            $accessRules = $adSecurity.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])

            # Schema GUIDs
            # computer class:          bf967a86-0de6-11d0-a285-00aa003049e2
            # dnsNode class:           e0fa1e8b-9b45-11d0-afdd-00c04fd930c9
            # All objects (null guid): 00000000-0000-0000-0000-000000000000
            $computerClassGuid = [Guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
            $dnsNodeClassGuid  = [Guid]'e0fa1e8b-9b45-11d0-afdd-00c04fd930c9'
            $nullGuid          = [Guid]::Empty

            $canCreateComputer  = $false
            $canWriteComputer   = $false
            $hasGenericAll      = $false

            foreach ($rule in $accessRules) {
                if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                if (-not $accountSids.Contains($rule.IdentityReference.Value)) { continue }

                $rights = $rule.ActiveDirectoryRights

                # GenericAll / FullControl covers everything
                if ($rights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll) {
                    $hasGenericAll     = $true
                    $canCreateComputer = $true
                    $canWriteComputer  = $true
                }

                # CreateChild for computer class (or all objects)
                if ($rights -band [System.DirectoryServices.ActiveDirectoryRights]::CreateChild) {
                    if ($rule.ObjectType -eq $nullGuid -or $rule.ObjectType -eq $computerClassGuid) {
                        $canCreateComputer = $true
                    }
                }

                # WriteProperty (All Properties) on computer objects in this OU
                if ($rights -band [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty) {
                    if ($rule.InheritedObjectType -eq $computerClassGuid -or $rule.InheritedObjectType -eq $nullGuid) {
                        $canWriteComputer = $true
                    }
                }
            }

            if ($hasGenericAll) {
                Add-Result $cat 'OU permission: Full Control' 'PASS' "Account has GenericAll (Full Control) on $ClusterOU"
            } else {
                $createLevel = if ($canCreateComputer) { 'PASS' } else { 'FAIL' }
                $writeLevel  = if ($canWriteComputer)  { 'PASS' } else { 'WARN' }

                Add-Result $cat 'OU permission: Create computer objects (CNO/VCO)' $createLevel $(
                    if ($canCreateComputer) {
                        "CreateChild (computer class) allowed — cluster can register CNO and VCOs"
                    } else {
                        "MISSING — run: dsacls '$ClusterOU' /I:T /G '${ServiceAccount}:CC;computer' and restart check"
                    }
                )
                Add-Result $cat 'OU permission: Write All Properties on computer objects' $writeLevel $(
                    if ($canWriteComputer) {
                        "WriteProperty on descendant computer objects allowed"
                    } else {
                        "Not detected — may be inherited via group; if issues arise: dsacls '$ClusterOU' /I:S /G '${ServiceAccount}:WP;;computer'"
                    }
                )
            }

            # DeleteChild — needed for VCO cleanup on cluster role removal
            $canDeleteComputer = $false
            foreach ($rule in $accessRules) {
                if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                if (-not $accountSids.Contains($rule.IdentityReference.Value)) { continue }
                if ($rule.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild) {
                    if ($rule.ObjectType -eq $nullGuid -or $rule.ObjectType -eq $computerClassGuid) {
                        $canDeleteComputer = $true
                    }
                }
            }
            $delLevel = if ($canDeleteComputer -or $hasGenericAll) { 'PASS' } else { 'WARN' }
            Add-Result $cat 'OU permission: Delete computer objects (VCO cleanup)' $delLevel $(
                if ($canDeleteComputer -or $hasGenericAll) { 'DeleteChild allowed' } else { 'Not detected — cluster role removal may leave orphan VCOs' }
            )

        } catch {
            Add-Result $cat 'OU DACL read' 'WARN' "ACL read failed: $_ — verify you have rights to read the OU DACL"
        }

        # ── J.4 DNS zone permissions (to register CNO A record) ───────────────
        $domainName = (Get-CimInstance Win32_ComputerSystem).Domain
        if ($domainName -and $domainName -ne 'WORKGROUP') {
            # DNS zones in AD are under DomainDnsZones or System partition
            $dnsZoneDN = "CN=$domainName,CN=MicrosoftDNS,DC=DomainDnsZones,DC=$($domainName.Replace('.', ',DC='))"
            try {
                $dnsZoneEntry = [System.DirectoryServices.DirectoryEntry]"LDAP://$dnsZoneDN"
                $dnsName      = $dnsZoneEntry.Name
                if ($dnsName) {
                    Add-Result $cat "DNS zone in AD: $dnsZoneDN" 'INFO' 'Zone found in DomainDnsZones partition'

                    $dnsAcl   = $dnsZoneEntry.psbase.ObjectSecurity
                    $dnsRules = $dnsAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])

                    $canCreateDnsNode = $false
                    foreach ($rule in $dnsRules) {
                        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                        if (-not $accountSids.Contains($rule.IdentityReference.Value)) { continue }
                        if ($rule.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll) { $canCreateDnsNode = $true; break }
                        if ($rule.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::CreateChild) {
                            if ($rule.ObjectType -eq $dnsNodeClassGuid -or $rule.ObjectType -eq $nullGuid) { $canCreateDnsNode = $true; break }
                        }
                    }

                    $dnsLevel = if ($canCreateDnsNode) { 'PASS' } else { 'WARN' }
                    Add-Result $cat 'DNS zone permission: Create dnsNode (CNO A record)' $dnsLevel $(
                        if ($canCreateDnsNode) {
                            "Account can create DNS records in zone $domainName"
                        } else {
                            "Not detected in DomainDnsZones — cluster may fail to register its name; grant DNS record creation or use 'DNSUpdateProxy' group"
                        }
                    )
                }
            } catch {
                Add-Result $cat "DNS zone permission" 'WARN' "Cannot read DNS zone ACL ($dnsZoneDN): $_ — verify DNS ACL manually or ensure the account is in 'DnsUpdateProxy' group"
            }
        }
    }

    # ── J.5 Prestaged CNO check ───────────────────────────────────────────────
    if ($ClusterName -ne '') {
        try {
            $cnoSearcher = [adsisearcher]"(&(objectCategory=computer)(name=$ClusterName))"
            $cnoSearcher.PropertiesToLoad.AddRange([string[]]@('distinguishedname', 'useraccountcontrol', 'objectsid'))
            $cnoResult = $cnoSearcher.FindOne()

            if ($cnoResult) {
                $cnoDN  = $cnoResult.Properties['distinguishedname'][0]
                $cnoUAC = [int]$cnoResult.Properties['useraccountcontrol'][0]
                $cnoDisabled = ($cnoUAC -band 0x0002) -ne 0
                Add-Result $cat "Prestaged CNO '$ClusterName' found" 'INFO' "DN: $cnoDN"

                if ($cnoDisabled) {
                    Add-Result $cat "Prestaged CNO '$ClusterName' is disabled" 'PASS' "Account is disabled — correct for a prestaged CNO (cluster will enable it)"
                } else {
                    Add-Result $cat "Prestaged CNO '$ClusterName' disabled state" 'WARN' "CNO account is enabled — for a prestaged CNO it should be disabled until the cluster is created"
                }

                # Verify CNO is in the expected OU
                if ($ClusterOU -ne '' -and $cnoDN -notlike "*$ClusterOU") {
                    Add-Result $cat "Prestaged CNO in correct OU" 'WARN' "CNO is in '$cnoDN' but expected under '$ClusterOU'"
                } elseif ($ClusterOU -ne '') {
                    Add-Result $cat "Prestaged CNO in correct OU" 'PASS' "CNO is under $ClusterOU"
                }

                # CNO must have Full Control over VCOs in the same OU — remind operator
                Add-Result $cat "Prestaged CNO: permissions on VCOs" 'WARN' "Manual check required: CNO computer account ($ClusterName`$) must have Full Control over any prestaged VCO accounts in $ClusterOU — run: dsacls '$ClusterOU' /I:S /G '$ClusterName`$:GA;;computer'"

            } else {
                Add-Result $cat "Prestaged CNO '$ClusterName'" 'INFO' "Not found in AD — cluster will create the CNO automatically (requires CreateChild permission on target OU)"
            }
        } catch {
            Add-Result $cat "Prestaged CNO check" 'WARN' "ADSI query failed: $_"
        }
    }
}

#endregion

#region ── Summary & Report ───────────────────────────────────────────────────

function Write-Summary {
    $passCount = ($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $warnCount = ($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
    $failCount = ($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $infoCount = ($script:Results | Where-Object { $_.Status -in 'INFO', 'SKIP' }).Count

    Write-Log '' -Level INFO
    Write-Log '════════════════════════════════════════════════════════════════' -Level SECTION
    Write-Log "  SUMMARY  |  PASS: $passCount  WARN: $warnCount  FAIL: $failCount  INFO/SKIP: $infoCount" -Level SECTION
    Write-Log '════════════════════════════════════════════════════════════════' -Level SECTION

    if ($failCount -gt 0) {
        Write-Log '' -Level INFO
        Write-Log 'FAILURES:' -Level FAIL
        $script:Results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
            Write-Log "  [$($_.Category)] $($_.Check): $($_.Detail)" -Level FAIL
        }
    }
    if ($warnCount -gt 0) {
        Write-Log '' -Level INFO
        Write-Log 'WARNINGS:' -Level WARN
        $script:Results | Where-Object { $_.Status -eq 'WARN' } | ForEach-Object {
            Write-Log "  [$($_.Category)] $($_.Check): $($_.Detail)" -Level WARN
        }
    }

    Write-Log '' -Level INFO
    Write-Log "Log file: $LogFile" -Level INFO
    return $failCount
}

function Write-HtmlReport {
    param([string]$Path)

    $rows = foreach ($r in $script:Results) {
        $bg   = switch ($r.Status) { 'PASS' { '#d4edda' } 'WARN' { '#fff3cd' } 'FAIL' { '#f8d7da' } 'SKIP' { '#e2e3e5' } default { '#ffffff' } }
        $icon = switch ($r.Status) { 'PASS' { '&#9989;' } 'WARN' { '&#9888;' } 'FAIL' { '&#10060;' } 'SKIP' { '&#9940;' } default { '&#8505;' } }
        "<tr style='background:$bg'><td>$($r.Category)</td><td>$($r.Check)</td><td>$icon $($r.Status)</td><td>$($r.Detail)</td></tr>"
    }

    $passCount = ($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $warnCount = ($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
    $failCount = ($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count

    @"
<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8">
<title>Hyper-V Node Readiness — $env:COMPUTERNAME</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:20px;background:#f5f5f5}
h1{color:#0078d4}
table{border-collapse:collapse;width:100%;background:white;box-shadow:0 1px 3px #ccc}
th{background:#0078d4;color:white;padding:8px 12px;text-align:left}
td{padding:7px 12px;border-bottom:1px solid #e0e0e0;font-size:.9em}
.badge{display:inline-block;padding:2px 10px;border-radius:12px;font-weight:bold}
.pass{background:#28a745;color:white}.warn{background:#ffc107;color:#333}.fail{background:#dc3545;color:white}
</style></head><body>
<h1>Hyper-V Node Readiness Report</h1>
<p><strong>Host:</strong> $env:COMPUTERNAME &nbsp;|&nbsp;
<strong>Mode:</strong> $Mode &nbsp;|&nbsp;
<strong>Storage:</strong> $StorageType &nbsp;|&nbsp;
<strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p><span class="badge pass">PASS: $passCount</span>&nbsp;
<span class="badge warn">WARN: $warnCount</span>&nbsp;
<span class="badge fail">FAIL: $failCount</span></p>
<table><thead><tr><th>Category</th><th>Check</th><th>Status</th><th>Detail</th></tr></thead>
<tbody>$($rows -join "`n")</tbody></table>
<hr><small>Generated by Test-HyperVNodeReadiness.ps1 — vmware2hyperv</small>
</body></html>
"@ | Out-File -FilePath $Path -Encoding UTF8
    Write-Log "HTML report: $Path" -Level INFO
}

#endregion

#region ── Main ──────────────────────────────────────────────────────────────

Write-Log "Test-HyperVNodeReadiness — Host: $env:COMPUTERNAME — Mode: $Mode — Storage: $StorageType" -Level SECTION
Write-Log "Log: $LogFile" -Level INFO

$runNode    = $Mode -in @('PreNode', 'Both')
$runCluster = $Mode -in @('PreCluster', 'Both')

if ($runNode) {
    Test-OSCompatibility
    Test-HardwareRequirements
    Test-NetworkConfiguration
    Test-ActiveDirectory
    Test-DNSResolution
    Test-TimeSync
    Test-FirewallRules
    Test-Storage
}

if ($runCluster) {
    Test-ClusterReadiness -Nodes $ClusterNodes
}

# Section J runs whenever a ServiceAccount is supplied, regardless of mode
if ($ServiceAccount -ne '' -or $ClusterOU -ne '') {
    Test-ServiceAccountPermissions
}

$failCount = Write-Summary

if ($HtmlReportPath -ne '') {
    Write-HtmlReport -Path $HtmlReportPath
}

exit $(if ($failCount -gt 0) { 1 } else { 0 })

#endregion
