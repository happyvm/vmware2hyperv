<#
.SYNOPSIS
<<<<<<< HEAD
    Structured task result helpers for step3 migration phases.

.DESCRIPTION
    Replaces the fragile log-grep pattern (Get-NetworkConfigurationState in
    worker-step3.ps1) with a structured JSON result file written by the
    migration phases themselves. Each phase records its outcome, and the
    worker reads a single structured file instead of parsing log text.

    Functions:
    - New-Step3TaskResult    Create a new result container with context
    - Set-Step3PhaseResult   Record a phase outcome
    - Write-Step3TaskResult  Persist the result as JSON next to the VM log

.NOTES
    Part of the vmware2hyperv migration toolkit — step3 refactoring.
#>

Set-StrictMode -Version Latest

# ============================================================================
# New-Step3TaskResult
# Create a new structured result container for a single VM migration.
# ============================================================================
function New-Step3TaskResult {
    <#
    .SYNOPSIS
        Create a new step3 task result container.

    .DESCRIPTION
        Initializes a [PSCustomObject] with context metadata and empty phase
        records. Phases register their outcomes via Set-Step3PhaseResult.
        The result is persisted via Write-Step3TaskResult.

    .PARAMETER Context
        A [PSCustomObject] or hashtable with context keys: VMName, BackupJobName,
        HyperVHost, HyperVHost2, HyperVCluster, ClusterStorage, SCVMMServer,
        VlanId, AdapterVlanMappings, Config, LogFile.

    .EXAMPLE
        $result = New-Step3TaskResult -Context $context
        Set-Step3PhaseResult -Result $result -Phase "InstantRecoveryStart" -State Success
        Write-Step3TaskResult -Result $result
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )

    $ctx = if ($Context -is [hashtable]) { [PSCustomObject]$Context } else { $Context }

    [PSCustomObject]@{
        VMName         = $ctx.VMName
        StartedAt      = (Get-Date).ToString('o')
        CompletedAt    = $null
        OverallResult  = $null
        Phases         = [ordered]@{}
        Context        = @{
            BackupJobName     = $ctx.BackupJobName
            HyperVHost        = $ctx.HyperVHost
            HyperVHost2       = $ctx.HyperVHost2
            HyperVCluster     = $ctx.HyperVCluster
            ClusterStorage    = $ctx.ClusterStorage
            SCVMMServer       = $ctx.SCVMMServer
            VlanId            = $ctx.VlanId
            AdapterVlanMappings = $ctx.AdapterVlanMappings
        }
    }
}

# ============================================================================
# Set-Step3PhaseResult
# Record a phase outcome in the result container.
# ============================================================================
function Set-Step3PhaseResult {
    <#
    .SYNOPSIS
        Record the outcome of a single step3 migration phase.

    .DESCRIPTION
        Stores the phase name, state (Success/Warning/Failed/Skipped),
        optional detail message, and timestamp in the result container.
        Automatically updates the OverallResult: Failed if any phase fails,
        or Warning if any phase warns (and none failed), or Success.

    .PARAMETER Result
        The result container from New-Step3TaskResult.

    .PARAMETER Phase
        Phase name (e.g. 'InstantRecoveryStart', 'NetworkConfig', 'HA').

    .PARAMETER State
        Phase outcome: Success, Warning, Failed, or Skipped.

    .PARAMETER Detail
        Optional detail message (e.g. error text, warning reason).

    .EXAMPLE
        Set-Step3PhaseResult -Result $result -Phase "NetworkConfig" -State Warning -Detail "Fallback VLAN mapping used"
=======
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
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')]
<<<<<<< HEAD
        [string]$State,

        [string]$Detail
    )

    $Result.Phases[$Phase] = [PSCustomObject]@{
        State     = $State
        Detail    = $Detail
        Timestamp = (Get-Date).ToString('o')
    }

    # Derive overall result: Failed > Warning > Success
    $allStates = $Result.Phases.Values | ForEach-Object { $_.State }
    if ('Failed' -in $allStates) {
        $Result.OverallResult = 'Failed'
    } elseif ('Warning' -in $allStates) {
        $Result.OverallResult = 'Warning'
    } else {
        $Result.OverallResult = 'Success'
    }
}

# ============================================================================
# Write-Step3TaskResult
# Persist the result container as a JSON file next to the VM log.
# ============================================================================
function Write-Step3TaskResult {
    <#
    .SYNOPSIS
        Write the step3 task result to a JSON file.

    .DESCRIPTION
        Saves the result container as a JSON file alongside the VM log.
        The file is named {VMName}.step3-result.json and placed in the same
        directory as the VM log. The worker reads this file instead of
        grepping the log for network configuration state.

    .PARAMETER Result
        The result container from New-Step3TaskResult.

    .PARAMETER LogFile
        Path to the VM log file. The result JSON is written next to it.

    .EXAMPLE
        Write-Step3TaskResult -Result $result -LogFile $LogFile
=======
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
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result,

        [Parameter(Mandatory = $true)]
<<<<<<< HEAD
        [string]$LogFile
    )

    $Result.CompletedAt = (Get-Date).ToString('o')

    $logDir = Split-Path -Parent $LogFile
    $vmName = $Result.VMName
    $resultPath = Join-Path $logDir "$vmName.step3-result.json"

    $Result | ConvertTo-Json -Depth 8 | Set-Content -Path $resultPath -Encoding utf8

    Write-Verbose "Task result written to: $resultPath"
    return $resultPath
}

# ============================================================================
# Read-Step3TaskResult
# Read a step3 task result JSON file (for worker consumption).
# ============================================================================
function Read-Step3TaskResult {
    <#
    .SYNOPSIS
        Read a step3 task result JSON file.

    .DESCRIPTION
        Reads the structured result file produced by Write-Step3TaskResult.
        Used by the worker to determine phase outcomes without grepping the
        VM log. Returns $null if the file does not exist.

    .PARAMETER VmLogFile
        Path to the VM log file. The result JSON is expected next to it.

    .EXAMPLE
        $result = Read-Step3TaskResult -VmLogFile $task.VmLogFile
        if ($result.OverallResult -eq 'Success') { ... }
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmLogFile
    )

    $logDir = if ($VmLogFile | Split-Path -Parent) { Split-Path -Parent $VmLogFile } else { '.' }
    # Derive VM name from log filename: {VMName}.log → {VMName}.step3-result.json
    $logBaseName = [System.IO.Path]::GetFileNameWithoutExtension($VmLogFile)
    $resultPath = Join-Path $logDir "$logBaseName.step3-result.json"

    if (-not (Test-Path -Path $resultPath)) {
        return $null
    }

    try {
        return Get-Content -Path $resultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Failed to read step3 result file '$resultPath': $_"
        return $null
    }
}

# Export module members
Export-ModuleMember -Function New-Step3TaskResult, Set-Step3PhaseResult,
    Write-Step3TaskResult, Read-Step3TaskResult
=======
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

    # $Result.Phases is an OrderedDictionary; access by key directly
    $phase = $Result.Phases['NetworkConfiguration']
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
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
