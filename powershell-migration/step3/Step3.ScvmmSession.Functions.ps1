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