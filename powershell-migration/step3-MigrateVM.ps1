<#
.SYNOPSIS
    Execute Instant Recovery, network configuration, and post-migration setup for a single VM.

.DESCRIPTION
    The core step3 migration script invoked per-VM (directly or via worker-step3.ps1).
    Starts the Veeam Instant Recovery mount, finalizes it (commit), configures the
    Hyper-V VM networking (VLAN, IP), applies OS-level post-migration changes, and
    cleans up the Veeam mount session.

.PARAMETER BackupJobName
    Name of the Veeam backup job. Mandatory.

.PARAMETER VMName
    Target VM name. Mandatory.

.PARAMETER VlanId
    VLAN ID for the restored VM. Mandatory.

.PARAMETER AdapterVlanMapJson
    JSON object mapping adapter names to VLAN IDs for multi-NIC VMs.

.PARAMETER OperatingSystem
    Guest OS identifier (e.g. Windows, Linux) for OS-specific configuration.

.PARAMETER Remark
    Additional notes from the CSV for operational context.

.PARAMETER SCVMMServer
    SCVMM server name. Defaults to Config.SCVMM.Server.

.PARAMETER HyperVHost
    Primary Hyper-V host. Auto-resolved from migration target if not provided.

.PARAMETER HyperVHost2
    Secondary Hyper-V host for host affinity configuration.

.PARAMETER HyperVCluster
    Hyper-V cluster name. Auto-resolved from migration target if not provided.

.PARAMETER ClusterStorage
    Cluster shared volume path. Auto-resolved from migration target if not provided.

.PARAMETER VmwareCluster
    Source VMware cluster name for migration target resolution.

.PARAMETER BackupTag
    Veeam backup tag for restore point selection. Defaults to Config.Tags.BackupTag.

.PARAMETER WaitingTimeoutSeconds
    Maximum wait time for mount operations. Default: 1800.

.PARAMETER WaitingPollIntervalSeconds
    Poll interval for mount operations. Default: 15.

.PARAMETER ForceNetworkConfigOnly
    Skip Instant Recovery and run only network/OS post-configuration.

.PARAMETER SkipInstantRecoveryStart
    Skip starting the Instant Recovery mount.

.PARAMETER SkipInstantRecoveryFinalization
    Skip finalizing (committing) the Instant Recovery mount.

.PARAMETER SkipNetworkAndPostConfig
    Skip network configuration and OS post-migration steps.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step3-MigrateVM.ps1 -BackupJobName Backup-HypMig-lot-118 -VMName SRV-WEB01 -VlanId 100 -HyperVHost hv01 -ClusterStorage C:\ClusterStorage\Volume1

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with Veeam.Backup.PowerShell and VirtualMachineManager modules.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$BackupJobName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$VlanId,
    [string]$AdapterVlanMapJson,

    [string]$OperatingSystem,
    [string]$Remark,
    [string]$SCVMMServer,
    [string]$HyperVHost,
    [string]$HyperVHost2,
    [string]$HyperVCluster,
    [string]$ClusterStorage,
    [string]$VmwareCluster,
    [string]$BackupTag,
    [int]$WaitingTimeoutSeconds = 1800,
    [int]$WaitingPollIntervalSeconds = 15,
    [switch]$ForceNetworkConfigOnly,
    [switch]$SkipInstantRecoveryStart,
    [switch]$SkipInstantRecoveryFinalization,
    [switch]$SkipNetworkAndPostConfig,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"

$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $SCVMMServer)   { $SCVMMServer   = $Config.SCVMM.Server }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step3-migrate-$VMName-$(Get-Date -Format 'yyyyMMdd').log" }

$resolvedMigrationTarget = Resolve-MigrationTarget -Config $Config -VmwareClusterName $VmwareCluster -LogFile $LogFile
if (-not $HyperVHost)    { $HyperVHost    = $resolvedMigrationTarget.HyperVHost }
if (-not $HyperVHost2)   { $HyperVHost2   = $resolvedMigrationTarget.HyperVHost2 }
if (-not $HyperVCluster) { $HyperVCluster = $resolvedMigrationTarget.HyperVCluster }
if (-not $ClusterStorage){ $ClusterStorage = $resolvedMigrationTarget.ClusterStorage }
if (-not $BackupTag)     { $BackupTag     = $Config.Tags.BackupTag }

if ($ForceNetworkConfigOnly) {
    $SkipInstantRecoveryStart = $true
    $SkipInstantRecoveryFinalization = $true
}

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback
if (-not $SkipInstantRecoveryStart -or -not $SkipInstantRecoveryFinalization) {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
} else {
    Write-MigrationLog "[$VMName] Instant Recovery start/finalization disabled: skipping Veeam module import." -LogFile $LogFile
}

function Start-SCVMMHostMigration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$DestinationHost
    )

    if (-not $PSCmdlet.ShouldProcess($Name, "Start host migration to $DestinationHost via SCVMM")) {
        return
    }

    Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName, $TargetHostName)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while starting migration."
        }

        $targetHost = Get-SCVMHost -VMMServer $server |
            Where-Object { $_.ComputerName -eq $TargetHostName -or $_.Name -eq $TargetHostName } |
            Select-Object -First 1
        if (-not $targetHost) {
            throw "Destination host '$TargetHostName' not found in SCVMM."
        }

        Move-SCVirtualMachine -VM $vm -VMHost $targetHost -UseLAN -RunAsynchronously | Out-Null
    } -ArgumentList @($Name, $ServerName, $DestinationHost)
}

function Get-SCVMMVmRuntimeState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        # Refresh the VM in SCVMM and read its state within the same server round-trip.
        # The polling loops used to pay two separate SCVMM connections per iteration
        # (Update-SCVMMVirtualMachine then Get-SCVMMVmRuntimeState).
        [switch]$Refresh
    )

    return Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName, $DoRefresh)
        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            return $null
        }

        if ($DoRefresh) {
            $refreshCommand = Get-Command -Name 'Read-SCVirtualMachine' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($refreshCommand) {
                $refreshedVm = & $refreshCommand -VM $vm | Select-Object -First 1
                if ($refreshedVm) {
                    $vm = $refreshedVm
                }
            }
        }

        $hostNameCandidates = @(
            [string]$vm.HostName,
            [string]$vm.VMHostName,
            [string]$vm.VMHost.ComputerName,
            [string]$vm.VMHost.Name,
            [string]$vm.HostComputerName,
            [string]$vm.Host
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        [pscustomobject]@{
            Name             = [string]$vm.Name
            IsHighlyAvailable = [bool]$vm.IsHighlyAvailable
            HostName         = $hostNameCandidates | Select-Object -First 1
            Status           = [string]$vm.Status
            StatusString     = [string]$vm.StatusString
        }
    } -ArgumentList @($Name, $ServerName, [bool]$Refresh)
}

function ConvertTo-NormalizedHostName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return $Name.Trim().ToLowerInvariant().Split('.')[0]
}

function Invoke-SCVMMNetworkAndPostConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$Vlan,
        $AdapterVlanMappings,

        [string]$SourceOperatingSystem,
        [string]$SourceRemark,
        $Config,
        [string]$BackupTagName,
        [string]$ClusterName,
        [string]$DestinationHost,
        [string]$LogFile
    )

    Write-MigrationLog "[$Name] Network configuration (default VLAN $Vlan)..." -LogFile $LogFile

    if ($Vlan -notmatch "^\d+$") {
        # Fail the task instead of returning: an early return here would silently skip
        # the whole post-configuration (network, Integration Services, HA, LiveMigration,
        # backup tag) while the worker still records the VM as a successful migration.
        # Non-numeric values ("PortGroup not found", "VM not found", "No network adapter")
        # are produced upstream by run-migration when VLAN resolution fails.
        $message = "[$Name] Invalid VLAN ID: '$Vlan' — network/post-configuration cannot proceed. Fix the VLAN resolution (or the CSV) and re-run this VM with -Step3VmName."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }

    $requiredConfigPaths = @(
        @{ Path = "SCVMM.Network.PortClassificationName"; Value = $Config.SCVMM.Network.PortClassificationName },
        @{ Path = "SCVMM.Network.LogicalSwitchName";      Value = $Config.SCVMM.Network.LogicalSwitchName }
    )
    foreach ($requiredConfig in $requiredConfigPaths) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredConfig.Value)) {
            throw "Invalid configuration: key '$($requiredConfig.Path)' is missing or empty in config.psd1."
        }
    }

    $TargetVM = Invoke-SCVMMCommand -ScriptBlock {
        param($Name, $ServerName)
        $server = Get-SCVMMServer -ComputerName $ServerName
        Get-SCVirtualMachine -Name $Name -VMMServer $server |
            Where-Object { $_.VirtualizationPlatform -eq "HyperV" } |
            Select-Object -First 1
    } -ArgumentList @($Name, $ServerName)
    if (!$TargetVM) {
        # Fail the task: skipping the whole post-configuration while the worker records
        # a success would leave an unconfigured VM reported as migrated.
        $message = "[$Name] VM not found in SCVMM — network/post-configuration cannot proceed."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }

    $networkConfigRetryDelaySeconds = 30
    $networkConfigRetryCount = 2

    $networkResult = $null
    for ($networkConfigAttempt = 1; $networkConfigAttempt -le $networkConfigRetryCount; $networkConfigAttempt++) {
        try {
            $networkResult = Invoke-SCVMMCommand -ScriptBlock {
        param(
            $Name,
            $ServerName,
            $Vlan,
            $LogicalSwitch,
            $PortClassificationName,
            $Description,
            $AdapterVlanMappings,
            $AllowedVmNetworkNames,
            $AllowedVmSubnetNames,
            $InventoryCacheTtlMinutes,
            $ForceInventoryRefresh
        )

        function Get-ScvmmInventoryCache {
            param(
                [Parameter(Mandatory = $true)]
                $Server,
                [int]$CacheTtlMinutes = 10,
                [switch]$ForceRefresh,
                $WarningSink
            )

            # SCVMM VMNetwork objects do not reference logical switches directly: a VMNetwork
            # belongs to a LogicalNetwork, and the logical switch exposes its logical networks
            # through the uplink port profiles attached to it. Resolve that chain instead of
            # guessing from object properties.
            function Get-ScvmmLogicalSwitchLogicalNetworkIds {
                param(
                    [Parameter(Mandatory = $true)]
                    $Server,

                    [Parameter(Mandatory = $true)]
                    [string]$LogicalSwitchName,

                    $WarningSink
                )

                $logicalNetworkIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

                $scLogicalSwitch = $null
                try {
                    $scLogicalSwitch = Get-SCLogicalSwitch -Name $LogicalSwitchName -VMMServer $Server -ErrorAction Stop | Select-Object -First 1
                } catch {
                    if ($WarningSink) { [void]$WarningSink.Add("Logical switch lookup failed for '$LogicalSwitchName': $($_.Exception.Message)") }
                }

                if (-not $scLogicalSwitch) {
                    if ($WarningSink) { [void]$WarningSink.Add("Logical switch '$LogicalSwitchName' not found in SCVMM; VM network discovery will use the unfiltered inventory.") }
                    return $logicalNetworkIds
                }

                try {
                    foreach ($uplinkSet in @(Get-SCUplinkPortProfileSet -LogicalSwitch $scLogicalSwitch -VMMServer $Server -ErrorAction Stop)) {
                        $uplinkProfiles = @()
                        foreach ($profilePropertyName in @('NativeUplinkPortProfile', 'UplinkPortProfile')) {
                            if ($uplinkSet.PSObject.Properties[$profilePropertyName] -and $uplinkSet.$profilePropertyName) {
                                $uplinkProfiles += $uplinkSet.$profilePropertyName
                            }
                        }

                        foreach ($uplinkProfile in $uplinkProfiles) {
                            if (-not $uplinkProfile.PSObject.Properties['LogicalNetworkDefinitions']) { continue }
                            foreach ($logicalNetworkDefinition in @($uplinkProfile.LogicalNetworkDefinitions)) {
                                if ($logicalNetworkDefinition.LogicalNetwork -and $logicalNetworkDefinition.LogicalNetwork.ID) {
                                    [void]$logicalNetworkIds.Add([string]$logicalNetworkDefinition.LogicalNetwork.ID)
                                }
                            }
                        }
                    }
                } catch {
                    if ($WarningSink) { [void]$WarningSink.Add("Unable to enumerate uplink port profiles of logical switch '$LogicalSwitchName': $($_.Exception.Message)") }
                }

                if ($logicalNetworkIds.Count -eq 0 -and $WarningSink) {
                    [void]$WarningSink.Add("No logical network resolved behind logical switch '$LogicalSwitchName'; VM network discovery will use the unfiltered inventory.")
                }

                return $logicalNetworkIds
            }

            if (-not $script:ScvmmInventoryCacheByServer) {
                $script:ScvmmInventoryCacheByServer = @{}
            }

            $serverKey = [string]$Server.Name
            if ([string]::IsNullOrWhiteSpace($serverKey)) {
                $serverKey = [string]$Server.ComputerName
            }
            $serverKey = $serverKey.ToLowerInvariant()

            $existingCache = $script:ScvmmInventoryCacheByServer[$serverKey]
            $cacheAgeMinutes = if ($existingCache) {
                ((Get-Date).ToUniversalTime() - $existingCache.LoadedAtUtc).TotalMinutes
            } else {
                [double]::PositiveInfinity
            }
            $isExpired = ($cacheAgeMinutes -ge [Math]::Max(1, $CacheTtlMinutes))

            if ($ForceRefresh -or -not $existingCache -or $isExpired) {
                $allVMNetworks = @(Get-SCVMNetwork -VMMServer $Server | Sort-Object Name)
                $allVMSubnets = @(Get-SCVMSubnet -VMMServer $Server | Sort-Object Name)

                if ($AllowedVmNetworkNames -and $AllowedVmNetworkNames.Count -gt 0) {
                    $allowedVmNetworkNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($allowedNetworkName in $AllowedVmNetworkNames) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$allowedNetworkName)) {
                            [void]$allowedVmNetworkNameSet.Add([string]$allowedNetworkName)
                        }
                    }

                    $allVMNetworks = @($allVMNetworks | Where-Object {
                        $allowedVmNetworkNameSet.Contains([string]$_.Name)
                    })
                }

                if ($AllowedVmSubnetNames -and $AllowedVmSubnetNames.Count -gt 0) {
                    $allowedVmSubnetNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($allowedSubnetName in $AllowedVmSubnetNames) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$allowedSubnetName)) {
                            [void]$allowedVmSubnetNameSet.Add([string]$allowedSubnetName)
                        }
                    }

                    $allVMSubnets = @($allVMSubnets | Where-Object {
                        $allowedVmSubnetNameSet.Contains([string]$_.Name)
                    })
                }

                if (-not [string]::IsNullOrWhiteSpace([string]$LogicalSwitch)) {
                    $targetLogicalSwitchName = [string]$LogicalSwitch
                    $switchLogicalNetworkIds = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server $Server -LogicalSwitchName $targetLogicalSwitchName -WarningSink $WarningSink

                    if ($switchLogicalNetworkIds.Count -gt 0) {
                        $filteredNetworks = @($allVMNetworks | Where-Object {
                            $_.LogicalNetwork -and $_.LogicalNetwork.ID -and $switchLogicalNetworkIds.Contains([string]$_.LogicalNetwork.ID)
                        })

                        $vmNetworkIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        $vmNetworkNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($networkEntry in $filteredNetworks) {
                            if ($networkEntry.ID) {
                                [void]$vmNetworkIdSet.Add([string]$networkEntry.ID)
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$networkEntry.Name)) {
                                [void]$vmNetworkNameSet.Add([string]$networkEntry.Name)
                            }
                        }

                        $filteredSubnets = @($allVMSubnets | Where-Object {
                            $subnet = $_

                            $subnetVmNetworkId = $null
                            if ($subnet.VMNetwork -and $subnet.VMNetwork.ID) {
                                $subnetVmNetworkId = [string]$subnet.VMNetwork.ID
                            } elseif ($subnet.VMNetworkID) {
                                $subnetVmNetworkId = [string]$subnet.VMNetworkID
                            }

                            if (-not [string]::IsNullOrWhiteSpace($subnetVmNetworkId) -and $vmNetworkIdSet.Contains($subnetVmNetworkId)) {
                                return $true
                            }

                            return ($subnet.VMNetworkName -and $vmNetworkNameSet.Contains([string]$subnet.VMNetworkName))
                        })

                        if ($filteredNetworks.Count -gt 0 -and $filteredSubnets.Count -gt 0) {
                            $allVMNetworks = $filteredNetworks
                            $allVMSubnets = $filteredSubnets
                        } elseif ($WarningSink) {
                            [void]$WarningSink.Add("Logical switch '$targetLogicalSwitchName' resolves to $($switchLogicalNetworkIds.Count) logical network(s) but no VMNetwork/VMSubnet pair belongs to them; VM network discovery falls back to the unfiltered inventory.")
                        }
                    }
                }
                $allPortClassifications = @(Get-SCPortClassification -VMMServer $Server)

                # Preferred lookup: the real VLAN ID that SCVMM stores on each VM subnet
                # (SubnetVLans[].VLanID), instead of digits parsed out of object names.
                $vmSubnetsByRealVlan = @{}
                foreach ($subnet in $allVMSubnets) {
                    $realVlanIds = @()
                    if ($subnet.PSObject.Properties['SubnetVLans'] -and $subnet.SubnetVLans) {
                        foreach ($subnetVlan in @($subnet.SubnetVLans)) {
                            if ($subnetVlan -and $subnetVlan.PSObject.Properties['VLanID']) {
                                $rawVlanValue = [string]$subnetVlan.VLanID
                                if ($rawVlanValue -match '^\d+$') {
                                    $realVlanIds += [string][int]$rawVlanValue
                                }
                            }
                        }
                    }
                    if ($subnet.PSObject.Properties['VLanID']) {
                        $rawVlanValue = [string]$subnet.VLanID
                        if ($rawVlanValue -match '^\d+$') {
                            $realVlanIds += [string][int]$rawVlanValue
                        }
                    }

                    # VLAN 0 means untagged in SCVMM; never a valid VMware VLAN mapping key.
                    foreach ($vlanKey in @($realVlanIds | Where-Object { $_ -ne '0' } | Select-Object -Unique)) {
                        if (-not $vmSubnetsByRealVlan.ContainsKey($vlanKey)) {
                            $vmSubnetsByRealVlan[$vlanKey] = New-Object System.Collections.ArrayList
                        }
                        [void]$vmSubnetsByRealVlan[$vlanKey].Add($subnet)
                    }
                }

                $vmNetworksByVlan = @{}
                foreach ($network in $allVMNetworks) {
                    $candidates = @([string]$network.Name, [string]$network.Description)
                    foreach ($candidateText in $candidates) {
                        if ([string]::IsNullOrWhiteSpace($candidateText)) { continue }
                        foreach ($match in [regex]::Matches($candidateText, '\d+')) {
                            $vlanKey = [string]$match.Value
                            if (-not $vmNetworksByVlan.ContainsKey($vlanKey)) {
                                $vmNetworksByVlan[$vlanKey] = New-Object System.Collections.ArrayList
                            }
                            [void]$vmNetworksByVlan[$vlanKey].Add($network)
                        }
                    }
                }

                $vmSubnetsByVlan = @{}
                foreach ($subnet in $allVMSubnets) {
                    $candidates = @([string]$subnet.Name, [string]$subnet.Description)
                    foreach ($candidateText in $candidates) {
                        if ([string]::IsNullOrWhiteSpace($candidateText)) { continue }
                        foreach ($match in [regex]::Matches($candidateText, '\d+')) {
                            $vlanKey = [string]$match.Value
                            if (-not $vmSubnetsByVlan.ContainsKey($vlanKey)) {
                                $vmSubnetsByVlan[$vlanKey] = New-Object System.Collections.ArrayList
                            }
                            [void]$vmSubnetsByVlan[$vlanKey].Add($subnet)
                        }
                    }
                }

                $vmNetworksByLookupName = @{}
                foreach ($network in $allVMNetworks) {
                    foreach ($nameKey in @([string]$network.Name, [string]$network.Description)) {
                        if ([string]::IsNullOrWhiteSpace($nameKey)) { continue }
                        $normalizedName = $nameKey.Trim().ToLowerInvariant()
                        if (-not $vmNetworksByLookupName.ContainsKey($normalizedName)) {
                            $vmNetworksByLookupName[$normalizedName] = New-Object System.Collections.ArrayList
                        }
                        [void]$vmNetworksByLookupName[$normalizedName].Add($network)
                    }
                }

                $vmSubnetsByVmNetworkId = @{}
                foreach ($subnet in $allVMSubnets) {
                    $networkId = $null
                    if ($subnet.VMNetwork -and $subnet.VMNetwork.ID) {
                        $networkId = [string]$subnet.VMNetwork.ID
                    } elseif ($subnet.VMNetworkID) {
                        $networkId = [string]$subnet.VMNetworkID
                    }

                    if (-not [string]::IsNullOrWhiteSpace($networkId)) {
                        if (-not $vmSubnetsByVmNetworkId.ContainsKey($networkId)) {
                            $vmSubnetsByVmNetworkId[$networkId] = New-Object System.Collections.ArrayList
                        }
                        [void]$vmSubnetsByVmNetworkId[$networkId].Add($subnet)
                    }
                }

                $portClassByName = @{}
                foreach ($portClassEntry in $allPortClassifications) {
                    $portClassName = [string]$portClassEntry.Name
                    if (-not [string]::IsNullOrWhiteSpace($portClassName)) {
                        $portClassByName[$portClassName.Trim().ToLowerInvariant()] = $portClassEntry
                    }
                }

                $vmNetworksById = @{}
                $vmNetworksByExactName = @{}
                foreach ($network in $allVMNetworks) {
                    if ($network.ID -and -not $vmNetworksById.ContainsKey([string]$network.ID)) {
                        $vmNetworksById[[string]$network.ID] = $network
                    }
                    $exactName = [string]$network.Name
                    if (-not [string]::IsNullOrWhiteSpace($exactName) -and -not $vmNetworksByExactName.ContainsKey($exactName)) {
                        $vmNetworksByExactName[$exactName] = $network
                    }
                }

                $existingCache = [pscustomobject]@{
                    LoadedAtUtc            = (Get-Date).ToUniversalTime()
                    AllVMNetworks          = $allVMNetworks
                    AllVMSubnets           = $allVMSubnets
                    VMSubnetsByRealVlan    = $vmSubnetsByRealVlan
                    VMNetworksByVlan       = $vmNetworksByVlan
                    VMSubnetsByVlan        = $vmSubnetsByVlan
                    VMNetworksByLookupName = $vmNetworksByLookupName
                    VMNetworksById         = $vmNetworksById
                    VMNetworksByExactName  = $vmNetworksByExactName
                    VMSubnetsByVmNetworkId = $vmSubnetsByVmNetworkId
                    PortClassByName        = $portClassByName
                }

                $script:ScvmmInventoryCacheByServer[$serverKey] = $existingCache
            }

            return $existingCache
        }

        # Resolve a VLAN key to a VMNetwork/VMSubnet pair: real SCVMM VLAN IDs first,
        # then VLAN digits parsed from names/descriptions as a fallback.
        function Resolve-ScvmmVlanMapping {
            param(
                [Parameter(Mandatory = $true)]
                $InventoryCache,

                [Parameter(Mandatory = $true)]
                [string]$VlanKey
            )

            if ($InventoryCache.VMSubnetsByRealVlan.ContainsKey($VlanKey)) {
                $pairs = @()
                foreach ($candidateSubnet in @($InventoryCache.VMSubnetsByRealVlan[$VlanKey])) {
                    $pairNetwork = $null
                    if ($candidateSubnet.VMNetwork -and $candidateSubnet.VMNetwork.ID) {
                        $pairNetwork = $InventoryCache.VMNetworksById[[string]$candidateSubnet.VMNetwork.ID]
                    }
                    if (-not $pairNetwork -and $candidateSubnet.PSObject.Properties['VMNetworkName'] -and $candidateSubnet.VMNetworkName) {
                        $pairNetwork = $InventoryCache.VMNetworksByExactName[[string]$candidateSubnet.VMNetworkName]
                    }
                    if ($pairNetwork) {
                        $pairs += [pscustomobject]@{ VMNetwork = $pairNetwork; VMSubnet = $candidateSubnet }
                    }
                }

                if ($pairs.Count -gt 0) {
                    return [pscustomobject]@{
                        VMNetwork               = $pairs[0].VMNetwork
                        VMSubnet                = $pairs[0].VMSubnet
                        Vlan                    = $VlanKey
                        Ambiguous               = ($pairs.Count -gt 1)
                        CandidateVMNetworkNames = @($pairs | ForEach-Object { [string]$_.VMNetwork.Name })
                        CandidateVMSubnetNames  = @($pairs | ForEach-Object { [string]$_.VMSubnet.Name })
                        ResolutionMode          = 'real-vlan-id'
                    }
                }
            }

            $matchingNetworks = if ($InventoryCache.VMNetworksByVlan.ContainsKey($VlanKey)) {
                @($InventoryCache.VMNetworksByVlan[$VlanKey])
            } else {
                @($InventoryCache.AllVMNetworks | Where-Object { $_.Name -like "*$VlanKey*" -or $_.Description -like "*$VlanKey*" })
            }
            $matchingSubnets = if ($InventoryCache.VMSubnetsByVlan.ContainsKey($VlanKey)) {
                @($InventoryCache.VMSubnetsByVlan[$VlanKey])
            } else {
                @($InventoryCache.AllVMSubnets | Where-Object { $_.Name -like "*$VlanKey*" -or $_.Description -like "*$VlanKey*" })
            }

            if ($matchingNetworks.Count -eq 0 -or $matchingSubnets.Count -eq 0) {
                return $null
            }

            [pscustomobject]@{
                VMNetwork               = $matchingNetworks | Select-Object -First 1
                VMSubnet                = $matchingSubnets | Select-Object -First 1
                Vlan                    = $VlanKey
                Ambiguous               = ($matchingNetworks.Count -gt 1 -or $matchingSubnets.Count -gt 1)
                CandidateVMNetworkNames = @($matchingNetworks | ForEach-Object { [string]$_.Name })
                CandidateVMSubnetNames  = @($matchingSubnets  | ForEach-Object { [string]$_.Name })
                ResolutionMode          = 'name-parsed-vlan'
            }
        }

        $server = Get-SCVMMServer -ComputerName $ServerName
        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$Name' not found in SCVMM while applying network configuration."
        }

        $inventoryWarnings = New-Object 'System.Collections.Generic.List[string]'
        $inventoryCache = Get-ScvmmInventoryCache -Server $server -CacheTtlMinutes $InventoryCacheTtlMinutes -ForceRefresh:$ForceInventoryRefresh -WarningSink $inventoryWarnings

        $allVMNetworks = @($inventoryCache.AllVMNetworks)
        $allVMSubnets = @($inventoryCache.AllVMSubnets)

        $portClass = $inventoryCache.PortClassByName[[string]$PortClassificationName.Trim().ToLowerInvariant()]
        if (-not $portClass) {
            throw "Port classification '$PortClassificationName' not found in SCVMM."
        }

        $networkAdapter = $null
        $adapterRetryCount = 18
        $adapterRetryDelaySeconds = 10
        $refreshVirtualMachineCommand = Get-Command -Name 'Read-SCVirtualMachine' -ErrorAction SilentlyContinue | Select-Object -First 1

        function ConvertTo-NormalizedMacAddress {
            param([AllowNull()][string]$Value)

            if ([string]::IsNullOrWhiteSpace($Value)) {
                return $null
            }

            return ($Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        }

        function Test-IsZeroMacAddress {
            param([AllowNull()][string]$Value)

            $normalized = ConvertTo-NormalizedMacAddress -Value $Value
            return ($normalized -and $normalized -eq '000000000000')
        }

        function Convert-ToScvmmStaticMacAddress {
            param([AllowNull()][string]$Value)

            $normalized = ConvertTo-NormalizedMacAddress -Value $Value
            if (-not $normalized -or $normalized.Length -ne 12) {
                return $null
            }

            return (($normalized -split '(.{2})' | Where-Object { $_ }) -join '-')
        }

        function Get-ScvmmNetworkAdapters {
            param(
                $CurrentVm,
                $CurrentServer,
                [string]$CurrentVmName,
                [switch]$AllowGlobalFallback
            )

            $adapters = @()
            if ($CurrentVm -and $CurrentVm.GetType().FullName -notlike 'Deserialized.*') {
                $adapters = @(Get-SCVirtualNetworkAdapter -VM $CurrentVm -ErrorAction SilentlyContinue)
            }
            if ($adapters) {
                return $adapters
            }

            if (-not $AllowGlobalFallback) {
                return @()
            }

            Write-Verbose "[$CurrentVmName] Debug fallback enabled: enumerating all SCVMM virtual network adapters on '$($CurrentServer.Name)'."
            $allAdapters = @(Get-SCVirtualNetworkAdapter -VMMServer $CurrentServer)
            if (-not $allAdapters) {
                return @()
            }

            $matchingAdapters = @($allAdapters |
                Where-Object {
                    ($_.VM -and $_.VM.ID -eq $CurrentVm.ID) -or
                    ($_.VMId -and $_.VMId -eq $CurrentVm.ID) -or
                    ($_.VMName -and $_.VMName -eq $CurrentVmName) -or
                    ($_.VM -and $_.VM.Name -eq $CurrentVmName)
                })

            return $matchingAdapters
        }

        $networkAdapters = @()
        $allowGlobalAdapterFallback = ($DebugPreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue)
        for ($attempt = 1; $attempt -le $adapterRetryCount; $attempt++) {
            $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
            if (-not $vm) {
                throw "VM '$Name' no longer available in SCVMM while waiting for the virtual network adapter."
            }

            $networkAdapters = @(Get-ScvmmNetworkAdapters -CurrentVm $vm -CurrentServer $server -CurrentVmName $Name -AllowGlobalFallback:$allowGlobalAdapterFallback)
            if ($networkAdapters.Count -gt 0) {
                break
            }

            if ($refreshVirtualMachineCommand) {
                & $refreshVirtualMachineCommand -VM $vm | Out-Null
                $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
                if (-not $vm) {
                    throw "VM '$Name' no longer available in SCVMM after refresh while waiting for the virtual network adapter."
                }

                $networkAdapters = @(Get-ScvmmNetworkAdapters -CurrentVm $vm -CurrentServer $server -CurrentVmName $Name -AllowGlobalFallback:$allowGlobalAdapterFallback)
                if ($networkAdapters.Count -gt 0) {
                    break
                }
            }

            Start-Sleep -Seconds $adapterRetryDelaySeconds
        }

        if ($networkAdapters.Count -eq 0) {
            throw "No SCVMM virtual network adapter found for VM '$Name' after waiting $($adapterRetryCount * $adapterRetryDelaySeconds) seconds. SCVMM may still show the VM in an incomplete configuration state; refresh the VM in SCVMM and retry."
        }

        $defaultMapping = Resolve-ScvmmVlanMapping -InventoryCache $inventoryCache -VlanKey ([string]$Vlan)
        if (-not $defaultMapping) {
            throw "No VMNetwork/VMSubnet found for default VLAN $Vlan (searched real SCVMM VLAN IDs first, then names/descriptions)."
        }

        $networkMappingsByVlan = @{}
        $networkMappingsBySourceNetworkName = @{}
        $networkMappingsByVlan[$Vlan] = $defaultMapping

        $adapterMappings = @()
        if ($AdapterVlanMappings) {
            $adapterMappings = @($AdapterVlanMappings | Where-Object { $_.VlanId -match '^\d+$' })
        }

        foreach ($adapterMapping in $adapterMappings) {
            $mappingVlan = [string]$adapterMapping.VlanId
            $mappingNetworkName = [string]$adapterMapping.NetworkName

            if (-not $networkMappingsByVlan.ContainsKey($mappingVlan)) {
                $resolvedMapping = Resolve-ScvmmVlanMapping -InventoryCache $inventoryCache -VlanKey $mappingVlan
                if ($resolvedMapping) {
                    $networkMappingsByVlan[$mappingVlan] = $resolvedMapping
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($mappingNetworkName) -and -not $networkMappingsBySourceNetworkName.ContainsKey($mappingNetworkName)) {
                $lookupKey = $mappingNetworkName.Trim().ToLowerInvariant()
                $matchingByName = if ($inventoryCache.VMNetworksByLookupName.ContainsKey($lookupKey)) {
                    @($inventoryCache.VMNetworksByLookupName[$lookupKey])
                } else {
                    @($allVMNetworks | Where-Object { $_.Name -eq $mappingNetworkName -or $_.Description -eq $mappingNetworkName })
                }
                if (-not $matchingByName) {
                    $matchingByName = @($allVMNetworks | Where-Object { $_.Name -like "*$mappingNetworkName*" -or $_.Description -like "*$mappingNetworkName*" })
                }
                if ($matchingByName.Count -gt 0) {
                    $selectedByName = $matchingByName | Select-Object -First 1
                    $matchingSubnetByName = if ($selectedByName.ID -and $inventoryCache.VMSubnetsByVmNetworkId.ContainsKey([string]$selectedByName.ID)) {
                        @($inventoryCache.VMSubnetsByVmNetworkId[[string]$selectedByName.ID])
                    } else {
                        @($allVMSubnets | Where-Object {
                            ($_.VMNetwork -and $_.VMNetwork.ID -eq $selectedByName.ID) -or
                            ($_.VMNetworkName -and $_.VMNetworkName -eq $selectedByName.Name)
                        })
                    }
                    if ($matchingSubnetByName.Count -gt 0) {
                        $networkMappingsBySourceNetworkName[$mappingNetworkName] = [pscustomobject]@{
                            VMNetwork               = $selectedByName
                            VMSubnet                = $matchingSubnetByName | Select-Object -First 1
                            Vlan                    = if ($mappingVlan -match '^\d+$') { $mappingVlan } else { $Vlan }
                            Ambiguous               = ($matchingByName.Count -gt 1 -or $matchingSubnetByName.Count -gt 1)
                            CandidateVMNetworkNames = @($matchingByName     | ForEach-Object { [string]$_.Name })
                            CandidateVMSubnetNames  = @($matchingSubnetByName | ForEach-Object { [string]$_.Name })
                            ResolutionMode          = 'source-network-name'
                        }
                    }
                }
            }
        }

        $mappedAdapters = 0
        $fallbackMappedAdapters = 0
        $indexedFallbackMappedAdapters = 0
        $macMatchedAdapters = 0
        $adapterResolutionWarnings = New-Object 'System.Collections.Generic.List[string]'

        if ($networkMappingsByVlan[$Vlan].Ambiguous) {
            $defaultCandidates = $networkMappingsByVlan[$Vlan].CandidateVMNetworkNames -join ', '
            $defaultSelected   = [string]$networkMappingsByVlan[$Vlan].VMNetwork.Name
            [void]$adapterResolutionWarnings.Add("[$Name] Default VLAN $Vlan mapping is ambiguous. Selected='$defaultSelected'; Candidates='$defaultCandidates'. First deterministic candidate selected.")
        }

        $macMatchesByTargetIndex = @{}
        $indexFallbackByTargetIndex = @{}
        $usedSourceIndexes = New-Object 'System.Collections.Generic.HashSet[int]'

        # 1) First pass: exact match by preserved MAC address
        for ($adapterIndex = 0; $adapterIndex -lt $networkAdapters.Count; $adapterIndex++) {
            $networkAdapter = $networkAdapters[$adapterIndex]

            $adapterMac = ConvertTo-NormalizedMacAddress -Value ([string]$networkAdapter.MACAddressString)
            if (-not $adapterMac) {
                $adapterMac = ConvertTo-NormalizedMacAddress -Value ([string]$networkAdapter.MACAddress)
            }

            if (-not $adapterMac -or (Test-IsZeroMacAddress -Value $adapterMac)) {
                continue
            }

            for ($sourceIndex = 0; $sourceIndex -lt $adapterMappings.Count; $sourceIndex++) {
                if ($usedSourceIndexes.Contains($sourceIndex)) {
                    continue
                }

                $sourceAdapter = $adapterMappings[$sourceIndex]
                $sourceMac = ConvertTo-NormalizedMacAddress -Value ([string]$sourceAdapter.MacAddress)

                if ($sourceMac -and $sourceMac -eq $adapterMac) {
                    $macMatchesByTargetIndex[$adapterIndex] = $sourceAdapter
                    [void]$usedSourceIndexes.Add($sourceIndex)
                    break
                }
            }
        }

        # 2) Second pass: fallback by remaining adapter order only for still-unmatched NICs
        $remainingTargetIndexes = @()
        for ($adapterIndex = 0; $adapterIndex -lt $networkAdapters.Count; $adapterIndex++) {
            if (-not $macMatchesByTargetIndex.ContainsKey($adapterIndex)) {
                $remainingTargetIndexes += $adapterIndex
            }
        }

        $remainingSourceIndexes = @()
        for ($sourceIndex = 0; $sourceIndex -lt $adapterMappings.Count; $sourceIndex++) {
            if (-not $usedSourceIndexes.Contains($sourceIndex)) {
                $remainingSourceIndexes += $sourceIndex
            }
        }

        $fallbackPairs = [Math]::Min($remainingTargetIndexes.Count, $remainingSourceIndexes.Count)
        for ($i = 0; $i -lt $fallbackPairs; $i++) {
            $targetIndex = $remainingTargetIndexes[$i]
            $sourceIndex = $remainingSourceIndexes[$i]
            $indexFallbackByTargetIndex[$targetIndex] = $adapterMappings[$sourceIndex]
            [void]$usedSourceIndexes.Add($sourceIndex)
        }

        for ($adapterIndex = 0; $adapterIndex -lt $networkAdapters.Count; $adapterIndex++) {
            $networkAdapter = $networkAdapters[$adapterIndex]
            $desiredMapping = $null
            $selectedSourceAdapter = $null

            if ($macMatchesByTargetIndex.ContainsKey($adapterIndex)) {
                $selectedSourceAdapter = $macMatchesByTargetIndex[$adapterIndex]

                if ($networkMappingsByVlan.ContainsKey([string]$selectedSourceAdapter.VlanId)) {
                    $desiredMapping = $networkMappingsByVlan[[string]$selectedSourceAdapter.VlanId]
                } elseif (
                    -not [string]::IsNullOrWhiteSpace([string]$selectedSourceAdapter.NetworkName) -and
                    $networkMappingsBySourceNetworkName.ContainsKey([string]$selectedSourceAdapter.NetworkName)
                ) {
                    $desiredMapping = $networkMappingsBySourceNetworkName[[string]$selectedSourceAdapter.NetworkName]
                }

                if ($desiredMapping) {
                    $macMatchedAdapters++
                }
            }

            if (-not $desiredMapping -and $indexFallbackByTargetIndex.ContainsKey($adapterIndex)) {
                $selectedSourceAdapter = $indexFallbackByTargetIndex[$adapterIndex]

                if ($networkMappingsByVlan.ContainsKey([string]$selectedSourceAdapter.VlanId)) {
                    $desiredMapping = $networkMappingsByVlan[[string]$selectedSourceAdapter.VlanId]
                } elseif (
                    -not [string]::IsNullOrWhiteSpace([string]$selectedSourceAdapter.NetworkName) -and
                    $networkMappingsBySourceNetworkName.ContainsKey([string]$selectedSourceAdapter.NetworkName)
                ) {
                    $desiredMapping = $networkMappingsBySourceNetworkName[[string]$selectedSourceAdapter.NetworkName]
                }

                if ($desiredMapping) {
                    $indexedFallbackMappedAdapters++
                }
            }

            $usedDefaultVlanFallback = $false
            if (-not $desiredMapping) {
                $desiredMapping = $networkMappingsByVlan[$Vlan]
                $usedDefaultVlanFallback = $true
                $fallbackMappedAdapters++
            }

            if ($usedDefaultVlanFallback) {
                $sourceMacText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.MacAddress } else { '<unknown>' }
                $sourceNetworkText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.NetworkName } else { '<unknown>' }
                $sourceVlanText = if ($selectedSourceAdapter -and [string]$selectedSourceAdapter.VlanId -match '^\d+$') { [string]$selectedSourceAdapter.VlanId } else { '<unknown>' }
                $selectedVmNetworkText = [string]$desiredMapping.VMNetwork.Name
                $reasonText = if ($sourceVlanText -ne '<unknown>') {
                    "No candidate found for source VLAN '$sourceVlanText'; mapped to default VLAN $Vlan."
                } else {
                    "No source adapter information; mapped to default VLAN $Vlan."
                }
                [void]$adapterResolutionWarnings.Add(
                    "[$Name] Adapter #$($adapterIndex + 1) fallback mapping used.`n" +
                    "SourceMac='$sourceMacText'`n" +
                    "SourceNetwork='$sourceNetworkText'`n" +
                    "SourceVlan='$sourceVlanText'`n" +
                    "Candidates='<none>'`n" +
                    "Selected='$selectedVmNetworkText' (default VLAN $Vlan)`n" +
                    "Reason='$reasonText'"
                )
            } elseif ($desiredMapping.Ambiguous) {
                $sourceMacText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.MacAddress } else { '<unknown>' }
                $sourceNetworkText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.NetworkName } else { '<unknown>' }
                $sourceVlanText = if ($selectedSourceAdapter -and $selectedSourceAdapter.VlanId) { [string]$selectedSourceAdapter.VlanId } else { [string]$desiredMapping.Vlan }
                $candidateNetworksText = if ($desiredMapping.CandidateVMNetworkNames) { $desiredMapping.CandidateVMNetworkNames -join ', ' } else { '<none>' }
                $selectedVmNetworkText = [string]$desiredMapping.VMNetwork.Name
                $resolutionReason = switch ([string]$desiredMapping.ResolutionMode) {
                    'source-network-name' { 'Ambiguous source-network-name match; first deterministic candidate selected.' }
                    'real-vlan-id' { 'Multiple SCVMM subnets carry this real VLAN ID; first deterministic candidate selected.' }
                    'name-parsed-vlan' { 'Ambiguous VLAN match parsed from names/descriptions; first deterministic candidate selected.' }
                    default { 'Ambiguous default VLAN mapping; first deterministic candidate selected.' }
                }
                [void]$adapterResolutionWarnings.Add(
                    "[$Name] Adapter #$($adapterIndex + 1) fallback mapping used.`n" +
                    "SourceMac='$sourceMacText'`n" +
                    "SourceNetwork='$sourceNetworkText'`n" +
                    "SourceVlan='$sourceVlanText'`n" +
                    "Candidates='$candidateNetworksText'`n" +
                    "Selected='$selectedVmNetworkText'`n" +
                    "Reason='$resolutionReason'"
                )
            }

            $setAdapterParameters = @{
                VirtualNetworkAdapter = $networkAdapter
                VMNetwork             = $desiredMapping.VMNetwork
                VMSubnet              = $desiredMapping.VMSubnet
                VLanEnabled           = $true
                VLanID                = $desiredMapping.Vlan
                VirtualNetwork        = $LogicalSwitch
                IPv4AddressType       = 'Dynamic'
                IPv6AddressType       = 'Dynamic'
                PortClassification    = $portClass
            }

            $targetAdapterMac = ConvertTo-NormalizedMacAddress -Value ([string]$networkAdapter.MACAddressString)
            if (-not $targetAdapterMac) {
                $targetAdapterMac = ConvertTo-NormalizedMacAddress -Value ([string]$networkAdapter.MACAddress)
            }

            if ((Test-IsZeroMacAddress -Value $targetAdapterMac) -and $selectedSourceAdapter) {
                $sourceStaticMac = Convert-ToScvmmStaticMacAddress -Value ([string]$selectedSourceAdapter.MacAddress)
                if ($sourceStaticMac) {
                    $setAdapterParameters['MACAddressType'] = 'Static'
                    $setAdapterParameters['MACAddress'] = $sourceStaticMac
                    [void]$adapterResolutionWarnings.Add("[$Name] Adapter #$($adapterIndex + 1): SCVMM returned 00:00:00:00:00:00, forcing static MAC from VMware ($sourceStaticMac).")
                }
            }

            Set-SCVirtualNetworkAdapter @setAdapterParameters | Out-Null
            $mappedAdapters++
        }

        if ($mappedAdapters -eq 0) {
            throw "No virtual network adapter could be mapped to a VLAN."
        }

        [pscustomobject]@{
            AdapterCount                = $networkAdapters.Count
            MappedAdapterCount          = $mappedAdapters
            MacMatchedAdapterCount      = $macMatchedAdapters
            FallbackAdapterCount        = $fallbackMappedAdapters
            IndexedFallbackCount        = $indexedFallbackMappedAdapters
            DefaultVlanResolutionMode   = [string]$defaultMapping.ResolutionMode
            DefaultVlanVMNetworkName    = [string]$defaultMapping.VMNetwork.Name
            DefaultVlanVMSubnetName     = [string]$defaultMapping.VMSubnet.Name
            AdapterWarnings             = @(@($inventoryWarnings) + @($adapterResolutionWarnings))
        }

        $setVmParameters = @{
            VM                             = $vm
            EnableOperatingSystemShutdown  = $true
            EnableTimeSynchronization      = $false
            EnableDataExchange             = $true
            EnableHeartbeat                = $true
            EnableBackup                   = $true
            EnableGuestServicesInterface   = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $setVmParameters["Description"] = $Description
        }

        Set-SCVirtualMachine @setVmParameters | Out-Null
            } -ArgumentList @(
        $Name,
        $ServerName,
        $Vlan,
        $Config.SCVMM.Network.LogicalSwitchName,
        $Config.SCVMM.Network.PortClassificationName,
        $SourceRemark,
        $AdapterVlanMappings,
        @($Config.SCVMM.Network.AllowedVmNetworkNames),
        @($Config.SCVMM.Network.AllowedVmSubnetNames),
        $(if ($Config.SCVMM.Network.InventoryCacheTtlMinutes -is [int]) { $Config.SCVMM.Network.InventoryCacheTtlMinutes } else { 10 }),
        ($networkConfigAttempt -gt 1)
            )
            break
        } catch {
            if ($networkConfigAttempt -ge $networkConfigRetryCount) {
                throw
            }

            Write-MigrationLog "[$Name] SCVMM network/post-configuration attempt $networkConfigAttempt failed (`"$($_.Exception.Message)`"). Waiting $networkConfigRetryDelaySeconds seconds before retry (suspected transient SCVMM refresh/state delay)." -Level WARNING -LogFile $LogFile
            Start-Sleep -Seconds $networkConfigRetryDelaySeconds
        }
    }

    if ($networkResult -and -not [string]::IsNullOrWhiteSpace([string]$networkResult.DefaultVlanResolutionMode)) {
        Write-MigrationLog "[$Name] Default VLAN $Vlan resolved via '$($networkResult.DefaultVlanResolutionMode)' to VMNetwork '$($networkResult.DefaultVlanVMNetworkName)' / VMSubnet '$($networkResult.DefaultVlanVMSubnetName)'." -LogFile $LogFile
    }

    if ($networkResult -and $networkResult.MacMatchedAdapterCount -gt 0) {
        Write-MigrationLog "[$Name] $($networkResult.MacMatchedAdapterCount)/$($networkResult.AdapterCount) adapter(s) matched by preserved MAC address." -LogFile $LogFile
    }

    if ($networkResult -and $networkResult.IndexedFallbackCount -gt 0) {
        Write-MigrationLog "[$Name] $($networkResult.IndexedFallbackCount) adapter(s) were matched by adapter order fallback." -Level WARNING -LogFile $LogFile
    }

    if ($networkResult -and $networkResult.FallbackAdapterCount -gt 0) {
        Write-MigrationLog "[$Name] $($networkResult.FallbackAdapterCount)/$($networkResult.AdapterCount) adapter(s) had no exact match and were kept on default VLAN $Vlan." -Level WARNING -LogFile $LogFile
    }

    if ($networkResult -and $networkResult.AdapterWarnings) {
        foreach ($adapterWarning in @($networkResult.AdapterWarnings)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$adapterWarning)) {
                Write-MigrationLog $adapterWarning -Level WARNING -LogFile $LogFile
            }
        }
    }

    Write-MigrationLog "[$Name] Network configured (default VLAN $Vlan, multi-adapter mapping enabled)." -Level SUCCESS -LogFile $LogFile
    Write-MigrationLog "[$Name] Integration Services configured." -LogFile $LogFile
    if (-not [string]::IsNullOrWhiteSpace($SourceRemark)) {
        Write-MigrationLog "[$Name] SCVMM description updated from VMware remark." -LogFile $LogFile
    } else {
        Write-MigrationLog "[$Name] VMware remark empty; SCVMM description unchanged." -LogFile $LogFile
    }
    Set-SCVMMOperatingSystem -Name $Name -ServerName $ServerName -SourceOperatingSystem $SourceOperatingSystem -OperatingSystemMap $Config.SCVMM.OperatingSystemMap -LogFile $LogFile

    $vmStateBeforeHa = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName
    $vmHaState = [bool]$vmStateBeforeHa.IsHighlyAvailable

    $clusterVmRegistrationCommand = Get-Command -Name "Add-ClusterVirtualMachineRole" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $clusterVmRegistrationCommand) {
        try {
            Import-RequiredModule -Name "FailoverClusters" -LogFile $LogFile -UseWindowsPowerShellFallback
            $clusterVmRegistrationCommand = Get-Command -Name "Add-ClusterVirtualMachineRole" -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } catch {
            Write-MigrationLog "[$Name] FailoverClusters module import failed; high-availability registration will use SCVMM state only. Details: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
        }
    }

    if ($vmHaState) {
        Write-MigrationLog "[$Name] VM is already highly available in SCVMM." -Level SUCCESS -LogFile $LogFile
    } else {
        try {
            if ($clusterVmRegistrationCommand) {
                & $clusterVmRegistrationCommand -Cluster $ClusterName -VirtualMachine $TargetVM.Name
                Write-MigrationLog "[$Name] VM added to cluster $ClusterName; validating high availability state in SCVMM after refresh." -Level SUCCESS -LogFile $LogFile
            } else {
                Write-MigrationLog "[$Name] Add-ClusterVirtualMachineRole cmdlet unavailable on this execution host; skipping direct cluster cmdlet call and validating SCVMM high-availability state only." -Level WARNING -LogFile $LogFile
            }
        } catch {
            if ([string]$_ -match "already exists|already been configured|already highly available|is already part of") {
                Write-MigrationLog "[$Name] Cluster role already present; skipping duplicate high-availability registration." -Level WARNING -LogFile $LogFile
            } else {
                Write-MigrationLog "[$Name] Cluster error: $_" -Level ERROR -LogFile $LogFile
                throw
            }
        }

        $vmStateAfterHa = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName -Refresh
        if (-not $vmStateAfterHa.IsHighlyAvailable) {
            if ($clusterVmRegistrationCommand) {
                throw "VM '$Name' is still not highly available in SCVMM after Add-ClusterVirtualMachineRole and refresh."
            }

            throw "VM '$Name' is still not highly available in SCVMM after refresh, and Add-ClusterVirtualMachineRole is unavailable on this execution host. Install/import the FailoverClusters module (with the command available) or run this step from a Failover Clustering management host."
        }

        Write-MigrationLog "[$Name] SCVMM confirms high availability is enabled." -Level SUCCESS -LogFile $LogFile
    }

    try {
        $vmStateBeforeMove = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName -Refresh
        Write-MigrationLog "[$Name] Preparing host migration validation. Current host: '$($vmStateBeforeMove.HostName)'." -LogFile $LogFile

        try {
            Start-SCVMMHostMigration -Name $Name -ServerName $ServerName -DestinationHost $DestinationHost
            Write-MigrationLog "[$Name] LiveMigration to $DestinationHost requested via SCVMM." -Level SUCCESS -LogFile $LogFile
        } catch {
            Write-MigrationLog "[$Name] SCVMM migration failed; retrying via Hyper-V Move-VM. Details: $_" -Level WARNING -LogFile $LogFile

            Install-RsatHyperV -LogFile $LogFile
            $hyperVMoveCommand = Get-Command -Name "Move-VM" -Module "Hyper-V" -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($hyperVMoveCommand) {
                & $hyperVMoveCommand -Name $TargetVM.Name -DestinationHost $DestinationHost -ErrorAction Stop
                Write-MigrationLog "[$Name] LiveMigration to $DestinationHost performed via Hyper-V module." -Level SUCCESS -LogFile $LogFile
            } else {
                throw "LiveMigration failed: SCVMM move failed and Hyper-V Move-VM cmdlet is unavailable on this runner."
            }
        }

        $destinationHostNormalized = ConvertTo-NormalizedHostName -Name $DestinationHost
        $migrationValidationTimeoutSeconds = 600
        $migrationValidationPollIntervalSeconds = 15
        $migrationValidationElapsedSeconds = 0
        $migrationValidated = $false
        do {
            Start-Sleep -Seconds $migrationValidationPollIntervalSeconds
            $migrationValidationElapsedSeconds += $migrationValidationPollIntervalSeconds

            $vmStateAfterMove = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName -Refresh
            $currentHostNormalized = ConvertTo-NormalizedHostName -Name $vmStateAfterMove.HostName

            if ($currentHostNormalized -eq $destinationHostNormalized) {
                Write-MigrationLog "[$Name] LiveMigration validated: VM is now running on '$($vmStateAfterMove.HostName)'." -Level SUCCESS -LogFile $LogFile
                $migrationValidated = $true
                break
            }

            Write-MigrationLog "[$Name] Waiting for live migration completion (current host: '$($vmStateAfterMove.HostName)', expected: '$DestinationHost', elapsed: ${migrationValidationElapsedSeconds}s)." -Level WARNING -LogFile $LogFile
        } while ($migrationValidationElapsedSeconds -lt $migrationValidationTimeoutSeconds)

        if (-not $migrationValidated) {
            throw "LiveMigration validation timed out after $migrationValidationTimeoutSeconds seconds. VM current host: '$($vmStateAfterMove.HostName)', expected destination: '$DestinationHost'."
        }
    } catch {
        if ([string]$_ -match "could not access an expected WMI class|Hyper-V Platform") {
            Write-MigrationLog "[$Name] LiveMigration unavailable on this runner (missing local Hyper-V platform). Migration already completed; run host-to-host move from a Hyper-V capable node or via SCVMM." -Level WARNING -LogFile $LogFile
        } else {
            # Propagate so the worker records the task as failed: swallowing the error
            # here used to mark VMs left on the wrong host as successful migrations.
            Write-MigrationLog "[$Name] LiveMigration error: $_" -Level ERROR -LogFile $LogFile
            throw
        }
    }

    Invoke-SCVMMCommand -ScriptBlock {
        param($Name, $ServerName, $TagName)
        $server = Get-SCVMMServer -ComputerName $ServerName
        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$Name' not found in SCVMM while setting tag."
        }

        Set-SCVirtualMachine -VM $vm -Tag $TagName | Out-Null
    } -ArgumentList @($Name, $ServerName, $BackupTagName)

    Write-MigrationLog "[$Name] Backup tag '$BackupTagName' applied." -LogFile $LogFile
}

function Set-SCVMMOperatingSystem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [AllowNull()]
        [string]$SourceOperatingSystem,

        $OperatingSystemMap,

        [string]$LogFile
    )

    if ([string]::IsNullOrWhiteSpace($SourceOperatingSystem)) {
        Write-MigrationLog "[$Name] No source operating system provided; SCVMM OS update skipped." -Level WARNING -LogFile $LogFile
        return
    }

    $targetOperatingSystem = Resolve-OperatingSystemMapping -OperatingSystem $SourceOperatingSystem -OperatingSystemMap $OperatingSystemMap
    if ([string]::IsNullOrWhiteSpace($targetOperatingSystem)) {
        $normalizedOperatingSystem = ConvertTo-NormalizedOperatingSystemName -Name $SourceOperatingSystem
        Write-MigrationLog "[$Name] No SCVMM OS mapping found for '$normalizedOperatingSystem'." -Level WARNING -LogFile $LogFile
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Set SCVMM operating system to '$targetOperatingSystem'")) {
        return
    }

    $mappingResult = Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName, $TargetOperatingSystemName)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $scvmmOperatingSystems = Get-SCOperatingSystem -VMMServer $server
        $scvmmOperatingSystem = $scvmmOperatingSystems | Where-Object { $_.Name -eq $TargetOperatingSystemName } | Select-Object -First 1
        if (-not $scvmmOperatingSystem) {
            throw "Operating system '$TargetOperatingSystemName' not found in SCVMM."
        }

        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq 'HyperV' } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while setting the operating system."
        }

        Set-SCVirtualMachine -VM $vm -OperatingSystem $scvmmOperatingSystem | Out-Null
        return $scvmmOperatingSystem.Name
    } -ArgumentList @($Name, $ServerName, $targetOperatingSystem)

    Write-MigrationLog "[$Name] SCVMM operating system set to '$mappingResult' from source '$SourceOperatingSystem'." -Level SUCCESS -LogFile $LogFile
}

# ── SCVMM connection ────────────────────────────────────────────────────────

$connectToScvmmServer = {
    Invoke-SCVMMCommand -ScriptBlock {
        param($ServerName)
        $server = Get-SCVMMServer -ComputerName $ServerName
        if (-not $server) {
            throw "SCVMM server '$ServerName' not found."
        }

        return $server.Name
    } -ArgumentList @($SCVMMServer)
}

try {
    $VMMServerName = & $connectToScvmmServer
} catch {
    # "IndigoLayer"/type-initializer errors mean the SCVMM module was loaded into the
    # PowerShell 7 process but its WCF runtime cannot work there. Re-import it through
    # the Windows PowerShell compatibility session and retry once before giving up.
    if ([string]$_ -match "IndigoLayer|type initializer" -and (Repair-WindowsOnlyModuleImport -Name "VirtualMachineManager" -LogFile $LogFile)) {
        try {
            $VMMServerName = & $connectToScvmmServer
            Write-MigrationLog "[$VMName] SCVMM connection recovered through the Windows PowerShell compatibility session." -Level SUCCESS -LogFile $LogFile
        } catch {
            Write-MigrationLog "[$VMName] SCVMM connection still failing after Windows PowerShell compatibility re-import. Validate that the Virtual Machine Manager Console matching the SCVMM server version is installed on the runner. Details: $_" -Level ERROR -LogFile $LogFile
            throw
        }
    } else {
        if ([string]$_ -match "IndigoLayer|type initializer") {
            Write-MigrationLog "[$VMName] SCVMM module error hints at a VMM console/runtime mismatch on the runner. Validate that Virtual Machine Manager Console matching the SCVMM server version is installed and restart the shell." -Level ERROR -LogFile $LogFile
        }
        Write-MigrationLog "[$VMName] Failed to connect to SCVMM server '$SCVMMServer': $_" -Level ERROR -LogFile $LogFile
        throw
    }
}

# ── Instant Recovery: start ─────────────────────────────────────────────

if (-not $SkipInstantRecoveryStart -or -not $SkipInstantRecoveryFinalization) {

if (-not $SkipInstantRecoveryStart) {

Write-MigrationLog "[$VMName] Checking SCVMM in Veeam..." -LogFile $LogFile
$VBRSCVMM = Invoke-VeeamCommand -ScriptBlock {
    param($ScvmmServerName)
    Get-VBRServer | Where-Object { $_.Name -eq $ScvmmServerName -and $_.Type -eq "Scvmm" } |
        Select-Object -First 1 -Property Name, Type
} -ArgumentList @($SCVMMServer)

if (!$VBRSCVMM) {
    $msg = "[$VMName] SCVMM $SCVMMServer is not registered in Veeam."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
}

$Backup = Invoke-VeeamCommand -ScriptBlock {
    param($JobName)
    Get-VBRBackup | Where-Object { $_.Name -eq $JobName } |
        Select-Object -First 1 -Property Name, Id
} -ArgumentList @($BackupJobName)

if (!$Backup) {
    $msg = "[$VMName] Backup job '$BackupJobName' not found in Veeam."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
}

try {
    Invoke-VeeamCommand -ScriptBlock {
        param(
            [string]$JobName,
            [string]$Vm,
            [string]$DestinationHost,
            [string]$DestinationPath
        )

        $backup = Get-VBRBackup | Where-Object { $_.Name -eq $JobName } | Select-Object -First 1
        if (-not $backup) {
            throw "Backup job '$JobName' not found in Veeam."
        }

        $restorePoint = Get-VBRRestorePoint -Backup $backup |
            Where-Object { $_.Name -eq $Vm } |
            Sort-Object -Property CreationTime -Descending |
            Select-Object -First 1

        if (-not $restorePoint) {
            throw "No restore point found for VM '$Vm' in job '$JobName'."
        }

        Start-VBRHvInstantRecovery -RestorePoint $restorePoint -Server $DestinationHost -Path $DestinationPath -PowerUp $false -NICsEnabled $true -PreserveMACs $true -PreserveVmID $true | Out-Null
        return $true
    } -ArgumentList @($BackupJobName, $VMName, $HyperVHost, "$ClusterStorage\$VMName")
} catch {
    Write-MigrationLog "[$VMName] Instant Recovery preparation failed: $_" -Level ERROR -LogFile $LogFile
    throw
}

Write-MigrationLog "[$VMName] Starting Instant Recovery..." -LogFile $LogFile
try {
    Write-MigrationLog "[$VMName] Instant Recovery started." -Level SUCCESS -LogFile $LogFile

    $elapsed = 0
    do {
        $waitCheck = Invoke-VeeamCommand -ScriptBlock {
            param($Vm)

            $instantRecoverySession = Get-VBRInstantRecovery |
                Where-Object { $_.VMName -eq $Vm } |
                Select-Object -First 1

            $currentState = if ($instantRecoverySession) { [string]$instantRecoverySession.State } else { "<none>" }
            $restoreSessionState = "<none>"
            $waitingDetected = $false
            $detectionSource = $null

            if ($instantRecoverySession -and $instantRecoverySession.State -eq "WaitingForUserAction") {
                $waitingDetected = $true
                $detectionSource = "instant-recovery-state"
            }

            if (-not $waitingDetected) {
                # Exact names plus a bounded pattern ("VM (Instant Recovery)"…): a plain
                # "$Vm*" wildcard would also match another batch VM whose name shares the
                # prefix (e.g. WEB1 vs WEB10) and follow the wrong session.
                $vmSessionPattern = '^{0}($|[^\w-])' -f [regex]::Escape($Vm)
                $restoreSession = Get-VBRRestoreSession |
                    Where-Object { $_.Name -eq $Vm -or $_.Name -eq "$Vm-migrationhyp" -or $_.Name -match $vmSessionPattern } |
                    Sort-Object -Property CreationTime -Descending |
                    Select-Object -First 1

                if ($restoreSession) {
                    $restoreSessionState = [string]$restoreSession.State
                    $sessionLog = $restoreSession.Logger.GetLog()
                    $logRecords = @()
                    if ($sessionLog.UpdatedRecords) { $logRecords += $sessionLog.UpdatedRecords }
                    if ($sessionLog.Records)        { $logRecords += $sessionLog.Records }

                    $logText = ($logRecords | ForEach-Object {
                        @($_.Title, $_.Description, $_.Message, $_.Text)
                    } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"

                    if ($logText -match "Waiting for user action") {
                        $waitingDetected = $true
                        $detectionSource = "restore-session-log"
                    }
                }
            }

            [PSCustomObject]@{
                WaitingDetected     = $waitingDetected
                CurrentState        = $currentState
                RestoreSessionState = $restoreSessionState
                DetectionSource     = $detectionSource
            }
        } -ArgumentList @($VMName)

        Write-MigrationLog "[$VMName] Current states: InstantRecovery='$($waitCheck.CurrentState)', RestoreSession='$($waitCheck.RestoreSessionState)' (elapsed: ${elapsed}s)." -LogFile $LogFile

        if ($waitCheck.WaitingDetected) {
            Write-MigrationLog "[$VMName] Instant Recovery in waiting mode (source=$($waitCheck.DetectionSource))." -Level SUCCESS -LogFile $LogFile
            break
        }


        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $elapsed += $WaitingPollIntervalSeconds
    } while ($elapsed -lt $WaitingTimeoutSeconds)

    if ($elapsed -ge $WaitingTimeoutSeconds) {
        throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for WaitingForUserAction."
    }
} catch {
    Write-MigrationLog "[$VMName] Instant Recovery error: $_" -Level ERROR -LogFile $LogFile
    throw
}
} else {
    Write-MigrationLog "[$VMName] SkipInstantRecoveryStart enabled: skipping Instant Recovery start/wait phase." -Level WARNING -LogFile $LogFile
}

# ── Instant Recovery: finalization ─────────────────────────────────────────

if (-not $SkipInstantRecoveryFinalization) {

$IRSession = Invoke-VeeamCommand -ScriptBlock {
    param($Vm)
    Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } |
        Select-Object -First 1 -Property VMName, State
} -ArgumentList @($VMName)

if (!$IRSession) {
    $msg = "[$VMName] No active Instant Recovery session."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
}

$vmInScvmm = Invoke-SCVMMCommand -ScriptBlock {
    param($Name, $ServerName)
    $server = Get-SCVMMServer -ComputerName $ServerName
    Get-SCVirtualMachine -Name $Name -VMMServer $server
} -ArgumentList @($VMName, $VMMServerName)
if (!$vmInScvmm) {
    $msg = "[$VMName] VM missing from SCVMM, finalization impossible."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
}

Write-MigrationLog "[$VMName] Finalizing Instant Recovery..." -LogFile $LogFile
try {
    Invoke-VeeamCommand -ScriptBlock {
        param($Vm)
        $irSession = Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } | Select-Object -First 1
        if (-not $irSession) {
            throw "No active Instant Recovery session for VM '$Vm'."
        }
        Start-VBRHvInstantRecoveryMigration -InstantRecovery $irSession | Out-Null
    } -ArgumentList @($VMName)

    Write-MigrationLog "[$VMName] Finalization completed." -Level SUCCESS -LogFile $LogFile

    $finalizationElapsed = 0
    do {
        $finalizationCheck = Invoke-VeeamCommand -ScriptBlock {
            param($Vm)

            # Same bounded matching as the wait phase: never follow a session belonging
            # to another VM whose name shares this VM's prefix (WEB1 vs WEB10).
            $vmSessionPattern = '^{0}($|[^\w-])' -f [regex]::Escape($Vm)
            $restoreSession = Get-VBRRestoreSession |
                Where-Object { $_.Name -eq $Vm -or $_.Name -eq "$Vm-migrationhyp" -or $_.Name -match $vmSessionPattern } |
                Sort-Object -Property CreationTime -Descending |
                Select-Object -First 1

            if (-not $restoreSession) {
                return [PSCustomObject]@{
                    Found  = $false
                    Name   = $null
                    State  = $null
                    Result = $null
                }
            }

            [PSCustomObject]@{
                Found  = $true
                Name   = [string]$restoreSession.Name
                State  = [string]$restoreSession.State
                Result = [string]$restoreSession.Result
            }
        } -ArgumentList @($VMName)

        if (-not $finalizationCheck.Found) {
            Write-MigrationLog "[$VMName] Restore session not yet visible after finalization start (elapsed: ${finalizationElapsed}s)." -Level WARNING -LogFile $LogFile
        } else {
            Write-MigrationLog "[$VMName] Restore session '$($finalizationCheck.Name)' status: State='$($finalizationCheck.State)', Result='$($finalizationCheck.Result)' (elapsed: ${finalizationElapsed}s)." -LogFile $LogFile

            if ($finalizationCheck.Result -eq "Success") {
                Write-MigrationLog "[$VMName] VM restored permanently; network reconfiguration can start." -Level SUCCESS -LogFile $LogFile
                break
            }

            if ($finalizationCheck.Result -eq "Warning") {
                Write-MigrationLog "[$VMName] Restore session '$($finalizationCheck.Name)' ended with result 'Warning'. Continuing with SCVMM network/post-configuration and keeping execution non-blocking." -Level WARNING -LogFile $LogFile
                break
            }

            if ($finalizationCheck.Result -eq "Failed") {
                throw "Restore session '$($finalizationCheck.Name)' ended with result '$($finalizationCheck.Result)'."
            }
        }

        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $finalizationElapsed += $WaitingPollIntervalSeconds
    } while ($finalizationElapsed -lt $WaitingTimeoutSeconds)

    if ($finalizationElapsed -ge $WaitingTimeoutSeconds) {
        throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for restore session success before network reconfiguration."
    }
} catch {
    Write-MigrationLog "[$VMName] Finalization error: $_" -Level ERROR -LogFile $LogFile
    throw
}
} else {
    Write-MigrationLog "[$VMName] SkipInstantRecoveryFinalization enabled: skipping Instant Recovery commit/finalization phase." -Level WARNING -LogFile $LogFile
}
} else {
    Write-MigrationLog "[$VMName] SkipInstantRecoveryStart enabled: skipping Instant Recovery start/wait phase." -Level WARNING -LogFile $LogFile
    Write-MigrationLog "[$VMName] SkipInstantRecoveryFinalization enabled: skipping Instant Recovery commit/finalization phase." -Level WARNING -LogFile $LogFile
}

# ── Network mapping ────────────────────────────────────────────────────────────

if ($ForceNetworkConfigOnly) {
    Write-MigrationLog "[$VMName] ForceNetworkConfigOnly enabled: skipping Instant Recovery/finalization and replaying only network/OS/post-configuration actions." -Level WARNING -LogFile $LogFile
}

if ($SkipNetworkAndPostConfig) {
    Write-MigrationLog "[$VMName] SkipNetworkAndPostConfig enabled: Instant Recovery phase completed; network/post-configuration skipped." -Level WARNING -LogFile $LogFile
    Write-MigrationLog "[$VMName] Migration completed (Instant Recovery only mode)." -Level SUCCESS -LogFile $LogFile
    return
}

$adapterVlanMappings = @()
if (-not [string]::IsNullOrWhiteSpace($AdapterVlanMapJson)) {
    try {
        $parsedMappings = ConvertFrom-Json -InputObject $AdapterVlanMapJson -ErrorAction Stop
        if ($parsedMappings) {
            $adapterVlanMappings = @($parsedMappings)
        }
    } catch {
        Write-MigrationLog "[$VMName] Unable to parse adapter VLAN mapping payload. Falling back to default VLAN '$VlanId'. Details: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
    }
}

Invoke-SCVMMNetworkAndPostConfig `
    -Name $VMName `
    -ServerName $VMMServerName `
    -Vlan $VlanId `
    -AdapterVlanMappings $adapterVlanMappings `
    -SourceOperatingSystem $OperatingSystem `
    -SourceRemark $Remark `
    -Config $Config `
    -BackupTagName $BackupTag `
    -ClusterName $HyperVCluster `
    -DestinationHost $HyperVHost2 `
    -LogFile $LogFile

Write-MigrationLog "[$VMName] Migration completed." -Level SUCCESS -LogFile $LogFile
