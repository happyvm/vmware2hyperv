<#
.SYNOPSIS
    Start Hyper-V VMs and validate post-migration compliance.

.DESCRIPTION
    Starts the migrated VMs on Hyper-V hosts, then loops until every VM is fully
    compliant (or the loop is interrupted / -IntegrationMaxIterations is reached):
    - VM running, NIC connected, guest IPv4 matches the expected IP (extract-ip.csv)
    - Integration services healthy (heartbeat, time sync, data exchange, guest agent)
    - High Availability enabled and the post-migration backup tag present in SCVMM
    - WinRM-based VMware Tools removal on Windows Server 2012+ (best effort)

    This folds what used to be a separate post-migration-checks pass into the same
    SCVMM inventory loop as the VM start/Integration Services polling, avoiding a
    second full pass over every VM. By default the loop has no iteration cap: it
    keeps polling until every VM is compliant. Interrupt with Ctrl+C to stop waiting
    without losing the VMs already started, or pass -IntegrationMaxIterations to cap it.

.PARAMETER ConfigFile
    Optional path to the configuration file. Defaults to config.psd1.

.PARAMETER CsvFile
    Path to the batch CSV file. Defaults to Config.Paths.CsvFile.

.PARAMETER ExtractIpCsvFile
    Path to the CSV of expected guest IPs. Defaults to Config.Paths.ExtractIpCsv, or
    <CsvFile folder>\extract-ip.csv. Optional: if the file is missing, the expected-IP
    check is skipped (treated as compliant) instead of failing the whole script.

.PARAMETER Tag
    Optional batch tag to filter VMs from the CSV.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.PARAMETER IntegrationPollIntervalSeconds
    Interval between compliance polls. Default: 30.

.PARAMETER IntegrationMaxIterations
    Maximum polling iterations. Default: 0 (unlimited — loop until every VM is
    compliant or the script is interrupted).

.PARAMETER WinRmRetryDelaySeconds
    Delay between WinRM retries in seconds. Default: 15.

.PARAMETER WinRmMaxAttempts
    Maximum WinRM connection attempts. Default: 20.

.EXAMPLE
    .\step4-StartVM.ps1 -Tag HypMig-lot-118

.EXAMPLE
    .\step4-StartVM.ps1 -Tag HypMig-lot-118 -IntegrationMaxIterations 20

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VirtualMachineManager module.
#>

param (
    [string]$ConfigFile,
    [string]$CsvFile,
    [string]$ExtractIpCsvFile,
    [string]$Tag,
    [string]$LogFile,
    [int]$IntegrationPollIntervalSeconds = 30,
    [int]$IntegrationMaxIterations = 0,
    [int]$WinRmRetryDelaySeconds = 15,
    [int]$WinRmMaxAttempts = 20
)

Set-StrictMode -Version Latest

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config = Import-MigrationConfig -ConfigFile $ConfigFile
if (-not $CsvFile) { $CsvFile = $Config.Paths.CsvFile }
Assert-PathPresent -Path $CsvFile -Label "Batch CSV"

if (-not $ExtractIpCsvFile) {
    $extractIpCsvConfigured = Get-MigrationConfigValue -Config $Config -Path 'Paths.ExtractIpCsv' -Default ''
    if ($extractIpCsvConfigured) {
        $ExtractIpCsvFile = [string]$extractIpCsvConfigured
    } else {
        $batchFolder = Split-Path -Path $CsvFile -Parent
        $ExtractIpCsvFile = Join-Path -Path $batchFolder -ChildPath "extract-ip.csv"
    }
}

if (-not $LogFile) {
    $batchLabel = if ([string]::IsNullOrWhiteSpace($Tag)) { 'all' } else { $Tag }
    $LogFile = "$($Config.Paths.LogDir)\step4-startvm-$batchLabel-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

function Get-ExpectedIpMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rows = Import-Csv -Path $Path -Delimiter ";"
    $map = @{}

    foreach ($row in $rows) {
        $vmName = Get-FirstPropertyValue -InputObject $row -PropertyNames @(
            'VMName', 'VmName', 'Name', 'NomVM'
        )
        $ip = Get-FirstPropertyValue -InputObject $row -PropertyNames @(
            'ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'TargetIp', 'IP', 'IPAddress', 'IpAddress'
        )

        if ([string]::IsNullOrWhiteSpace($vmName) -or [string]::IsNullOrWhiteSpace($ip)) {
            continue
        }

        $map[$vmName.ToLowerInvariant()] = $ip
    }

    return $map
}

if (Test-Path -Path $ExtractIpCsvFile) {
    $expectedIpMap = Get-ExpectedIpMap -Path $ExtractIpCsvFile
} else {
    Write-MigrationLog "Extract IP CSV not found ($ExtractIpCsvFile) — skipping expected-IP validation." -Level WARNING -LogFile $LogFile
    $expectedIpMap = @{}
}

function Get-SCVMMVmInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$VMNames,

        [hashtable]$ExpectedIpMap = @{},

        [string]$ExpectedBackupTag,

        [switch]$ForceRefresh,

        [int]$BatchInventoryThreshold = 25
    )

    $names = @(
        $VMNames |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
    )

    if (-not $names) {
        return @()
    }

    return @(
        Invoke-SCVMMCommand -ScriptBlock {
            param($VmmServerName, $Names, $IpMap, $BackupTag, $ForceRefresh, $InventoryThreshold)

            # Property-guarded read: not every SCVMM version exposes the same VM
            # properties (VirtualMachineState, GuestAgentStatus...), and in local
            # (non-compat) mode this scriptblock runs under the caller's StrictMode.
            function Get-VmPropertyText {
                param($Vm, [string]$PropertyName, [string]$Context = 'SCVMM VM')
                if (-not $Vm) {
                    Write-Verbose "SCVMM debug: $Context is null while reading '$PropertyName'."
                    return ''
                }

                $property = $Vm.PSObject.Properties[$PropertyName]
                if ($property) { return [string]$property.Value }

                $availableProperties = @($Vm.PSObject.Properties.Name | Sort-Object) -join ', '
                Write-Verbose "SCVMM debug: property '$PropertyName' is missing on $Context ($($Vm.GetType().FullName)). Available properties: $availableProperties"
                return ''
            }

            function Get-IntegrationStatusSummary {
                param($Vm)

                $primarySignals = @(
                    (Get-VmPropertyText -Vm $Vm -PropertyName 'IntegrationServicesState'),
                    (Get-VmPropertyText -Vm $Vm -PropertyName 'GuestAgentStatus'),
                    (Get-VmPropertyText -Vm $Vm -PropertyName 'VMAddition')
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                $secondarySignals = @(
                    (Get-VmPropertyText -Vm $Vm -PropertyName 'HeartbeatStatus'),
                    (Get-VmPropertyText -Vm $Vm -PropertyName 'HeartbeatEnabled')
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                $summary = $null
                if ($primarySignals) {
                    $summary = ($primarySignals | Select-Object -Unique) -join ' | '
                } elseif ($secondarySignals) {
                    $summary = ($secondarySignals | Select-Object -Unique) -join ' | '
                }

                if ([string]::IsNullOrWhiteSpace($summary)) {
                    $summary = 'Not detected'
                }

                $ready = $false
                if ($summary -match 'OK|Operational|Up|Ready|Responding|\u0041ctif|\u0046onctionnel|Installed|Enabled|Version') {
                    $ready = $true
                }
                if ($summary -match 'Not.?Detected|Disabled|Stopped|Error|Unknown|Unavailable|N.?A|Unknown|Arr\u00eat\u00e9|Missing|Non d\u00e9tect\u00e9') {
                    $ready = $false
                }

                return [pscustomobject]@{
                    Ready   = [bool]$ready
                    Summary = [string]$summary
                }
            }

            $server = Get-SCVMMServer -ComputerName $VmmServerName
            $nameLookup = @{}
            foreach ($name in $Names) {
                $nameLookup[$name.ToLowerInvariant()] = $name
            }

            # Performance: use the cheaper strategy for the lot size. For small lots,
            # targeted lookups avoid enumerating every VM managed by SCVMM. For larger
            # lots, one full inventory pass avoids hundreds of per-VM SCVMM calls.
            $vmByName = @{}
            if ($InventoryThreshold -gt 0 -and $Names.Count -le $InventoryThreshold) {
                foreach ($name in $Names) {
                    $candidateVm = Get-SCVirtualMachine -Name $name -VMMServer $server | Select-Object -First 1
                    if ($candidateVm) {
                        $vmByName[$name.ToLowerInvariant()] = $candidateVm
                    }
                }
            } else {
                foreach ($candidateVm in @(Get-SCVirtualMachine -VMMServer $server)) {
                    $candidateName = [string]$candidateVm.Name
                    if ([string]::IsNullOrWhiteSpace($candidateName)) {
                        continue
                    }

                    $candidateKey = $candidateName.ToLowerInvariant()
                    if ($nameLookup.ContainsKey($candidateKey) -and -not $vmByName.ContainsKey($candidateKey)) {
                        $vmByName[$candidateKey] = $candidateVm
                    }
                }
            }

            foreach ($name in $Names) {
                $vm = $vmByName[$name.ToLowerInvariant()]

                if (-not $vm) {
                    [pscustomobject]@{
                        VMName                  = $name
                        Exists                  = $false
                        Running                 = $false
                        HypervConfiguredOs      = $null
                        Status                  = $null
                        StatusString            = $null
                        VMHostComputerName      = $null
                        IntegrationReady        = $false
                        IntegrationDetails      = 'VM not found'
                        NetworkConnected        = $false
                        CurrentIPs              = @()
                        IPMatches               = $false
                        HighAvailabilityEnabled = $false
                        CurrentTag              = $null
                        BackupTagPresent        = $false
                    }
                    continue
                }

                if ($ForceRefresh) {
                    try {
                        $refreshedVm = Read-SCVirtualMachine -VM $vm -Force -ErrorAction Stop
                        if ($refreshedVm) {
                            $vm = $refreshedVm
                        }
                    } catch {
                        # Keep the VM object from the batched inventory. Falling back to a
                        # per-VM Get-SCVirtualMachine here would reintroduce the slow path.
                        # No Write-MigrationLog here: this scriptblock may execute inside the
                        # WinPS compat session where neither the function nor $LogFile exist —
                        # calling it would turn a tolerated refresh failure into a hard error.
                        Write-Verbose "Read-SCVirtualMachine -Force failed for VM '$name', using cached object: $($_.Exception.Message)"
                    }
                }

                $statusRaw = @(
                    (Get-VmPropertyText -Vm $vm -PropertyName 'Status'),
                    (Get-VmPropertyText -Vm $vm -PropertyName 'StatusString'),
                    (Get-VmPropertyText -Vm $vm -PropertyName 'VirtualMachineState')
                ) -join ' '

                $running = $statusRaw -match 'Running|Power.*On|En cours d.?ex\u00e9cution|D\u00e9marr\u00e9'
                $integrationStatus = Get-IntegrationStatusSummary -Vm $vm

                $adapters = @(Get-SCVirtualNetworkAdapter -VM $vm -ErrorAction SilentlyContinue)
                $connectedAdapters = @($adapters | Where-Object {
                    $state = Get-VmPropertyText -Vm $_ -PropertyName 'ConnectionState' -Context "network adapter for '$name'"
                    $vmNetwork = Get-VmPropertyText -Vm $_ -PropertyName 'VMNetwork' -Context "network adapter for '$name'"
                    $vmSubnet = Get-VmPropertyText -Vm $_ -PropertyName 'VMSubnet' -Context "network adapter for '$name'"

                    $state -match 'Connected|Connect\u00e9|OK|On' -or
                    (-not [string]::IsNullOrWhiteSpace($vmNetwork)) -or
                    (-not [string]::IsNullOrWhiteSpace($vmSubnet))
                })
                $networkConnected = $connectedAdapters.Count -gt 0

                $allIps = @(
                    foreach ($adapter in $adapters) {
                        foreach ($address in @($adapter.IPv4Addresses)) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$address)) {
                                [string]$address
                            }
                        }
                    }
                ) | Select-Object -Unique

                $expectedIp = $null
                if ($IpMap -and $IpMap.ContainsKey($name.ToLowerInvariant())) {
                    $expectedIp = [string]$IpMap[$name.ToLowerInvariant()]
                }
                $ipMatches = if ([string]::IsNullOrWhiteSpace($expectedIp)) { $true } else { $allIps -contains $expectedIp }

                $highAvailabilityEnabled = [bool]$vm.IsHighlyAvailable

                $currentTag = [string]$vm.Tag
                $backupTagPresent = if ([string]::IsNullOrWhiteSpace($BackupTag)) {
                    $true
                } else {
                    [bool]($currentTag -split ';|,' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $BackupTag } | Measure-Object | Select-Object -ExpandProperty Count)
                }

                [pscustomobject]@{
                    VMName                  = $name
                    Exists                  = $true
                    Running                 = [bool]$running
                    HypervConfiguredOs      = [string]$vm.OperatingSystem
                    Status                  = [string]$vm.Status
                    StatusString            = [string]$vm.StatusString
                    VMHostComputerName      = [string]$vm.VMHost.ComputerName
                    IntegrationReady        = [bool]$integrationStatus.Ready
                    IntegrationDetails      = [string]$integrationStatus.Summary
                    NetworkConnected        = [bool]$networkConnected
                    CurrentIPs              = @($allIps)
                    IPMatches               = [bool]$ipMatches
                    HighAvailabilityEnabled = [bool]$highAvailabilityEnabled
                    CurrentTag              = $currentTag
                    BackupTagPresent        = [bool]$backupTagPresent
                }
            }
        } -ArgumentList @($ServerName, $names, $ExpectedIpMap, $ExpectedBackupTag, [bool]$ForceRefresh, $BatchInventoryThreshold)
    )
}

function Start-SCVMMVms {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$VMNames,

        [int]$BatchInventoryThreshold = 25
    )

    $names = @(
        $VMNames |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
    )

    if (-not $names) {
        return @()
    }

    Invoke-SCVMMCommand -ScriptBlock {
        param($VmmServerName, $Names, $InventoryThreshold)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $nameLookup = @{}
        foreach ($name in $Names) {
            $nameLookup[$name.ToLowerInvariant()] = $name
        }

        $vmByName = @{}
        if ($InventoryThreshold -gt 0 -and $Names.Count -le $InventoryThreshold) {
            foreach ($name in $Names) {
                $candidateVm = Get-SCVirtualMachine -Name $name -VMMServer $server | Select-Object -First 1
                if ($candidateVm) {
                    $vmByName[$name.ToLowerInvariant()] = $candidateVm
                }
            }
        } else {
            foreach ($candidateVm in @(Get-SCVirtualMachine -VMMServer $server)) {
                $candidateName = [string]$candidateVm.Name
                if ([string]::IsNullOrWhiteSpace($candidateName)) {
                    continue
                }

                $candidateKey = $candidateName.ToLowerInvariant()
                if ($nameLookup.ContainsKey($candidateKey) -and -not $vmByName.ContainsKey($candidateKey)) {
                    $vmByName[$candidateKey] = $candidateVm
                }
            }
        }

        foreach ($name in $Names) {
            $vm = $vmByName[$name.ToLowerInvariant()]
            if (-not $vm) {
                [pscustomobject]@{
                    VMName = $name
                    Started = $false
                    Error = "VM '$name' not found in SCVMM."
                }
                continue
            }

            try {
                Start-SCVirtualMachine -VM $vm -ErrorAction Stop | Out-Null
                [pscustomobject]@{
                    VMName = $name
                    Started = $true
                    Error = $null
                }
            } catch {
                [pscustomobject]@{
                    VMName = $name
                    Started = $false
                    Error = $_.Exception.Message
                }
            }
        }
    } -ArgumentList @($ServerName, $names, $BatchInventoryThreshold)
}

function Resolve-OsActionPlan {
    param(
        [string]$OperatingSystem
    )

    $generation = Get-OsGeneration -OperatingSystem $OperatingSystem

    if (-not $generation) {
        return [pscustomobject]@{
            OsGeneration = $null
            ActionPlan   = 'ManualUnknown'
        }
    }

    if ($generation -eq 2003 -or $generation -eq 2008) {
        return [pscustomobject]@{
            OsGeneration = $generation
            ActionPlan   = 'ManualLegacy'
        }
    }

    if ($generation -ge 2012 -and $generation -le 2025) {
        return [pscustomobject]@{
            OsGeneration = $generation
            ActionPlan   = 'WinRM'
        }
    }

    return [pscustomobject]@{
        OsGeneration = $generation
        ActionPlan   = 'ManualOther'
    }
}

# ---------------------------------------------------------------------------
# Test-VmCompliant : a VM is fully done once it's running, connected, has its
# expected IP, integration services are healthy, HA is on, and the
# post-migration backup tag is present — folds what used to be the separate
# post-migration-checks pass into this same loop.
# ---------------------------------------------------------------------------
function Test-VmCompliant {
    param(
        [bool]$Exists,
        [bool]$Running,
        [bool]$NetworkConnected,
        [bool]$IntegrationReady,
        [bool]$HighAvailabilityEnabled,
        [bool]$BackupTagPresent,
        [bool]$IPMatches
    )

    return [bool]($Exists -and $Running -and $NetworkConnected -and $IntegrationReady -and $HighAvailabilityEnabled -and $BackupTagPresent -and $IPMatches)
}

function Get-ComplianceIssues {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if (-not $VmItem.VmFound) {
        return @('VM not found')
    }

    $issues = @()
    if (-not $VmItem.Started) { $issues += 'not started' }
    if (-not $VmItem.NetworkConnected) { $issues += 'NIC not connected' }
    if (-not $VmItem.IPMatches) { $issues += 'unexpected IP' }
    if (-not $VmItem.IntegrationReady) { $issues += 'Integration Services not OK' }
    if (-not $VmItem.HighAvailabilityEnabled) { $issues += 'HA not enabled' }
    if (-not $VmItem.BackupTagPresent) { $issues += 'backup tag missing' }

    return $issues
}

function Get-ActionDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if (-not $VmItem.VmFound) {
        return 'VM not found in SCVMM'
    }

    if (-not [string]::IsNullOrWhiteSpace($VmItem.StartError) -and -not $VmItem.Started) {
        return "SCVMM start failed: check manually"
    }

    switch ($VmItem.ActionPlan) {
        'ManualUnknown' { return 'Unknown OS: manual action required' }
        'ManualLegacy'  { return "OS $($VmItem.OsGeneration) : manual action required" }
        'ManualOther'   { return "OS $($VmItem.OsGeneration) : manual action required" }
        'WinRM' {
            switch ($VmItem.ActionState) {
                'Queued'        { return "OS $($VmItem.OsGeneration) : WinRM pending" }
                'Running'       { return "OS $($VmItem.OsGeneration) : WinRM running" }
                'Success-HTTPS' { return "OS $($VmItem.OsGeneration) : WinRM HTTPS OK" }
                'Success-HTTP'  { return "OS $($VmItem.OsGeneration) : WinRM HTTP OK" }
                'Failed'        { return "OS $($VmItem.OsGeneration) : WinRM failed, manual action required" }
                'Skipped'       { return "OS $($VmItem.OsGeneration) : WinRM not started, manual action required" }
                default         { return "OS $($VmItem.OsGeneration) : WinRM pending" }
            }
        }
        default { return 'To be determined' }
    }
}

function Get-PowerStateDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if (-not $VmItem.VmFound) {
        return 'VM not found'
    }

    if ($VmItem.Started) {
        return 'Powered on'
    }

    return 'Powered off'
}

function Start-WinRmRemediationJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$LocalScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$RemoteScriptPath,

        [PSCredential]$Credential,

        [string]$TargetLogFile,

        [int]$MaxAttempts = 20,

        [int]$RetryDelaySeconds = 15
    )

    # Each job writes to its own log file: multiple ThreadJobs sharing
    # the same file cause Add-Content collisions ("file in use") and
    # lost lines. The per-VM log is derived from the main log (suffix -<VM>).
    $jobLogFile = $TargetLogFile
    if (-not [string]::IsNullOrWhiteSpace($TargetLogFile)) {
        $safeVmName = ($VMName -replace '[\\/:*?"<>|\s]', '_')
        $jobLogFile = ($TargetLogFile -replace '\.log$', '') + "-$safeVmName.log"
    }

    # Start-ThreadJob is used instead of Start-Job to avoid PSUseUsingScopeModifierInNewRunspaces warnings.
    # ThreadJob is available in PS 7+ and provides better performance for parallel workloads.
    return Start-ThreadJob -Name "startvm-$VMName" -ArgumentList @(
        $VMName,
        $LocalScriptPath,
        $RemoteScriptPath,
        $Credential,
        $jobLogFile,
        $MaxAttempts,
        $RetryDelaySeconds
    ) -ScriptBlock {
        param(
            [string]$ComputerName,
            [string]$JobLocalScriptPath,
            [string]$JobRemoteScriptPath,
            [PSCredential]$JobCredential,
            [string]$JobLogFile,
            [int]$JobMaxAttempts,
            [int]$JobRetryDelaySeconds
        )

        function Write-JobLog {
            param(
                [string]$Message,
                [string]$Level = 'INFO',
                [string]$LogFile
            )

            if ([string]::IsNullOrWhiteSpace($LogFile)) {
                return
            }

            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Add-Content -Path $LogFile -Value "[$timestamp] [$Level] [$ComputerName] $Message"
        }

        function Get-WinRmSession {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ComputerName,

                [PSCredential]$Credential
            )

            $sessionParams = @{
                ComputerName = $ComputerName
                ErrorAction  = 'Stop'
            }

            if ($Credential) {
                $sessionParams.Credential = $Credential
            }

            try {
                Test-WSMan -ComputerName $ComputerName -UseSSL -ErrorAction Stop | Out-Null
                $httpsSessionParams = $sessionParams.Clone()
                $httpsSessionParams.UseSSL = $true
                return [pscustomobject]@{
                    Protocol = 'HTTPS'
                    Session  = New-PSSession @httpsSessionParams
                }
            } catch {
                Write-JobLog -Message "WinRM HTTPS unavailable: $($_.Exception.Message)" -Level 'WARNING' -LogFile $JobLogFile
            }

            try {
                Test-WSMan -ComputerName $ComputerName -ErrorAction Stop | Out-Null
                return [pscustomobject]@{
                    Protocol = 'HTTP'
                    Session  = New-PSSession @sessionParams
                }
            } catch {
                Write-JobLog -Message "WinRM HTTP unavailable: $($_.Exception.Message)" -Level 'WARNING' -LogFile $JobLogFile
            }

            return $null
        }

        function Invoke-RemoteVmwareToolsRemoval {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ComputerName,

                [Parameter(Mandatory = $true)]
                [string]$LocalScriptPath,

                [Parameter(Mandatory = $true)]
                [string]$RemoteScriptPath,

                [PSCredential]$Credential
            )

            if (-not (Test-Path -Path $LocalScriptPath)) {
                Write-JobLog -Message "Remote script not found: $LocalScriptPath" -Level 'WARNING' -LogFile $JobLogFile
                return 'ScriptAbsent'
            }

            $winRmConnection = Get-WinRmSession -ComputerName $ComputerName -Credential $Credential
            if (-not $winRmConnection) {
                return 'WinRMUnavailable'
            }

            $session = $winRmConnection.Session
            $protocol = $winRmConnection.Protocol

            try {
                $remoteFolder = Split-Path -Path $RemoteScriptPath -Parent

                Invoke-Command -Session $session -ScriptBlock {
                    param($Path)
                    if (-not (Test-Path -Path $Path)) {
                        New-Item -Path $Path -ItemType Directory -Force | Out-Null
                    }
                } -ArgumentList @($remoteFolder) -ErrorAction Stop

                Copy-Item -Path $LocalScriptPath -Destination $RemoteScriptPath -ToSession $session -Force -ErrorAction Stop

                # The remote script is a .bat file: powershell.exe -File only accepts .ps1 files.
                # Batch exit codes: 0 = success, 1 = error, 2 = partial VMware cleanup.
                $remoteExitCode = Invoke-Command -Session $session -ScriptBlock {
                    param($ScriptPath)
                    & cmd.exe /c "`"$ScriptPath`"" | Out-Null
                    $LASTEXITCODE
                } -ArgumentList @($RemoteScriptPath) -ErrorAction Stop

                if ($remoteExitCode -eq 1) {
                    Write-JobLog -Message "Integration Services script finished with an error (exit code 1) via WinRM $protocol." -Level 'WARNING' -LogFile $JobLogFile
                    return "ExecutionFailed-$protocol"
                }

                if ($remoteExitCode -eq 2) {
                    Write-JobLog -Message "Integration Services script finished with partial VMware cleanup (exit code 2) via WinRM $protocol." -Level 'WARNING' -LogFile $JobLogFile
                }

                Write-JobLog -Message "Integration Services script executed via WinRM $protocol (exit code $remoteExitCode)." -Level 'SUCCESS' -LogFile $JobLogFile
                return "Success-$protocol"
            } catch {
                Write-JobLog -Message "Failure over WinRM ${protocol}: $($_.Exception.Message)" -Level 'WARNING' -LogFile $JobLogFile
                return "ExecutionFailed-$protocol"
            } finally {
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
            }
        }

        $lastStatus = 'WinRMUnavailable'

        for ($attempt = 1; $attempt -le $JobMaxAttempts; $attempt++) {
            Write-JobLog -Message "Tentative WinRM $attempt/$JobMaxAttempts." -LogFile $JobLogFile
            $lastStatus = Invoke-RemoteVmwareToolsRemoval -ComputerName $ComputerName -LocalScriptPath $JobLocalScriptPath -RemoteScriptPath $JobRemoteScriptPath -Credential $JobCredential

            if ($lastStatus -like 'Success-*') {
                return [pscustomobject]@{
                    VMName       = $ComputerName
                    FinalStatus  = $lastStatus
                    Attempts     = $attempt
                }
            }

            if ($lastStatus -eq 'ScriptAbsent') {
                break
            }

            if ($attempt -lt $JobMaxAttempts) {
                Start-Sleep -Seconds $JobRetryDelaySeconds
            }
        }

        return [pscustomobject]@{
            VMName      = $ComputerName
            FinalStatus = $lastStatus
            Attempts    = $JobMaxAttempts
        }
    }
}

function Update-WinRmActionState {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if ($VmItem.ActionPlan -ne 'WinRM' -or -not $VmItem.ActionJobId) {
        return
    }

    $job = Get-Job -Id $VmItem.ActionJobId -ErrorAction SilentlyContinue
    if (-not $job) {
        if ($VmItem.ActionState -in @('Queued', 'Running')) {
            $VmItem.ActionState = 'Failed'
        }
        $VmItem.ActionJobId = $null
        return
    }

    switch ($job.State) {
        'NotStarted' {
            $VmItem.ActionState = 'Queued'
        }
        'Running' {
            $VmItem.ActionState = 'Running'
        }
        'Completed' {
            $result = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue | Select-Object -Last 1
            $finalStatus = if ($result -and $result.PSObject.Properties['FinalStatus']) {
                [string]$result.FinalStatus
            } else {
                'Unknown'
            }

            switch -Wildcard ($finalStatus) {
                'Success-HTTPS' { $VmItem.ActionState = 'Success-HTTPS' }
                'Success-HTTP'  { $VmItem.ActionState = 'Success-HTTP' }
                default         { $VmItem.ActionState = 'Failed' }
            }

            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $VmItem.ActionJobId = $null
        }
        'Failed' {
            $VmItem.ActionState = 'Failed'
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $VmItem.ActionJobId = $null
        }
        'Stopped' {
            $VmItem.ActionState = 'Failed'
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $VmItem.ActionJobId = $null
        }
        default {
            $VmItem.ActionState = 'Queued'
        }
    }
}


function Limit-DashboardText {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [int]$MaxLength
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($MaxLength -le 0 -or $text.Length -le $MaxLength) {
        return $text
    }

    if ($MaxLength -eq 1) {
        return '…'
    }

    return ($text.Substring(0, $MaxLength - 1) + '…')
}

function Show-PendingDashboard {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Inventory,

        [int]$Iteration,

        [int]$MaxIterations
    )

    $pendingRows = @(
        $Inventory |
            Where-Object { -not $_.DisplayCompleted } |
            Sort-Object VMName |
            ForEach-Object {
                [pscustomobject]@{
                    'VM name'        = Limit-DashboardText -Value $_.VMName -MaxLength 26
                    'Power state'    = Limit-DashboardText -Value (Get-PowerStateDisplayText -VmItem $_) -MaxLength 12
                    'OS'             = Limit-DashboardText -Value $(if ([string]::IsNullOrWhiteSpace($_.DisplayOperatingSystem)) { 'Unknown' } else { $_.DisplayOperatingSystem }) -MaxLength 32
                    'Non-compliance' = Limit-DashboardText -Value ((Get-ComplianceIssues -VmItem $_) -join ', ') -MaxLength 34
                    'Actions to take' = Limit-DashboardText -Value (Get-ActionDisplayText -VmItem $_) -MaxLength 48
                }
            }
    )

    if ($Host.Name -notin @('ServerRemoteHost')) {
        try { Clear-Host } catch { Write-Verbose "Clear-Host is not supported by the current host: $($_.Exception.Message)" }
    }

    $iterationLabel = if ($MaxIterations -le 0) { "$Iteration (unlimited, Ctrl+C to stop)" } else { "$Iteration/$MaxIterations" }
    Write-Information "Batch tracking - refresh $iterationLabel - items remaining: $($pendingRows.Count)" -InformationAction Continue
    Write-Information "" -InformationAction Continue

    if ($pendingRows) {
        $pendingRows |
            Format-Table -Property @(
                @{ Label = 'VM name'; Expression = { $_.'VM name' }; Width = 26 },
                @{ Label = 'Power state'; Expression = { $_.'Power state' }; Width = 12 },
                @{ Label = 'OS'; Expression = { $_.OS }; Width = 32 },
                @{ Label = 'Non-compliance'; Expression = { $_.'Non-compliance' }; Width = 34 },
                @{ Label = 'Actions to take'; Expression = { $_.'Actions to take' }; Width = 48 }
            ) |
            Out-String -Width 180 |
            ForEach-Object { Write-Information $_ -InformationAction Continue }
    } else {
        Write-Information "All VMs are compliant (started, network, IP, Integration Services, HA, backup tag)." -InformationAction Continue
    }
}

$rows = Import-Csv -Path $CsvFile -Delimiter ';'
$targetRows = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })

# Same batch-filtering rule as step2/step3/step5: trim the CSV tag before comparing,
# and keep the previous behavior (all rows) for CSVs without a populated Tag column.
if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $rowsWithTag = @($targetRows | Where-Object { $_.PSObject.Properties['Tag'] -and -not [string]::IsNullOrWhiteSpace($_.Tag) })
    if ($rowsWithTag) {
        $targetRows = @($rowsWithTag | Where-Object { $_.Tag.Trim() -eq $Tag })
    }
}

if (-not $targetRows) {
    $target = if ([string]::IsNullOrWhiteSpace($Tag)) { 'all rows' } else { "tag '$Tag'" }
    Write-MigrationLog "No VM found in the CSV for $target." -Level ERROR -LogFile $LogFile
    exit 1
}

# Get-MigrationConfigValue everywhere below: StartVm/RemoteActions are optional
# sections and a bare dot access on a missing key throws under StrictMode.
$pollIntervalFromConfig = Get-MigrationConfigValue -Config $Config -Path 'StartVm.IntegrationPollIntervalSeconds'
if ($pollIntervalFromConfig -and [int]$pollIntervalFromConfig -gt 0) {
    $IntegrationPollIntervalSeconds = [int]$pollIntervalFromConfig
}

$maxIterationsFromConfig = Get-MigrationConfigValue -Config $Config -Path 'StartVm.IntegrationMaxIterations'
if ($maxIterationsFromConfig -and [int]$maxIterationsFromConfig -gt 0) {
    $IntegrationMaxIterations = [int]$maxIterationsFromConfig
}

$inventoryBatchThreshold = 25
$inventoryBatchThresholdFromConfig = Get-MigrationConfigValue -Config $Config -Path 'StartVm.InventoryBatchThreshold'
if ($inventoryBatchThresholdFromConfig -and [int]$inventoryBatchThresholdFromConfig -gt 0) {
    $inventoryBatchThreshold = [int]$inventoryBatchThresholdFromConfig
}

$winRmCredential = Get-MigrationConfigValue -Config $Config -Path 'RemoteActions.WinRm.Credential'

$localWinRmScriptPath = [string](Get-MigrationConfigValue -Config $Config -Path 'RemoteActions.WinRm.RemoveVmwareToolsScriptLocalPath' -Default '')
$remoteWinRmScriptPath = [string](Get-MigrationConfigValue -Config $Config -Path 'RemoteActions.WinRm.RemoveVmwareToolsScriptRemotePath' -Default '')
$expectedBackupTag = [string](Get-MigrationConfigValue -Config $Config -Path 'Tags.BackupTag' -Default '')

$initialSnapshots = Get-SCVMMVmInventory -ServerName $Config.SCVMM.Server -VMNames ($targetRows.VMName) -ExpectedIpMap $expectedIpMap -ExpectedBackupTag $expectedBackupTag -ForceRefresh -BatchInventoryThreshold $inventoryBatchThreshold
$initialSnapshotByName = @{}
foreach ($snapshot in $initialSnapshots) {
    $initialSnapshotByName[[string]$snapshot.VMName] = $snapshot
}

# @(): with a single CSV row the foreach result is a scalar and the later
# $vmInventory.Count would throw under StrictMode.
$vmInventory = @(foreach ($row in $targetRows) {
    $vmName = [string]$row.VMName
    $sourceOs = Get-FirstPropertyValue -InputObject $row -PropertyNames @('OperatingSystem', 'Operating system')
    $snapshot = $initialSnapshotByName[$vmName]

    $displayOperatingSystem = if ($snapshot -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.HypervConfiguredOs)) {
        [string]$snapshot.HypervConfiguredOs
    } else {
        $sourceOs
    }

    $actionPlan = Resolve-OsActionPlan -OperatingSystem $displayOperatingSystem

    if (-not $snapshot) {
        $snapshot = [pscustomobject]@{
            VMName                  = $vmName
            Exists                  = $false
            Running                 = $false
            HypervConfiguredOs      = $null
            IntegrationReady        = $false
            IntegrationDetails      = 'VM not found'
            NetworkConnected        = $false
            CurrentIPs              = @()
            IPMatches               = $false
            HighAvailabilityEnabled = $false
            CurrentTag              = $null
            BackupTagPresent        = $false
        }
    }

    [pscustomobject]@{
        VMName                  = $vmName
        SourceOperatingSystem   = $sourceOs
        DisplayOperatingSystem  = $displayOperatingSystem
        OsGeneration            = $actionPlan.OsGeneration
        ActionPlan              = $actionPlan.ActionPlan
        ActionState             = if ($snapshot.Exists) { 'Queued' } else { 'Skipped' }
        ActionJobId             = $null
        VmFound                 = [bool]$snapshot.Exists
        Started                 = [bool]$snapshot.Running
        StartError              = $null
        IntegrationReady        = [bool]$snapshot.IntegrationReady
        IntegrationDetails      = if ($snapshot.Exists) { [string]$snapshot.IntegrationDetails } else { 'VM not found' }
        NetworkConnected        = [bool]$snapshot.NetworkConnected
        CurrentIPs              = @($snapshot.CurrentIPs)
        IPMatches               = [bool]$snapshot.IPMatches
        HighAvailabilityEnabled = [bool]$snapshot.HighAvailabilityEnabled
        CurrentTag              = $snapshot.CurrentTag
        BackupTagPresent        = [bool]$snapshot.BackupTagPresent
        DisplayCompleted        = Test-VmCompliant -Exists $snapshot.Exists -Running $snapshot.Running -NetworkConnected $snapshot.NetworkConnected -IntegrationReady $snapshot.IntegrationReady -HighAvailabilityEnabled $snapshot.HighAvailabilityEnabled -BackupTagPresent $snapshot.BackupTagPresent -IPMatches $snapshot.IPMatches
    }
})

Write-MigrationLog "Batch loaded: $($vmInventory.Count) VM(s)." -LogFile $LogFile

$vmsToStart = @($vmInventory | Where-Object { $_.VmFound -and -not $_.Started })
if ($vmsToStart) {
    $startResults = @(Start-SCVMMVms -ServerName $Config.SCVMM.Server -VMNames ($vmsToStart.VMName) -BatchInventoryThreshold $inventoryBatchThreshold)
    $startResultByName = @{}
    foreach ($startResult in $startResults) {
        $startResultByName[[string]$startResult.VMName] = $startResult
    }

    foreach ($vmItem in $vmsToStart) {
        $startResult = $startResultByName[$vmItem.VMName]
        if ($startResult -and $startResult.Started) {
            $vmItem.Started = $true
            Write-MigrationLog "[$($vmItem.VMName)] Start requested in SCVMM." -Level SUCCESS -LogFile $LogFile
        } else {
            $vmItem.StartError = if ($startResult) { [string]$startResult.Error } else { 'Missing SCVMM start result.' }
            $vmItem.Started = $false
            Write-MigrationLog "[$($vmItem.VMName)] SCVMM start failed: $($vmItem.StartError)" -Level WARNING -LogFile $LogFile
        }
    }
}

$winRmScriptAvailable = -not [string]::IsNullOrWhiteSpace($localWinRmScriptPath) -and (Test-Path -Path $localWinRmScriptPath)
if (-not $winRmScriptAvailable) {
    Write-MigrationLog "WinRM script not found or not configured: $localWinRmScriptPath" -Level WARNING -LogFile $LogFile
}

foreach ($vmItem in @($vmInventory | Where-Object { $_.VmFound -and -not $_.DisplayCompleted })) {
    switch ($vmItem.ActionPlan) {
        'ManualUnknown' {
            $vmItem.ActionState = 'Skipped'
        }
        'ManualLegacy' {
            $vmItem.ActionState = 'Skipped'
        }
        'ManualOther' {
            $vmItem.ActionState = 'Skipped'
        }
        'WinRM' {
            if (-not $winRmScriptAvailable) {
                $vmItem.ActionState = 'Failed'
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($vmItem.StartError) -and -not $vmItem.Started) {
                $vmItem.ActionState = 'Skipped'
                continue
            }

            $job = Start-WinRmRemediationJob -VMName $vmItem.VMName -LocalScriptPath $localWinRmScriptPath -RemoteScriptPath $remoteWinRmScriptPath -Credential $winRmCredential -TargetLogFile $LogFile -MaxAttempts $WinRmMaxAttempts -RetryDelaySeconds $WinRmRetryDelaySeconds
            $vmItem.ActionJobId = $job.Id
            $vmItem.ActionState = 'Queued'
            Write-MigrationLog "[$($vmItem.VMName)] WinRM job started." -LogFile $LogFile
        }
    }
}

$iteration = 0
$refreshNeeded = $true

# IntegrationMaxIterations = 0 means unlimited: keep polling until every VM is
# compliant, or the operator interrupts with Ctrl+C.
while ($refreshNeeded -and ($IntegrationMaxIterations -le 0 -or $iteration -lt $IntegrationMaxIterations)) {
    $iteration++

    foreach ($vmItem in @($vmInventory | Where-Object { $_.ActionPlan -eq 'WinRM' })) {
        Update-WinRmActionState -VmItem $vmItem
    }

    $namesToRefresh = @(
        $vmInventory |
            Where-Object { $_.VmFound -and -not $_.DisplayCompleted } |
            Select-Object -ExpandProperty VMName
    )

    if ($namesToRefresh) {
        $refreshedSnapshots = Get-SCVMMVmInventory -ServerName $Config.SCVMM.Server -VMNames $namesToRefresh -ExpectedIpMap $expectedIpMap -ExpectedBackupTag $expectedBackupTag -BatchInventoryThreshold $inventoryBatchThreshold
        $snapshotByName = @{}
        foreach ($snapshot in $refreshedSnapshots) {
            $snapshotByName[[string]$snapshot.VMName] = $snapshot
        }

        foreach ($vmItem in @($vmInventory | Where-Object { $_.VmFound -and -not $_.DisplayCompleted })) {
            $snapshot = $snapshotByName[$vmItem.VMName]
            if (-not $snapshot) {
                continue
            }

            $vmItem.Started = [bool]$snapshot.Running
            if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.HypervConfiguredOs)) {
                $vmItem.DisplayOperatingSystem = [string]$snapshot.HypervConfiguredOs

                if ($vmItem.ActionPlan -like 'Manual*' -or -not $vmItem.OsGeneration) {
                    $previousActionPlan = $vmItem.ActionPlan
                    $resolvedActionPlan = Resolve-OsActionPlan -OperatingSystem $vmItem.DisplayOperatingSystem
                    $vmItem.OsGeneration = $resolvedActionPlan.OsGeneration
                    $vmItem.ActionPlan = $resolvedActionPlan.ActionPlan

                    if ($previousActionPlan -ne 'WinRM' -and $vmItem.ActionPlan -eq 'WinRM' -and -not $vmItem.DisplayCompleted) {
                        $vmItem.ActionState = 'Queued'
                    }
                }
            }

            $vmItem.IntegrationReady = [bool]$snapshot.IntegrationReady
            $vmItem.IntegrationDetails = [string]$snapshot.IntegrationDetails
            $vmItem.NetworkConnected = [bool]$snapshot.NetworkConnected
            $vmItem.CurrentIPs = @($snapshot.CurrentIPs)
            $vmItem.IPMatches = [bool]$snapshot.IPMatches
            $vmItem.HighAvailabilityEnabled = [bool]$snapshot.HighAvailabilityEnabled
            $vmItem.CurrentTag = $snapshot.CurrentTag
            $vmItem.BackupTagPresent = [bool]$snapshot.BackupTagPresent

            if (Test-VmCompliant -Exists $vmItem.VmFound -Running $vmItem.Started -NetworkConnected $vmItem.NetworkConnected -IntegrationReady $vmItem.IntegrationReady -HighAvailabilityEnabled $vmItem.HighAvailabilityEnabled -BackupTagPresent $vmItem.BackupTagPresent -IPMatches $vmItem.IPMatches) {
                $vmItem.DisplayCompleted = $true
                Write-MigrationLog "[$($vmItem.VMName)] Compliant (started, network, IP, Integration Services, HA, backup tag)." -Level SUCCESS -LogFile $LogFile
            }

            if (
                $vmItem.ActionPlan -eq 'WinRM' -and
                -not $vmItem.DisplayCompleted -and
                -not $vmItem.ActionJobId -and
                $vmItem.ActionState -eq 'Queued' -and
                $winRmScriptAvailable
            ) {
                $job = Start-WinRmRemediationJob -VMName $vmItem.VMName -LocalScriptPath $localWinRmScriptPath -RemoteScriptPath $remoteWinRmScriptPath -Credential $winRmCredential -TargetLogFile $LogFile -MaxAttempts $WinRmMaxAttempts -RetryDelaySeconds $WinRmRetryDelaySeconds
                $vmItem.ActionJobId = $job.Id
                $vmItem.ActionState = 'Queued'
                Write-MigrationLog "[$($vmItem.VMName)] WinRM job restarted." -LogFile $LogFile
            }
        }
    }

    Show-PendingDashboard -Inventory $vmInventory -Iteration $iteration -MaxIterations $IntegrationMaxIterations

    $remainingItems = @($vmInventory | Where-Object { -not $_.DisplayCompleted })
    $refreshNeeded = $remainingItems.Count -gt 0

    if ($refreshNeeded -and ($IntegrationMaxIterations -le 0 -or $iteration -lt $IntegrationMaxIterations)) {
        Start-Sleep -Seconds $IntegrationPollIntervalSeconds
    }
}

foreach ($vmItem in @($vmInventory | Where-Object { $_.ActionPlan -eq 'WinRM' })) {
    Update-WinRmActionState -VmItem $vmItem
}

$remainingAfterLoop = @($vmInventory | Where-Object { -not $_.DisplayCompleted })
if ($remainingAfterLoop) {
    Write-MigrationLog "$($remainingAfterLoop.Count) VM(s) non-compliant after $iteration iteration(s) (IntegrationMaxIterations reached)." -Level WARNING -LogFile $LogFile
    foreach ($vmItem in $remainingAfterLoop) {
        $issues = (Get-ComplianceIssues -VmItem $vmItem) -join '; '
        Write-MigrationLog "[$($vmItem.VMName)] $issues" -Level WARNING -LogFile $LogFile
    }
} else {
    Write-MigrationLog "All VMs are compliant after $iteration iteration(s)." -Level SUCCESS -LogFile $LogFile
}

$results = foreach ($vmItem in $vmInventory) {
    [pscustomobject]@{
        VMName                    = $vmItem.VMName
        PowerState                = Get-PowerStateDisplayText -VmItem $vmItem
        OperatingSystem           = $vmItem.DisplayOperatingSystem
        OsGeneration              = $vmItem.OsGeneration
        VmFound                   = $vmItem.VmFound
        Started                   = $vmItem.Started
        NetworkConnected          = $vmItem.NetworkConnected
        CurrentIPs                = ($vmItem.CurrentIPs -join ',')
        IPMatches                 = $vmItem.IPMatches
        IntegrationReady          = $vmItem.IntegrationReady
        IntegrationServicesStatus = $vmItem.IntegrationDetails
        HighAvailabilityEnabled   = $vmItem.HighAvailabilityEnabled
        BackupTagPresent          = $vmItem.BackupTagPresent
        Compliant                 = $vmItem.DisplayCompleted
        ActionPlan                = $vmItem.ActionPlan
        ActionState               = $vmItem.ActionState
        ActionToTake              = Get-ActionDisplayText -VmItem $vmItem
        StartError                = $vmItem.StartError
    }
}

Write-Information "" -InformationAction Continue
$results |
    Select-Object VMName, PowerState, OperatingSystem, Compliant, IntegrationServicesStatus, ActionToTake |
    Format-Table -AutoSize |
    Out-String -Width 4096 |
    ForEach-Object { Write-Information $_ -InformationAction Continue }

$summaryPath = Join-Path -Path $Config.Paths.LogDir -ChildPath "step4-startvm-summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $summaryPath -Delimiter ';' -NoTypeInformation
Write-MigrationLog "Summary exported: $summaryPath" -Level SUCCESS -LogFile $LogFile
Write-MigrationLog "step4-startvm completed." -Level SUCCESS -LogFile $LogFile

if ($remainingAfterLoop -and $IntegrationMaxIterations -gt 0) {
    exit 2
}
