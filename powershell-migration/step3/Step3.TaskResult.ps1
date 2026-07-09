<#
.SYNOPSIS
    Task result tracking for step3 VM migration phases.

.DESCRIPTION
    Provides structured phase-by-phase result tracking for step3-MigrateVM.ps1.
    Each migration phase (Instant Recovery, Network Configuration, HA, LiveMigration,
    etc.) records its outcome (Success/Warning/Failed/Skipped) with a timestamp,
    message, and optional metadata. The full result is serialized as JSON alongside
    the VM log so worker-step3.ps1 can read it instead of grepping the log.

    Replaces the fragile log-grep approach (Get-NetworkConfigurationState) with
    machine-readable phase results.

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+.
    This module is loaded via dot-sourcing from step3-MigrateVM.ps1.
#>

# Step3.TaskResult.ps1 — Phase-by-phase migration result tracking
# Load: . "$PSScriptRoot\step3\Step3.TaskResult.ps1"

# ---------------------------------------------------------------------------
# New-Step3TaskResult : creates a new result object with context
# ---------------------------------------------------------------------------
function New-Step3TaskResult {
    <#
    .SYNOPSIS
        Creates a new structured task result object for a step3 migration.

    .DESCRIPTION
        Initialises a result object that tracks the outcome of each migration
        phase. The caller populates phases via Add-Step3PhaseResult, then
        finalises with Complete-Step3TaskResult and serialises with
        Write-Step3TaskResult.

    .PARAMETER Context
        Hashtable of context information (VMName, VlanId, HyperVHost, etc.)
        that is serialised into the result for traceability.

    .EXAMPLE
        $result = New-Step3TaskResult -Context @{ VMName = 'SRV-WEB01'; VlanId = '100' }
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )

    [PSCustomObject]@{
        Context     = $Context
        Phases      = [ordered]@{}
        StartedAt   = (Get-Date).ToString('o')
        CompletedAt = $null
        Status      = 'Running'
    }
}

# ---------------------------------------------------------------------------
# Add-Step3PhaseResult : records a phase outcome
# ---------------------------------------------------------------------------
function Add-Step3PhaseResult {
    <#
    .SYNOPSIS
        Records the outcome of a single migration phase in the result object.

    .DESCRIPTION
        Appends a phase entry to the result object and automatically updates
        the overall Status:
          - 'Failed' phase → overall Status = 'Failed'
          - 'Warning' phase (unless already Failed) → overall Status = 'CompletedWithWarnings'
          - Otherwise overall Status stays as-is

    .PARAMETER Result
        The task result object created by New-Step3TaskResult.

    .PARAMETER Phase
        Phase name (e.g. 'InstantRecoveryStart', 'NetworkConfiguration',
        'HighAvailability', 'LiveMigration').

    .PARAMETER Status
        Phase outcome: Success, Warning, Failed, or Skipped.

    .PARAMETER Message
        Human-readable description of the phase outcome.

    .PARAMETER Data
        Optional hashtable of structured metadata (e.g. MAC match counts,
        VLAN resolution details, adapter counts).

    .EXAMPLE
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Success' -Message 'Network configured (default VLAN 100)' `
            -Data @{ MacMatchedCount = 2; FallbackCount = 0 }
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')]
        [string]$Status,

        [string]$Message = '',

        [hashtable]$Data = @{}
    )

    $Result.Phases[$Phase] = [PSCustomObject]@{
        Status    = $Status
        Message   = $Message
        Timestamp = (Get-Date).ToString('o')
        Data      = $Data
    }

    # Update overall status based on worst phase outcome
    switch ($Status) {
        'Failed' {
            $Result.Status = 'Failed'
        }
        'Warning' {
            if ($Result.Status -ne 'Failed') {
                $Result.Status = 'CompletedWithWarnings'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Complete-Step3TaskResult : finalises the result object
# ---------------------------------------------------------------------------
function Complete-Step3TaskResult {
    <#
    .SYNOPSIS
        Finalises the task result object.

    .DESCRIPTION
        Sets the CompletedAt timestamp and, if no phase has set the overall
        Status to Failed or CompletedWithWarnings, marks it as Success.

    .PARAMETER Result
        The task result object created by New-Step3TaskResult.

    .EXAMPLE
        Complete-Step3TaskResult -Result $result
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result
    )

    if ($Result.Status -eq 'Running') {
        $Result.Status = 'Success'
    }
    $Result.CompletedAt = (Get-Date).ToString('o')
}

# ---------------------------------------------------------------------------
# Write-Step3TaskResult : serialises the result to JSON on disk
# ---------------------------------------------------------------------------
function Write-Step3TaskResult {
    <#
    .SYNOPSIS
        Writes the task result object as a JSON file.

    .DESCRIPTION
        Serialises the result to a UTF-8 JSON file. By convention the file is
        placed alongside the VM log (e.g. <VmLogFile>.result.json) so that
        worker-step3.ps1 can find and read it.

    .PARAMETER Result
        The task result object.

    .PARAMETER Path
        Output file path. Convention: "{VmLogFile}.result.json".

    .EXAMPLE
        Write-Step3TaskResult -Result $result -Path "D:\Logs\SRV-WEB01.log.result.json"
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $Result | ConvertTo-Json -Depth 10 -Compress:$false |
        Set-Content -Path $Path -Encoding utf8
}

# ---------------------------------------------------------------------------
# Get-Step3NetworkConfigurationState : extracts network state from result
# ---------------------------------------------------------------------------
function Get-Step3NetworkConfigurationState {
    <#
    .SYNOPSIS
        Extracts the network configuration state from a TaskResult object.

    .DESCRIPTION
        Maps the NetworkConfiguration phase status from the TaskResult to the
        canonical NetworkConfigurationState values used by worker-step3.ps1
        and run-migration.ps1:

          NetworkConfiguration Success → 'Configured'
          NetworkConfiguration Warning → 'ConfiguredWithWarning'
          NetworkConfiguration Failed  → 'NotDetected'
          NetworkConfiguration Skipped → 'NotDetected'
          No NetworkConfiguration phase → 'NotDetected'

    .PARAMETER Result
        The task result object (deserialised from JSON).

    .EXAMPLE
        $result = Get-Content 'SRV-WEB01.log.result.json' -Raw | ConvertFrom-Json
        $state = Get-Step3NetworkConfigurationState -Result $result
        # Returns 'Configured', 'ConfiguredWithWarning', or 'NotDetected'
    #>

    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result
    )

    # $Result.Phases may be an OrderedDictionary (in-memory) or a PSCustomObject
    # (deserialised JSON).  OrderedDictionary supports ['key'] but not .Property;
    # PSCustomObject supports .Property but not ['key'].  Branch accordingly.
    $phase = if ($Result.Phases -is [System.Collections.IDictionary]) {
        $Result.Phases['NetworkConfiguration']
    } else {
        $Result.Phases.NetworkConfiguration
    }
    if (-not $phase) {
        return 'NotDetected'
    }

    switch ($phase.Status) {
        'Success' { return 'Configured' }
        'Warning' { return 'ConfiguredWithWarning' }
        'Failed'  { return 'NotDetected' }
        'Skipped' { return 'NotDetected' }
        default   { return 'NotDetected' }
    }
}
