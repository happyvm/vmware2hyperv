<#
.SYNOPSIS
    SCVMM session-side functions — pushed into the WinPS compatibility session.

.DESCRIPTION
    This file contains:
      1. Initialize-ScvmmSessionFunction — PS7-side orchestrator that pushes functions
         into the WinPS compatibility session (called from step3-MigrateVM.ps1).
      2. WinPS 5.1 compatible functions designed to execute inside the compat session
         via Invoke-SCVMMCommand scriptblocks.

    Loading strategy:
      - Dot-sourced locally by step3-MigrateVM.ps1 (defines Initialize-ScvmmSessionFunction
        and all session-side functions in the local PS7 scope for direct mode).
      - Pushed into WinPSCompatSession via Invoke-Command -FilePath (defines the session-side
        functions in the compat session for use by Invoke-SCVMMCommand).

    Cache semantics:
      - $script:ScvmmInventoryCacheByServer : per-server inventory cache (SCVMM VMNetworks,
        VMSubnets, PortClassifications). Indexed by normalized server name.
      - $script:CachedVmmServer            : SCVMM server connection object, reused across
        calls within the same session lifetime.

    Part of the vmware2hyperv migration toolkit — step 3 refactoring.
    See doc/refactoring-step3.md for the full design.

.NOTES
    COMMIT OBLIGATOIRE — BEA-271
#>

Set-StrictMode -Version Latest

# ══════════════════════════════════════════════════════════════════════════════
# Get-ScvmmObjectPropertyValue
# ══════════════════════════════════════════════════════════════════════════════
function Get-ScvmmObjectPropertyValue {
    <#
    .SYNOPSIS
        StrictMode-safe SCVMM object property reader.

    .DESCRIPTION
        SCVMM cmdlets can return objects with different property sets depending
        on module version, object freshness, or serialization through the WinPS
        compatibility session. Direct dot-property access can throw under
        Set-StrictMode -Version Latest when the property is absent. This helper
        safely reads a property by name and returns $null when it is missing.
    #>
    param(
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [string]$Context = 'SCVMM object'
    )

    if (-not $InputObject) {
        Write-Verbose "SCVMM debug: $Context is null while reading '$PropertyName'."
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($property) { return $property.Value }

    $availableProperties = @($InputObject.PSObject.Properties.Name | Sort-Object) -join ', '
    Write-Verbose "SCVMM debug: property '$PropertyName' is missing on $Context ($($InputObject.GetType().FullName)). Available properties: $availableProperties"
    return $null
}

# ══════════════════════════════════════════════════════════════════════════════
# Initialize-ScvmmSessionFunction (PS7 orchestrator — runs LOCALLY, not pushed)
# ══════════════════════════════════════════════════════════════════════════════
function Initialize-ScvmmSessionFunction {
    <#
    .SYNOPSIS
        Pushes SCVMM helper functions into the WinPS compatibility session and
        dot-sources them locally for direct (non-compat) execution.

    .DESCRIPTION
        Option A du document refactoring-step3.md : les fonctions SCVMM sont definies
        une fois dans la session compat WinPS, evitant le re-parse a chaque appel
        Invoke-SCVMMCommand (~780 lignes re-serialisees a chaque appel avant refactoring).

        - Si une session WinPSCompatSession existe : Invoke-Command -FilePath
          definit les fonctions cote WinPS (session distante).
        - Le fichier est aussi dot-source localement pour le mode direct PS7.
        - Avec les workers persistants, les fonctions ne sont parsees qu'une
          fois par worker. Bonus : cache Get-CachedScvmmServer loge dans la session.

    .PARAMETER FunctionFiles
        Array of paths to .ps1 files containing only function definitions
        to push into the compatibility session.

    .EXAMPLE
        Initialize-ScvmmSessionFunction -FunctionFiles @(
            "$PSScriptRoot\step3\Step3.ScvmmSession.Functions.ps1"
        )
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$FunctionFiles
    )

    $compatSession = Get-PSSession -Name 'WinPSCompatSession' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    foreach ($file in $FunctionFiles) {
        if (-not (Test-Path -Path $file -PathType Leaf)) {
            Write-Warning "[Initialize-ScvmmSessionFunction] Function file not found: $file"
            continue
        }

        if ($compatSession) {
            try {
                Invoke-Command -Session $compatSession -FilePath $file -ErrorAction Stop
                Write-Verbose "[Initialize-ScvmmSessionFunction] Pushed '$file' into WinPSCompatSession."
            } catch {
                Write-Error "[Initialize-ScvmmSessionFunction] Failed to push '$file' into WinPSCompatSession: $($_.Exception.Message)"
                throw
            }
        }

        # Dot-source locally for direct (non-compat) execution mode.
        # Already dot-sourced by step3-MigrateVM.ps1, but safe to re-source.
        . $file
        Write-Verbose "[Initialize-ScvmmSessionFunction] Dot-sourced '$file' locally."
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Get-CachedScvmmServer
# ══════════════════════════════════════════════════════════════════════════════
function Get-CachedScvmmServer {
    <#
    .SYNOPSIS
        Returns a cached SCVMM server connection, creating one if needed.

    .DESCRIPTION
        Maintains a script-scoped cache of the SCVMM server connection. The first call
        connects to the specified server and stores the result; subsequent calls return
        the cached object. This avoids paying the SCVMM connection overhead inside every
        Invoke-SCVMMCommand scriptblock (optimisation n°3 in OPTIMISATIONS.md).

        The cache lives in $script:CachedVmmServer and persists for the lifetime of the
        Windows PowerShell compatibility session. Worker persistence means the connection
        is established once per worker, not once per VM migration task.

    .PARAMETER ServerName
        SCVMM server computer name or FQDN.

    .PARAMETER ForceRefresh
        Bypass the cache and establish a fresh connection.

    .EXAMPLE
        $server = Get-CachedScvmmServer -ServerName 'scvmm01.contoso.com'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [switch]$ForceRefresh
    )

    # StrictMode-safe read: this file is dot-sourced into scopes where
    # Set-StrictMode -Version Latest is active (step3 modules), and a bare read of
    # an unset $script: variable would throw "variable cannot be retrieved".
    if (-not (Get-Variable -Name CachedVmmServer -Scope Script -ErrorAction SilentlyContinue)) {
        $script:CachedVmmServer = $null
    }

    if (-not $ForceRefresh -and $script:CachedVmmServer) {
        $cachedName = if ($script:CachedVmmServer.PSObject.Properties['Name'] -and $script:CachedVmmServer.Name) {
            [string]$script:CachedVmmServer.Name
        } elseif ($script:CachedVmmServer.PSObject.Properties['ComputerName']) {
            [string]$script:CachedVmmServer.ComputerName
        } else {
            ''
        }

        if ($cachedName -eq $ServerName) {
            return $script:CachedVmmServer
        }

        # Server name changed — discard old cache
        $script:CachedVmmServer = $null
    }

    $script:CachedVmmServer = Get-SCVMMServer -ComputerName $ServerName
    if (-not $script:CachedVmmServer) {
        throw "SCVMM server '$ServerName' not found."
    }

    return $script:CachedVmmServer
}

# ══════════════════════════════════════════════════════════════════════════════
# Get-ScvmmLogicalSwitchLogicalNetworkIds (helper for Get-ScvmmInventoryCache)
# ══════════════════════════════════════════════════════════════════════════════
function Get-ScvmmLogicalSwitchLogicalNetworkIds {
    <#
    .SYNOPSIS
        Resolves the logical network IDs behind a logical switch.

    .DESCRIPTION
        SCVMM VMNetwork objects do not reference logical switches directly: a VMNetwork
        belongs to a LogicalNetwork, and the logical switch exposes its logical networks
        through the uplink port profiles attached to it. This function resolves that chain
        instead of guessing from object properties.
    #>
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

# ══════════════════════════════════════════════════════════════════════════════
# Get-ScvmmInventoryCache
# ══════════════════════════════════════════════════════════════════════════════
function Get-ScvmmInventoryCache {
    <#
    .SYNOPSIS
        Builds or returns a cached inventory of SCVMM VMNetworks, VMSubnets, and
        PortClassifications for a given SCVMM server.

    .DESCRIPTION
        Enumerates VMNetworks, VMSubnets, and PortClassifications from SCVMM and indexes
        them by VLAN (real SCVMM VLAN IDs first, then name/description digits), by lookup
        name, by ID, and by VMNetwork→VMSubnet relationship.

        Results are cached in $script:ScvmmInventoryCacheByServer with a configurable TTL.
        The cache is server-scoped (keyed by normalized server name) and persists across
        scriptblock invocations within the same WinPS session lifetime.

    .PARAMETER Server
        SCVMM server object (from Get-SCVMMServer or Get-CachedScvmmServer).

    .PARAMETER CacheTtlMinutes
        How long the cache is considered valid. Default: 10 minutes.

    .PARAMETER ForceRefresh
        Bypass the cache and rebuild the inventory.

    .PARAMETER WarningSink
        A [List[string]] to collect non-fatal warnings during inventory discovery.

    .PARAMETER AllowedVmNetworkNames
        Optional whitelist of VMNetwork names to include (case-insensitive).

    .PARAMETER AllowedVmSubnetNames
        Optional whitelist of VMSubnet names to include (case-insensitive).

    .PARAMETER LogicalSwitch
        Optional logical switch name to filter VMNetworks/subnets by logical network membership.

    .EXAMPLE
        $cache = Get-ScvmmInventoryCache -Server $server -CacheTtlMinutes 10
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Server,

        [int]$CacheTtlMinutes = 10,

        [switch]$ForceRefresh,

        $WarningSink,

        [string[]]$AllowedVmNetworkNames = @(),

        [string[]]$AllowedVmSubnetNames = @(),

        [string]$LogicalSwitch
    )

    # StrictMode-safe initialization: same rationale as in Get-CachedScvmmServer —
    # a bare read of the unset $script: variable throws under StrictMode (active in
    # direct mode, where the step3 modules are dot-sourced into a strict scope).
    if (-not (Get-Variable -Name ScvmmInventoryCacheByServer -Scope Script -ErrorAction SilentlyContinue) -or -not $script:ScvmmInventoryCacheByServer) {
        $script:ScvmmInventoryCacheByServer = @{}
    }

    # Property-guarded reads: under StrictMode a bare access on an object
    # lacking Name/ComputerName would throw.
    $serverKey = if ($Server.PSObject.Properties['Name']) { [string]$Server.Name } else { '' }
    if ([string]::IsNullOrWhiteSpace($serverKey) -and $Server.PSObject.Properties['ComputerName']) {
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

# ══════════════════════════════════════════════════════════════════════════════
# Resolve-ScvmmVlanMapping
# ══════════════════════════════════════════════════════════════════════════════
function Resolve-ScvmmVlanMapping {
    <#
    .SYNOPSIS
        Resolves a VLAN key to a VMNetwork/VMSubnet pair.

    .DESCRIPTION
        Two resolution passes:
          1) Real SCVMM VLAN IDs (SubnetVLans[].VLanID) — most reliable.
          2) VLAN digits parsed from names/descriptions — fallback for legacy configs.

        Returns a result object with the selected VMNetwork/VMSubnet, ambiguity info,
        candidate names, and the resolution mode used.

    .PARAMETER InventoryCache
        Cache object from Get-ScvmmInventoryCache.

    .PARAMETER VlanKey
        VLAN identifier to resolve (numeric string, e.g. '42').

    .EXAMPLE
        $mapping = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '42'
    #>
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

    # Outer @(): assigning an if/else expression unrolls an empty array to $null,
    # and the .Count reads below would then throw under StrictMode.
    $matchingNetworks = @(if ($InventoryCache.VMNetworksByVlan.ContainsKey($VlanKey)) {
        @($InventoryCache.VMNetworksByVlan[$VlanKey])
    } else {
        @($InventoryCache.AllVMNetworks | Where-Object { $_.Name -like "*$VlanKey*" -or $_.Description -like "*$VlanKey*" })
    })
    $matchingSubnets = @(if ($InventoryCache.VMSubnetsByVlan.ContainsKey($VlanKey)) {
        @($InventoryCache.VMSubnetsByVlan[$VlanKey])
    } else {
        @($InventoryCache.AllVMSubnets | Where-Object { $_.Name -like "*$VlanKey*" -or $_.Description -like "*$VlanKey*" })
    })

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

# ══════════════════════════════════════════════════════════════════════════════
# MAC address helpers
# ══════════════════════════════════════════════════════════════════════════════

function ConvertTo-NormalizedMacAddress {
    <#
    .SYNOPSIS
        Normalizes a MAC address string by stripping separators and uppercasing.
        Returns null for empty/whitespace input.
    #>
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return ($Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

function Test-IsZeroMacAddress {
    <#
    .SYNOPSIS
        Returns $true if the MAC address is all zeros (00:00:00:00:00:00 or equivalent).
    #>
    param(
        [AllowNull()]
        [string]$Value
    )

    $normalized = ConvertTo-NormalizedMacAddress -Value $Value
    return ($normalized -and $normalized -eq '000000000000')
}

function Convert-ToScvmmStaticMacAddress {
    <#
    .SYNOPSIS
        Formats a normalized MAC address for SCVMM static MAC assignment (XX-XX-XX-XX-XX-XX).
        Returns $null if the input cannot be normalized to 12 hex characters.
    #>
    param(
        [AllowNull()]
        [string]$Value
    )

    $normalized = ConvertTo-NormalizedMacAddress -Value $Value
    if (-not $normalized -or $normalized.Length -ne 12) {
        return $null
    }

    return (($normalized -split '(.{2})' | Where-Object { $_ }) -join '-')
}

# ══════════════════════════════════════════════════════════════════════════════
# Get-ScvmmNetworkAdapters
# ══════════════════════════════════════════════════════════════════════════════
function Get-ScvmmNetworkAdapters {
    <#
    .SYNOPSIS
        Retrieves virtual network adapters for a VM, with a debug fallback.

    .DESCRIPTION
        Primary path: Get-SCVirtualNetworkAdapter -VM (works when the VM object is live).
        Debug fallback (AllowGlobalFallback): enumerates ALL adapters on the server and
        filters by VM ID/name — useful when the VM object is deserialized or incomplete.
    #>
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

# ══════════════════════════════════════════════════════════════════════════════
# Cache scope documentation
# ══════════════════════════════════════════════════════════════════════════════
<#
    $script: scope variables persist for the lifetime of the Windows PowerShell
    compatibility session:
      - $script:ScvmmInventoryCacheByServer : hashtable keyed by normalized server name
      - $script:CachedVmmServer            : last connected SCVMM server object

    With persistent workers, the connection is established once per worker and
    the inventory cache is reused across VM migration tasks until the TTL expires
    or ForceRefresh is requested.
#>
