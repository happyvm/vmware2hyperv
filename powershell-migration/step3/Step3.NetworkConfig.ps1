<#
.SYNOPSIS
    Network configuration functions for step3: VLAN mapping, adapter assignment,
    and Integration Services setup.

.DESCRIPTION
    Extracted from step3-MigrateVM.ps1 (§3 du plan de refactoring).
    Contains the core network configuration logic previously embedded in
    Invoke-SCVMMNetworkAndPostConfig. The function runs inside the WinPS
    compat session via Invoke-SCVMMCommand and configures SCVMM virtual
    network adapters with the correct VLAN, VMNetwork, VMSubnet, and
    Integration Services settings.

    Functions:
    - Set-VmNetworkConfiguration   Full network mapping + config + Integration Services

.NOTES
    Part of the vmware2hyperv migration toolkit — step3 refactoring.
    Depends on lib.ps1 (Write-MigrationLog, Invoke-SCVMMCommand) and
    Step3.ScvmmSession.Functions.ps1 (Get-ScvmmInventoryCache,
    Resolve-ScvmmVlanMapping, Get-ScvmmNetworkAdapters,
    ConvertTo-NormalizedMacAddress, Test-IsZeroMacAddress,
    Convert-ToScvmmStaticMacAddress).
    Post-config functions (OS, HA, LiveMigration, BackupTag) are called
    separately by the step3-MigrateVM.ps1 orchestrator.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Set-VmNetworkConfiguration — configure VM network adapters and Integration Services
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Configure network adapters and Integration Services for a Hyper-V VM in SCVMM.

.DESCRIPTION
    Validates the VLAN and configuration, retrieves the VM from SCVMM, builds
    the network inventory cache, resolves VLAN mappings, matches source adapters
    to target adapters (MAC exact → index fallback → default VLAN), applies
    the network configuration via Set-SCVirtualNetworkAdapter, and configures
    Integration Services via Set-SCVirtualMachine.

    The network configuration scriptblock is retried once on transient SCVMM
    failures. Post-configuration steps (OS mapping, HA registration,
    LiveMigration, backup tag) are NOT performed by this function — they must
    be called separately by the orchestrator.

.PARAMETER Name
    VM name. Mandatory.

.PARAMETER ServerName
    SCVMM server name (obtained from Connect-Step3Scvmm). Mandatory.

.PARAMETER Vlan
    Default VLAN ID. Must be a numeric string. Mandatory.

.PARAMETER AdapterVlanMappings
    Array of per-adapter VLAN mappings from the CSV/JSON.

.PARAMETER SourceRemark
    VMware remark to use as SCVMM description.

.PARAMETER Config
    Configuration data from config.psd1. Mandatory.

.PARAMETER LogFile
    Path to the migration log file. Mandatory.

.EXAMPLE
    $result = Set-VmNetworkConfiguration -Name "SRV-WEB01" -ServerName $VMMServerName `
        -Vlan "100" -Config $Config -LogFile $LogFile

.OUTPUTS
    [PSCustomObject] with network configuration summary:
    - AdapterCount, MappedAdapterCount, MacMatchedAdapterCount,
      FallbackAdapterCount, IndexedFallbackCount,
      DefaultVlanResolutionMode, DefaultVlanVMNetworkName,
      DefaultVlanVMSubnetName, AdapterWarnings
#>
function Set-VmNetworkConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$Vlan,
        $AdapterVlanMappings,

        [string]$SourceRemark,
        $Config,

        [string]$LogFile
    )

    Write-MigrationLog "[$Name] Network configuration (default VLAN $Vlan)..." -LogFile $LogFile

    if ($Vlan -notmatch "^\d+$") {
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
        param($VmName, $VmmServerName)
        $server = Get-SCVMMServer -ComputerName $VmmServerName
        Get-SCVirtualMachine -Name $VmName -VMMServer $server |
            Where-Object { $_.VirtualizationPlatform -eq "HyperV" } |
            Select-Object -First 1
    } -ArgumentList @($Name, $ServerName)
    if (!$TargetVM) {
        $message = "[$Name] VM not found in SCVMM — network/post-configuration cannot proceed."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }

    # Guard: AllowedVmNetworkNames/AllowedVmSubnetNames/InventoryCacheTtlMinutes are optional
    # keys (unlike PortClassificationName/LogicalSwitchName above). A config.psd1 deployed
    # before these keys existed won't have them, and under StrictMode a direct
    # $Config.SCVMM.Network.X access throws PropertyNotFoundException instead of $null.
    $networkConfig = $Config.SCVMM.Network
    $allowedVmNetworkNames = if ($networkConfig.ContainsKey('AllowedVmNetworkNames')) { $networkConfig.AllowedVmNetworkNames } else { @() }
    $allowedVmSubnetNames = if ($networkConfig.ContainsKey('AllowedVmSubnetNames')) { $networkConfig.AllowedVmSubnetNames } else { @() }
    $inventoryCacheTtlMinutes = if ($networkConfig.ContainsKey('InventoryCacheTtlMinutes') -and $networkConfig.InventoryCacheTtlMinutes -is [int]) {
        $networkConfig.InventoryCacheTtlMinutes
    } else {
        10
    }

    $networkConfigRetryDelaySeconds = 30
    $networkConfigRetryCount = 2

    $networkResult = $null
    for ($networkConfigAttempt = 1; $networkConfigAttempt -le $networkConfigRetryCount; $networkConfigAttempt++) {
        try {
            $networkResult = Invoke-SCVMMCommand -ScriptBlock {
        param(
            $VmName,
            $VmmServerName,
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

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while applying network configuration."
        }

        $inventoryWarnings = New-Object 'System.Collections.Generic.List[string]'
        $inventoryCache = Get-ScvmmInventoryCache -Server $server -CacheTtlMinutes $InventoryCacheTtlMinutes -ForceRefresh:$ForceInventoryRefresh -WarningSink $inventoryWarnings -AllowedVmNetworkNames $AllowedVmNetworkNames -AllowedVmSubnetNames $AllowedVmSubnetNames -LogicalSwitch $LogicalSwitch

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

        $networkAdapters = @()
        $allowGlobalAdapterFallback = ($DebugPreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue)
        for ($attempt = 1; $attempt -le $adapterRetryCount; $attempt++) {
            $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
            if (-not $vm) {
                throw "VM '$VmName' no longer available in SCVMM while waiting for the virtual network adapter."
            }

            $networkAdapters = @(Get-ScvmmNetworkAdapters -CurrentVm $vm -CurrentServer $server -CurrentVmName $VmName -AllowGlobalFallback:$allowGlobalAdapterFallback)
            if ($networkAdapters.Count -gt 0) {
                break
            }

            if ($refreshVirtualMachineCommand) {
                & $refreshVirtualMachineCommand -VM $vm | Out-Null
                $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
                if (-not $vm) {
                    throw "VM '$VmName' no longer available in SCVMM after refresh while waiting for the virtual network adapter."
                }

                $networkAdapters = @(Get-ScvmmNetworkAdapters -CurrentVm $vm -CurrentServer $server -CurrentVmName $VmName -AllowGlobalFallback:$allowGlobalAdapterFallback)
                if ($networkAdapters.Count -gt 0) {
                    break
                }
            }

            Start-Sleep -Seconds $adapterRetryDelaySeconds
        }

        if ($networkAdapters.Count -eq 0) {
            throw "No SCVMM virtual network adapter found for VM '$VmName' after waiting $($adapterRetryCount * $adapterRetryDelaySeconds) seconds. SCVMM may still show the VM in an incomplete configuration state; refresh the VM in SCVMM and retry."
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
            [void]$adapterResolutionWarnings.Add("[$VmName] Default VLAN $Vlan mapping is ambiguous. Selected='$defaultSelected'; Candidates='$defaultCandidates'. First deterministic candidate selected.")
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
                    "[$VmName] Adapter #$($adapterIndex + 1) fallback mapping used.`n" +
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
                    "[$VmName] Adapter #$($adapterIndex + 1) fallback mapping used.`n" +
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
                    [void]$adapterResolutionWarnings.Add("[$VmName] Adapter #$($adapterIndex + 1): SCVMM returned 00:00:00:00:00:00, forcing static MAC from VMware ($sourceStaticMac).")
                }
            }

            Set-SCVirtualNetworkAdapter @setAdapterParameters | Out-Null
            $mappedAdapters++
        }

        if ($mappedAdapters -eq 0) {
            throw "No virtual network adapter could be mapped to a VLAN."
        }

        # Integration Services configuration
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
            } -ArgumentList @(
        $Name,
        $ServerName,
        $Vlan,
        $Config.SCVMM.Network.LogicalSwitchName,
        $Config.SCVMM.Network.PortClassificationName,
        $SourceRemark,
        $AdapterVlanMappings,
        @($allowedVmNetworkNames),
        @($allowedVmSubnetNames),
        $inventoryCacheTtlMinutes,
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

    return $networkResult
}