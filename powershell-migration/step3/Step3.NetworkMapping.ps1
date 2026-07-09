<#
.SYNOPSIS
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
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$TargetAdapters,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SourceAdapters,

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
            if ($usedSourceIndexes.Contains($sourceIdx)) {
                continue
            }

            $sourceMac = $SourceAdapters[$sourceIdx].MacAddress
            if ([string]::IsNullOrWhiteSpace($sourceMac)) {
                continue
            }

            if ($sourceMac -eq $targetMac) {
                $macMatches[$targetIdx] = $SourceAdapters[$sourceIdx]
                [void]$usedSourceIndexes.Add($sourceIdx)
                break
            }
        }
    }

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
