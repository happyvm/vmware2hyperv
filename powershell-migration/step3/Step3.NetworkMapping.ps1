<#
.SYNOPSIS
<<<<<<< HEAD
    Pure adapter mapping plan — no SCVMM dependencies, fully testable.

.DESCRIPTION
    Function-only file (no inline execution). Contains the core MAC matching
    and index-fallback algorithm that determines which source VMware adapter
    maps to which target Hyper-V adapter.

    This is a PURE function: inputs and outputs are simple data (hashtables,
    strings, arrays). No SCVMM cmdlets, no logging, no side effects. Designed
    to be testable with Pester without mocking.

    Functions:
    - Get-AdapterMappingPlan    Two-pass matching: MAC exact → index fallback → default VLAN

.NOTES
    Part of the vmware2hyperv migration toolkit — step3 refactoring §3.
    All MAC addresses passed to this function MUST be pre-normalized
    (uppercase, no delimiters) via ConvertTo-NormalizedMacAddress.
    Zero MACs (000000000000) must be pre-filtered or passed as $null.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Get-AdapterMappingPlan — two-pass adapter matching algorithm
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Produces a mapping plan that assigns source (VMware) adapters to target
    (Hyper-V) adapters using a two-pass algorithm.

.DESCRIPTION
    Pass 1: Exact MAC address match. If a target adapter's MAC matches exactly
    one unused source adapter, they are paired with Resolution 'mac'.

    Pass 2: Index-based fallback. Remaining unmatched target adapters are paired
    with remaining unmatched source adapters in order, first to first, second to
    second, etc. Resolution 'index'.

    Pass 3: Any target adapter still unmatched gets Resolution 'default'
    (VLAN fallback, handled by the caller).

    The function is deterministic: source adapters are consumed in array order
    and each is used at most once.

.PARAMETER TargetAdapters
    Array of target adapter descriptors. Each entry should be a hashtable or
    pscustomobject with:
    - Index (int): position in the target adapter list
    - MacAddress (string or $null): pre-normalized MAC (uppercase hex, no delimiters)
    Optional properties are ignored.

.PARAMETER SourceAdapters
    Array of source adapter descriptors. Each entry should be a hashtable or
    pscustomobject with:
    - MacAddress (string or $null): pre-normalized MAC (uppercase hex, no delimiters)
    - VlanId (string): source VLAN identifier
    - NetworkName (string): source network name
    All three properties are preserved in the output plan.

.PARAMETER DefaultVlan
    Default VLAN identifier (string). Not used in matching logic but recorded
    in the plan metadata for consumers that need it.

.EXAMPLE
    $targets = @(
        @{ Index = 0; MacAddress = "001122334455" },
        @{ Index = 1; MacAddress = "AABBCCDDEEFF" }
    )
    $sources = @(
        @{ MacAddress = "AABBCCDDEEFF"; VlanId = "100"; NetworkName = "VM Network" },
        @{ MacAddress = "001122334455"; VlanId = "200"; NetworkName = "DMZ" }
    )
    $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan "0"
    # Plan: [0]="001122334455"->source[1] via mac, [1]="AABBCCDDEEFF"->source[0] via mac

.EXAMPLE
    # More targets than sources: extras get 'default' resolution
    $targets = @(@{Index=0;MacAddress="AA"}, @{Index=1;MacAddress="BB"}, @{Index=2;MacAddress="CC"})
    $sources = @(@{MacAddress="AA";VlanId="10";NetworkName="Net1"})
    $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan "0"
    # [0]=mac, [1]=default, [2]=default

.OUTPUTS
    Array of pscustomobject:
    - TargetIndex (int): position in the target adapter list
    - SourceAdapter (object or $null): matching source adapter entry, or $null for default
    - Resolution (string): 'mac', 'index', or 'default'
#>
function Get-AdapterMappingPlan {
    [CmdletBinding()]
=======
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
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$TargetAdapters,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SourceAdapters,

<<<<<<< HEAD
        [Parameter(Mandatory = $true)]
        [string]$DefaultVlan
    )

    $macMatches = @{}       # target index (int) -> source adapter
    $indexFallbacks = @{}   # target index (int) -> source adapter
    $usedSourceIndexes = New-Object 'System.Collections.Generic.HashSet[int]'

    # ── Pass 1: exact MAC match ──────────────────────────────────────────
    for ($targetIdx = 0; $targetIdx -lt $TargetAdapters.Count; $targetIdx++) {
        $targetMac = $TargetAdapters[$targetIdx].MacAddress

        # Skip null/empty/zero MACs — they cannot match
        if ([string]::IsNullOrWhiteSpace($targetMac) -or $targetMac -eq '000000000000') {
            continue
        }

        for ($sourceIdx = 0; $sourceIdx -lt $SourceAdapters.Count; $sourceIdx++) {
=======
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
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
            if ($usedSourceIndexes.Contains($sourceIdx)) {
                continue
            }

<<<<<<< HEAD
            $sourceMac = $SourceAdapters[$sourceIdx].MacAddress
            if ([string]::IsNullOrWhiteSpace($sourceMac)) {
                continue
            }

            if ($sourceMac -eq $targetMac) {
                $macMatches[$targetIdx] = $SourceAdapters[$sourceIdx]
=======
            $source = $sources[$sourceIdx]
            if ($source.MacAddress -and $source.MacAddress -eq $target.MacAddress) {
                $macMatchPlan[$target.OriginalIndex] = $source
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
                [void]$usedSourceIndexes.Add($sourceIdx)
                break
            }
        }
    }

<<<<<<< HEAD
    # ── Pass 2: index-based fallback ─────────────────────────────────────
    $remainingTargetIndexes = @()
    for ($targetIdx = 0; $targetIdx -lt $TargetAdapters.Count; $targetIdx++) {
        if (-not $macMatches.ContainsKey($targetIdx)) {
            $remainingTargetIndexes += $targetIdx
        }
    }

    $remainingSourceIndexes = @()
    for ($sourceIdx = 0; $sourceIdx -lt $SourceAdapters.Count; $sourceIdx++) {
        if (-not $usedSourceIndexes.Contains($sourceIdx)) {
            $remainingSourceIndexes += $sourceIdx
        }
    }

    $fallbackPairs = [Math]::Min($remainingTargetIndexes.Count, $remainingSourceIndexes.Count)
    for ($i = 0; $i -lt $fallbackPairs; $i++) {
        $targetIdx = $remainingTargetIndexes[$i]
        $sourceIdx = $remainingSourceIndexes[$i]
        $indexFallbacks[$targetIdx] = $SourceAdapters[$sourceIdx]
        [void]$usedSourceIndexes.Add($sourceIdx)
    }

    # ── Build result plan ────────────────────────────────────────────────
    $plan = New-Object System.Collections.ArrayList
    for ($targetIdx = 0; $targetIdx -lt $TargetAdapters.Count; $targetIdx++) {
        $targetIndexValue = $TargetAdapters[$targetIdx].Index
        if ($null -eq $targetIndexValue) {
            $targetIndexValue = $targetIdx
        }
        if ($macMatches.ContainsKey($targetIdx)) {
            [void]$plan.Add([pscustomobject]@{
                TargetIndex   = $targetIndexValue
                SourceAdapter = $macMatches[$targetIdx]
                Resolution    = 'mac'
            })
        } elseif ($indexFallbacks.ContainsKey($targetIdx)) {
            [void]$plan.Add([pscustomobject]@{
                TargetIndex   = $targetIndexValue
                SourceAdapter = $indexFallbacks[$targetIdx]
                Resolution    = 'index'
            })
        } else {
            [void]$plan.Add([pscustomobject]@{
                TargetIndex   = $targetIndexValue
                SourceAdapter = $null
                Resolution    = 'default'
            })
        }
    }

    # PowerShell unrolls empty collections to $null; comma operator prevents this
    return , @($plan)
}
=======
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

    return $plan.ToArray()
}
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
