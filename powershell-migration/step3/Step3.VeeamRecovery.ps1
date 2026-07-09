# Step3.VeeamRecovery.ps1
# Veeam recovery helper functions for step 3 migration.
# Dot-source this file inside an Invoke-VeeamCommand scriptblock or before
# using the functions locally on a Veeam server.

Set-StrictMode -Version Latest

function Find-VmRestoreSession {
    <#
    .SYNOPSIS
    Finds the most recent Veeam restore session for a given VM using bounded name matching.

    .DESCRIPTION
    Uses a bounded regex pattern to avoid false positives when VM names share prefixes
    (e.g., WEB1 vs WEB10). Matches exact VM name, VMName-migrationhyp suffix, or the
    bounded pattern `^{VMName}($|[^\w-])`.
    Returns the most recently created restore session, or $null if none found.

    .PARAMETER VmName
    The VM name to search for.

    .PARAMETER RestoreSessions
    Optional pre-fetched array of VBRRestoreSession objects. When omitted the function
    calls Get-VBRRestoreSession internally. Pass a pre-fetched array to avoid duplicate
    Veeam cmdlet calls in batch loops.

    .OUTPUTS
    VBRRestoreSession or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $false)]
        [object[]]$RestoreSessions
    )

    # Bounded pattern: ^{name}($|[^\w-])
    # Prevents WEB1 from matching WEB10, while still allowing WEB1-migrationhyp.
    $vmSessionPattern = '^{0}($|[^\w-])' -f [regex]::Escape($VmName)

    if ($PSBoundParameters.ContainsKey('RestoreSessions')) {
        $sessions = $RestoreSessions
    }
    else {
        $sessions = @(Get-VBRRestoreSession)
    }

    $restoreSession = $sessions |
        Where-Object {
            $_.Name -eq $VmName -or
            $_.Name -eq "$VmName-migrationhyp" -or
            $_.Name -match $vmSessionPattern
        } |
        Sort-Object -Property CreationTime -Descending |
        Select-Object -First 1

    return $restoreSession
}
