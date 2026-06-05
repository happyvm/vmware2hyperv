#Requires -Version 5.1
<#
.SYNOPSIS
    Validate OS readiness for a future Hyper-V node (WS2022/2025) and/or failover cluster.

.DESCRIPTION
    Runs a comprehensive set of checks derived from Microsoft documentation:
      A. OS edition (Datacenter/Standard) and build — targets WS2022 and WS2025 only
      B. Hardware: CPU virtualization, SLAT, DEP, RAM, Hyper-V/Failover-Clustering features
      C. Network: NIC count, static IPs, RDMA (S2D), DNS, WinRM
      D. Active Directory: domain membership, DC reachability, computer account, SPN, Live Migration Kerberos delegation, CredSSP
      E. DNS: forward/reverse resolution, AD SRV records, dynamic update
      F. Time synchronization (W32TM, Kerberos < 5 minutes)
      G. Firewall: cluster/SMB/Live-Migration rules and critical TCP ports
      H. Storage — mode-specific:
            SAN : MPIO required, iSCSI/FC initiator, disk visibility across nodes
            S2D : Datacenter edition, physical disks eligible, bus type, no shared SAS,
                  RDMA NICs, SMB Direct, drive tier inventory
      I. Failover Cluster: quorum recommendation, cross-node OS/domain/hotfix consistency,
         Test-Cluster validation, network segregation
      J. Service account & OU AD permissions:
            account exists and is enabled, local admin on this node,
            CreateChild (computer) on target OU, Write All Properties on computer objects,
            OU accidental-deletion protection warning, CreateChild (dnsNode) on DNS zone,
            DNS scavenging state, prestaged CNO/VCO check
      K. Event Log Health (last 24h): System/Application critical errors, disk/storage
            driver errors (disk, storahci, stornvme), network driver errors,
            Hyper-V VMMS and Failover Clustering operational errors

    Network section also covers:
      - IPv6 consistency (uniform enable/disable across nodes)
      - LBFO deprecation detection (migrate to SET on WS2022/2025)
      - Role-aware NIC checks via NetworkAdapters/NetworkRoles mapping
      - MTU / Jumbo frames only on iSCSI and S2D storage NICs
      - VMQ on VM traffic, not management/cluster heartbeat
      - RSS (Receive Side Scaling)
      - RDMA/PFC/DCB only on S2D storage or RDMA Live Migration adapters

    Modes:
      PreNode     — Validate this machine as a standalone Hyper-V host
      PreCluster  — Validate this machine and remote nodes for failover clustering
      Both        — Run all checks (default)

    Exit codes:
      0 = All checks passed (or only warnings)
      1 = One or more checks failed

.PARAMETER ConfigFile
    Path to the hyperv-check.psd1 configuration file. The script searches in order:
      1. The path provided here
      2. hyperv-check.psd1 in the same directory as the script
      3. hyperv-check.psd1 in the current working directory
    If no file is found, the script enters interactive mode and prompts for each value.

.EXAMPLE
    # Use a config file (recommended)
    .\Test-HyperVNodeReadiness.ps1
    .\Test-HyperVNodeReadiness.ps1 -ConfigFile C:\Admin\hyperv-check.psd1

.EXAMPLE
    # Interactive mode (no config file present)
    .\Test-HyperVNodeReadiness.ps1

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
    # Path to hyperv-check.psd1. If empty, the script searches next to itself then CWD.
    # If still not found, interactive prompts are shown.
    [string]$ConfigFile = ''
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

# Prompt helper — returns config value if present, otherwise prompts interactively
function Read-CfgValue {
    param(
        [hashtable]$Cfg,
        [string]$Key,
        [string]$Prompt,
        [string]$Default = '',
        [switch]$IsArray,
        [switch]$Required
    )
    $val = $Cfg[$Key]
    if ($null -eq $val -or ($val -is [string] -and $val -eq '')) {
        $hint  = if ($Default -ne '') { " [$Default]" } else { '' }
        $input = Read-Host "$Prompt$hint"
        if ($input -eq '' -and $Default -ne '') { $input = $Default }
        if ($input -eq '' -and $Required) { throw "Required value '$Key' was not provided." }
        $val = $input
    }
    if ($IsArray) {
        if ($val -is [array]) { return @($val | Where-Object { $_ -ne '' }) }
        return @($val -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    return $val
}

function Initialize-Config {
    # Locate config file
    $candidates = @(
        $ConfigFile,
        (Join-Path $PSScriptRoot 'hyperv-check.psd1'),
        (Join-Path (Get-Location) 'hyperv-check.psd1')
    ) | Where-Object { $_ -ne '' }

    $cfgPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    $cfg     = @{}

    if ($cfgPath) {
        Write-Host "[======] Loading config: $cfgPath" -ForegroundColor Cyan
        $cfg = Import-PowerShellDataFile -Path $cfgPath
    } else {
        Write-Host "[======] No hyperv-check.psd1 found — interactive mode" -ForegroundColor Yellow
        Write-Host "         (Create hyperv-check.psd1 from the template to skip these prompts)" -ForegroundColor DarkYellow
        Write-Host ''
    }

    # ── Populate script-scope configuration variables ─────────────────────────
    $script:Mode         = Read-CfgValue $cfg 'Mode'         'Mode (PreNode / PreCluster / Both)' 'Both'
    if ($script:Mode -notin @('PreNode','PreCluster','Both')) { $script:Mode = 'Both' }

    $script:StorageType  = Read-CfgValue $cfg 'StorageType'  'Storage type (SAN / S2D)' 'SAN'
    if ($script:StorageType -notin @('SAN','S2D')) { $script:StorageType = 'SAN' }

    $script:LiveMigrationAuth = if ($cfg.ContainsKey('LiveMigrationAuth') -and $cfg['LiveMigrationAuth']) { $cfg['LiveMigrationAuth'] } else { 'Kerberos' }
    if ($script:LiveMigrationAuth -notin @('Kerberos','CredSSP')) { $script:LiveMigrationAuth = 'Kerberos' }

    $script:NetworkAdapters = @()
    if ($cfg.ContainsKey('NetworkAdapters') -and $cfg['NetworkAdapters']) {
        $script:NetworkAdapters = @($cfg['NetworkAdapters'])
    } elseif ($cfg.ContainsKey('NetworkRoles') -and $cfg['NetworkRoles']) {
        $script:NetworkAdapters = @($cfg['NetworkRoles'])
    }

    $script:ClusterNodes = Read-CfgValue $cfg 'ClusterNodes' 'Other cluster node FQDNs/IPs (comma-separated, empty = single node)' '' -IsArray
    $script:WitnessShare = Read-CfgValue $cfg 'WitnessShare' 'File share witness UNC (e.g. \\srv\witness, empty to skip)'
    $script:ClusterName  = Read-CfgValue $cfg 'ClusterName'  'Planned cluster NetBIOS name (e.g. CLHYPERV01, empty to skip)'
    $script:ClusterOU    = Read-CfgValue $cfg 'ClusterOU'    'OU DN for CNO/VCOs (e.g. OU=Clusters,DC=corp,DC=local, empty to skip)'
    $script:ServiceAccount = Read-CfgValue $cfg 'ServiceAccount' 'Service account SAMAccountName (e.g. CORP\svc_cluster, empty to skip)'

    # Infrastructure endpoints used for port checks
    $script:DomainControllers = Read-CfgValue $cfg 'DomainControllers' 'Domain controller FQDNs/IPs for port tests (comma-sep, empty = auto-discover)' '' -IsArray
    $script:IscsiTargets      = Read-CfgValue $cfg 'IscsiTargets'      'iSCSI target FQDNs/IPs (comma-sep, SAN only, empty to skip)' '' -IsArray
    $script:NtpServer         = Read-CfgValue $cfg 'NtpServer'         'NTP server FQDN/IP for port test (empty to skip)'
    $script:ScvmmServer       = Read-CfgValue $cfg 'ScvmmServer'       'SCVMM server FQDN/IP (empty to skip)'

    $script:SkipClusterValidation = [bool]($cfg['SkipClusterValidation'])

    # Optional platform security requirements. When left disabled, the related
    # checks are informational only; when enabled, missing/disabled features are
    # reported as WARN/FAIL.
    $script:RequireSecureBoot = [bool]($cfg['RequireSecureBoot'])
    $script:RequireTpm        = [bool]($cfg['RequireTpm'])
    $script:RequireBitLocker  = [bool]($cfg['RequireBitLocker'])
    $script:RequireVbs        = [bool]($cfg['RequireVbs'])
    $script:RequireHvci       = [bool]($cfg['RequireHvci'])

    # Log / report paths
    $logCfg = $cfg['LogFile']
    $script:LogFile = if ($logCfg -and $logCfg -ne '') { $logCfg } else {
        ".\HyperV-Readiness-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    }
    $script:HtmlReportPath = if ($cfg['HtmlReportPath']) { $cfg['HtmlReportPath'] } else { '' }

    # Auto-discover DCs if none supplied and machine is domain-joined
    if (-not $script:DomainControllers -or $script:DomainControllers.Count -eq 0) {
        try {
            $discovered = @(
                [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers |
                Select-Object -ExpandProperty Name -First 3
            )
            if ($discovered.Count -gt 0) {
                $script:DomainControllers = $discovered
                Write-Host "[ INFO ] Auto-discovered DCs: $($discovered -join ', ')" -ForegroundColor Gray
            }
        } catch { }
    }

    # Summary of active config
    Write-Host ''
    Write-Host "[======] Configuration summary" -ForegroundColor Cyan
    Write-Host "  Mode          : $($script:Mode)"
    Write-Host "  StorageType   : $($script:StorageType)"
    Write-Host "  LiveMigrationAuth: $($script:LiveMigrationAuth)"
    Write-Host "  ClusterNodes  : $(if ($script:ClusterNodes) { $script:ClusterNodes -join ', ' } else { '(none)' })"
    Write-Host "  WitnessShare  : $(if ($script:WitnessShare) { $script:WitnessShare } else { '(none)' })"
    Write-Host "  ServiceAccount: $(if ($script:ServiceAccount) { $script:ServiceAccount } else { '(none)' })"
    Write-Host "  DomainControllers: $(if ($script:DomainControllers) { $script:DomainControllers -join ', ' } else { '(none)' })"
    $networkAdapterSummary = if ($script:NetworkAdapters -and $script:NetworkAdapters.Count -gt 0) { "$($script:NetworkAdapters.Count) role mapping(s)" } else { '(none)' }
    Write-Host "  NetworkAdapters: $networkAdapterSummary"
    $platformRequirements = @(
        $(if ($script:RequireSecureBoot) { 'SecureBoot' }),
        $(if ($script:RequireTpm) { 'TPM' }),
        $(if ($script:RequireBitLocker) { 'BitLocker' }),
        $(if ($script:RequireVbs) { 'VBS' }),
        $(if ($script:RequireHvci) { 'HVCI' })
    ) | Where-Object { $_ }
    Write-Host "  PlatformSecurity: $(if ($platformRequirements) { $platformRequirements -join ', ' } else { 'informational only' })"
    Write-Host "  LogFile       : $($script:LogFile)"
    Write-Host ''
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

    # PowerShell execution policy
    $execPolicy = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction SilentlyContinue
    if ($execPolicy -in @('Restricted', 'AllSigned')) {
        Add-Result $cat 'PowerShell execution policy' 'FAIL' "$execPolicy — cluster and Hyper-V management scripts require at least RemoteSigned: Set-ExecutionPolicy RemoteSigned -Force"
    } elseif ($execPolicy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        Add-Result $cat 'PowerShell execution policy' 'PASS' $execPolicy
    } else {
        Add-Result $cat 'PowerShell execution policy' 'INFO' "Scope LocalMachine: $execPolicy — effective policy may differ (GPO)"
    }
}

#endregion

#region ── B. Platform Security ───────────────────────────────────────────────

function Test-PlatformSecurity {
    Section 'B. Platform Security'
    $cat = 'Platform Security'

    $anyRequirement = $script:RequireSecureBoot -or $script:RequireTpm -or $script:RequireBitLocker -or $script:RequireVbs -or $script:RequireHvci
    if (-not $anyRequirement) {
        Add-Result $cat 'Platform security requirements' 'INFO' 'No security baseline requirement enabled; checks below are informational only'
    } else {
        $enabledRequirements = @(
            $(if ($script:RequireSecureBoot) { 'Secure Boot' }),
            $(if ($script:RequireTpm) { 'TPM' }),
            $(if ($script:RequireBitLocker) { 'BitLocker' }),
            $(if ($script:RequireVbs) { 'VBS/Credential Guard' }),
            $(if ($script:RequireHvci) { 'HVCI' })
        ) | Where-Object { $_ }
        Add-Result $cat 'Platform security requirements' 'INFO' "Required: $($enabledRequirements -join ', ')"
    }

    # UEFI / Legacy boot detection from firmware type. The registry value is
    # generally available on modern Windows; bcdedit is a secondary fallback.
    $firmwareType = 'Unknown'
    try {
        $peFirmware = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction SilentlyContinue
        if ($peFirmware -and $null -ne $peFirmware.PEFirmwareType) {
            $firmwareType = switch ([int]$peFirmware.PEFirmwareType) {
                1 { 'BIOS/Legacy' }
                2 { 'UEFI' }
                default { "Unknown ($($peFirmware.PEFirmwareType))" }
            }
        }
    } catch { }
    if ($firmwareType -eq 'Unknown') {
        try {
            $bcdFirmware = (& bcdedit /enum '{current}' 2>$null | Select-String -Pattern 'winload\.efi|winload\.exe')
            if ($bcdFirmware -match 'winload\.efi') { $firmwareType = 'UEFI' }
            elseif ($bcdFirmware -match 'winload\.exe') { $firmwareType = 'BIOS/Legacy' }
        } catch { }
    }
    $firmwareStatus = if ($firmwareType -eq 'BIOS/Legacy' -and $script:RequireSecureBoot) { 'FAIL' } elseif ($firmwareType -eq 'Unknown') { 'INFO' } else { 'INFO' }
    Add-Result $cat 'Firmware boot mode' $firmwareStatus $firmwareType

    # Secure Boot. Confirm-SecureBootUEFI returns $true/$false on UEFI systems
    # and throws on unsupported platforms or insufficient access.
    $secureBootState = $null
    $secureBootDetail = ''
    try {
        $secureBootCmd = Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        if ($secureBootCmd) {
            $secureBootState = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
            $secureBootDetail = if ($secureBootState) { 'Enabled' } else { 'Disabled' }
        } else {
            $secureBootDetail = 'Confirm-SecureBootUEFI cmdlet unavailable'
        }
    } catch {
        $secureBootDetail = "Unable to query Secure Boot: $($_.Exception.Message)"
        if ($firmwareType -eq 'BIOS/Legacy') { $secureBootDetail = 'Not available in BIOS/Legacy boot mode' }
    }
    $secureBootStatus = if ($script:RequireSecureBoot) {
        if ($secureBootState -eq $true) { 'PASS' } elseif ($secureBootState -eq $false -or $firmwareType -eq 'BIOS/Legacy') { 'FAIL' } else { 'WARN' }
    } else { 'INFO' }
    Add-Result $cat 'Secure Boot' $secureBootStatus $secureBootDetail

    # TPM state.
    $tpmReady = $null
    $tpmDetail = ''
    try {
        $tpmCmd = Get-Command Get-Tpm -ErrorAction SilentlyContinue
        if ($tpmCmd) {
            $tpm = Get-Tpm -ErrorAction Stop
            $tpmPresent = [bool]$tpm.TpmPresent
            $tpmReady = $tpmPresent -and [bool]$tpm.TpmReady -and [bool]$tpm.TpmEnabled -and [bool]$tpm.TpmActivated
            $tpmDetail = "Present=$($tpm.TpmPresent); Ready=$($tpm.TpmReady); Enabled=$($tpm.TpmEnabled); Activated=$($tpm.TpmActivated); Owned=$($tpm.TpmOwned)"
        } else {
            $tpmDetail = 'Get-Tpm cmdlet unavailable'
        }
    } catch {
        $tpmDetail = "Unable to query TPM: $($_.Exception.Message)"
    }
    $tpmStatus = if ($script:RequireTpm) {
        if ($tpmReady -eq $true) { 'PASS' } elseif ($tpmReady -eq $false) { 'FAIL' } else { 'WARN' }
    } else { 'INFO' }
    Add-Result $cat 'TPM' $tpmStatus $tpmDetail

    # BitLocker state. Query only when the BitLocker module/cmdlet exists.
    $bitLockerProtected = $null
    $bitLockerDetail = ''
    try {
        $bitLockerCmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
        if ($bitLockerCmd) {
            $volumes = @(Get-BitLockerVolume -ErrorAction Stop)
            $osVolume = $volumes | Where-Object { $_.MountPoint -eq $env:SystemDrive } | Select-Object -First 1
            if (-not $osVolume) { $osVolume = $volumes | Select-Object -First 1 }
            if ($osVolume) {
                $protectionStatusText = [string]$osVolume.ProtectionStatus
                $protectionStatusValue = if ($osVolume.ProtectionStatus -is [int]) { [int]$osVolume.ProtectionStatus } else { $null }
                $protectionOn = $protectionStatusText -eq 'On' -or $protectionStatusValue -eq 1
                $bitLockerProtected = [bool]$protectionOn
                $bitLockerDetail = "Volume=$($osVolume.MountPoint); ProtectionStatus=$($osVolume.ProtectionStatus); VolumeStatus=$($osVolume.VolumeStatus); EncryptionPercentage=$($osVolume.EncryptionPercentage)%"
            } else {
                $bitLockerProtected = $false
                $bitLockerDetail = 'No BitLocker volumes returned'
            }
        } else {
            $bitLockerDetail = 'Get-BitLockerVolume cmdlet unavailable (BitLocker module not installed)'
        }
    } catch {
        $bitLockerDetail = "Unable to query BitLocker: $($_.Exception.Message)"
    }
    $bitLockerStatus = if ($script:RequireBitLocker) {
        if ($bitLockerProtected -eq $true) { 'PASS' } elseif ($bitLockerProtected -eq $false) { 'FAIL' } else { 'WARN' }
    } else { 'INFO' }
    Add-Result $cat 'BitLocker OS volume protection' $bitLockerStatus $bitLockerDetail

    # Device Guard / VBS / Credential Guard / HVCI via CIM with registry fallback.
    $vbsEnabled = $null
    $credentialGuardRunning = $null
    $hvciRunning = $null
    $deviceGuardDetails = @()
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $vbsEnabled = $dg.VirtualizationBasedSecurityStatus -gt 0
        $credentialGuardRunning = 1 -in @($dg.SecurityServicesRunning)
        $hvciRunning = 2 -in @($dg.SecurityServicesRunning)
        $deviceGuardDetails += "CIM: VBSStatus=$($dg.VirtualizationBasedSecurityStatus); ServicesConfigured=$(@($dg.SecurityServicesConfigured) -join ','); ServicesRunning=$(@($dg.SecurityServicesRunning) -join ',')"
    } catch {
        $deviceGuardDetails += "CIM unavailable: $($_.Exception.Message)"
    }

    try {
        $dgReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -ErrorAction SilentlyContinue
        if ($dgReg -and $null -ne $dgReg.EnableVirtualizationBasedSecurity -and $null -eq $vbsEnabled) {
            $vbsEnabled = [int]$dgReg.EnableVirtualizationBasedSecurity -eq 1
        }
        if ($dgReg -and $null -ne $dgReg.EnableVirtualizationBasedSecurity) {
            $deviceGuardDetails += "RegistryVBS=$($dgReg.EnableVirtualizationBasedSecurity)"
        }
    } catch { }

    try {
        $lsaReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LsaCfgFlags' -ErrorAction SilentlyContinue
        if ($lsaReg -and $null -ne $lsaReg.LsaCfgFlags -and $null -eq $credentialGuardRunning) {
            $credentialGuardRunning = [int]$lsaReg.LsaCfgFlags -in @(1,2)
        }
        if ($lsaReg -and $null -ne $lsaReg.LsaCfgFlags) { $deviceGuardDetails += "LsaCfgFlags=$($lsaReg.LsaCfgFlags)" }
    } catch { }

    try {
        $hvciReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -ErrorAction SilentlyContinue
        if ($hvciReg -and $null -ne $hvciReg.Enabled -and $null -eq $hvciRunning) {
            $hvciRunning = [int]$hvciReg.Enabled -eq 1
        }
        if ($hvciReg -and $null -ne $hvciReg.Enabled) { $deviceGuardDetails += "RegistryHVCI=$($hvciReg.Enabled)" }
    } catch { }

    $deviceGuardDetail = if ($deviceGuardDetails.Count -gt 0) { $deviceGuardDetails -join '; ' } else { 'No Device Guard state detected' }
    $vbsStatus = if ($script:RequireVbs) {
        if ($vbsEnabled -eq $true -or $credentialGuardRunning -eq $true) { 'PASS' } elseif ($vbsEnabled -eq $false -and $credentialGuardRunning -eq $false) { 'FAIL' } else { 'WARN' }
    } else { 'INFO' }
    Add-Result $cat 'VBS / Credential Guard' $vbsStatus $deviceGuardDetail

    $hvciStatus = if ($script:RequireHvci) {
        if ($hvciRunning -eq $true) { 'PASS' } elseif ($hvciRunning -eq $false) { 'FAIL' } else { 'WARN' }
    } else { 'INFO' }
    Add-Result $cat 'HVCI (Memory Integrity)' $hvciStatus $deviceGuardDetail
}

#endregion

#region ── C. Hardware & Virtualization Support ───────────────────────────────

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

function Normalize-NetworkAdapterRole {
    param([string]$Role)

    if ([string]::IsNullOrWhiteSpace($Role)) { return $null }

    switch -Regex ($Role.Trim()) {
        '^Management$'    { return 'Management' }
        '^(Cluster|Heartbeat)$' { return 'Cluster' }
        '^LiveMigration$' { return 'LiveMigration' }
        '^iSCSI$'         { return 'iSCSI' }
        '^(S2DStorage|Storage|S2D)$' { return 'S2DStorage' }
        '^(VM|VirtualMachine|VMUplink)$' { return 'VM' }
        default           { return $null }
    }
}

function ConvertTo-NetworkRoleMap {
    param([object[]]$Mappings)

    $roleMap = @{}
    foreach ($mapping in @($Mappings)) {
        if (-not $mapping) { continue }

        if ($mapping -is [hashtable]) {
            $keys = @($mapping.Keys)
            $looksLikeMap = $keys.Count -gt 0 -and -not ($mapping.ContainsKey('Name') -or $mapping.ContainsKey('InterfaceAlias') -or $mapping.ContainsKey('InterfaceDescription') -or $mapping.ContainsKey('Role'))
            if ($looksLikeMap) {
                foreach ($key in $keys) {
                    $role = Normalize-NetworkAdapterRole -Role ([string]$mapping[$key])
                    if ($role) { $roleMap[[string]$key] = $role }
                }
                continue
            }
        }

        $name = $null
        $role = $null
        foreach ($nameProperty in @('Name', 'InterfaceAlias', 'InterfaceDescription')) {
            $property = $mapping.PSObject.Properties[$nameProperty]
            if ($property -and $property.Value) {
                $name = [string]$property.Value
                break
            }
        }
        $roleProperty = $mapping.PSObject.Properties['Role']
        if ($roleProperty) {
            $role = Normalize-NetworkAdapterRole -Role ([string]$roleProperty.Value)
        }
        if ($name -and $role) { $roleMap[$name] = $role }
    }

    return $roleMap
}

function Get-NetworkAdapterRole {
    param(
        [object]$Adapter,
        [hashtable]$RoleMap
    )

    if (-not $Adapter -or -not $RoleMap -or $RoleMap.Count -eq 0) { return $null }

    $candidateValues = @()
    foreach ($nameProperty in @('Name', 'InterfaceAlias', 'InterfaceDescription')) {
        $property = $Adapter.PSObject.Properties[$nameProperty]
        if ($property -and $property.Value) { $candidateValues += [string]$property.Value }
    }

    foreach ($candidate in $candidateValues) {
        if ($RoleMap.ContainsKey([string]$candidate)) {
            return $RoleMap[[string]$candidate]
        }
    }

    return $null
}

function Test-NetworkConfiguration {
    Section 'C. Network Configuration'
    $cat = 'Network'

    $adapters     = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    $adapterCount = $adapters.Count
    $roleMap      = ConvertTo-NetworkRoleMap -Mappings $script:NetworkAdapters
    $adapterRoles = @{}

    if ($roleMap.Count -eq 0) {
        Add-Result $cat 'Network adapter role mapping' 'INFO' 'No NetworkAdapters/NetworkRoles mapping configured; role-specific NIC checks are skipped where enforcement would be ambiguous'
    } else {
        Add-Result $cat 'Network adapter role mapping' 'INFO' "$($roleMap.Count) configured role mapping(s)"
    }

    # S2D requires RDMA NICs — minimum 2 dedicated 10 GbE+ for SMB Direct
    $minNics = if ($StorageType -eq 'S2D') { 4 } else { 2 }
    $nicLevel= if ($adapterCount -ge $minNics) { 'PASS' } elseif ($adapterCount -ge 2) { 'WARN' } else { 'FAIL' }
    Add-Result $cat "NIC count (minimum $minNics for $StorageType)" $nicLevel "$adapterCount active NIC(s)"

    foreach ($nic in $adapters) {
        $role = Get-NetworkAdapterRole -Adapter $nic -RoleMap $roleMap
        $adapterRoles[$nic.Name] = $role
        if ($role) {
            Add-Result $cat "NIC '$($nic.Name)' role" 'INFO' $role
        } else {
            Add-Result $cat "NIC '$($nic.Name)' role" 'INFO' 'No role mapping found — role-specific requirements skipped for this NIC'
        }

        $ipCfg = Get-NetIPConfiguration -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $ipCfg) { continue }

        $ipv4 = $ipCfg.IPv4Address
        if (-not $ipv4) {
            if ($role -eq 'VM') {
                Add-Result $cat "NIC '$($nic.Name)' IPv4" 'SKIP' 'No IPv4 address required for a pure VM uplink'
            } elseif ($role -in @('Management', 'Cluster', 'iSCSI', 'S2DStorage')) {
                Add-Result $cat "NIC '$($nic.Name)' IPv4" 'WARN' "No IPv4 address — expected for $role traffic"
            } else {
                Add-Result $cat "NIC '$($nic.Name)' IPv4" 'INFO' 'No IPv4 address; no mapped role requiring IPv4 enforcement'
            }
            continue
        }

        $addr   = $ipv4.IPAddress
        $prefix = $ipv4.PrefixLength

        $dhcp = (Get-NetIPInterface -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4).Dhcp -eq 'Enabled'
        if ($role -in @('Management', 'Cluster', 'iSCSI', 'S2DStorage')) {
            if ($dhcp) {
                Add-Result $cat "NIC '$($nic.Name)' static IP" 'FAIL' "IP $addr/$prefix via DHCP — static IP required for $role traffic"
            } else {
                Add-Result $cat "NIC '$($nic.Name)' static IP" 'PASS' "$addr/$prefix ($role)"
            }
        } elseif ($role -eq 'VM') {
            Add-Result $cat "NIC '$($nic.Name)' static IP" 'SKIP' 'Pure VM uplink — host IPv4/static-IP enforcement skipped'
        } else {
            Add-Result $cat "NIC '$($nic.Name)' static IP" 'INFO' "IP $addr/$prefix; no mapped role requiring static-IP enforcement"
        }

        # Link speed
        $speedGbps = [math]::Round($nic.LinkSpeed / 1000000000, 0)
        if ($role -eq 'S2DStorage' -and $speedGbps -lt 10) {
            Add-Result $cat "NIC '$($nic.Name)' link speed" 'FAIL' "${speedGbps} Gbps — S2D storage requires minimum 10 GbE (25 GbE+ recommended)"
        } elseif ($role -in @('iSCSI', 'LiveMigration') -and $speedGbps -lt 10) {
            Add-Result $cat "NIC '$($nic.Name)' link speed" 'WARN' "${speedGbps} Gbps — $role traffic usually benefits from dedicated 10 GbE+"
        } elseif ($speedGbps -lt 1) {
            Add-Result $cat "NIC '$($nic.Name)' link speed" 'WARN' "${speedGbps} Gbps — low speed for Hyper-V host traffic"
        } else {
            Add-Result $cat "NIC '$($nic.Name)' link speed" 'INFO' "${speedGbps} Gbps"
        }

        # DNS servers and default gateway are required only on management NICs.
        $dns = $ipCfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 }
        if ($role -eq 'Management') {
            if ($dns -and $dns.ServerAddresses) {
                Add-Result $cat "NIC '$($nic.Name)' DNS servers" 'PASS' ($dns.ServerAddresses -join ', ')
            } else {
                Add-Result $cat "NIC '$($nic.Name)' DNS servers" 'FAIL' 'DNS servers required on management NIC'
            }

            if ($ipCfg.IPv4DefaultGateway) {
                Add-Result $cat "NIC '$($nic.Name)' gateway" 'PASS' $ipCfg.IPv4DefaultGateway.NextHop
            } else {
                Add-Result $cat "NIC '$($nic.Name)' gateway" 'FAIL' 'Default gateway required on management NIC'
            }
        } elseif ($role) {
            if ($dns -and $dns.ServerAddresses) {
                Add-Result $cat "NIC '$($nic.Name)' DNS servers" 'INFO' "Configured on $role NIC but only required on management: $($dns.ServerAddresses -join ', ')"
            }
            if ($ipCfg.IPv4DefaultGateway) {
                Add-Result $cat "NIC '$($nic.Name)' gateway" 'INFO' "Configured on $role NIC but only required on management: $($ipCfg.IPv4DefaultGateway.NextHop)"
            }
        } else {
            Add-Result $cat "NIC '$($nic.Name)' DNS/gateway role check" 'SKIP' 'NIC is not mapped to a role; management DNS/gateway requirements not evaluated'
        }
    }

    # RDMA — only S2D storage and RDMA-backed Live Migration roles should require/enable it.
    try {
        $rdmaAdapters = @(Get-NetAdapterRDMA -ErrorAction Stop | Where-Object { $_.Enabled })
        $s2dStorageNames = @($adapters | Where-Object { (Get-NetworkAdapterRole -Adapter $_ -RoleMap $roleMap) -eq 'S2DStorage' } | Select-Object -ExpandProperty Name)

        if ($roleMap.Count -gt 0) {
            if ($StorageType -eq 'S2D') {
                $s2dRdma = @($rdmaAdapters | Where-Object { $_.Name -in $s2dStorageNames })
                if ($s2dRdma.Count -ge 2) {
                    Add-Result $cat 'RDMA adapters (S2DStorage role)' 'PASS' "$($s2dRdma.Count) S2DStorage RDMA-enabled NIC(s): $($s2dRdma.Name -join ', ')"
                } elseif ($s2dRdma.Count -eq 1) {
                    Add-Result $cat 'RDMA adapters (S2DStorage role)' 'WARN' 'Only 1 S2DStorage RDMA NIC — minimum 2 recommended for redundant SMB Direct (S2D)'
                } else {
                    Add-Result $cat 'RDMA adapters (S2DStorage role)' 'WARN' 'No RDMA-enabled S2DStorage NICs — SMB Direct / RDMA strongly recommended for S2D performance'
                }
            }

            foreach ($rdmaNic in $rdmaAdapters) {
                $rdmaRole = Get-NetworkAdapterRole -Adapter $rdmaNic -RoleMap $roleMap
                if ($rdmaRole -in @('S2DStorage', 'LiveMigration')) {
                    Add-Result $cat "NIC '$($rdmaNic.Name)' RDMA" 'INFO' "RDMA enabled on $rdmaRole NIC"
                } elseif ($rdmaRole) {
                    Add-Result $cat "NIC '$($rdmaNic.Name)' RDMA" 'WARN' "RDMA enabled on $rdmaRole NIC — RDMA should be limited to S2DStorage or RDMA LiveMigration traffic"
                } else {
                    Add-Result $cat "NIC '$($rdmaNic.Name)' RDMA" 'SKIP' 'RDMA enabled, but NIC is not mapped to a role; verify this is S2DStorage or RDMA LiveMigration traffic'
                }
            }
        } elseif ($StorageType -eq 'S2D') {
            if ($rdmaAdapters.Count -ge 2) {
                Add-Result $cat 'RDMA adapters (S2D SMB Direct)' 'PASS' "$($rdmaAdapters.Count) RDMA-enabled NIC(s): $($rdmaAdapters.Name -join ', ')"
            } elseif ($rdmaAdapters.Count -eq 1) {
                Add-Result $cat 'RDMA adapters (S2D SMB Direct)' 'WARN' 'Only 1 RDMA NIC — minimum 2 recommended for redundant SMB Direct (S2D)'
            } else {
                Add-Result $cat 'RDMA adapters (S2D SMB Direct)' 'WARN' 'No RDMA-enabled NICs — SMB Direct / RDMA strongly recommended for S2D performance'
            }
        } else {
            $rdmaInfo = if ($rdmaAdapters.Count -gt 0) { "$($rdmaAdapters.Count) RDMA NIC(s) — map roles to verify only S2DStorage/LiveMigration use RDMA" } else { 'None detected' }
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

    # Default gateway placement — required only on management NICs.
    $allGateways = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if ($allGateways.Count -gt 1) {
        $managementGatewayCount = 0
        $nonManagementGateways = @()
        foreach ($gateway in $allGateways) {
            $gatewayNic = $adapters | Where-Object { $_.InterfaceIndex -eq $gateway.InterfaceIndex } | Select-Object -First 1
            $gatewayRole = Get-NetworkAdapterRole -Adapter $gatewayNic -RoleMap $roleMap
            if ($gatewayRole -eq 'Management') {
                $managementGatewayCount++
            } elseif ($gatewayRole) {
                $nonManagementGateways += "$($gateway.NextHop) on $gatewayRole"
            } else {
                $nonManagementGateways += "$($gateway.NextHop) on unmapped NIC"
            }
        }

        if ($managementGatewayCount -gt 1) {
            Add-Result $cat 'Multiple management default gateways' 'WARN' "$managementGatewayCount management default routes — verify asymmetric routing does not break host management"
        }
        if ($nonManagementGateways.Count -gt 0) {
            Add-Result $cat 'Non-management default gateways' 'INFO' "Default gateway is only required on management NICs; found: $($nonManagementGateways -join ', ')"
        }
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

    # IPv6 — must be uniformly enabled or disabled across all cluster nodes
    $ipv6Disabled = $false
    try {
        $ipv6Reg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
            -Name 'DisabledComponents' -ErrorAction SilentlyContinue
        if ($ipv6Reg -and ($ipv6Reg.DisabledComponents -band 0xFF) -eq 0xFF) {
            $ipv6Disabled = $true
            Add-Result $cat 'IPv6 state' 'WARN' "IPv6 fully disabled via registry (DisabledComponents=0xFF) — must be identical on ALL cluster nodes; inconsistency causes heartbeat issues"
        } else {
            Add-Result $cat 'IPv6 state' 'INFO' "IPv6 enabled — ensure consistent across all nodes"
        }
    } catch {
        Add-Result $cat 'IPv6 state' 'INFO' "Cannot read registry: $_ — verify IPv6 state is consistent across nodes"
    }

    # NIC Teaming — LBFO deprecated on WS2022/2025; SET recommended
    try {
        $lbfoTeams = @(Get-NetLbfoTeam -ErrorAction Stop)
        if ($lbfoTeams.Count -gt 0) {
            $teamNames = $lbfoTeams.Name -join ', '
            Add-Result $cat 'NIC Teaming: LBFO teams detected' 'WARN' "LBFO teams found: $teamNames — LBFO is deprecated on WS2022/2025; migrate to Switch Embedded Teaming (SET) via Hyper-V vSwitch"
        } else {
            Add-Result $cat 'NIC Teaming: LBFO' 'INFO' 'No LBFO teams — correct for WS2022/2025 (use SET via Hyper-V vSwitch)'
        }
    } catch {
        Add-Result $cat 'NIC Teaming: LBFO' 'SKIP' "Get-NetLbfoTeam unavailable: $_"
    }

    # MTU / Jumbo frames — enforce MTU 9000 only for iSCSI and S2D storage NICs.
    $storageMinMtu = 9000
    foreach ($nic in $adapters) {
        $role = $adapterRoles[$nic.Name]
        try {
            $adv = Get-NetAdapterAdvancedProperty -Name $nic.Name -RegistryKeyword 'JumboPacket' -ErrorAction SilentlyContinue
            if ($adv) {
                $mtu = [int]$adv.RegistryValue[0]
                if ($role -in @('iSCSI', 'S2DStorage')) {
                    if ($mtu -lt $storageMinMtu) {
                        Add-Result $cat "NIC '$($nic.Name)' MTU (JumboPacket)" 'WARN' "MTU $mtu — $role storage NICs should be $storageMinMtu; verify NIC and switch port MTU match"
                    } else {
                        Add-Result $cat "NIC '$($nic.Name)' MTU (JumboPacket)" 'PASS' "MTU $mtu ($role)"
                    }
                } elseif ($role) {
                    Add-Result $cat "NIC '$($nic.Name)' MTU (JumboPacket)" 'INFO' "MTU $mtu — jumbo-frame requirement applies only to iSCSI/S2DStorage roles, not $role"
                } else {
                    Add-Result $cat "NIC '$($nic.Name)' MTU (JumboPacket)" 'SKIP' "MTU $mtu; NIC is not mapped to a role, so storage MTU requirement was not evaluated"
                }
            } else {
                $mtuDef = (Get-NetIPInterface -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu
                if ($mtuDef) {
                    if ($role -in @('iSCSI', 'S2DStorage') -and $mtuDef -lt $storageMinMtu) {
                        Add-Result $cat "NIC '$($nic.Name)' MTU" 'WARN' "NlMtu = $mtuDef — $role storage NICs should be $storageMinMtu"
                    } elseif ($role -in @('iSCSI', 'S2DStorage')) {
                        Add-Result $cat "NIC '$($nic.Name)' MTU" 'PASS' "NlMtu = $mtuDef ($role)"
                    } elseif ($role) {
                        Add-Result $cat "NIC '$($nic.Name)' MTU" 'INFO' "NlMtu = $mtuDef — jumbo-frame requirement applies only to iSCSI/S2DStorage roles"
                    } else {
                        Add-Result $cat "NIC '$($nic.Name)' MTU" 'SKIP' "NlMtu = $mtuDef; NIC is not mapped to a role"
                    }
                }
            }
        } catch {
            Add-Result $cat "NIC '$($nic.Name)' MTU" 'SKIP' "MTU query failed: $_"
        }
    }

    # VMQ (Virtual Machine Queue) — recommended for VM traffic, not management/cluster heartbeat.
    try {
        $vmqAdapters = @(Get-NetAdapterVmq -ErrorAction Stop)
        foreach ($vmqNic in $vmqAdapters) {
            $role = $null
            if ($adapterRoles.ContainsKey($vmqNic.Name)) { $role = $adapterRoles[$vmqNic.Name] }
            if ($role -eq 'VM') {
                if ($vmqNic.Enabled) {
                    Add-Result $cat "NIC '$($vmqNic.Name)' VMQ" 'PASS' 'VMQ enabled for VM traffic'
                } else {
                    Add-Result $cat "NIC '$($vmqNic.Name)' VMQ" 'WARN' 'VMQ recommended on Hyper-V VM traffic NICs'
                }
            } elseif ($role -in @('Management', 'Cluster')) {
                if ($vmqNic.Enabled) {
                    Add-Result $cat "NIC '$($vmqNic.Name)' VMQ" 'WARN' "VMQ enabled on $role NIC — VMQ is not recommended on management/heartbeat traffic"
                } else {
                    Add-Result $cat "NIC '$($vmqNic.Name)' VMQ" 'PASS' "VMQ disabled on $role NIC"
                }
            } elseif ($role) {
                Add-Result $cat "NIC '$($vmqNic.Name)' VMQ" 'INFO' "VMQ Enabled=$($vmqNic.Enabled) on $role NIC"
            } else {
                Add-Result $cat "NIC '$($vmqNic.Name)' VMQ" 'SKIP' "VMQ Enabled=$($vmqNic.Enabled); NIC is not mapped to a role"
            }
        }
    } catch {
        Add-Result $cat 'VMQ configuration' 'SKIP' "Get-NetAdapterVmq unavailable: $_"
    }

    # RSS (Receive Side Scaling)
    try {
        $rssAdapters = @(Get-NetAdapterRss -ErrorAction Stop | Where-Object { $_.Enabled })
        Add-Result $cat 'RSS (Receive Side Scaling)' 'INFO' "$($rssAdapters.Count) NIC(s) with RSS enabled: $($rssAdapters.Name -join ', ')"
    } catch {
        Add-Result $cat 'RSS (Receive Side Scaling)' 'SKIP' "Get-NetAdapterRss unavailable: $_"
    }

    # PFC (Priority Flow Control) / DCB — only relevant for S2DStorage and RDMA-backed LiveMigration.
    try {
        $rdmaAll = @(Get-NetAdapterRDMA -ErrorAction Stop | Where-Object { $_.Enabled })
        if ($rdmaAll.Count -gt 0) {
            foreach ($rdmaNic in $rdmaAll) {
                $role = Get-NetworkAdapterRole -Adapter $rdmaNic -RoleMap $roleMap
                $pfcCheckAllowed = $role -eq 'S2DStorage' -or $role -eq 'LiveMigration'
                if (-not $role) {
                    Add-Result $cat "NIC '$($rdmaNic.Name)' PFC/DCB role check" 'SKIP' 'RDMA NIC is not mapped to a role; verify PFC/DCB manually only if this is S2DStorage or RDMA LiveMigration'
                    continue
                }
                if (-not $pfcCheckAllowed) {
                    Add-Result $cat "NIC '$($rdmaNic.Name)' PFC/DCB" 'WARN' "RDMA/PFC/DCB should be limited to S2DStorage or RDMA LiveMigration, not $role"
                    continue
                }

                try {
                    $qos = Get-NetAdapterQos -Name $rdmaNic.Name -ErrorAction Stop
                    $pfcEnabled = $qos.Enabled -and ($qos.OperationalFlowControl -ne 'None' -or ($null -ne $qos.OperationalPriorityAssignmentTable))
                    if ($pfcEnabled) {
                        Add-Result $cat "NIC '$($rdmaNic.Name)' PFC/DCB (RoCE)" 'PASS' "QoS/PFC appears active for $role RDMA traffic — required for RoCE RDMA"
                    } else {
                        Add-Result $cat "NIC '$($rdmaNic.Name)' PFC/DCB (RoCE)" 'WARN' "QoS/PFC not detected on $role RDMA NIC — if this NIC uses RoCE (not iWARP), PFC must be configured on the NIC and switch"
                    }
                } catch {
                    Add-Result $cat "NIC '$($rdmaNic.Name)' PFC/DCB check" 'SKIP' "Get-NetAdapterQos failed: $_ — verify PFC manually if using RoCE"
                }
            }
        }
    } catch {
        Add-Result $cat 'PFC/DCB (Priority Flow Control)' 'SKIP' "RDMA query unavailable: $_"
    }
}

#endregion

#region ── D. Active Directory ───────────────────────────────────────────────

function ConvertTo-LdapEscapedFilterValue {
    param([string]$Value)

    if ($null -eq $Value) { return '' }

    return ($Value -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00')
}

function Get-UniqueTextValues {
    param([string[]]$Values)

    $seen = @{}
    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $trimmed = $value.Trim()
        $key = $trimmed.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $trimmed
        }
    }
}

function Resolve-ClusterNodeIdentity {
    param(
        [string]$NodeName,
        [string]$DomainName
    )

    $name = if ([string]::IsNullOrWhiteSpace($NodeName)) { $env:COMPUTERNAME } else { $NodeName.Trim() }
    $fqdn = $null
    $short = $name

    if ($name -match '^\d{1,3}(\.\d{1,3}){3}$') {
        try {
            $resolvedName = [System.Net.Dns]::GetHostEntry($name).HostName
            if ($resolvedName) {
                $fqdn = $resolvedName
                $short = ($resolvedName -split '\.')[0]
            }
        } catch {
            $short = $name
        }
    } elseif ($name -match '\.') {
        $fqdn = $name
        $short = ($name -split '\.')[0]
    } else {
        $short = $name
        if ($DomainName) { $fqdn = "$name.$DomainName" }
    }

    $hostNames = @(Get-UniqueTextValues -Values @($short, $fqdn))

    [pscustomobject]@{
        InputName     = $name
        ShortName     = $short
        Fqdn          = $fqdn
        ExpectedHosts = $hostNames
        Account       = $null
    }
}

function Get-ADComputerForNode {
    param([pscustomobject]$Node)

    $clauses = @()
    foreach ($candidate in @(Get-UniqueTextValues -Values @($Node.ShortName, $Node.Fqdn, $Node.InputName))) {
        $escaped = ConvertTo-LdapEscapedFilterValue -Value $candidate
        $clauses += "(name=$escaped)"
        $clauses += "(dNSHostName=$escaped)"
    }

    if ($Node.ShortName -and $Node.ShortName -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        $sam = ConvertTo-LdapEscapedFilterValue -Value "$($Node.ShortName)$"
        $clauses += "(sAMAccountName=$sam)"
    }

    $filter = if ($clauses.Count -gt 1) { "(&(objectCategory=computer)(|$($clauses -join '')))" } else { "(&(objectCategory=computer)$($clauses -join ''))" }
    $searcher = [adsisearcher]$filter
    $searcher.PropertiesToLoad.AddRange([string[]]@('distinguishedname', 'dnshostname', 'name', 'serviceprincipalname', 'msds-allowedtodelegateto', 'operatingsystem'))
    $result = $searcher.FindOne()

    if (-not $result) { return $null }

    [pscustomobject]@{
        DistinguishedName       = [string]$result.Properties['distinguishedname'][0]
        DnsHostName             = if ($result.Properties['dnshostname']) { [string]$result.Properties['dnshostname'][0] } else { $null }
        Name                    = if ($result.Properties['name']) { [string]$result.Properties['name'][0] } else { $Node.ShortName }
        OperatingSystem         = if ($result.Properties['operatingsystem']) { [string]$result.Properties['operatingsystem'][0] } else { $null }
        ServicePrincipalName    = @($result.Properties['serviceprincipalname'])
        AllowedToDelegateTo     = @($result.Properties['msds-allowedtodelegateto'])
    }
}

function Test-ServicePrincipalNamesForNode {
    param(
        [pscustomobject]$Node,
        [string]$Category
    )

    $spns = @($Node.Account.ServicePrincipalName | ForEach-Object { [string]$_ })
    $spnKeys = @{}
    foreach ($spn in $spns) { $spnKeys[$spn.ToLowerInvariant()] = $true }

    $hostSpns = @($spns | Where-Object { $_ -match '^HOST/' })
    if ($hostSpns) {
        Add-Result $Category "HOST SPN registered: $($Node.ShortName)" 'PASS' ($hostSpns -join '; ')
    } else {
        Add-Result $Category "HOST SPN registered: $($Node.ShortName)" 'WARN' 'No HOST SPN — may cause Kerberos failures for cluster communications'
    }

    $missingMigration = @()
    $presentMigration = @()
    $missingCifs = @()
    $presentCifs = @()

    foreach ($hostName in $Node.ExpectedHosts) {
        $migrationSpn = "Microsoft Virtual System Migration Service/$hostName"
        $cifsSpn = "cifs/$hostName"

        if ($spnKeys.ContainsKey($migrationSpn.ToLowerInvariant())) { $presentMigration += $migrationSpn } else { $missingMigration += $migrationSpn }
        if ($spnKeys.ContainsKey($cifsSpn.ToLowerInvariant())) { $presentCifs += $cifsSpn } else { $missingCifs += $cifsSpn }
    }

    if ($missingMigration.Count -eq 0) {
        Add-Result $Category "Live Migration SPN: $($Node.ShortName)" 'PASS' ($presentMigration -join '; ')
    } else {
        Add-Result $Category "Live Migration SPN: $($Node.ShortName)" 'WARN' "Missing: $($missingMigration -join '; ')"
    }

    if ($missingCifs.Count -eq 0) {
        Add-Result $Category "CIFS SPN for delegation: $($Node.ShortName)" 'PASS' ($presentCifs -join '; ')
    } else {
        $status = if ($script:LiveMigrationAuth -eq 'Kerberos') { 'WARN' } else { 'INFO' }
        Add-Result $Category "CIFS SPN for delegation: $($Node.ShortName)" $status "Missing: $($missingCifs -join '; ') — required when Kerberos Live Migration also delegates SMB/CIFS access"
    }
}

function Test-LiveMigrationDelegation {
    param(
        [pscustomobject[]]$Nodes,
        [string]$Category
    )

    Add-Result $Category 'Live Migration authentication mode' 'INFO' "Configured target: $($script:LiveMigrationAuth)"

    if ($script:LiveMigrationAuth -ne 'Kerberos') {
        Add-Result $Category 'Kerberos constrained delegation' 'INFO' 'Skipped because LiveMigrationAuth is CredSSP; Kerberos constrained delegation is not mandatory in this mode'
        return
    }

    if ($Nodes.Count -lt 2) {
        Add-Result $Category 'Kerberos constrained delegation' 'INFO' 'Single-node configuration; no inter-node Live Migration delegation path to validate'
        return
    }

    foreach ($source in $Nodes) {
        if (-not $source.Account) { continue }

        $delegation = @($source.Account.AllowedToDelegateTo | ForEach-Object { [string]$_ })
        $delegationKeys = @{}
        foreach ($entry in $delegation) { $delegationKeys[$entry.ToLowerInvariant()] = $true }

        foreach ($target in $Nodes) {
            if ($source.ShortName.ToLowerInvariant() -eq $target.ShortName.ToLowerInvariant()) { continue }
            if (-not $target.Account) { continue }

            $expected = @()
            foreach ($hostName in $target.ExpectedHosts) {
                $expected += "Microsoft Virtual System Migration Service/$hostName"
                $expected += "cifs/$hostName"
            }

            $missing = @($expected | Where-Object { -not $delegationKeys.ContainsKey($_.ToLowerInvariant()) })
            if ($missing.Count -eq 0) {
                Add-Result $Category "Kerberos constrained delegation: $($source.ShortName) -> $($target.ShortName)" 'PASS' ($expected -join '; ')
            } else {
                Add-Result $Category "Kerberos constrained delegation: $($source.ShortName) -> $($target.ShortName)" 'WARN' "Missing msDS-AllowedToDelegateTo entries: $($missing -join '; ')"
            }
        }
    }
}

function Test-CredSSPForLiveMigration {
    param([string]$Category)

    try {
        $credSSP = Get-WSManCredSSP -ErrorAction SilentlyContinue
        $credSSPEnabled = ($credSSP -and ($credSSP -match 'enabled'))

        if ($script:LiveMigrationAuth -eq 'CredSSP') {
            if ($credSSPEnabled) {
                Add-Result $Category 'CredSSP delegation (Live Migration)' 'INFO' 'CredSSP is enabled and LiveMigrationAuth is CredSSP; verify the operational security trade-off is accepted'
            } else {
                Add-Result $Category 'CredSSP delegation (Live Migration)' 'WARN' 'LiveMigrationAuth is CredSSP but client-side CredSSP is not enabled'
            }
        } else {
            if ($credSSPEnabled) {
                Add-Result $Category 'CredSSP delegation (Live Migration)' 'INFO' 'CredSSP is enabled but not required because LiveMigrationAuth is Kerberos; Kerberos constrained delegation is validated separately'
            } else {
                Add-Result $Category 'CredSSP delegation (Live Migration)' 'INFO' 'CredSSP is not enabled and is not required because LiveMigrationAuth is Kerberos'
            }
        }
    } catch {
        $status = if ($script:LiveMigrationAuth -eq 'CredSSP') { 'WARN' } else { 'INFO' }
        Add-Result $Category 'CredSSP delegation (Live Migration)' $status 'WSMan query unavailable; CredSSP cannot be verified locally'
    }
}

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

    $localFqdn = if ($cs.DNSHostName -and $cs.Domain) { "$($cs.DNSHostName).$($cs.Domain)" } else { $env:COMPUTERNAME }
    $nodeInputs = @(Get-UniqueTextValues -Values @($localFqdn, $script:ClusterNodes))
    $nodes = @()
    $seenNodeKeys = @{}

    foreach ($nodeInput in $nodeInputs) {
        $node = Resolve-ClusterNodeIdentity -NodeName $nodeInput -DomainName $cs.Domain
        $nodeKey = $node.ShortName.ToLowerInvariant()
        if ($seenNodeKeys.ContainsKey($nodeKey)) { continue }
        $seenNodeKeys[$nodeKey] = $true

        try {
            $account = Get-ADComputerForNode -Node $node
            if ($account) {
                $node.Account = $account
                if ($account.DnsHostName) {
                    $node.Fqdn = $account.DnsHostName
                    $node.ExpectedHosts = @(Get-UniqueTextValues -Values @($node.ShortName, $account.DnsHostName))
                }

                Add-Result $cat "Computer account in AD: $($node.ShortName)" 'PASS' $account.DistinguishedName
                if ($account.OperatingSystem) { Add-Result $cat "Computer AD OS attribute: $($node.ShortName)" 'INFO' $account.OperatingSystem }
                Test-ServicePrincipalNamesForNode -Node $node -Category $cat
            } else {
                Add-Result $cat "Computer account in AD: $($node.ShortName)" 'FAIL' "Computer object for '$($node.InputName)' not found in AD"
            }
        } catch {
            Add-Result $cat "Computer account in AD: $($node.ShortName)" 'WARN' "ADSI query failed: $_"
        }

        $nodes += $node
    }

    Test-LiveMigrationDelegation -Nodes $nodes -Category $cat
    Test-CredSSPForLiveMigration -Category $cat
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

        # DNS scavenging — required to avoid stale CNO/VCO A records on cluster rebuild
        # Query the AD-integrated zone object for dnszones scavenging properties
        try {
            $dnsZoneDNScav = "DC=$domainName,CN=MicrosoftDNS,DC=DomainDnsZones,DC=$($domainName.Replace('.', ',DC='))"
            $zoneEntry     = [System.DirectoryServices.DirectoryEntry]"LDAP://$dnsZoneDNScav"
            $zoneEntry.psbase.RefreshCache([string[]]@('dnsProperty'))
            # dnsProperty is a multi-valued byte array; scavenging is encoded within it
            # A simpler approach: check via WMI DNS server if available
            $dnsSrv = Get-CimInstance -Namespace root\MicrosoftDNS -ClassName MicrosoftDNS_Zone `
                -Filter "Name='$domainName'" -ErrorAction Stop | Select-Object -First 1
            if ($dnsSrv) {
                if ($dnsSrv.Aging) {
                    Add-Result $cat "DNS scavenging on zone '$domainName'" 'PASS' "Aging/scavenging enabled (NoRefreshInterval: $($dnsSrv.NoRefreshInterval)h, RefreshInterval: $($dnsSrv.RefreshInterval)h)"
                } else {
                    Add-Result $cat "DNS scavenging on zone '$domainName'" 'WARN' "Aging/scavenging DISABLED — stale CNO/VCO A records will accumulate after cluster rebuilds; enable via DNS Manager > Zone Properties > Aging"
                }
            }
        } catch {
            Add-Result $cat "DNS scavenging on zone '$domainName'" 'SKIP' "WMI DNS query unavailable (run on DNS server or with DNS-Server role): $_"
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

    # Hotfix / patch level consistency — Microsoft requires all nodes at same patch level
    $nodeHotfixCounts = @{ $localNode = (Get-HotFix -ErrorAction SilentlyContinue | Measure-Object).Count }
    foreach ($node in $Nodes) {
        try {
            $remoteHfCount = Invoke-Command -ComputerName $node -ScriptBlock {
                (Get-HotFix -ErrorAction SilentlyContinue | Measure-Object).Count
            } -ErrorAction Stop
            $nodeHotfixCounts[$node] = $remoteHfCount
        } catch {
            Add-Result $cat "Node $node: hotfix count" 'SKIP' "Remote query failed: $_"
        }
    }
    $distinctHfCounts = $nodeHotfixCounts.Values | Select-Object -Unique
    if ($distinctHfCounts.Count -le 1) {
        Add-Result $cat 'Hotfix/patch level consistency' 'PASS' "All nodes report ~$($distinctHfCounts[0]) KBs installed"
    } else {
        $hfList = ($nodeHotfixCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)KBs" }) -join ', '
        Add-Result $cat 'Hotfix/patch level consistency' 'WARN' "Unequal KB counts: $hfList — inconsistent patch levels can cause unexpected cluster behavior; align via WSUS or Windows Update before finalizing cluster"
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

        # OU accidental deletion protection — if enabled, cluster cannot delete VCOs
        try {
            $ouDE = [System.DirectoryServices.DirectoryEntry]"LDAP://$ClusterOU"
            $ouACL = $ouDE.psbase.ObjectSecurity
            $denyDeleteAll = $ouACL.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
                Where-Object {
                    $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
                    ($_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::Delete) -and
                    $_.IdentityReference.Value -eq 'S-1-1-0'  # Everyone
                }
            # Simpler heuristic: check nTSecurityDescriptor for "Deny Delete All" on Everyone = accidental deletion protection
            # In practice, check the adminCount or use a flag — easiest is to try deleting a test object... too invasive.
            # Instead, query the OU itself for the 'Protect from accidental deletion' checkbox effect (Deny Delete on Everyone)
            $ouEntry.psbase.RefreshCache([string[]]@('nTSecurityDescriptor'))
            Add-Result $cat 'OU accidental deletion protection' 'INFO' "Cannot reliably detect via ADSI — verify manually in ADUC > OU Properties > Object tab that 'Protect object from accidental deletion' is UNCHECKED (otherwise VCO cleanup will fail)"
        } catch {
            Add-Result $cat 'OU accidental deletion protection' 'SKIP' "ACL inspection failed: $_"
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

#region ── K. Event Log Health ───────────────────────────────────────────────

function Test-EventLogHealth {
    Section 'K. Event Log Health (last 24 hours)'
    $cat  = 'EventLog'
    $since = (Get-Date).AddHours(-24)

    # Logs and source patterns to check
    $checks = @(
        @{ Log = 'System';      Level = 1; Label = 'System critical errors' }
        @{ Log = 'Application'; Level = 1; Label = 'Application critical errors' }
        @{ Log = 'System';      Level = 2; Label = 'System errors'; Limit = 10 }
    )

    foreach ($chk in $checks) {
        try {
            $filter = @{
                LogName   = $chk.Log
                Level     = $chk.Level
                StartTime = $since
            }
            $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
            $count  = $events.Count
            $limit  = if ($chk.ContainsKey('Limit')) { $chk.Limit } else { 1 }
            if ($count -ge $limit) {
                $top = ($events | Select-Object -First 3 | ForEach-Object {
                    "$($_.TimeCreated.ToString('HH:mm')) [$($_.Id)] $($_.ProviderName): $($_.Message.Split("`n")[0].Substring(0, [Math]::Min(80, $_.Message.Split("`n")[0].Length)))"
                }) -join ' | '
                $level = if ($chk.Level -eq 1) { 'FAIL' } else { 'WARN' }
                Add-Result $cat "$($chk.Label) (last 24h)" $level "$count event(s) — $top"
            } else {
                Add-Result $cat "$($chk.Label) (last 24h)" 'PASS' "None (0 events)"
            }
        } catch [System.Exception] {
            if ($_.Exception.Message -match 'No events were found') {
                Add-Result $cat "$($chk.Label) (last 24h)" 'PASS' 'None (0 events)'
            } else {
                Add-Result $cat "$($chk.Label) (last 24h)" 'SKIP' "Query failed: $_"
            }
        }
    }

    # Disk errors (source: disk, storahci, volmgr) — critical for S2D and SAN
    try {
        $diskEvents = @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = @('disk', 'storahci', 'volmgr', 'Ntfs', 'stornvme')
            Level        = @(1, 2)
            StartTime    = $since
        } -ErrorAction Stop)
        if ($diskEvents.Count -gt 0) {
            $top = ($diskEvents | Select-Object -First 3 | ForEach-Object {
                "$($_.TimeCreated.ToString('HH:mm')) [$($_.Id)] $($_.ProviderName)"
            }) -join ', '
            Add-Result $cat 'Disk/storage driver errors (last 24h)' 'FAIL' "$($diskEvents.Count) event(s): $top — investigate before joining cluster"
        } else {
            Add-Result $cat 'Disk/storage driver errors (last 24h)' 'PASS' 'None'
        }
    } catch {
        if ($_ -match 'No events') {
            Add-Result $cat 'Disk/storage driver errors (last 24h)' 'PASS' 'None'
        } else {
            Add-Result $cat 'Disk/storage driver errors (last 24h)' 'SKIP' "Query failed: $_"
        }
    }

    # Network errors (driver/NIC faults) — important for cluster heartbeat
    try {
        $netEvents = @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = @('e1i65x64', 'mlx4_bus', 'mlx5_bus', 'iWARP', 'ndis', 'Tcpip')
            Level        = @(1, 2)
            StartTime    = $since
        } -ErrorAction Stop)
        if ($netEvents.Count -gt 0) {
            Add-Result $cat 'Network driver errors (last 24h)' 'WARN' "$($netEvents.Count) event(s) — NIC resets or drops may affect cluster heartbeat"
        } else {
            Add-Result $cat 'Network driver errors (last 24h)' 'PASS' 'None'
        }
    } catch {
        if ($_ -match 'No events') {
            Add-Result $cat 'Network driver errors (last 24h)' 'PASS' 'None'
        } else {
            Add-Result $cat 'Network driver errors (last 24h)' 'SKIP' "Query failed: $_"
        }
    }

    # Hyper-V event log (if role installed)
    try {
        $hvEvents = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-Hyper-V-VMMS-Admin'
            Level     = @(1, 2)
            StartTime = $since
        } -ErrorAction Stop)
        if ($hvEvents.Count -gt 0) {
            Add-Result $cat 'Hyper-V VMMS errors (last 24h)' 'WARN' "$($hvEvents.Count) error(s) in Hyper-V-VMMS-Admin"
        } else {
            Add-Result $cat 'Hyper-V VMMS errors (last 24h)' 'PASS' 'None'
        }
    } catch {
        if ($_ -match 'No events|not found|does not exist') {
            Add-Result $cat 'Hyper-V VMMS errors (last 24h)' 'SKIP' 'Log not present (Hyper-V role not installed yet)'
        } else {
            Add-Result $cat 'Hyper-V VMMS errors (last 24h)' 'SKIP' "Query failed: $_"
        }
    }

    # Failover Clustering log (if feature installed)
    try {
        $fcEvents = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-FailoverClustering/Operational'
            Level     = @(1, 2)
            StartTime = $since
        } -ErrorAction Stop)
        if ($fcEvents.Count -gt 0) {
            Add-Result $cat 'Failover Clustering errors (last 24h)' 'WARN' "$($fcEvents.Count) error(s) in FailoverClustering/Operational"
        } else {
            Add-Result $cat 'Failover Clustering errors (last 24h)' 'PASS' 'None'
        }
    } catch {
        if ($_ -match 'No events|not found|does not exist') {
            Add-Result $cat 'Failover Clustering errors (last 24h)' 'SKIP' 'Log not present (Failover-Clustering feature not installed yet)'
        } else {
            Add-Result $cat 'Failover Clustering errors (last 24h)' 'SKIP' "Query failed: $_"
        }
    }
}

#endregion

#region ── L. Network Port Connectivity ──────────────────────────────────────

function Test-TcpPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 2000)
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect($Target, $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        try { $tcp.Close() } catch {}
        return $ok
    } catch { return $false }
}

function Test-UdpPort {
    param([string]$Target, [int]$Port, [byte[]]$Payload, [int]$TimeoutMs = 2000)
    try {
        $udp = [System.Net.Sockets.UdpClient]::new()
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Target, $Port)
        [void]$udp.Send($Payload, $Payload.Length)
        $ep  = [System.Net.IPEndPoint]([System.Net.IPAddress]::Any, 0)
        [void]$udp.Receive([ref]$ep)
        $udp.Close()
        return $true
    } catch [System.Net.Sockets.SocketException] {
        # ICMP port unreachable = host replied (port closed but host reachable)
        if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionReset) {
            return $false
        }
        return $false
    } catch { return $false }
}

function Test-PortConnectivity {
    Section 'L. Network Port Connectivity'
    $cat = 'Ports'

    function Check-Port {
        param([string]$Target, [int]$Port, [string]$Service, [string]$Scope,
              [ValidateSet('TCP','UDP')][string]$Proto = 'TCP',
              [byte[]]$UdpPayload, [switch]$Optional)
        if ($Target -eq '' -or $null -eq $Target) { return }
        $label = "$Scope → ${Target}:${Port}/${Proto} ($Service)"
        $ok = if ($Proto -eq 'UDP') {
            Test-UdpPort -Target $Target -Port $Port -Payload $UdpPayload
        } else {
            Test-TcpPort -Target $Target -Port $Port
        }
        if ($ok) {
            Add-Result $cat $label 'PASS' 'Open'
        } elseif ($Optional) {
            Add-Result $cat $label 'INFO' 'Closed/unreachable (optional port)'
        } else {
            Add-Result $cat $label 'FAIL' 'Closed or filtered — verify firewall rules'
        }
    }

    # ── L.1 Domain Controllers ────────────────────────────────────────────────
    if ($script:DomainControllers -and $script:DomainControllers.Count -gt 0) {
        foreach ($dc in $script:DomainControllers) {
            Check-Port $dc  53  'DNS'             "DC"
            Check-Port $dc  88  'Kerberos'        "DC"
            Check-Port $dc 135  'RPC EPM'         "DC"
            Check-Port $dc 389  'LDAP'            "DC"
            Check-Port $dc 445  'SMB/Netlogon'    "DC"
            Check-Port $dc 636  'LDAPS'           "DC" -Optional
            Check-Port $dc 3268 'Global Catalog'  "DC"
            Check-Port $dc 3269 'GC SSL'          "DC" -Optional
            # NTP via UDP on each DC
            $ntpPayload    = [byte[]]::new(48); $ntpPayload[0] = 0x1b
            Check-Port $dc 123  'NTP'             "DC" -Proto UDP -UdpPayload $ntpPayload -Optional
        }
    } else {
        Add-Result $cat 'DC port checks' 'SKIP' 'No domain controllers configured or discovered'
    }

    # ── L.2 NTP server (dedicated, if specified) ──────────────────────────────
    if ($script:NtpServer -and $script:NtpServer -ne '') {
        $ntpPayload = [byte[]]::new(48); $ntpPayload[0] = 0x1b
        Check-Port $script:NtpServer 123 'NTP' "NTP" -Proto UDP -UdpPayload $ntpPayload
    }

    # ── L.3 Other cluster nodes ───────────────────────────────────────────────
    $remoteNodes = @($script:ClusterNodes | Where-Object { $_ -ne $env:COMPUTERNAME -and $_ -ne '' })
    if ($remoteNodes.Count -gt 0) {
        foreach ($node in $remoteNodes) {
            Check-Port $node  135  'RPC EPM'             "Node"
            Check-Port $node  445  'SMB (CSV/Cluster)'   "Node"
            Check-Port $node 3343  'Cluster Service'      "Node"
            Check-Port $node 5985  'WinRM HTTP'           "Node"
            Check-Port $node 5986  'WinRM HTTPS'          "Node" -Optional
            Check-Port $node 6600  'Live Migration'        "Node"
            Check-Port $node 2179  'Hyper-V VMConnect'    "Node" -Optional
        }
    } else {
        Add-Result $cat 'Cluster node port checks' 'SKIP' 'No remote cluster nodes specified (single-node mode or -ClusterNodes empty)'
    }

    # ── L.4 File share witness server ────────────────────────────────────────
    if ($script:WitnessShare -and $script:WitnessShare -ne '') {
        # Extract server from \\server\share
        if ($script:WitnessShare -match '^\\\\([^\\]+)') {
            $witnessServer = $Matches[1]
            Check-Port $witnessServer 445 'SMB (witness share)' "Witness"
            Check-Port $witnessServer 135 'RPC EPM (DFS)'       "Witness" -Optional
        } else {
            Add-Result $cat 'Witness server port check' 'SKIP' "Cannot parse server from '$($script:WitnessShare)'"
        }
    }

    # ── L.5 iSCSI targets (SAN only) ─────────────────────────────────────────
    if ($script:StorageType -eq 'SAN' -and $script:IscsiTargets -and $script:IscsiTargets.Count -gt 0) {
        foreach ($target in $script:IscsiTargets) {
            Check-Port $target 3260 'iSCSI' "iSCSI"
        }
    } elseif ($script:StorageType -eq 'SAN' -and (-not $script:IscsiTargets -or $script:IscsiTargets.Count -eq 0)) {
        Add-Result $cat 'iSCSI target port checks' 'SKIP' 'No iSCSI targets specified (add IscsiTargets to hyperv-check.psd1)'
    }

    # ── L.6 SCVMM server (optional) ───────────────────────────────────────────
    if ($script:ScvmmServer -and $script:ScvmmServer -ne '') {
        Check-Port $script:ScvmmServer 8100 'SCVMM Agent'  "SCVMM"
        Check-Port $script:ScvmmServer  445 'SMB'          "SCVMM" -Optional
        Check-Port $script:ScvmmServer 5985 'WinRM HTTP'   "SCVMM" -Optional
    }

    # ── L.7 Self-checks (services that must listen locally) ───────────────────
    foreach ($p in @(
        @{ Port = 135;  Desc = 'RPC EPM (local)' },
        @{ Port = 445;  Desc = 'SMB (local)' },
        @{ Port = 3343; Desc = 'Cluster Service (local)' }
    )) {
        $ok = Test-TcpPort '127.0.0.1' $p.Port
        Add-Result $cat "Local $($p.Port)/TCP ($($p.Desc))" (if ($ok) { 'PASS' } else { 'WARN' }) (if ($ok) { 'Listening' } else { 'Not listening' })
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
    Write-Log "Log file: $script:LogFile" -Level INFO
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

# Load config file or prompt interactively — populates all $script:* variables
Initialize-Config

Write-Log "Test-HyperVNodeReadiness — Host: $env:COMPUTERNAME — Mode: $script:Mode — Storage: $script:StorageType" -Level SECTION
Write-Log "Log: $script:LogFile" -Level INFO

$runNode    = $script:Mode -in @('PreNode', 'Both')
$runCluster = $script:Mode -in @('PreCluster', 'Both')

if ($runNode) {
    Test-OSCompatibility
    Test-PlatformSecurity
    Test-HardwareRequirements
    Test-NetworkConfiguration
    Test-ActiveDirectory
    Test-DNSResolution
    Test-TimeSync
    Test-FirewallRules
    Test-Storage
}

if ($runCluster) {
    Test-ClusterReadiness -Nodes $script:ClusterNodes
}

# Section J: service account / OU — runs whenever configured
if ($script:ServiceAccount -ne '' -or $script:ClusterOU -ne '') {
    Test-ServiceAccountPermissions
}

# Section K: event log health (always for PreNode and Both)
if ($runNode) {
    Test-EventLogHealth
}

# Section L: port connectivity (always — needs infra endpoints from config)
Test-PortConnectivity

$failCount = Write-Summary

if ($script:HtmlReportPath -ne '') {
    Write-HtmlReport -Path $HtmlReportPath
}

exit $(if ($failCount -gt 0) { 1 } else { 0 })

#endregion
