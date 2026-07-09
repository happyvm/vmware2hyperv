<#
.SYNOPSIS
    SCVMM session functions — pushed into the WinPS compat session by Initialize-ScvmmSessionFunction.

.DESCRIPTION
    Function-only file (no inline execution). Loaded once into the WinPS compat session
    at worker startup; functions persist for the worker lifetime, avoiding re-parse on
    every Invoke-SCVMMCommand call.

    Functions defined here run inside the WinPS compat session where SCVMM cmdlets
    are available. They return simple data (strings, hashtables, arrays) — never live
    SCVMM objects — because results cross the session boundary as deserialized copies.

    Functions:
    - Get-CachedScvmmServer          Cached SCVMM server connection (new)
    - Get-ScvmmInventoryCache        VM network inventory cache (extracted from original scriptblock)
    - Resolve-ScvmmVlanMapping       VLAN → VMNetwork/VMSubnet resolution
    - Get-ScvmmNetworkAdapters       Adapter enumeration with retry
    - ConvertTo-NormalizedMacAddress MAC format normalization
    - Test-IsZeroMacAddress          Zero MAC detection
    - Convert-ToScvmmStaticMacAddress Static MAC address conversion

.NOTES
    Part of the vmware2hyperv migration toolkit — step3 refactoring §3.
    Design constraint: all function outputs MUST be simple data types.
    Live SCVMM objects cannot cross the WinPS compat session boundary.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Get-CachedScvmmServer — cached SCVMM server connection (lives in $script: scope)
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Returns a cached SCVMM server connection, creating one if necessary.

.DESCRIPTION
    Maintains a connection cache in $script:CachedVmmServer keyed by server name.
    On first call, connects to the SCVMM server via Get-SCVMMServer. Subsequent
    calls reuse the cached connection. The cache lives in the WinPS compat session
    $script: scope, so it persists across Invoke-SCVMMCommand calls within the
    same worker lifetime.

.PARAMETER ComputerName
    SCVMM server name. Mandatory.

.EXAMPLE
    $server = Get-CachedScvmmServer -ComputerName "scvmm01.contoso.com"
#>
function Get-CachedScvmmServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    if (-not $script:CachedVmmServer) {
        $script:CachedVmmServer = @{}
    }

    if (-not $script:CachedVmmServer.ContainsKey($ComputerName)) {
        Write-Verbose "Get-CachedScvmmServer: connecting to '$ComputerName'"
        $server = Get-SCVMMServer -ComputerName $ComputerName
        if (-not $server) {
            throw "Unable to connect to SCVMM server '$ComputerName'."
        }
        $script:CachedVmmServer[$ComputerName] = $server
    } else {
        Write-Verbose "Get-CachedScvmmServer: using cached connection to '$ComputerName'"
    }

    return $script:CachedVmmServer[$ComputerName]
}

# ---------------------------------------------------------------------------
# Get-ScvmmInventoryCache — VM network inventory cache with logical switch filtering
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Builds or returns a cached inventory of SCVMM VM networks, subnets, and port
    classifications, optionally filtered by logical switch and allow-lists.

.DESCRIPTION
    On first call (or when cache TTL expires), fetches all VMNetworks, VMSubnets,
    and port classifications from the SCVMM server. Builds multiple lookup indices
    (by VLAN, by name, by real VLAN ID from SubnetVLans). Optionally filters to
    only networks/subnets belonging to a specific logical switch's logical networks.

    The cache is stored in $script:ScvmmInventoryCacheByServer keyed by server name.

.PARAMETER Server
    SCVMM server object. Mandatory.

.PARAMETER CacheTtlMinutes
    Cache validity duration in minutes. Default: 10.

.PARAMETER ForceRefresh
    Bypass the cache and force a fresh inventory fetch.

.PARAMETER WarningSink
    A List[string] to collect non-fatal warnings during inventory discovery.

.PARAMETER AllowedVmNetworkNames
    Optional allow-list of VMNetwork names to include.

.PARAMETER AllowedVmSubnetNames
    Optional allow-list of VMSubnet names to include.

.PARAMETER LogicalSwitch
    Optional logical switch name; when provided, only VMNetworks and VMSubnets
    belonging to this switch's logical networks are included.

.EXAMPLE
    $cache = Get-ScvmmInventoryCache -Server $vmmServer -LogicalSwitch "MyLogicalSwitch"
#>
function Get-ScvmmInventoryCache {
    param(
        [Parameter(Mandatory = $true)]
        $Server,

        [int]$CacheTtlMinutes = 10,
        [switch]$ForceRefresh,
        $WarningSink,
        [object[]]$AllowedVmNetworkNames,
        [object[]]$AllowedVmSubnetNames,
        [string]$LogicalSwitch
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

# ---------------------------------------------------------------------------
# Resolve-ScvmmVlanMapping — resolve a VLAN key to a VMNetwork/VMSubnet pair
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Resolves a VLAN identifier to the corresponding SCVMM VMNetwork and VMSubnet.

.DESCRIPTION
    Two-phase resolution: first checks real SCVMM VLAN IDs (SubnetVLans), then
    falls back to parsing VLAN digits from network/subnet names and descriptions.
    Returns an object with VMNetwork, VMSubnet, Vlan, Ambiguous flag, and
    ResolutionMode metadata.

.PARAMETER InventoryCache
    An inventory cache object produced by Get-ScvmmInventoryCache. Mandatory.

.PARAMETER VlanKey
    VLAN identifier string to resolve. Mandatory.

.EXAMPLE
    $mapping = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey "100"
#>
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

# ---------------------------------------------------------------------------
# ConvertTo-NormalizedMacAddress — strip delimiters, uppercase, 12-char hex string
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Normalizes a MAC address string by removing all non-hex characters and
    converting to uppercase.

.PARAMETER Value
    Raw MAC address string. Null/whitespace returns $null.

.EXAMPLE
    ConvertTo-NormalizedMacAddress -Value "00:11:22:aa:bb:cc"
    # Returns "001122AABBCC"
#>
function ConvertTo-NormalizedMacAddress {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return ($Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

# ---------------------------------------------------------------------------
# Test-IsZeroMacAddress — detect 00:00:00:00:00:00
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Returns $true if the MAC address is all zeros.

.PARAMETER Value
    MAC address string. Null/whitespace returns $false.

.EXAMPLE
    Test-IsZeroMacAddress -Value "00:00:00:00:00:00"
    # Returns $true
#>
function Test-IsZeroMacAddress {
    param([AllowNull()][string]$Value)

    $normalized = ConvertTo-NormalizedMacAddress -Value $Value
    return ($normalized -and $normalized -eq '000000000000')
}

# ---------------------------------------------------------------------------
# Convert-ToScvmmStaticMacAddress — format as XX-XX-XX-XX-XX-XX
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Converts a MAC address to SCVMM static MAC format (dash-separated pairs).

.PARAMETER Value
    Raw MAC address string. Must be 12 hex chars after normalization.

.EXAMPLE
    Convert-ToScvmmStaticMacAddress -Value "00:11:22:aa:bb:cc"
    # Returns "00-11-22-AA-BB-CC"
#>
function Convert-ToScvmmStaticMacAddress {
    param([AllowNull()][string]$Value)

    $normalized = ConvertTo-NormalizedMacAddress -Value $Value
    if (-not $normalized -or $normalized.Length -ne 12) {
        return $null
    }

    return (($normalized -split '(.{2})' | Where-Object { $_ }) -join '-')
}

# ---------------------------------------------------------------------------
# Get-ScvmmNetworkAdapters — enumerate virtual network adapters with fallback
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Retrieves SCVMM virtual network adapters for a VM, with an optional global
    fallback when direct enumeration returns nothing.

.DESCRIPTION
    First attempts Get-SCVirtualNetworkAdapter -VM (requires a live, non-deserialized
    VM object). If that returns nothing and AllowGlobalFallback is set, enumerates
    all adapters on the server and filters by VM ID/Name.

.PARAMETER CurrentVm
    The SCVMM virtual machine object.

.PARAMETER CurrentServer
    The SCVMM server object.

.PARAMETER CurrentVmName
    The VM name for fallback matching.

.PARAMETER AllowGlobalFallback
    When set, falls back to enumerating all adapters on the server and filtering
    by VM identity.

.EXAMPLE
    $adapters = Get-ScvmmNetworkAdapters -CurrentVm $vm -CurrentServer $server -CurrentVmName "SRV-WEB01"
#>
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
