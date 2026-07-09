<#
.SYNOPSIS
    Veeam Recovery helper functions for step3 migration.

.DESCRIPTION
    Contains Veeam-related helper functions shared across step3 scripts.
    Uses scriptblock string composition so functions execute inside the
    WinPS compat session where Veeam live objects are available.

.NOTES
    Part of the vmware2hyperv migration toolkit — step3 refactoring.
    Requires lib.ps1 to be dot-sourced first (for Invoke-VeeamCommand).
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Find-VmRestoreSession function definition (string — injected into scriptblocks)
# ---------------------------------------------------------------------------
# This function MUST run inside the WinPS compat session (via Invoke-VeeamCommand)
# because it returns live Veeam objects whose .Logger property would break if
# deserialized across session boundaries.
$script:FindVmRestoreSessionFuncDef = @'
function Find-VmRestoreSession {
    <#
    .SYNOPSIS
        Finds the most recent Veeam restore session for a given VM.
    .DESCRIPTION
        Uses exact name match, a migration-hyp suffix variant, and a bounded
        regex pattern to avoid false matches with VMs sharing a prefix
        (e.g. WEB1 vs WEB10). Must run inside the WinPS compat session.
    .PARAMETER Vm
        Name of the VM whose restore session should be located.
    .OUTPUTS
        The live Veeam restore session object, or $null if none found.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Vm
    )

    # Exact names plus a bounded pattern ("VM (Instant Recovery)"…): a plain
    # "$Vm*" wildcard would also match another batch VM whose name shares the
    # prefix (e.g. WEB1 vs WEB10) and follow the wrong session.
    $vmSessionPattern = '^{0}($|[^\w-])' -f [regex]::Escape($Vm)
    Get-VBRRestoreSession |
        Where-Object { $_.Name -eq $Vm -or $_.Name -eq "$Vm-migrationhyp" -or $_.Name -match $vmSessionPattern } |
        Sort-Object -Property CreationTime -Descending |
        Select-Object -First 1
}
'@

# ---------------------------------------------------------------------------
# New-VeeamScriptBlock — compose a scriptblock that includes Find-VmRestoreSession
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Creates a scriptblock with Find-VmRestoreSession pre-loaded for use with Invoke-VeeamCommand.

.DESCRIPTION
    Takes raw script text and composes it with the Find-VmRestoreSession function
    definition so the function is available inside the WinPS compat session.
    Eliminates inline duplication of the restore session query across call sites.

.PARAMETER ScriptText
    Raw PowerShell script text (without Find-VmRestoreSession definition).
    Can use Find-VmRestoreSession -Vm <name> directly.

.EXAMPLE
    $sb = New-VeeamScriptBlock @'
    param($Vm)
    $session = Find-VmRestoreSession -Vm $Vm
    # ... use $session ...
'@
    Invoke-VeeamCommand -ScriptBlock $sb -ArgumentList @($VMName)
#>
function New-VeeamScriptBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptText
    )

    return [scriptblock]::Create("$FindVmRestoreSessionFuncDef`n$ScriptText")
}