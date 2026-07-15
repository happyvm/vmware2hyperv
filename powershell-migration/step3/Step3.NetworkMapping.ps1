<#
.SYNOPSIS
    Pure network adapter mapping planner — no SCVMM/VMware dependency.

.DESCRIPTION
    Step3.NetworkMapping.ps1 contains the pure function Get-AdapterMappingPlan,
    extracted from step3-MigrateVM.ps1 (lines ~856-1006). It takes source
    (VMware) and target (Hyper-V) adapter lists and produces a deterministic
    mapping plan using three passes:

    1) Exact MAC address match
    2) Fallback by remaining adapter index order
    3) Default VLAN fallback for any still-unmatched target adapters

    This function is pure: no side effects, no module dependencies. Fully
    testable with Pester without mocking SCVMM or VMware cmdlets.

.NOTES
    Part of the BEA-261 refactoring: step3-MigrateVM.ps1 decomposition.
    Ref: doc/refactoring-step3.md §5 — "Extraction de la logique pure".
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Pure helpers — also defined in step3-MigrateVM.ps1 (lines 694-720).
# Duplicated here to keep Step3.NetworkMapping.ps1 self-contained and
# testable without dot-sourcing the main migration script.
# ---------------------------------------------------------------------------

function ConvertTo-NormalizedMacAddress {
    <#
    .SYNOPSIS
        Normalize a MAC address string to uppercase hex without separators.
    .EXAMPLE
        ConvertTo-NormalizedMacAddress -Value '00:50:56:aa:bb:cc'
        # Returns '005056AABBCC'
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
        Test whether a MAC address normalizes to all zeros (e.g. 00:00:00:00:00:00).
    #>
    param(
        [AllowNull()]
        [string]$Value
    )

    $normalized = ConvertTo-NormalizedMacAddress -Value $Value
    return ($normalized -and $normalized -eq '000000000000')
}

# ---------------------------------------------------------------------------
# Core pure function
# ---------------------------------------------------------------------------

function Get-AdapterMappingPlan {
    <#
    .SYNOPSIS
        Build a deterministic mapping plan from source (VMware) to target (Hyper-V) adapters.

    .DESCRIPTION
        Three-pass resolution:
        1. Exact MAC match — preserved MAC addresses from VMware are matched
           against Hyper-V NIC MACs.
        2. Index fallback — remaining unmatched adapters are paired by their
           positional order.
        3. Default VLAN — any target adapter still unmatched gets the default
           VLAN assignment.

        This function is PURE: no SCVMM/VMware calls, no side effects. Inputs
        are plain objects/arrays; output is a predictable plan.

    .PARAMETER TargetAdapters
        Array of target Hyper-V adapters. Each entry must have:
        - Index (int): position in the Hyper-V NIC list
        - MacAddress (string): raw MAC address (any format)

    .PARAMETER SourceAdapters
        Array of source VMware adapters. Each entry must have:
        - MacAddress (string): raw MAC address
        - (Optional) NetworkName, VlanId — carried through for reference

    .PARAMETER DefaultVlan
        VLAN ID used as fallback when no mapping is found. Not used in the
        plan output itself (the caller resolves VLAN→VMNetwork), but determines
        whether an adapter is tagged as 'default' resolution.

    .EXAMPLE
        $targetAdapters = @(
            @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
            @{ Index = 1; MacAddress = '00:50:56:DD:EE:FF' }
        )
        $sourceAdapters = @(
            @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-1816'; VlanId = '1816' },
            @{ MacAddress = '00:50:56:11:22:33'; NetworkName = 'dvPG-100';  VlanId = '100' }
        )
        Get-AdapterMappingPlan -TargetAdapters $targetAdapters -SourceAdapters $sourceAdapters

        # Adapter 0: MAC match → source[0], resolution='mac'
        # Adapter 1: no MAC match → index fallback → source[1], resolution='index'

    .OUTPUTS
        Array of [pscustomobject] with properties:
        - TargetIndex (int)
        - SourceIndex (int or $null for default-only)
        - SourceMacAddress (string, normalized)
        - SourceNetworkName (string or $null)
        - SourceVlanId (string or $null)
        - Resolution (string): 'mac', 'index', or 'default'
    #>

    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$TargetAdapters,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SourceAdapters,

        [Parameter()]
        [string]$DefaultVlan
    )

    # -----------------------------------------------------------------------
    # Normalize inputs
    # -----------------------------------------------------------------------

    # Build a clean list of target adapters with normalized MACs
    $targets = [System.Collections.Generic.List[pscustomobject]]::new()
    for ($i = 0; $i -lt $TargetAdapters.Count; $i++) {
        # Normalize hashtable inputs to [pscustomobject] for consistent property access
        $adapter = if ($TargetAdapters[$i] -is [hashtable]) {
            [pscustomobject]$TargetAdapters[$i]
        } else {
            $TargetAdapters[$i]
        }
        $mac = if ($adapter.PSObject.Properties['MacAddress']) {
            ConvertTo-NormalizedMacAddress -Value ([string]$adapter.MacAddress)
        } else {
            $null
        }

        $adapterIndex = if ($adapter.PSObject.Properties['Index'] -and $adapter.Index -is [int]) { $adapter.Index } else { $i }

        $targets.Add([pscustomobject]@{
            OriginalIndex = $i
            Index         = $adapterIndex
            MacAddress    = $mac
            IsZeroMac     = Test-IsZeroMacAddress -Value ([string]$adapter.MacAddress)
        })
    }

    # Build a clean list of source adapters with normalized MACs
    $sources = [System.Collections.Generic.List[pscustomobject]]::new()
    for ($i = 0; $i -lt $SourceAdapters.Count; $i++) {
        $adapter = if ($SourceAdapters[$i] -is [hashtable]) {
            [pscustomobject]$SourceAdapters[$i]
        } else {
            $SourceAdapters[$i]
        }
        $mac = if ($adapter.PSObject.Properties['MacAddress']) {
            ConvertTo-NormalizedMacAddress -Value ([string]$adapter.MacAddress)
        } else {
            $null
        }

        $sources.Add([pscustomobject]@{
            OriginalIndex = $i
            MacAddress    = $mac
            NetworkName   = if ($adapter.PSObject.Properties['NetworkName']) { [string]$adapter.NetworkName } else { $null }
            VlanId        = if ($adapter.PSObject.Properties['VlanId'])        { [string]$adapter.VlanId        } else { $null }
        })
    }

    # -----------------------------------------------------------------------
    # Pass 1: Exact MAC address match
    # -----------------------------------------------------------------------

    $usedSourceIndexes = [System.Collections.Generic.HashSet[int]]::new()
    $macMatchPlan = @{}  # key = target original index, value = source object

    for ($targetIdx = 0; $targetIdx -lt $targets.Count; $targetIdx++) {
        $target = $targets[$targetIdx]

        # Skip targets without a valid MAC or with zero MAC
        if (-not $target.MacAddress -or $target.IsZeroMac) {
            continue
        }

        for ($sourceIdx = 0; $sourceIdx -lt $sources.Count; $sourceIdx++) {
            if ($usedSourceIndexes.Contains($sourceIdx)) {
                continue
            }

            $source = $sources[$sourceIdx]
            if ($source.MacAddress -and $source.MacAddress -eq $target.MacAddress) {
                $macMatchPlan[$target.OriginalIndex] = $source
                [void]$usedSourceIndexes.Add($sourceIdx)
                break
            }
        }
    }

    # -----------------------------------------------------------------------
    # Pass 2: Index-order fallback for unmatched adapters
    # -----------------------------------------------------------------------

    # Collect still-unmatched target indexes (in order)
    $unmatchedTargetIndexes = [System.Collections.Generic.List[int]]::new()
    for ($targetIdx = 0; $targetIdx -lt $targets.Count; $targetIdx++) {
        if (-not $macMatchPlan.ContainsKey($targets[$targetIdx].OriginalIndex)) {
            $unmatchedTargetIndexes.Add($targets[$targetIdx].OriginalIndex)
        }
    }

    # Collect still-unused source indexes (in order)
    $unusedSourceIndexes = [System.Collections.Generic.List[int]]::new()
    for ($sourceIdx = 0; $sourceIdx -lt $sources.Count; $sourceIdx++) {
        if (-not $usedSourceIndexes.Contains($sourceIdx)) {
            $unusedSourceIndexes.Add($sourceIdx)
        }
    }

    $indexFallbackPlan = @{}  # key = target original index, value = source object
    $fallbackPairCount = [Math]::Min($unmatchedTargetIndexes.Count, $unusedSourceIndexes.Count)

    for ($i = 0; $i -lt $fallbackPairCount; $i++) {
        $targetOrigIdx = $unmatchedTargetIndexes[$i]
        $sourceIdx = $unusedSourceIndexes[$i]
        $indexFallbackPlan[$targetOrigIdx] = $sources[$sourceIdx]
        [void]$usedSourceIndexes.Add($sourceIdx)
    }

    # -----------------------------------------------------------------------
    # Build the final mapping plan
    # -----------------------------------------------------------------------

    $plan = [System.Collections.Generic.List[pscustomobject]]::new()

    for ($targetIdx = 0; $targetIdx -lt $targets.Count; $targetIdx++) {
        $targetOrigIdx = $targets[$targetIdx].OriginalIndex
        $resolution = 'default'
        $matchedSource = $null

        if ($macMatchPlan.ContainsKey($targetOrigIdx)) {
            $matchedSource = $macMatchPlan[$targetOrigIdx]
            $resolution = 'mac'
        } elseif ($indexFallbackPlan.ContainsKey($targetOrigIdx)) {
            $matchedSource = $indexFallbackPlan[$targetOrigIdx]
            $resolution = 'index'
        }

        $plan.Add([pscustomobject]@{
            TargetIndex       = $targets[$targetIdx].Index
            SourceIndex       = if ($matchedSource) { $matchedSource.OriginalIndex } else { $null }
            SourceMacAddress  = if ($matchedSource) { $matchedSource.MacAddress } else { $null }
            SourceNetworkName = if ($matchedSource) { $matchedSource.NetworkName } else { $null }
            SourceVlanId      = if ($matchedSource) { $matchedSource.VlanId } else { $null }
            Resolution        = $resolution
            TargetMacAddress  = $targets[$targetIdx].MacAddress
            IsZeroMac         = $targets[$targetIdx].IsZeroMac
        })
    }

    # Comma operator: without it an empty plan unrolls to $null on return and
    # the caller's .Count would throw under StrictMode.
    return ,$plan.ToArray()
}