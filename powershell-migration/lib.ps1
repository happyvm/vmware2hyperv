<#
.SYNOPSIS
    Shared function library for the VMware → Hyper-V migration toolkit.

.DESCRIPTION
    Central library imported by all migration scripts via dot-sourcing
    (`. "$PSScriptRoot\lib.ps1"`). Provides reusable functions covering:

    - **Logging**: Write-MigrationLog (timestamped, multi-stream with file output)
    - **Connections**: Connect-VCenter, Disconnect-VCenter, Import-RequiredModule
    - **Module compatibility**: PowerShell 7 / Windows PowerShell fallback strategies
      for modules that fail with .NET type-initializer errors in PS7
      (VirtualMachineManager, Veeam.Backup.PowerShell, FailoverClusters)
    - **OS mapping**: Normalize and map source OS labels to SCVMM operating systems
    - **VLAN resolution**: Multi-layer VLAN ID discovery from VMware Distributed
      Virtual Switches, standard port groups, and extension data
    - **Migration targeting**: Resolve-MigrationTarget maps VMware clusters to
      Hyper-V clusters via config.psd1 MigrationMappings.ClusterMappings
    - **CSV helpers**: Read standard or CMDB-extract CSVs with auto-detection of
      French/English column names and delimiter variants
    - **VMware Tools**: Get-OsGeneration, guest IP extraction
    - **Email**: Send-HtmlMail via SMTP, ConvertTo-HtmlEncoded for safe HTML
    - **Validation**: Assert-PathPresent, file-system helpers
    - **Config layering**: Import-MigrationConfig merges config.local.psd1 (operator
      overrides, gitignored) over config.psd1; Invoke-MigrationConfigWizard drives
      the interactive prompts behind configure-migration.ps1

    All functions use Write-MigrationLog for structured logging and support the
    -LogFile parameter for persistent audit trails.

.EXAMPLE
    # Dot-source from any migration script:
    . "$PSScriptRoot\lib.ps1"

    # Use individual functions:
    Write-MigrationLog "Step completed." -Level SUCCESS -LogFile $LogFile
    Connect-VCenter -Server "vcenter.domain.local" -LogFile $LogFile
    $os = ConvertTo-NormalizedOperatingSystemName "Windows Server 2022 Datacenter"

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI, Veeam.Backup.PowerShell,
    and VirtualMachineManager modules (imported on demand by individual functions).
    All functions in this library are idempotent where possible.
#>

# lib.ps1 — Common functions for VMware → Hyper-V migration scripts
# Load: . "$PSScriptRoot\lib.ps1"

# Dot-sourcing propagates strict mode to the calling script's scope, so every
# pipeline script runs strict. Under 'Latest', reads of unset variables, absent
# object properties, absent hashtable keys (dot notation) and .Count on scalars
# all throw — optional config keys must go through Get-MigrationConfigValue.
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Get-MigrationConfigValue : StrictMode-safe read of a nested config path
# (e.g. 'Orchestrator.Step3MaxParallelJobs'). Returns $Default when any
# segment is missing. Supports hashtables and PSCustomObjects.
# ---------------------------------------------------------------------------
function Get-MigrationConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        $Default = $null
    )

    $current = $Config
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }

        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
            continue
        }

        $property = $current.PSObject.Properties[$segment]
        if (-not $property) { return $Default }
        $current = $property.Value
    }

    if ($null -eq $current) { return $Default }
    return $current
}



# ---------------------------------------------------------------------------
# IPv4 validation helpers shared by step4 and step5.
# ---------------------------------------------------------------------------
function Test-ValidIPv4Address {
    param([AllowNull()][object]$Address)
    $text = if ($null -eq $Address) { '' } else { ([string]$Address).Trim() }
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $parsed = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($text, [ref]$parsed)) { return $false }
    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-ApipaIPv4Address {
    param([AllowNull()][object]$Address)
    $text = if ($null -eq $Address) { '' } else { ([string]$Address).Trim() }
    return (Test-ValidIPv4Address -Address $text) -and $text.StartsWith('169.254.')
}

function Normalize-IPv4AddressList {
    param([AllowNull()][object[]]$Addresses)
    $valid = @()
    $diagnostic = @()
    foreach ($address in @($Addresses)) {
        $text = if ($null -eq $address) { '' } else { ([string]$address).Trim() }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if (Test-ValidIPv4Address -Address $text) {
            $diagnostic += $text
            if (-not (Test-ApipaIPv4Address -Address $text)) { $valid += $text }
        }
    }
    [pscustomobject]@{
        RoutableIPv4 = @($valid | Select-Object -Unique)
        DiagnosticIPv4 = @($diagnostic | Select-Object -Unique)
    }
}

function Test-ExpectedIPv4Address {
    param(
        [AllowNull()][string]$ExpectedIP,
        [AllowNull()][object[]]$CurrentIPs,
        [bool]$RequireExpectedIp = $false,
        [bool]$ExpectedIpInvalid = $false,
        [bool]$ExpectedIpValidationSkipped = $false
    )
    $current = Normalize-IPv4AddressList -Addresses $CurrentIPs
    $expected = if ($null -eq $ExpectedIP) { '' } else { $ExpectedIP.Trim() }
    if ($ExpectedIpValidationSkipped) {
        return [pscustomobject]@{ ExpectedIP=$expected; CurrentIPs=@($current.DiagnosticIPv4); ComparableIPs=@($current.RoutableIPv4); IPMatches=$true; IPValidationStatus='ValidationSkipped'; IPValidationDetails='expected IP validation skipped' }
    }
    if ([string]::IsNullOrWhiteSpace($expected)) {
        $details = 'expected IP missing from extract-ip.csv'
        return [pscustomobject]@{ ExpectedIP=$expected; CurrentIPs=@($current.DiagnosticIPv4); ComparableIPs=@($current.RoutableIPv4); IPMatches=(-not $RequireExpectedIp); IPValidationStatus=($(if ($RequireExpectedIp) {'MissingExpectedIP'} else {'ValidationSkipped'})); IPValidationDetails=$details }
    }
    if ($ExpectedIpInvalid -or -not (Test-ValidIPv4Address -Address $expected)) {
        return [pscustomobject]@{ ExpectedIP=$expected; CurrentIPs=@($current.DiagnosticIPv4); ComparableIPs=@($current.RoutableIPv4); IPMatches=$false; IPValidationStatus='InvalidExpectedIP'; IPValidationDetails="invalid expected IPv4 address: $expected" }
    }
    if ($current.RoutableIPv4.Count -eq 0) {
        $detected = if ($current.DiagnosticIPv4.Count) { $current.DiagnosticIPv4 -join ', ' } else { 'none' }
        return [pscustomobject]@{ ExpectedIP=$expected; CurrentIPs=@($current.DiagnosticIPv4); ComparableIPs=@($current.RoutableIPv4); IPMatches=$false; IPValidationStatus='NoGuestIPReported'; IPValidationDetails="expected $expected, detected $detected" }
    }
    if (@($current.RoutableIPv4) -contains $expected) {
        return [pscustomobject]@{ ExpectedIP=$expected; CurrentIPs=@($current.DiagnosticIPv4); ComparableIPs=@($current.RoutableIPv4); IPMatches=$true; IPValidationStatus='Matched'; IPValidationDetails="expected $expected detected" }
    }
    return [pscustomobject]@{ ExpectedIP=$expected; CurrentIPs=@($current.DiagnosticIPv4); ComparableIPs=@($current.RoutableIPv4); IPMatches=$false; IPValidationStatus='Mismatch'; IPValidationDetails="unexpected IP: expected $expected, detected $($current.DiagnosticIPv4 -join ', ')" }
}

# ---------------------------------------------------------------------------
# Write-MigrationLog : timestamped logging to streams + file
# ---------------------------------------------------------------------------
function Write-MigrationLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [string]$LogFile
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    Write-Verbose -Message $entry

    switch ($Level) {
        "ERROR" {
            Write-Error -Message $entry -ErrorAction Continue
        }
        "WARNING" {
            Write-Warning -Message $entry
        }
        default {
            Write-Information -MessageData $entry -InformationAction Continue
        }
    }

    if ($LogFile) {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $entry
    }
}

# ---------------------------------------------------------------------------
# Assert-PathPresent : stops the script if a file is missing
# ---------------------------------------------------------------------------
function Assert-PathPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Label = "File",

        [string]$LogFile
    )

    if (-not (Test-Path $Path)) {
        $message = "$Label not found: $Path"
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Connect-VCenter : vCenter connection using Multiple mode
# ---------------------------------------------------------------------------
$script:VCenterCredentialFallback = $null

function Get-VCenterPowerCLIConfiguration {
    return Get-PowerCLIConfiguration
}

function Set-VCenterPowerCLIConfigurationMultipleMode {
    Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Confirm:$false | Out-Null
}

function Invoke-VCenterVIServerConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [System.Management.Automation.PSCredential]$Credential
    )

    if ($Credential) {
        Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop | Out-Null
    } else {
        Connect-VIServer -Server $Server -ErrorAction Stop | Out-Null
    }
}

function Request-VCenterFallbackCredential {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    return Get-Credential -Message "Enter credentials for vCenter $Server"
}

function Connect-VCenter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [string]$LogFile
    )

    Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile

    if ((Get-VCenterPowerCLIConfiguration).DefaultVIServerMode -ne "Multiple") {
        Set-VCenterPowerCLIConfigurationMultipleMode
    }

    try {
        Invoke-VCenterVIServerConnection -Server $Server
        Write-MigrationLog "Connected to vCenter using current Windows credentials: $Server" -Level SUCCESS -LogFile $LogFile
        return
    } catch {
        Write-MigrationLog "Windows credential pass-through failed for vCenter $Server. Falling back to an explicit credential prompt." -Level WARNING -LogFile $LogFile
    }

    if (-not $script:VCenterCredentialFallback) {
        $script:VCenterCredentialFallback = Request-VCenterFallbackCredential -Server $Server
    }

    if (-not $script:VCenterCredentialFallback) {
        $message = "Failed to connect to vCenter ${Server}: no fallback credential was provided."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }

    try {
        Invoke-VCenterVIServerConnection -Server $Server -Credential $script:VCenterCredentialFallback
        Write-MigrationLog "Connected to vCenter using fallback credentials: $Server" -Level SUCCESS -LogFile $LogFile
    } catch {
        $message = "Failed to connect to vCenter $Server with fallback credentials: $_"
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Disconnect-VCenter : silent disconnection from vCenter
# ---------------------------------------------------------------------------
function Disconnect-VCenter {
    param([string]$LogFile)

    # -Server *: Connect-VCenter enforces DefaultVIServerMode Multiple, so several
    # connections can be open; without it only the default server is disconnected.
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    Write-MigrationLog "Disconnected from vCenter." -Level INFO -LogFile $LogFile
}

# ---------------------------------------------------------------------------
# Get-ModuleImportStrategies : ordered import fallbacks for the current engine
# ---------------------------------------------------------------------------
# Modules that import fine into the PowerShell 7 process (their manifest allows it)
# but whose cmdlets then fail at runtime with .NET type-initializer errors such as
# "Microsoft.VirtualManager.Utils.TraceProviders.IndigoLayer". For these, the
# Windows PowerShell compatibility session must be tried FIRST: a successful
# in-process import would otherwise mask the broken runtime until the first call.
$script:WindowsOnlyManagementModules = @(
    'VirtualMachineManager',
    'Veeam.Backup.PowerShell',
    'FailoverClusters'
)

function Get-ModuleImportStrategies {
    param(
        [switch]$UseWindowsPowerShellFallback,

        [string]$ModuleName
    )

    if ($PSVersionTable.PSEdition -ne "Core") {
        return @("Standard")
    }

    if ($UseWindowsPowerShellFallback -and $IsWindows) {
        if ($ModuleName -and $script:WindowsOnlyManagementModules -contains $ModuleName) {
            return @("WindowsPowerShell", "Standard", "SkipEditionCheck")
        }

        # Windows-only management modules such as VirtualMachineManager/Veeam can
        # throw .NET type-initializer errors when loaded directly in PowerShell 7.
        # Prefer the Windows PowerShell compatibility session before trying
        # SkipEditionCheck, which still loads the module into the pwsh process.
        return @("Standard", "WindowsPowerShell", "SkipEditionCheck")
    }

    return @("Standard", "SkipEditionCheck")
}

# ---------------------------------------------------------------------------
# Import-RequiredModule : PowerShell 7-compatible module import
# ---------------------------------------------------------------------------
function Import-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$LogFile,

        [switch]$UseWindowsPowerShellFallback
    )

    $candidateNames = if ($Name -eq "VMware.PowerCLI") {
        @("VMware.PowerCLI", "VCF.PowerCLI")
    } else {
        @($Name)
    }

    foreach ($candidateName in $candidateNames) {
        $loadedModule = Get-Module -Name $candidateName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($loadedModule) {
            Write-MigrationLog "Module already loaded in current session: $($loadedModule.Name)" -LogFile $LogFile
            return
        }
    }

    function Import-ModuleCandidate {
        param([string]$CandidateName)

        $importErrors = @()
        foreach ($strategy in (Get-ModuleImportStrategies -UseWindowsPowerShellFallback:$UseWindowsPowerShellFallback -ModuleName $CandidateName)) {
            try {
                switch ($strategy) {
                    "Standard" {
                        Import-Module -Name $CandidateName -DisableNameChecking -ErrorAction Stop 3>$null
                        Write-MigrationLog "Module imported: $CandidateName" -LogFile $LogFile
                    }
                    "WindowsPowerShell" {
                        Import-Module -Name $CandidateName -UseWindowsPowerShell -DisableNameChecking -ErrorAction Stop 3>$null
                        Write-MigrationLog "Module imported via Windows PowerShell compatibility mode: $CandidateName" -Level WARNING -LogFile $LogFile
                    }
                    "SkipEditionCheck" {
                        Import-Module -Name $CandidateName -SkipEditionCheck -DisableNameChecking -ErrorAction Stop 3>$null
                        Write-MigrationLog "Module imported via SkipEditionCheck fallback: $CandidateName" -Level WARNING -LogFile $LogFile
                    }
                }

                return $true
            } catch {
                $importErrors += "${strategy}: $_"
            }
        }

        Write-MigrationLog "Unable to import module $CandidateName. Attempts failed: $($importErrors -join '; ')" -Level WARNING -LogFile $LogFile
        return $false
    }

    foreach ($candidateName in $candidateNames) {
        if (Import-ModuleCandidate -CandidateName $candidateName) {
            return
        }
    }

    if ($Name -eq "VMware.PowerCLI") {
        foreach ($candidateName in $candidateNames) {
            if (Get-Module -ListAvailable -Name $candidateName) {
                continue
            }

            try {
                Install-Module -Name $candidateName -Scope CurrentUser -AllowClobber -Force -ErrorAction Stop
                Write-MigrationLog "PowerCLI module installed for current user: $candidateName" -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-MigrationLog "Automatic install failed for ${candidateName}: $_" -Level WARNING -LogFile $LogFile
            }
        }

        foreach ($candidateName in $candidateNames) {
            if (Import-ModuleCandidate -CandidateName $candidateName) {
                return
            }
        }
    }

    $candidateList = $candidateNames -join ", "
    $message = "Unable to import module $Name. Tried: $candidateList"
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    throw $message
}

# ---------------------------------------------------------------------------
# Repair-WindowsOnlyModuleImport : recover from an in-process import of a
# Windows-only module whose cmdlets fail at runtime (e.g. SCVMM "IndigoLayer"
# type-initializer errors). Re-imports the module through the Windows
# PowerShell compatibility session; the compat proxy functions then take
# precedence over the broken in-process cmdlets.
# ---------------------------------------------------------------------------
function Repair-WindowsOnlyModuleImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$LogFile
    )

    if ($PSVersionTable.PSEdition -ne "Core" -or -not $IsWindows) {
        return $false
    }

    try {
        Remove-Module -Name $Name -Force -ErrorAction SilentlyContinue
        Import-Module -Name $Name -UseWindowsPowerShell -DisableNameChecking -Force -ErrorAction Stop 3>$null
        Write-MigrationLog "Module '$Name' re-imported through the Windows PowerShell compatibility session after an in-process runtime failure." -Level WARNING -LogFile $LogFile
        return $true
    } catch {
        Write-MigrationLog "Unable to re-import module '$Name' through the Windows PowerShell compatibility session: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
        return $false
    }
}

# ---------------------------------------------------------------------------
# Install-RsatHyperV : install Hyper-V RSAT management tools when available
# ---------------------------------------------------------------------------
function Install-RsatHyperV {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Validation result is intentionally cached per worker process, across dot-sourced script invocations.')]
    param([string]$LogFile)

    # Get-Variable: a bare read of the never-set global throws under StrictMode.
    $rsatAlreadyValidated = Get-Variable -Name 'Vmware2HyperV_RsatHyperVValidated' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($rsatAlreadyValidated) {
        Write-MigrationLog "Hyper-V RSAT/module availability already validated in current worker session; skipping repeated check." -LogFile $LogFile
        return
    }

    # $IsLinux/$IsMacOS only exist on PowerShell Core; guard for Windows PowerShell 5.1.
    if ($PSVersionTable.PSEdition -eq 'Core' -and ($IsLinux -or $IsMacOS)) {
        Write-MigrationLog "RSAT Hyper-V check skipped on non-Windows host." -Level WARNING -LogFile $LogFile
        $global:Vmware2HyperV_RsatHyperVValidated = $true
        return
    }

    if (Get-Module -ListAvailable -Name "Hyper-V") {
        $global:Vmware2HyperV_RsatHyperVValidated = $true
        Write-MigrationLog "Hyper-V PowerShell module already available; caching validation result for current worker session." -LogFile $LogFile
        return
    }

    try {
        $rsatCapabilities = Get-WindowsCapability -Online -ErrorAction Stop |
            Where-Object { $_.Name -match 'Rsat\..*Hyper.?V.*Tools' }

        foreach ($capability in $rsatCapabilities) {
            if ($capability.State -ne "Installed") {
                Add-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop | Out-Null
                Write-MigrationLog "Installed Windows capability: $($capability.Name)" -Level SUCCESS -LogFile $LogFile
            }
        }
    } catch {
        Write-MigrationLog "Unable to install RSAT Hyper-V capability via Add-WindowsCapability: $_" -Level WARNING -LogFile $LogFile
    }

    if (-not (Get-Module -ListAvailable -Name "Hyper-V")) {
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V-Management-PowerShell" -All -NoRestart -ErrorAction Stop | Out-Null
            Write-MigrationLog "Enabled optional feature Microsoft-Hyper-V-Management-PowerShell." -Level SUCCESS -LogFile $LogFile
        } catch {
            Write-MigrationLog "Unable to enable Hyper-V PowerShell management feature automatically: $_" -Level WARNING -LogFile $LogFile
        }
    }

    if (-not (Get-Module -ListAvailable -Name "Hyper-V")) {
        $message = "Unable to ensure Hyper-V PowerShell module availability after installation attempts."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }

    $global:Vmware2HyperV_RsatHyperVValidated = $true
    Write-MigrationLog "Hyper-V RSAT/module availability validated and cached for current worker session." -Level SUCCESS -LogFile $LogFile
}


# ---------------------------------------------------------------------------
# Resolve-MigrationTarget : resolves Hyper-V target settings from VMware cluster mapping
# ---------------------------------------------------------------------------
function Resolve-MigrationTarget {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [AllowNull()]
        [string]$VmwareClusterName,

        [string]$LogFile
    )

    # Every read goes through Get-MigrationConfigValue: a mapping entry (or a
    # custom config file) may omit keys, and a bare dot access on a missing
    # hashtable key throws under StrictMode Latest.
    $target = [ordered]@{
        VMwareCluster  = $VmwareClusterName
        HyperVHost     = [string](Get-MigrationConfigValue -Config $Config -Path 'HyperV.Host1' -Default '')
        HyperVHost2    = [string](Get-MigrationConfigValue -Config $Config -Path 'HyperV.Host2' -Default '')
        HyperVCluster  = [string](Get-MigrationConfigValue -Config $Config -Path 'HyperV.Cluster' -Default '')
        ClusterStorage = [string](Get-MigrationConfigValue -Config $Config -Path 'HyperV.ClusterStorage' -Default '')
        MappingMatched = $false
    }

    $clusterMappings = @(Get-MigrationConfigValue -Config $Config -Path 'MigrationMappings.ClusterMappings' -Default @())

    if (-not [string]::IsNullOrWhiteSpace($VmwareClusterName) -and $clusterMappings.Count -gt 0) {
        $mapping = $clusterMappings |
            Where-Object {
                $mappingClusterName = [string](Get-MigrationConfigValue -Config $_ -Path 'VMwareCluster' -Default '')
                -not [string]::IsNullOrWhiteSpace($mappingClusterName) -and [string]::Equals($mappingClusterName, $VmwareClusterName, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Select-Object -First 1

        if ($mapping) {
            foreach ($mappingEntry in @(
                @{ Key = 'Host1';          Target = 'HyperVHost' }
                @{ Key = 'Host2';          Target = 'HyperVHost2' }
                @{ Key = 'HyperVCluster';  Target = 'HyperVCluster' }
                @{ Key = 'ClusterStorage'; Target = 'ClusterStorage' }
            )) {
                $mappingValue = [string](Get-MigrationConfigValue -Config $mapping -Path $mappingEntry.Key -Default '')
                if (-not [string]::IsNullOrWhiteSpace($mappingValue)) { $target[$mappingEntry.Target] = $mappingValue }
            }
            $target.MappingMatched = $true
        }
    }

    if ($target.MappingMatched) {
        Write-MigrationLog "Resolved target mapping for VMware cluster '$VmwareClusterName': Hyper-V cluster '$($target.HyperVCluster)', storage '$($target.ClusterStorage)', hosts '$($target.HyperVHost)'/'$($target.HyperVHost2)'." -LogFile $LogFile
    } elseif (-not [string]::IsNullOrWhiteSpace($VmwareClusterName)) {
        Write-MigrationLog "No target mapping found for VMware cluster '$VmwareClusterName'; using default Hyper-V target '$($target.HyperVCluster)' and storage '$($target.ClusterStorage)'." -Level WARNING -LogFile $LogFile
    } else {
        Write-MigrationLog "VMware cluster is unknown; using default Hyper-V target '$($target.HyperVCluster)' and storage '$($target.ClusterStorage)'." -Level WARNING -LogFile $LogFile
    }

    return [pscustomobject]$target
}

# ---------------------------------------------------------------------------
# ConvertTo-HtmlEncoded : HTML-encode a string to prevent injection in mail templates
# ---------------------------------------------------------------------------
function ConvertTo-HtmlEncoded {
    param(
        [AllowNull()]
        [string]$Value
    )
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

# ---------------------------------------------------------------------------
# Send-HtmlMail : send an email in HTML format
#
# SECURITY: Forces TLS 1.2+ on every call. The default port is now 587 (submission)
#           instead of 25 (unencrypted SMTP relay) to enforce STARTTLS.
#           SMTP authentication is supported via the optional -Credential parameter.
#           The credential object is explicitly nulled in the finally block to limit
#           its lifetime in memory.
# ---------------------------------------------------------------------------
function Send-HtmlMail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$From,

        [Parameter(Mandatory = $true)]
        [string[]]$To,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$HtmlBody,

        [Parameter(Mandatory = $true)]
        [string]$SmtpServer,

        [int]$Port = 587,

        [System.Management.Automation.PSCredential]$Credential,

        [string]$LogFile
    )

    # Force TLS 1.2+ for every SMTP call in this function
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

    $mailMessage = $null
    $smtpClient = $null
    try {
        $mailMessage = [System.Net.Mail.MailMessage]::new()
        $mailMessage.From = [System.Net.Mail.MailAddress]::new($From)
        foreach ($recipient in $To) {
            [void]$mailMessage.To.Add($recipient)
        }
        $mailMessage.Subject = $Subject
        $mailMessage.Body = $HtmlBody
        $mailMessage.IsBodyHtml = $true

        $smtpClient = [System.Net.Mail.SmtpClient]::new($SmtpServer, $Port)
        $smtpClient.EnableSsl = $true

        if ($Credential) {
            $smtpClient.Credentials = $Credential.GetNetworkCredential()
            Write-MigrationLog "SMTP authentication enabled for $From" -LogFile $LogFile
        }

        $smtpClient.Send($mailMessage)

        Write-MigrationLog "Email sent to: $($To -join ', ')" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-MigrationLog "Failed to send email : $_" -Level ERROR -LogFile $LogFile
    } finally {
        if ($mailMessage) { $mailMessage.Dispose() }
        if ($smtpClient) {
            if ($smtpClient.Credentials) { $smtpClient.Credentials = $null }
            $smtpClient.Dispose()
        }
        # Clear the credential variable to limit its lifetime in memory
        if ($Credential) { $Credential = $null }
    }
}



# ---------------------------------------------------------------------------
# Invoke-SCVMMCommand : proxy for SCVMM cmdlets (routes through WinPS compat session if present)
#
# SECURITY: Accepts a [scriptblock] parameter. This function is designed for
#           internal callers only; all call sites pass hard-coded scriptblocks
#           defined in migration scripts. Do NOT pass user-provided or external
#           input as a ScriptBlock — this would open an arbitrary code injection
#           vector. If dynamic invocation is needed in the future, use
#           [ScriptBlock]::Create() with strict input validation.
# ---------------------------------------------------------------------------
function Invoke-SCVMMCommand {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @()
    )

    $compatSession = Get-PSSession -Name 'WinPSCompatSession' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($compatSession) {
        return Invoke-Command -Session $compatSession -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }

    return & $ScriptBlock @ArgumentList
}

# ---------------------------------------------------------------------------
# Invoke-VeeamCommand : proxy for Veeam cmdlets (routes through WinPS compat session if present)
#
# SECURITY: Same ScriptBlock injection warning as Invoke-SCVMMCommand above.
#           All call sites are internal and pass hard-coded scriptblocks.
#           Do NOT pass user input as a ScriptBlock.
# ---------------------------------------------------------------------------
function Invoke-VeeamCommand {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @()
    )

    $compatSession = Get-PSSession -Name 'WinPSCompatSession' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($compatSession) {
        return Invoke-Command -Session $compatSession -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }

    return & $ScriptBlock @ArgumentList
}

# ---------------------------------------------------------------------------
# Get-FirstPropertyValue : return the first non-empty value from a list of candidate property names
# ---------------------------------------------------------------------------
function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Get-OsGeneration : extract OS release year (2003-2025) from an OS name string
# ---------------------------------------------------------------------------
function Get-OsGeneration {
    param(
        [string]$OperatingSystem
    )

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
        return $null
    }

    if ($OperatingSystem -match '2003') { return 2003 }
    if ($OperatingSystem -match '2008') { return 2008 }
    if ($OperatingSystem -match '2012') { return 2012 }
    if ($OperatingSystem -match '2016') { return 2016 }
    if ($OperatingSystem -match '2019') { return 2019 }
    if ($OperatingSystem -match '2022') { return 2022 }
    if ($OperatingSystem -match '2025') { return 2025 }

    return $null
}

# ---------------------------------------------------------------------------
# ConvertTo-NormalizedOperatingSystemName : normalize OS labels before mapping to SCVMM operating systems
# ---------------------------------------------------------------------------
function ConvertTo-NormalizedOperatingSystemName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $normalized = $Name.Trim().ToLowerInvariant()
    $normalized = $normalized -replace '[\/_-]+', ' '
    $normalized = $normalized -replace '\s+', ' '
    $normalized = $normalized -replace '^microsoft\s+', ''
    return $normalized.Trim()
}

# ---------------------------------------------------------------------------
# Resolve-OperatingSystemMapping : resolve a source OS value to an SCVMM OS name
# ---------------------------------------------------------------------------
function Resolve-OperatingSystemMapping {
    param(
        [AllowNull()]
        [string]$OperatingSystem,

        $OperatingSystemMap
    )

    $normalized = ConvertTo-NormalizedOperatingSystemName -Name $OperatingSystem
    if ([string]::IsNullOrWhiteSpace($normalized) -or -not $OperatingSystemMap) {
        return $null
    }

    foreach ($entry in $OperatingSystemMap.GetEnumerator()) {
        $entryKey = ConvertTo-NormalizedOperatingSystemName -Name ([string]$entry.Key)
        if ($entryKey -eq $normalized) {
            return [string]$entry.Value
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Initialize-ScvmmSessionFunction : push function definitions into the WinPS compat session
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Loads PowerShell function files into the WinPS compatibility session so
    they are available inside Invoke-SCVMMCommand scriptblocks.

.DESCRIPTION
    Uses Invoke-Command -FilePath to push function-only .ps1 files into the
    persistent WinPS compat session. Also dot-sources the same files locally
    so they work in direct (non-compat) mode.

    With persistent workers, functions are parsed only once per worker lifetime,
    avoiding the current re-parse of ~800 lines of nested functions on every
    Invoke-SCVMMCommand call.

.PARAMETER FunctionFiles
    Array of .ps1 file paths containing only function definitions (no inline
    execution). These files are pushed into the WinPS compat session and
    dot-sourced locally.

.EXAMPLE
    Initialize-ScvmmSessionFunction -FunctionFiles @(
        "$PSScriptRoot\step3\Step3.ScvmmSession.Functions.ps1"
    )
#>
function Initialize-ScvmmSessionFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$FunctionFiles
    )

    $compatSession = Get-PSSession -Name 'WinPSCompatSession' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    foreach ($file in $FunctionFiles) {
        if (-not (Test-Path -Path $file -PathType Leaf)) {
            Write-Warning "Initialize-ScvmmSessionFunction: file not found — '$file'"
            continue
        }

        if ($compatSession) {
            Write-Verbose "Initialize-ScvmmSessionFunction: loading '$file' into WinPS compat session"
            Invoke-Command -Session $compatSession -FilePath $file
        }

        Write-Verbose "Initialize-ScvmmSessionFunction: dot-sourcing '$file' locally"
        . $file
    }
}

# ---------------------------------------------------------------------------
# Config layering : config.psd1 (versioned template) + config.local.psd1
# (gitignored, operator-specific overrides). See configure-migration.ps1.
# ---------------------------------------------------------------------------

# Curated list of config values an operator is expected to customize per
# environment. Add an entry here whenever a script starts depending on a new
# config.psd1 key — configure-migration.ps1 will then prompt for it on the
# next run instead of silently leaving it unset.
$script:MigrationConfigSchema = @(
    @{ Section = 'VCenter';    Key = 'Server';        Question = 'Serveur vCenter (nom ou IP)' }
    @{ Section = 'SCVMM';      Key = 'Server';         Question = 'Serveur SCVMM (nom ou IP)' }
    @{ Section = 'HyperV';     Key = 'Host1';          Question = "Hôte Hyper-V par défaut (Instant Recovery)" }
    @{ Section = 'HyperV';     Key = 'Host2';          Question = "Hôte Hyper-V par défaut (LiveMigration)" }
    @{ Section = 'HyperV';     Key = 'Cluster';        Question = "Cluster Hyper-V par défaut" }
    @{ Section = 'HyperV';     Key = 'ClusterStorage'; Question = 'Cluster Shared Volume par défaut (ex: C:\ClusterStorage\Volume2)' }
    @{ Section = 'Veeam';      Key = 'BackupRepo';     Question = 'Repository de backup Veeam' }
    @{ Section = 'Veeam';      Key = 'BackupProxy';    Question = 'Proxy de backup Veeam'; Optional = $true }
    @{ Section = 'Tags';       Key = 'Category';       Question = 'Catégorie de tag vSphere pour les lots de migration' }
    @{ Section = 'Tags';       Key = 'BackupTag';      Question = 'Tag appliqué aux VMs après migration' }
    @{ Section = 'Smtp';       Key = 'Server';         Question = 'Serveur SMTP' }
    @{ Section = 'Smtp';       Key = 'Port';           Question = 'Port SMTP'; Type = 'Int' }
    @{ Section = 'Smtp';       Key = 'From';           Question = 'Adresse expéditeur des emails' }
    @{ Section = 'Smtp';       Key = 'Enabled';        Question = "Activer l'envoi d'email ? (o/n)"; Type = 'Bool' }
    @{ Section = 'Recipients'; Key = 'internal';       Question = "Destinataires du groupe 'internal' (emails séparés par des virgules)"; Type = 'StringList' }
    @{ Section = 'Recipients'; Key = 'infogerant';     Question = "Destinataires du groupe 'infogerant' (emails séparés par des virgules)"; Type = 'StringList' }
    @{ Section = 'Paths';      Key = 'CsvFile';        Question = 'Chemin du CSV batch (colonnes VMName;Tag)' }
    @{ Section = 'Paths';      Key = 'ExtractIpCsv';   Question = 'Chemin du CSV IP attendues'; Optional = $true }
    @{ Section = 'Paths';      Key = 'CmdbExtractCsv'; Question = "Chemin de l'extrait CMDB"; Optional = $true }
    @{ Section = 'Paths';      Key = 'LogDir';         Question = 'Dossier des logs' }
)

# ---------------------------------------------------------------------------
# Merge-Hashtable : recursive merge, $Override wins on conflicting leaf keys
# ---------------------------------------------------------------------------
function Merge-Hashtable {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Base,

        [Parameter(Mandatory = $true)]
        [hashtable]$Override
    )

    $merged = $Base.Clone()
    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $merged[$key] = Merge-Hashtable -Base $merged[$key] -Override $Override[$key]
        } else {
            $merged[$key] = $Override[$key]
        }
    }
    return $merged
}

function Get-MigrationLocalConfigPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
    )

    return Join-Path -Path (Split-Path -Path $ConfigFile -Parent) -ChildPath "config.local.psd1"
}

# ---------------------------------------------------------------------------
# Import-MigrationConfig : loads config.psd1, then layers config.local.psd1
# on top when present. Use this instead of Import-PowerShellDataFile directly
# so every script picks up operator overrides the same way.
# ---------------------------------------------------------------------------
function Import-MigrationConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
    )

    $config = Import-PowerShellDataFile -LiteralPath $ConfigFile
    $localConfigFile = Get-MigrationLocalConfigPath -ConfigFile $ConfigFile
    if (Test-Path -LiteralPath $localConfigFile) {
        $localConfig = Import-PowerShellDataFile -LiteralPath $localConfigFile
        $config = Merge-Hashtable -Base $config -Override $localConfig
    }
    return $config
}

# ---------------------------------------------------------------------------
# Get-MigrationConfigMissingKeys : schema entries not yet answered in
# config.local.psd1 (new questions introduced by a script update, or the
# very first run before config.local.psd1 exists).
# ---------------------------------------------------------------------------
function Get-MigrationConfigMissingKeys {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
    )

    $localConfigFile = Get-MigrationLocalConfigPath -ConfigFile $ConfigFile
    $localConfig = if (Test-Path -LiteralPath $localConfigFile) { Import-PowerShellDataFile -LiteralPath $localConfigFile } else { @{} }

    return @($script:MigrationConfigSchema | Where-Object {
        -not ($localConfig.ContainsKey($_.Section) -and $localConfig[$_.Section].ContainsKey($_.Key))
    })
}

function ConvertTo-Psd1ScalarLiteral {
    param($Value)

    if ($null -eq $Value) { return "''" }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [int])  { return "$Value" }
    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-Psd1ScalarLiteral $_ })
        return "@(" + ($items -join ', ') + ")"
    }
    # Nested hashtables: config.local.psd1 may carry hand-added structured overrides
    # (e.g. SCVMM.Network); stringifying them would corrupt the file on the next
    # wizard run ('System.Collections.Hashtable').
    if ($Value -is [hashtable]) {
        $entries = @(foreach ($key in $Value.Keys) {
            "$key = $(ConvertTo-Psd1ScalarLiteral $Value[$key])"
        })
        return "@{ " + ($entries -join '; ') + " }"
    }
    $escaped = [string]$Value -replace "'", "''"
    return "'$escaped'"
}

# ---------------------------------------------------------------------------
# Save-MigrationLocalConfig : writes a { Section = { Key = scalar/array } }
# hashtable out as a valid config.local.psd1.
# ---------------------------------------------------------------------------
function Save-MigrationLocalConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Data
    )

    $body = foreach ($section in $Data.Keys) {
        "    $section = @{"
        foreach ($key in $Data[$section].Keys) {
            "        $key = $(ConvertTo-Psd1ScalarLiteral $Data[$section][$key])"
        }
        "    }"
        ""
    }

    $content = @(
        "# config.local.psd1 — valeurs spécifiques à cet environnement (vCenter, SCVMM, SMTP, chemins...)."
        "# Généré/complété par configure-migration.ps1 — ne pas versionner (voir .gitignore)."
        "# Fusionné par-dessus config.psd1 au chargement (Import-MigrationConfig dans lib.ps1)."
        "@{"
    ) + $body + @("}")

    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Invoke-MigrationConfigWizard : interactive prompt loop over
# $script:MigrationConfigSchema. Only asks about entries missing from
# config.local.psd1 unless -Full is passed to re-ask everything.
# ---------------------------------------------------------------------------
function Invoke-MigrationConfigWizard {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile,

        [switch]$Full
    )

    $defaults = Import-PowerShellDataFile -LiteralPath $ConfigFile
    $localConfigFile = Get-MigrationLocalConfigPath -ConfigFile $ConfigFile
    $localConfig = if (Test-Path -LiteralPath $localConfigFile) { Import-PowerShellDataFile -LiteralPath $localConfigFile } else { @{} }

    $entriesToAsk = if ($Full) {
        $script:MigrationConfigSchema
    } else {
        @($script:MigrationConfigSchema | Where-Object {
            -not ($localConfig.ContainsKey($_.Section) -and $localConfig[$_.Section].ContainsKey($_.Key))
        })
    }

    if ($entriesToAsk.Count -eq 0) {
        Write-Host "Configuration locale déjà complète ($localConfigFile) — rien à demander." -ForegroundColor Green
        return
    }

    Write-Host ""
    Write-Host "=== Configuration de la migration ($($entriesToAsk.Count) valeur(s) à renseigner) ===" -ForegroundColor Cyan
    Write-Host "Entrée seule = garder la valeur entre crochets." -ForegroundColor DarkGray
    Write-Host ""

    foreach ($entry in $entriesToAsk) {
        # 'Type' and 'Optional' are optional schema keys: a bare $entry.Type on a
        # hashtable without that key throws under StrictMode Latest.
        $entryType = [string](Get-MigrationConfigValue -Config $entry -Path 'Type' -Default '')
        $entryOptional = [bool](Get-MigrationConfigValue -Config $entry -Path 'Optional' -Default $false)

        $currentValue = $null
        if ($localConfig.ContainsKey($entry.Section) -and $localConfig[$entry.Section].ContainsKey($entry.Key)) {
            $currentValue = $localConfig[$entry.Section][$entry.Key]
        } elseif ($defaults.ContainsKey($entry.Section) -and $defaults[$entry.Section].ContainsKey($entry.Key)) {
            $currentValue = $defaults[$entry.Section][$entry.Key]
        }

        $displayValue = if ($entryType -eq 'StringList' -and $currentValue) { $currentValue -join ', ' } else { $currentValue }
        $suffix = if ($null -ne $displayValue -and "$displayValue" -ne '') { " [$displayValue]" } else { "" }
        $optionalSuffix = if ($entryOptional) { " (optionnel)" } else { "" }

        do {
            $answer = Read-Host "$($entry.Question)$optionalSuffix$suffix"
            $parseFailed = $false
            $value = if ([string]::IsNullOrWhiteSpace($answer)) {
                $currentValue
            } else {
                switch ($entryType) {
                    'Int' {
                        # TryParse instead of a bare [int] cast: an invalid entry must
                        # re-prompt, not throw out of the wizard (or leave $value stale).
                        $parsedInt = 0
                        if ([int]::TryParse($answer.Trim(), [ref]$parsedInt)) { $parsedInt } else { $parseFailed = $true; $null }
                    }
                    'Bool'       { $answer -match '^(o|oui|y|yes|true|1)$' }
                    'StringList' { @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                    default      { $answer }
                }
            }
            $isEmpty = ($null -eq $value) -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) -or ($value -is [array] -and $value.Count -eq 0)
            if ($parseFailed) {
                Write-Host "Valeur numérique invalide." -ForegroundColor Yellow
            } elseif ($isEmpty -and -not $entryOptional) {
                Write-Host "Valeur obligatoire." -ForegroundColor Yellow
            }
        } while ($parseFailed -or ($isEmpty -and -not $entryOptional))

        if (-not $localConfig.ContainsKey($entry.Section)) { $localConfig[$entry.Section] = @{} }
        $localConfig[$entry.Section][$entry.Key] = $value
    }

    Save-MigrationLocalConfig -Path $localConfigFile -Data $localConfig
    Write-Host ""
    Write-Host "Configuration enregistrée dans: $localConfigFile" -ForegroundColor Green
}
