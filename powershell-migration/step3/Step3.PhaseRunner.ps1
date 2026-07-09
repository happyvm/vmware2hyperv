<#
.SYNOPSIS
    Phase runner helpers for step3-MigrateVM.ps1 orchestrator.

.DESCRIPTION
    Provides Should-RunPhase (phase gating logic) and Invoke-Phase
    (phase execution wrapper with result tracking). Extracted from
    step3-MigrateVM.ps1 to keep the orchestrator free of inline
    function definitions (BEA-283 / BEA-268).

.NOTES
    Part of vmware2hyperv — BEA-283. PowerShell 7+.
#>

# Step3.PhaseRunner.ps1 — Phase execution helpers for step3 orchestrator
# Load: . "$PSScriptRoot\step3\Step3.PhaseRunner.ps1"

# ---------------------------------------------------------------------------
# Should-RunPhase : determines whether a phase should execute
# ---------------------------------------------------------------------------
function Should-RunPhase {
    <#
    .SYNOPSIS
        Determines whether a named phase should execute based on the
        current skip switches and explicit phase list.

    .DESCRIPTION
        Evaluates the phase-gating rules for step3-MigrateVM.ps1:
          - If $Phases (explicit list) is provided, returns true only
            when the phase name is in that list.
          - Otherwise, consults the Skip* switch parameters.
          - Post-config phases (Network, IntegrationServices, OS, HA,
            LiveMigration, BackupTag) are skipped when
            -SkipNetworkAndPostConfig is set.
          - IRStart and IRCommit are controlled by their respective
            -SkipInstantRecoveryStart / -SkipInstantRecoveryFinalization
            switches.

    .PARAMETER Name
        Phase name (e.g. 'IRStart', 'Network', 'HA', 'BackupTag').

    .EXAMPLE
        if (Should-RunPhase 'Network') { ... }
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Phases) { return $Name -in $Phases }

    switch ($Name) {
        'IRStart'  { return -not $SkipInstantRecoveryStart }
        'IRCommit' { return -not $SkipInstantRecoveryFinalization }
        { $_ -in @('Network', 'IntegrationServices', 'OS', 'HA', 'LiveMigration', 'BackupTag') } {
            return -not $SkipNetworkAndPostConfig
        }
        default { return $true }
    }
}

# ---------------------------------------------------------------------------
# Invoke-Phase : executes a phase with result tracking
# ---------------------------------------------------------------------------
function Invoke-Phase {
    <#
    .SYNOPSIS
        Executes a migration phase and records the outcome in the task
        result object.

    .DESCRIPTION
        Wraps a scriptblock representing a migration phase. If the
        phase is disabled (Should-RunPhase returns $false), it is
        recorded as Skipped. On success, recorded as Success. On
        failure:
          - Non-blocking phases: recorded as Warning, does not throw.
          - Blocking phases (default): recorded as Failed, re-throws.

    .PARAMETER Name
        Phase name used for gating (passed to Should-RunPhase).

    .PARAMETER DisplayName
        Human-readable phase name for the result object.

    .PARAMETER Action
        Scriptblock to execute.

    .PARAMETER NonBlocking
        When $true, failures are recorded as Warning instead of
        Failed and do not stop the migration.

    .EXAMPLE
        Invoke-Phase -Name 'Network' -DisplayName 'NetworkConfiguration' -Action {
            Set-VmNetworkConfiguration -Context $context -Result $result
        }
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [bool]$NonBlocking = $false
    )

    if (-not (Should-RunPhase $Name)) {
        Add-Step3PhaseResult -Result $result -Phase $DisplayName -Status 'Skipped' -Message "Désactivée"
        return
    }
    try {
        & $Action
        Add-Step3PhaseResult -Result $result -Phase $DisplayName -Status 'Success' -Message 'OK'
    } catch {
        $status = if ($NonBlocking) { 'Warning' } else { 'Failed' }
        Add-Step3PhaseResult -Result $result -Phase $DisplayName -Status $status -Message $_.Exception.Message
        if (-not $NonBlocking) { throw }
    }
}
