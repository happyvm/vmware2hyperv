#Requires -Version 5.1
<#
.SYNOPSIS
    Validate OS readiness for a future Hyper-V node and/or Hyper-V failover cluster.

.DESCRIPTION
    Runs a comprehensive set of checks derived from Microsoft documentation:
      - Hardware requirements for the Hyper-V role
      - OS edition, version, and pending-reboot state
      - Network configuration (static IPs, NIC count, DNS)
      - Active Directory domain membership
      - DNS resolution (forward, reverse, SRV records)
      - Time synchronization (Kerberos requirement < 5 minutes)
      - Windows features (Hyper-V, Failover Clustering)
      - Firewall rules required by clustering and live migration
      - Shared storage visibility
      - Quorum recommendation and cross-node consistency (PreCluster mode)

    Modes:
      PreNode     - Validate this machine as a standalone Hyper-V host
      PreCluster  - Validate this machine and remote nodes for failover clustering
      Both        - Run all checks (default)

    Exit codes:
      0 = All checks passed (or only warnings)
      1 = One or more checks failed

.PARAMETER Mode
    Validation scope: PreNode | PreCluster | Both

.PARAMETER ClusterNodes
    FQDNs or IPs of the other cluster nodes (required for PreCluster / Both modes
    when validating multi-node consistency). This node is always included.

.PARAMETER WitnessShare
    UNC path of the file share witness (e.g. \\fileserver\witness).
    Used to validate quorum witness connectivity.

.PARAMETER LogFile
    Path for the text log file. Defaults to .\HyperV-Readiness-<timestamp>.log.

.PARAMETER HtmlReportPath
    If provided, an HTML summary report is written to this path.

.PARAMETER SkipClusterValidation
    Skip the potentially long-running Test-Cluster cmdlet during PreCluster checks.

.EXAMPLE
    # Validate this node only
    .\Test-HyperVNodeReadiness.ps1 -Mode PreNode

.EXAMPLE
    # Validate full 3-node cluster (run on each node)
    .\Test-HyperVNodeReadiness.ps1 -Mode Both -ClusterNodes node2.corp.local,node3.corp.local -WitnessShare \\fs01\clusterwitness

.EXAMPLE
    # PreCluster check with HTML report, skip long cluster validation
    .\Test-HyperVNodeReadiness.ps1 -Mode PreCluster -ClusterNodes node2,node3 -HtmlReportPath C:\Reports\readiness.html -SkipClusterValidation

.NOTES
    References:
      - https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/system-requirements-for-hyper-v-on-windows
      - https://learn.microsoft.com/en-us/windows-server/failover-clustering/clustering-requirements
      - https://learn.microsoft.com/en-us/windows-server/failover-clustering/manage-cluster-quorum
      - https://learn.microsoft.com/en-us/windows-server/failover-clustering/configure-ad-accounts
#>

[CmdletBinding()]
param(
    [ValidateSet('PreNode', 'PreCluster', 'Both')]
    [string]$Mode = 'Both',

    [string[]]$ClusterNodes = @(),

    [string]$WitnessShare = '',

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
    $level = switch ($Status) {
        'PASS' { 'OK' }
        'WARN' { 'WARN' }
        'FAIL' { 'FAIL' }
        'SKIP' { 'INFO' }
        default { 'INFO' }
    }
    Write-Log "$Check — $Detail" -Level $level
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

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $caption = $os.Caption
    $build   = [int]$os.BuildNumber
    $arch    = $os.OSArchitecture

    # Minimum supported: Windows Server 2016 (build 14393)
    $minBuild = 14393
    $supportedEditions = @('Standard', 'Datacenter', 'Essentials')

    Add-Result $cat 'OS Caption' 'INFO' $caption

    # 64-bit
    if ($arch -match '64') {
        Add-Result $cat 'Architecture 64-bit' 'PASS' $arch
    } else {
        Add-Result $cat 'Architecture 64-bit' 'FAIL' "Found: $arch — Hyper-V requires 64-bit"
    }

    # Server OS
    if ($caption -notmatch 'Server') {
        Add-Result $cat 'Windows Server edition' 'FAIL' "$caption is not a Server edition"
    } elseif ($caption -match 'Standard|Datacenter') {
        Add-Result $cat 'Windows Server edition' 'PASS' $caption
    } elseif ($caption -match 'Essentials') {
        Add-Result $cat 'Windows Server edition' 'WARN' "Essentials edition — limited cluster support"
    } else {
        Add-Result $cat 'Windows Server edition' 'WARN' "Edition not validated: $caption"
    }

    # Minimum version
    if ($build -ge $minBuild) {
        Add-Result $cat 'Minimum OS version (2016+)' 'PASS' "Build $build"
    } else {
        Add-Result $cat 'Minimum OS version (2016+)' 'FAIL' "Build $build < $minBuild — Windows Server 2016 minimum required"
    }

    # Pending reboot
    $pendingReboot = $false
    $rebootReasons = @()
    $cbsPath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $wuPath   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
    $pfroPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

    if (Test-Path "$cbsPath\RebootPending") {
        $pendingReboot = $true; $rebootReasons += 'CBS'
    }
    if (Test-Path "$wuPath\RebootRequired") {
        $pendingReboot = $true; $rebootReasons += 'Windows Update'
    }
    try {
        $pfro = Get-ItemProperty $pfroPath -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($pfro -and $pfro.PendingFileRenameOperations) {
            $pendingReboot = $true; $rebootReasons += 'PendingFileRename'
        }
    } catch {}

    if ($pendingReboot) {
        Add-Result $cat 'No pending reboot' 'FAIL' "Reboot required ($($rebootReasons -join ', ')) — must reboot before adding Hyper-V / cluster roles"
    } else {
        Add-Result $cat 'No pending reboot' 'PASS' 'No reboot pending'
    }

    # Windows Update last search date
    try {
        $wu = New-Object -ComObject Microsoft.Update.AutoUpdate
        $lastSearch = $wu.Results.LastSearchSuccessDate
        if ($null -eq $lastSearch) {
            Add-Result $cat 'Windows Update last search' 'WARN' 'No recorded search — verify updates are applied'
        } else {
            $daysAgo = (New-TimeSpan -Start $lastSearch -End (Get-Date)).Days
            if ($daysAgo -gt 30) {
                Add-Result $cat 'Windows Update last search' 'WARN' "Last search: $($lastSearch.ToString('yyyy-MM-dd')) ($daysAgo days ago)"
            } else {
                Add-Result $cat 'Windows Update last search' 'PASS' "Last search: $($lastSearch.ToString('yyyy-MM-dd'))"
            }
        }
    } catch {
        Add-Result $cat 'Windows Update last search' 'SKIP' 'COM object unavailable (non-interactive or core?)'
    }
}

#endregion

#region ── B. Hardware / Virtualization Support ───────────────────────────────

function Test-HardwareRequirements {
    Section 'B. Hardware & Virtualization Support'
    $cat = 'Hardware'

    # Hyper-V capability via CIM (works even if role not yet installed)
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    Add-Result $cat 'Physical machine detection' 'INFO' "Model: $($cs.Model), Manufacturer: $($cs.Manufacturer)"

    # RAM — Microsoft minimum is 4 GB, recommended >= 32 GB for production
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    if ($ramGB -lt 4) {
        Add-Result $cat 'RAM minimum (4 GB)' 'FAIL' "${ramGB} GB installed — minimum 4 GB"
    } elseif ($ramGB -lt 32) {
        Add-Result $cat 'RAM minimum (4 GB)' 'WARN' "${ramGB} GB installed — 32 GB+ recommended for production Hyper-V"
    } else {
        Add-Result $cat 'RAM minimum (4 GB)' 'PASS' "${ramGB} GB installed"
    }

    # Processor count
    $cpuCount = (Get-CimInstance Win32_Processor).Count
    if (-not $cpuCount) { $cpuCount = 1 }
    Add-Result $cat 'Processor count' 'INFO' "$cpuCount logical processor(s)"

    # Hyper-V requirements via SystemInfo or MSFT_HyperVHardware if available
    try {
        # Virtualization-based check via Win32_Processor
        $procs = Get-CimInstance -ClassName Win32_Processor
        $vtEnabled  = $false
        $slatSupport = $false
        $depEnabled = $false

        foreach ($proc in $procs) {
            # VirtualizationFirmwareEnabled — hardware VT in BIOS
            if ($proc.VirtualizationFirmwareEnabled) { $vtEnabled = $true }
            # DataExecutionPrevention_Available
            if ($proc.DataExecutionPrevention_Available) { $depEnabled = $true }
            # SecondLevelAddressTranslationExtensions (SLAT)
            # Available on modern WMI; may not exist on older providers
            if ($proc.PSObject.Properties['SecondLevelAddressTranslationExtensions'] -and
                $proc.SecondLevelAddressTranslationExtensions) {
                $slatSupport = $true
            }
        }

        if ($vtEnabled) {
            Add-Result $cat 'Hardware virtualization (VT-x/AMD-V) enabled in BIOS' 'PASS' 'VirtualizationFirmwareEnabled = True'
        } else {
            Add-Result $cat 'Hardware virtualization (VT-x/AMD-V) enabled in BIOS' 'FAIL' 'VirtualizationFirmwareEnabled = False — enable in BIOS/UEFI'
        }

        if ($depEnabled) {
            Add-Result $cat 'Hardware DEP/NX enabled' 'PASS' 'DataExecutionPrevention_Available = True'
        } else {
            Add-Result $cat 'Hardware DEP/NX enabled' 'FAIL' 'DEP not available — required for Hyper-V'
        }

        if ($slatSupport) {
            Add-Result $cat 'SLAT (Second Level Address Translation)' 'PASS' 'Supported'
        } else {
            # WMI property may be absent on some systems; fall back to info
            Add-Result $cat 'SLAT (Second Level Address Translation)' 'WARN' 'Property not reported via WMI — verify CPU spec (Intel EPT / AMD RVI required)'
        }
    } catch {
        Add-Result $cat 'Processor virtualization features' 'WARN' "WMI query failed: $_"
    }

    # Hyper-V role pre-check via Get-WindowsOptionalFeature or ServerManager
    try {
        Import-Module ServerManager -ErrorAction Stop
        $hvFeature = Get-WindowsFeature -Name 'Hyper-V' -ErrorAction SilentlyContinue
        if ($hvFeature) {
            $state = $hvFeature.InstallState
            if ($state -eq 'Installed') {
                Add-Result $cat 'Hyper-V role' 'PASS' 'Already installed'
            } elseif ($state -eq 'Available') {
                Add-Result $cat 'Hyper-V role' 'PASS' 'Available for installation'
            } else {
                Add-Result $cat 'Hyper-V role' 'WARN' "State: $state"
            }
        } else {
            Add-Result $cat 'Hyper-V role' 'WARN' 'Feature not found via ServerManager (Desktop Experience required?)'
        }
    } catch {
        Add-Result $cat 'Hyper-V role availability' 'SKIP' 'ServerManager module unavailable'
    }

    # Failover Clustering feature
    try {
        $fcFeature = Get-WindowsFeature -Name 'Failover-Clustering' -ErrorAction SilentlyContinue
        if ($fcFeature) {
            $state = $fcFeature.InstallState
            if ($state -eq 'Installed') {
                Add-Result $cat 'Failover Clustering feature' 'PASS' 'Already installed'
            } elseif ($state -eq 'Available') {
                Add-Result $cat 'Failover Clustering feature' 'PASS' 'Available for installation'
            } else {
                Add-Result $cat 'Failover Clustering feature' 'WARN' "State: $state"
            }
        }
    } catch {
        Add-Result $cat 'Failover Clustering feature' 'SKIP' 'ServerManager module unavailable'
    }
}

#endregion

#region ── C. Network Configuration ──────────────────────────────────────────

function Test-NetworkConfiguration {
    Section 'C. Network Configuration'
    $cat = 'Network'

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    $adapterCount = ($adapters | Measure-Object).Count

    if ($adapterCount -lt 2) {
        Add-Result $cat 'NIC count (minimum 2 recommended)' 'WARN' "$adapterCount active NIC(s) — Microsoft recommends at least 2 (management + cluster/live-migration)"
    } else {
        Add-Result $cat 'NIC count (minimum 2 recommended)' 'PASS' "$adapterCount active NIC(s)"
    }

    foreach ($nic in $adapters) {
        $ipCfg = Get-NetIPConfiguration -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $ipCfg) { continue }

        $ipv4 = $ipCfg.IPv4Address
        if (-not $ipv4) {
            Add-Result $cat "NIC '$($nic.Name)' IPv4" 'WARN' 'No IPv4 address assigned'
            continue
        }

        $addr = $ipv4.IPAddress
        $prefix = $ipv4.PrefixLength

        # Static vs DHCP
        $dhcpEnabled = (Get-NetIPInterface -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4).Dhcp -eq 'Enabled'
        if ($dhcpEnabled) {
            Add-Result $cat "NIC '$($nic.Name)' static IP" 'FAIL' "IP $addr/$prefix is DHCP — cluster nodes must have static IP addresses"
        } else {
            Add-Result $cat "NIC '$($nic.Name)' static IP" 'PASS' "$addr/$prefix (static)"
        }

        # Gateway only on management NIC (warn if multiple NICs have default gateway)
        $gw = $ipCfg.IPv4DefaultGateway
        if ($gw) {
            Add-Result $cat "NIC '$($nic.Name)' default gateway" 'INFO' "Gateway: $($gw.NextHop)"
        }

        # DNS servers configured
        $dns = $ipCfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 }
        if ($dns -and $dns.ServerAddresses) {
            Add-Result $cat "NIC '$($nic.Name)' DNS servers" 'PASS' ($dns.ServerAddresses -join ', ')
        } else {
            Add-Result $cat "NIC '$($nic.Name)' DNS servers" 'WARN' 'No DNS servers configured on this interface'
        }
    }

    # DNS suffix / search list
    $dnsSuffix = (Get-DnsClientGlobalSetting).SuffixSearchList
    $domainSuffix = (Get-CimInstance Win32_ComputerSystem).Domain
    if ($dnsSuffix -or $domainSuffix) {
        $all = (@($dnsSuffix) + @($domainSuffix) | Select-Object -Unique | Where-Object { $_ }) -join ', '
        Add-Result $cat 'DNS suffix search list' 'PASS' $all
    } else {
        Add-Result $cat 'DNS suffix search list' 'WARN' 'No DNS suffix configured — FQDN resolution may fail'
    }

    # Multiple gateways (common misconfiguration)
    $allGateways = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.RouteMetric -ge 0 }
    if (($allGateways | Measure-Object).Count -gt 1) {
        Add-Result $cat 'Multiple default gateways' 'WARN' 'More than one default route detected — ensure routing is correct for cluster traffic'
    }

    # WinRM (required for cross-node management and Hyper-V live migration)
    $winrmSvc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($winrmSvc -and $winrmSvc.Status -eq 'Running') {
        Add-Result $cat 'WinRM service' 'PASS' 'Running'
    } else {
        Add-Result $cat 'WinRM service' 'WARN' 'Not running — run: winrm quickconfig'
    }
}

#endregion

#region ── D. Active Directory ───────────────────────────────────────────────

function Test-ActiveDirectory {
    Section 'D. Active Directory'
    $cat = 'ActiveDirectory'

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $domainRole = $cs.DomainRole
    # DomainRole: 0=Standalone Workstation, 1=Member Workstation, 2=Standalone Server, 3=Member Server, 4=DC, 5=PDC

    if ($cs.PartOfDomain) {
        Add-Result $cat 'Domain membership' 'PASS' "Member of: $($cs.Domain)"
    } else {
        Add-Result $cat 'Domain membership' 'FAIL' "Not domain-joined (DomainRole=$domainRole) — all cluster nodes must be in the same AD domain"
        return
    }

    # Test AD connectivity via LDAP
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        Add-Result $cat 'AD domain reachable' 'PASS' "Domain: $($domain.Name), Forest: $($domain.Forest.Name)"

        # Domain functional level (minimum Windows Server 2008 for clustering)
        $domainMode = $domain.DomainMode.ToString()
        Add-Result $cat 'AD domain functional level' 'INFO' $domainMode
    } catch {
        Add-Result $cat 'AD domain reachable' 'FAIL' "LDAP bind failed: $_"
    }

    # Locate a writable DC
    try {
        $dc = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().FindDomainController()
        Add-Result $cat 'Domain controller reachable' 'PASS' "DC: $($dc.Name)"
    } catch {
        Add-Result $cat 'Domain controller reachable' 'FAIL' "Cannot locate DC: $_"
    }

    # Computer account in AD
    try {
        $searcher = [adsisearcher]"(&(objectCategory=computer)(name=$($env:COMPUTERNAME)))"
        $result = $searcher.FindOne()
        if ($result) {
            Add-Result $cat 'Computer account in AD' 'PASS' $result.Properties['distinguishedname']
        } else {
            Add-Result $cat 'Computer account in AD' 'FAIL' 'Computer object not found in AD'
        }
    } catch {
        Add-Result $cat 'Computer account in AD' 'WARN' "ADSI query failed: $_"
    }

    # SPN check (HOST SPN required for Kerberos)
    try {
        $spnSearcher = [adsisearcher]"(&(objectCategory=computer)(name=$($env:COMPUTERNAME)))"
        $spnSearcher.PropertiesToLoad.Add('serviceprincipalname') | Out-Null
        $spnResult = $spnSearcher.FindOne()
        if ($spnResult) {
            $spns = $spnResult.Properties['serviceprincipalname']
            $hostSpn = $spns | Where-Object { $_ -match '^HOST/' }
            if ($hostSpn) {
                Add-Result $cat 'HOST SPN registered' 'PASS' "Found: $($hostSpn -join '; ')"
            } else {
                Add-Result $cat 'HOST SPN registered' 'WARN' 'No HOST SPN found — may cause Kerberos failures'
            }
        }
    } catch {
        Add-Result $cat 'HOST SPN registered' 'SKIP' "ADSI SPN query failed: $_"
    }

    # CredSSP delegation (needed for live migration)
    try {
        $credSSP = Get-WSManCredSSP -ErrorAction SilentlyContinue
        if ($credSSP -and $credSSP[0] -match 'enabled') {
            Add-Result $cat 'CredSSP (Live Migration delegation)' 'PASS' 'Client-side CredSSP enabled'
        } else {
            Add-Result $cat 'CredSSP (Live Migration delegation)' 'WARN' 'CredSSP not enabled — may be required for Live Migration'
        }
    } catch {
        Add-Result $cat 'CredSSP (Live Migration delegation)' 'SKIP' 'WSMan query unavailable'
    }
}

#endregion

#region ── E. DNS Resolution ──────────────────────────────────────────────────

function Test-DNSResolution {
    Section 'E. DNS Resolution'
    $cat = 'DNS'

    $fqdn     = [System.Net.Dns]::GetHostEntry('').HostName
    $hostname = $env:COMPUTERNAME

    # Forward resolution of own FQDN
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($fqdn)
        $ips = ($resolved | ForEach-Object { $_.ToString() }) -join ', '
        Add-Result $cat "Forward DNS: $fqdn" 'PASS' "Resolved to: $ips"
    } catch {
        Add-Result $cat "Forward DNS: $fqdn" 'FAIL' "Cannot resolve own FQDN — $_"
    }

    # Reverse DNS (PTR) for each NIC IP
    $nicIPs = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -ne 'Loopback Pseudo-Interface 1' }

    foreach ($nicIP in $nicIPs) {
        $ip = $nicIP.IPAddress
        try {
            $ptr = [System.Net.Dns]::GetHostEntry($ip)
            Add-Result $cat "Reverse DNS (PTR): $ip" 'PASS' "-> $($ptr.HostName)"
        } catch {
            Add-Result $cat "Reverse DNS (PTR): $ip" 'WARN' "No PTR record — cluster name registration may fail"
        }
    }

    # AD DNS SRV records
    $domainName = (Get-CimInstance Win32_ComputerSystem).Domain
    if ($domainName -and $domainName -ne 'WORKGROUP') {
        foreach ($srvRecord in @("_ldap._tcp.$domainName", "_kerberos._tcp.$domainName", "_ldap._tcp.dc._msdcs.$domainName")) {
            try {
                $srv = Resolve-DnsName -Name $srvRecord -Type SRV -ErrorAction Stop
                Add-Result $cat "AD SRV record: $srvRecord" 'PASS' "$($srv.Count) record(s) found"
            } catch {
                Add-Result $cat "AD SRV record: $srvRecord" 'FAIL' "Not found — AD DNS not properly configured"
            }
        }

        # DNS dynamic update (required for cluster CNO registration)
        try {
            $zone = Resolve-DnsName -Name $domainName -Type SOA -ErrorAction Stop
            Add-Result $cat 'DNS SOA for domain' 'PASS' "Primary NS: $($zone[0].PrimaryServer)"
        } catch {
            Add-Result $cat 'DNS SOA for domain' 'WARN' "SOA query failed — verify DNS zone allows dynamic updates"
        }
    }
}

#endregion

#region ── F. Time Synchronization ───────────────────────────────────────────

function Test-TimeSync {
    Section 'F. Time Synchronization'
    $cat = 'TimeSync'

    # W32TM service
    $w32tm = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    if ($w32tm -and $w32tm.Status -eq 'Running') {
        Add-Result $cat 'Windows Time service (W32TM)' 'PASS' 'Running'
    } else {
        Add-Result $cat 'Windows Time service (W32TM)' 'FAIL' "Status: $($w32tm.Status) — run: w32tm /config /syncfromflags:domhier /update && net start W32Time"
        return
    }

    # Current NTP source
    try {
        $w32Query = & w32tm /query /source 2>&1
        Add-Result $cat 'NTP source' 'INFO' ($w32Query -join '')
    } catch {
        Add-Result $cat 'NTP source' 'WARN' "w32tm /query failed: $_"
    }

    # Time offset from DC (Kerberos requires < 300 seconds = 5 minutes)
    try {
        $w32Status = & w32tm /query /status 2>&1
        $offsetLine = $w32Status | Where-Object { $_ -match 'offset|décalage' } | Select-Object -First 1
        if ($offsetLine) {
            # Extract numeric offset in seconds
            if ($offsetLine -match '([+-]?\d+[\.,]\d+)\s*s') {
                $offsetSec = [math]::Abs([double]($Matches[1] -replace ',', '.'))
                if ($offsetSec -lt 60) {
                    Add-Result $cat 'Time offset (Kerberos < 300s)' 'PASS' "${offsetSec}s offset"
                } elseif ($offsetSec -lt 300) {
                    Add-Result $cat 'Time offset (Kerberos < 300s)' 'WARN' "${offsetSec}s offset — approaching Kerberos limit"
                } else {
                    Add-Result $cat 'Time offset (Kerberos < 300s)' 'FAIL' "${offsetSec}s offset — exceeds 5-minute Kerberos limit — cluster authentication will fail"
                }
            } else {
                Add-Result $cat 'Time offset' 'INFO' $offsetLine.Trim()
            }
        } else {
            Add-Result $cat 'Time offset' 'WARN' 'Could not parse offset from w32tm output'
        }
    } catch {
        Add-Result $cat 'Time offset' 'WARN' "w32tm /query /status failed: $_"
    }

    # Local system clock
    Add-Result $cat 'Current system time (UTC)' 'INFO' (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
}

#endregion

#region ── G. Firewall ────────────────────────────────────────────────────────

function Test-FirewallRules {
    Section 'G. Firewall & Required Ports'
    $cat = 'Firewall'

    # Overall firewall profile status
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($profile in $profiles) {
            $status = if ($profile.Enabled) { 'Enabled' } else { 'Disabled' }
            $level  = if ($profile.Enabled) { 'INFO' } else { 'WARN' }
            Add-Result $cat "Firewall profile: $($profile.Name)" $level $status
        }
    } catch {
        Add-Result $cat 'Firewall profile status' 'SKIP' "NetFirewallProfile unavailable: $_"
    }

    # Required cluster rules (check built-in rules are enabled)
    $requiredRuleNames = @(
        # Failover Clustering
        'Failover Clusters (RPC)',
        'Failover Clusters (RPC-EPMAP)',
        # WMI
        'Windows Management Instrumentation (DCOM-In)',
        # SMB
        'File and Printer Sharing (SMB-In)',
        # Remote Event Log (for cluster health monitoring)
        'Remote Event Log Management (RPC)'
    )

    foreach ($ruleName in $requiredRuleNames) {
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if (-not $rule) {
            Add-Result $cat "FW rule: $ruleName" 'WARN' 'Rule not found (may have different name or be covered by group policy)'
        } elseif ($rule.Enabled -eq 'True') {
            Add-Result $cat "FW rule: $ruleName" 'PASS' 'Enabled'
        } else {
            Add-Result $cat "FW rule: $ruleName" 'FAIL' 'Exists but DISABLED'
        }
    }

    # Hyper-V Live Migration rule group
    $liveMigRules = Get-NetFirewallRule -Group '@%SystemRoot%\system32\vmms.exe,-105' -ErrorAction SilentlyContinue
    if (-not $liveMigRules) {
        # Try by DisplayGroup
        $liveMigRules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayGroup -match 'Hyper-V' -and $_.Direction -eq 'Inbound' }
    }
    if ($liveMigRules) {
        $enabledCount = ($liveMigRules | Where-Object { $_.Enabled -eq 'True' } | Measure-Object).Count
        $totalCount   = ($liveMigRules | Measure-Object).Count
        if ($enabledCount -eq $totalCount) {
            Add-Result $cat 'Hyper-V firewall rules (Live Migration)' 'PASS' "$enabledCount/$totalCount rules enabled"
        } else {
            Add-Result $cat 'Hyper-V firewall rules (Live Migration)' 'WARN' "$enabledCount/$totalCount rules enabled"
        }
    } else {
        Add-Result $cat 'Hyper-V firewall rules (Live Migration)' 'SKIP' 'Rules not found — Hyper-V role may not be installed yet'
    }

    # Validate critical ports for clustering are reachable locally (loopback)
    $criticalPorts = @(
        @{ Port = 135;  Desc = 'RPC Endpoint Mapper' },
        @{ Port = 445;  Desc = 'SMB (Cluster communications)' },
        @{ Port = 3343; Desc = 'Cluster Service' }
    )
    foreach ($p in $criticalPorts) {
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $result = $tcp.BeginConnect('127.0.0.1', $p.Port, $null, $null)
            $connected = $result.AsyncWaitHandle.WaitOne(1000, $false)
            $tcp.Close()
            if ($connected) {
                Add-Result $cat "Local port $($p.Port)/TCP ($($p.Desc))" 'PASS' 'Listening'
            } else {
                Add-Result $cat "Local port $($p.Port)/TCP ($($p.Desc))" 'WARN' 'Not listening — service may be stopped or port blocked'
            }
        } catch {
            Add-Result $cat "Local port $($p.Port)/TCP ($($p.Desc))" 'WARN' "Test failed: $_"
        }
    }
}

#endregion

#region ── H. Storage ────────────────────────────────────────────────────────

function Test-Storage {
    Section 'H. Storage'
    $cat = 'Storage'

    # System drive free space (minimum 10 GB free, warn below 20%)
    $systemDrive = $env:SystemDrive
    $disk = Get-PSDrive -Name ($systemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($disk) {
        $freeGB  = [math]::Round($disk.Free / 1GB, 1)
        $totalGB = [math]::Round(($disk.Used + $disk.Free) / 1GB, 1)
        $pctFree = if ($totalGB -gt 0) { [math]::Round(($disk.Free / ($disk.Used + $disk.Free)) * 100, 0) } else { 0 }

        if ($freeGB -lt 10) {
            Add-Result $cat "System drive free space ($systemDrive)" 'FAIL' "${freeGB} GB free / ${totalGB} GB ($pctFree%) — minimum 10 GB recommended"
        } elseif ($pctFree -lt 20) {
            Add-Result $cat "System drive free space ($systemDrive)" 'WARN' "${freeGB} GB free / ${totalGB} GB ($pctFree%)"
        } else {
            Add-Result $cat "System drive free space ($systemDrive)" 'PASS' "${freeGB} GB free / ${totalGB} GB ($pctFree%)"
        }
    }

    # All volumes
    $volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.FileSystem }
    foreach ($vol in $volumes) {
        $fs = $vol.FileSystem
        # Hyper-V recommended: NTFS or ReFS
        if ($fs -notin @('NTFS', 'ReFS', 'CSV')) {
            Add-Result $cat "Volume $($vol.DriveLetter): filesystem" 'WARN' "$fs — Hyper-V VHDs should be on NTFS or ReFS volumes"
        } else {
            $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
            Add-Result $cat "Volume $($vol.DriveLetter): filesystem" 'PASS' "$fs, ${freeGB} GB free"
        }
        # Volume health
        if ($vol.HealthStatus -ne 'Healthy') {
            Add-Result $cat "Volume $($vol.DriveLetter): health" 'FAIL' "$($vol.HealthStatus)"
        }
    }

    # Multipath I/O (MPIO) — recommended for SAN-attached cluster storage
    $mpio = Get-WindowsFeature -Name 'Multipath-IO' -ErrorAction SilentlyContinue
    if ($mpio) {
        if ($mpio.InstallState -eq 'Installed') {
            Add-Result $cat 'MPIO (Multipath I/O)' 'PASS' 'Installed'
        } else {
            Add-Result $cat 'MPIO (Multipath I/O)' 'WARN' "State: $($mpio.InstallState) — required for FC/iSCSI shared storage with multiple paths"
        }
    }

    # iSCSI initiator service
    $iscsiSvc = Get-Service -Name MSiSCSI -ErrorAction SilentlyContinue
    if ($iscsiSvc) {
        if ($iscsiSvc.Status -eq 'Running') {
            Add-Result $cat 'iSCSI Initiator service' 'INFO' 'Running'
        } else {
            Add-Result $cat 'iSCSI Initiator service' 'INFO' "Status: $($iscsiSvc.Status) — start if using iSCSI shared storage"
        }
    }
}

#endregion

#region ── I. Cluster Pre-validation (PreCluster) ────────────────────────────

function Test-ClusterReadiness {
    param([string[]]$Nodes)

    Section 'I. Failover Cluster Pre-validation'
    $cat = 'Cluster'

    $localNode   = $env:COMPUTERNAME
    $allNodes    = (@($localNode) + $Nodes | Select-Object -Unique)
    $nodeCount   = $allNodes.Count

    Add-Result $cat 'Cluster node count' 'INFO' "$nodeCount node(s): $($allNodes -join ', ')"

    # Quorum recommendation per Microsoft documentation
    # Ref: https://learn.microsoft.com/en-us/windows-server/failover-clustering/manage-cluster-quorum
    $quorumRec = switch ($nodeCount) {
        1 { 'N/A — single node' }
        2 { 'Node and File Share Majority (witness required) — 2 nodes always need a witness' }
        { $_ % 2 -eq 1 -and $_ -ge 3 } { "Node Majority ($nodeCount votes — odd number, no witness required)" }
        { $_ % 2 -eq 0 -and $_ -ge 4 } { "Node and Disk Majority or Node and File Share Majority (witness required — even number of nodes)" }
        default { 'Node Majority' }
    }
    $quorumLevel = if ($nodeCount -ge 3) { 'PASS' } else { 'WARN' }
    Add-Result $cat 'Quorum recommendation' $quorumLevel $quorumRec

    # Witness share connectivity
    if ($WitnessShare -ne '') {
        if (Test-Path $WitnessShare -ErrorAction SilentlyContinue) {
            Add-Result $cat "File share witness: $WitnessShare" 'PASS' 'Accessible'
        } else {
            Add-Result $cat "File share witness: $WitnessShare" 'FAIL' "Cannot access — required for quorum with $nodeCount nodes"
        }
    } elseif ($nodeCount -eq 2 -or ($nodeCount % 2 -eq 0)) {
        Add-Result $cat 'File share witness' 'WARN' "Node count ($nodeCount) requires a witness — specify -WitnessShare to validate"
    }

    # Cross-node checks
    $nodeOsVersions = @{}
    $nodeOsVersions[$localNode] = [System.Environment]::OSVersion.Version.ToString()

    foreach ($node in $Nodes) {
        # Reachability
        $ping = Test-Connection -ComputerName $node -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $ping) {
            Add-Result $cat "Node $node reachable" 'FAIL' "Cannot ping $node — node must be reachable before joining cluster"
            continue
        }
        Add-Result $cat "Node $node reachable" 'PASS' 'Ping OK'

        # WMI / CIM to remote node
        try {
            $remoteOS = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $node -ErrorAction Stop
            $nodeOsVersions[$node] = $remoteOS.Version
            Add-Result $cat "Node $node OS" 'INFO' "$($remoteOS.Caption) (Build $($remoteOS.BuildNumber))"

            # Same domain
            $remoteCS = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $node -ErrorAction Stop
            $localDomain  = (Get-CimInstance Win32_ComputerSystem).Domain
            if ($remoteCS.Domain -eq $localDomain) {
                Add-Result $cat "Node $node domain" 'PASS' "Same domain: $($remoteCS.Domain)"
            } else {
                Add-Result $cat "Node $node domain" 'FAIL' "Domain mismatch: $($remoteCS.Domain) != $localDomain — all nodes must be in the same domain"
            }
        } catch {
            Add-Result $cat "Node $node WMI/CIM" 'WARN' "Remote WMI unavailable: $_ — ensure WinRM / firewall allows CIM"
        }
    }

    # OS version consistency across nodes
    $distinctVersions = $nodeOsVersions.Values | Select-Object -Unique
    if ($distinctVersions.Count -eq 1) {
        Add-Result $cat 'OS version consistency' 'PASS' "All nodes: $($distinctVersions[0])"
    } elseif ($distinctVersions.Count -gt 1) {
        Add-Result $cat 'OS version consistency' 'FAIL' "Version mismatch: $($nodeOsVersions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Join-String -Separator ', ') — all nodes must run the same Windows Server version"
    }

    # Failover Clustering feature on all nodes
    foreach ($node in $Nodes) {
        try {
            $fc = Invoke-Command -ComputerName $node -ScriptBlock {
                Import-Module ServerManager
                (Get-WindowsFeature -Name 'Failover-Clustering').InstallState
            } -ErrorAction Stop
            if ($fc -eq 'Installed') {
                Add-Result $cat "Node $node Failover-Clustering feature" 'PASS' 'Installed'
            } else {
                Add-Result $cat "Node $node Failover-Clustering feature" 'WARN' "State: $fc"
            }
        } catch {
            Add-Result $cat "Node $node Failover-Clustering feature" 'SKIP' "Remote query failed: $_"
        }
    }

    # Cluster Validation Wizard (Test-Cluster) — optional due to duration
    if (-not $SkipClusterValidation) {
        $fcModule = Get-Module -Name FailoverClusters -ListAvailable -ErrorAction SilentlyContinue
        if ($fcModule) {
            Import-Module FailoverClusters -ErrorAction SilentlyContinue
            try {
                Write-Log "Running Test-Cluster on nodes: $($allNodes -join ', ') — this may take several minutes..." -Level INFO
                $reportPath = [System.IO.Path]::Combine($env:TEMP, "ClusterValidation-$(Get-Date -Format 'yyyyMMdd-HHmmss').htm")
                $validation = Test-Cluster -Node $allNodes -ReportName $reportPath -ErrorAction Stop
                $failed  = ($validation | Where-Object { $_.Status -eq 'Failed' } | Measure-Object).Count
                $warned  = ($validation | Where-Object { $_.Status -eq 'Warning' } | Measure-Object).Count
                $passed  = ($validation | Where-Object { $_.Status -eq 'Successful' } | Measure-Object).Count
                if ($failed -eq 0) {
                    Add-Result $cat 'Test-Cluster validation' 'PASS' "$passed passed, $warned warnings — report: $reportPath"
                } else {
                    Add-Result $cat 'Test-Cluster validation' 'FAIL' "$failed failed, $warned warnings, $passed passed — see report: $reportPath"
                }
            } catch {
                Add-Result $cat 'Test-Cluster validation' 'WARN' "Validation run failed: $_"
            }
        } else {
            Add-Result $cat 'Test-Cluster validation' 'SKIP' 'FailoverClusters module not available — install Failover-Clustering feature first'
        }
    } else {
        Add-Result $cat 'Test-Cluster validation' 'SKIP' 'Skipped via -SkipClusterValidation'
    }

    # Cluster-dedicated network recommendation
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    if ($adapters.Count -ge 3) {
        Add-Result $cat 'Network segregation (management / cluster / live migration)' 'PASS' "$($adapters.Count) active NICs — sufficient for network segregation"
    } elseif ($adapters.Count -eq 2) {
        Add-Result $cat 'Network segregation' 'WARN' '2 active NICs — Microsoft recommends 3+ separate networks: management, cluster heartbeat, live migration'
    } else {
        Add-Result $cat 'Network segregation' 'FAIL' "Only 1 NIC — cannot segregate management, cluster, and live-migration traffic"
    }
}

#endregion

#region ── Summary & Report ───────────────────────────────────────────────────

function Write-Summary {
    $passCount = ($script:Results | Where-Object { $_.Status -eq 'PASS' } | Measure-Object).Count
    $warnCount = ($script:Results | Where-Object { $_.Status -eq 'WARN' } | Measure-Object).Count
    $failCount = ($script:Results | Where-Object { $_.Status -eq 'FAIL' } | Measure-Object).Count
    $infoCount = ($script:Results | Where-Object { $_.Status -in 'INFO', 'SKIP' } | Measure-Object).Count

    Write-Log '' -Level INFO
    Write-Log '════════════════════════════════════════════════════════' -Level SECTION
    Write-Log "  SUMMARY  |  PASS: $passCount  WARN: $warnCount  FAIL: $failCount  INFO/SKIP: $infoCount" -Level SECTION
    Write-Log '════════════════════════════════════════════════════════' -Level SECTION

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
        $bg = switch ($r.Status) {
            'PASS' { '#d4edda' }
            'WARN' { '#fff3cd' }
            'FAIL' { '#f8d7da' }
            'SKIP' { '#e2e3e5' }
            default { '#ffffff' }
        }
        $icon = switch ($r.Status) {
            'PASS' { '&#9989;' }
            'WARN' { '&#9888;' }
            'FAIL' { '&#10060;' }
            'SKIP' { '&#9940;' }
            default { '&#8505;' }
        }
        "<tr style='background:$bg'>
            <td>$($r.Category)</td>
            <td>$($r.Check)</td>
            <td>$icon $($r.Status)</td>
            <td>$($r.Detail)</td>
        </tr>"
    }

    $passCount = ($script:Results | Where-Object { $_.Status -eq 'PASS' } | Measure-Object).Count
    $warnCount = ($script:Results | Where-Object { $_.Status -eq 'WARN' } | Measure-Object).Count
    $failCount = ($script:Results | Where-Object { $_.Status -eq 'FAIL' } | Measure-Object).Count

    $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Hyper-V Node Readiness — $env:COMPUTERNAME</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #f5f5f5; }
  h1   { color: #0078d4; }
  table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px #ccc; }
  th   { background: #0078d4; color: white; padding: 8px 12px; text-align: left; }
  td   { padding: 7px 12px; border-bottom: 1px solid #e0e0e0; font-size: 0.9em; }
  .badge { display:inline-block; padding: 2px 10px; border-radius: 12px; font-weight: bold; }
  .pass { background:#28a745; color:white; }
  .warn { background:#ffc107; color:#333; }
  .fail { background:#dc3545; color:white; }
</style>
</head>
<body>
<h1>Hyper-V Node Readiness Report</h1>
<p><strong>Host:</strong> $env:COMPUTERNAME &nbsp;|&nbsp;
   <strong>Mode:</strong> $Mode &nbsp;|&nbsp;
   <strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<p>
  <span class="badge pass">PASS: $passCount</span>&nbsp;
  <span class="badge warn">WARN: $warnCount</span>&nbsp;
  <span class="badge fail">FAIL: $failCount</span>
</p>
<table>
  <thead><tr><th>Category</th><th>Check</th><th>Status</th><th>Detail</th></tr></thead>
  <tbody>
    $($rows -join "`n")
  </tbody>
</table>
<hr>
<small>Generated by Test-HyperVNodeReadiness.ps1 — vmware2hyperv</small>
</body>
</html>
"@
    $html | Out-File -FilePath $Path -Encoding UTF8
    Write-Log "HTML report written: $Path" -Level INFO
}

#endregion

#region ── Main ──────────────────────────────────────────────────────────────

Write-Log "Test-HyperVNodeReadiness — Host: $env:COMPUTERNAME — Mode: $Mode" -Level SECTION
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

$failCount = Write-Summary

if ($HtmlReportPath -ne '') {
    Write-HtmlReport -Path $HtmlReportPath
}

exit $(if ($failCount -gt 0) { 1 } else { 0 })

#endregion
