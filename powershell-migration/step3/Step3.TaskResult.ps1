<#
.SYNOPSIS
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
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')]
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
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result,

        [Parameter(Mandatory = $true)]
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