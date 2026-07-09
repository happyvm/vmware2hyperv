<<<<<<< HEAD
<#
.SYNOPSIS
    Veeam Recovery helper functions for step3 migration.

.DESCRIPTION
    Contains all Veeam-related functions for the Instant Recovery phase:
    - Find-VmRestoreSession (string-injected into WinPS compat session)
    - New-VeeamScriptBlock (string-based composition)
    - Start-VeeamInstantRecovery (start IR mount)
    - Wait-VeeamInstantRecoveryMount (poll until WaitingForUserAction)
    - Complete-VeeamInstantRecovery (commit/finalize IR session)
    - Wait-VeeamRestoreSession (poll restore session to terminal state)
    - Invoke-VeeamRecoveryPhase (full orchestration lifecycle)

.NOTES
    Part of the vmware2hyperv migration toolkit — step3 refactoring.
    Requires lib.ps1 to be dot-sourced first (for Invoke-VeeamCommand,
    Write-MigrationLog, Invoke-SCVMMCommand).
#>

=======
# Step3.VeeamRecovery.ps1
# Veeam recovery helper functions for step 3 migration.
# Dot-source this file inside an Invoke-VeeamCommand scriptblock or before
# using the functions locally on a Veeam server.
#
# Functions:
#   Find-VmRestoreSession         Bounded-name restore session lookup
#   Start-VmInstantRecovery       Start VBR Instant Recovery mount (Context-based)
#   Wait-InstantRecoveryUserAction Poll until mount reaches WaitingForUserAction (Context-based)
#   Complete-InstantRecovery      Commit IR session + wait for restore completion (Context-based)

>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
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
<<<<<<< HEAD
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
=======
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
>>>>>>> 85c6c4b45aca08b82d1ed0ef7c219683bdad1aba
}

# ============================================================================
# Start-VmInstantRecovery
# Start the Veeam Instant Recovery mount for a single VM.
# Context-based wrapper around the Veeam IR start logic.
# ============================================================================
function Start-VmInstantRecovery {
    <#
    .SYNOPSIS
        Start the Veeam Instant Recovery mount for a single VM.

    .DESCRIPTION
        Validates that SCVMM is registered in Veeam and the backup job exists,
        then calls Start-VBRHvInstantRecovery. Does NOT wait for the mount to
        become ready — call Wait-InstantRecoveryUserAction afterwards.

    .PARAMETER Context
        Hashtable with keys: VMName, BackupJobName, HyperVHost, ClusterStorage,
        SCVMMServer, LogFile.

    .PARAMETER Result
        Task result object (not modified by this function; phase tracking is
        handled by the orchestrator via Invoke-Phase).

    .EXAMPLE
        Start-VmInstantRecovery -Context $context -Result $result
    #>

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result
    )

    $VMName          = $Context.VMName
    $BackupJobName   = $Context.BackupJobName
    $HyperVHost      = $Context.HyperVHost
    $ClusterStorage  = $Context.ClusterStorage
    $SCVMMServer     = $Context.SCVMMServer
    $LogFile         = $Context.LogFile

    if (-not $PSCmdlet.ShouldProcess($VMName, "Start Veeam Instant Recovery")) {
        return
    }

    Write-MigrationLog "[$VMName] Checking SCVMM in Veeam..." -LogFile $LogFile

    $VBRSCVMM = Invoke-VeeamCommand -ScriptBlock {
        param($ScvmmServerName)
        Get-VBRServer | Where-Object { $_.Name -eq $ScvmmServerName -and $_.Type -eq "Scvmm" } |
            Select-Object -First 1 -Property Name, Type
    } -ArgumentList @($SCVMMServer)

    if (-not $VBRSCVMM) {
        $msg = "[$VMName] SCVMM $SCVMMServer is not registered in Veeam."
        Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
        throw $msg
    }

    $Backup = Invoke-VeeamCommand -ScriptBlock {
        param($JobName)
        Get-VBRBackup | Where-Object { $_.Name -eq $JobName } |
            Select-Object -First 1 -Property Name, Id
    } -ArgumentList @($BackupJobName)

    if (-not $Backup) {
        $msg = "[$VMName] Backup job '$BackupJobName' not found in Veeam."
        Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
        throw $msg
    }

    try {
        Invoke-VeeamCommand -ScriptBlock {
            param(
                [string]$JobName,
                [string]$Vm,
                [string]$DestinationHost,
                [string]$DestinationPath
            )

            $backup = Get-VBRBackup | Where-Object { $_.Name -eq $JobName } | Select-Object -First 1
            if (-not $backup) {
                throw "Backup job '$JobName' not found in Veeam."
            }

            $restorePoint = Get-VBRRestorePoint -Backup $backup |
                Where-Object { $_.Name -eq $Vm } |
                Sort-Object -Property CreationTime -Descending |
                Select-Object -First 1

            if (-not $restorePoint) {
                throw "No restore point found for VM '$Vm' in job '$JobName'."
            }

            Start-VBRHvInstantRecovery -RestorePoint $restorePoint `
                -Server $DestinationHost `
                -Path $DestinationPath `
                -PowerUp $false `
                -NICsEnabled $true `
                -PreserveMACs $true `
                -PreserveVmID $true | Out-Null

            return $true
        } -ArgumentList @($BackupJobName, $VMName, $HyperVHost, "$ClusterStorage\$VMName")
    } catch {
        Write-MigrationLog "[$VMName] Instant Recovery preparation failed: $_" -Level ERROR -LogFile $LogFile
        throw
    }

    Write-MigrationLog "[$VMName] Instant Recovery started." -Level SUCCESS -LogFile $LogFile
}

# ============================================================================
# Wait-InstantRecoveryUserAction
# Poll until the Instant Recovery mount reaches WaitingForUserAction.
# Context-based wrapper around the Veeam IR polling logic.
# ============================================================================
function Wait-InstantRecoveryUserAction {
    <#
    .SYNOPSIS
        Wait for the Instant Recovery mount to reach the WaitingForUserAction state.

    .DESCRIPTION
        Polls Get-VBRInstantRecovery and Get-VBRRestoreSession logs until the
        mount is ready. Detects WaitingForUserAction either through the IR state
        or through the restore session log text.

    .PARAMETER Context
        Hashtable with keys: VMName, WaitingTimeoutSeconds (default 1800),
        WaitingPollIntervalSeconds (default 15), LogFile.

    .PARAMETER Result
        Task result object (not modified by this function; phase tracking is
        handled by the orchestrator via Invoke-Phase).

    .EXAMPLE
        Wait-InstantRecoveryUserAction -Context $context -Result $result
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result
    )

    $VMName                     = $Context.VMName
    $WaitingTimeoutSeconds      = if ($Context.ContainsKey('WaitingTimeoutSeconds'))      { $Context.WaitingTimeoutSeconds      } else { 1800 }
    $WaitingPollIntervalSeconds = if ($Context.ContainsKey('WaitingPollIntervalSeconds')) { $Context.WaitingPollIntervalSeconds } else { 15 }
    $LogFile                    = $Context.LogFile

    Write-MigrationLog "[$VMName] Waiting for Instant Recovery mount..." -LogFile $LogFile

    $elapsed = 0
    do {
        $waitCheck = Invoke-VeeamCommand -ScriptBlock (New-VeeamScriptBlock @'
            param($Vm)

            $instantRecoverySession = Get-VBRInstantRecovery |
                Where-Object { $_.VMName -eq $Vm } |
                Select-Object -First 1

            $currentState = if ($instantRecoverySession) { [string]$instantRecoverySession.State } else { "<none>" }
            $restoreSessionState = "<none>"
            $waitingDetected = $false
            $detectionSource = $null

            if ($instantRecoverySession -and $instantRecoverySession.State -eq "WaitingForUserAction") {
                $waitingDetected = $true
                $detectionSource = "instant-recovery-state"
            }

            if (-not $waitingDetected) {
                $restoreSession = Find-VmRestoreSession -Vm $Vm

                if ($restoreSession) {
                    $restoreSessionState = [string]$restoreSession.State
                    $sessionLog = $restoreSession.Logger.GetLog()
                    $logRecords = @()
                    if ($sessionLog.UpdatedRecords) { $logRecords += $sessionLog.UpdatedRecords }
                    if ($sessionLog.Records)        { $logRecords += $sessionLog.Records }

                    $logText = ($logRecords | ForEach-Object {
                        @($_.Title, $_.Description, $_.Message, $_.Text)
                    } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"

                    if ($logText -match "Waiting for user action") {
                        $waitingDetected = $true
                        $detectionSource = "restore-session-log"
                    }
                }
            }

            [PSCustomObject]@{
                WaitingDetected     = $waitingDetected
                CurrentState        = $currentState
                RestoreSessionState = $restoreSessionState
                DetectionSource     = $detectionSource
            }
'@) -ArgumentList @($VMName)

        Write-MigrationLog "[$VMName] Current states: InstantRecovery='$($waitCheck.CurrentState)', RestoreSession='$($waitCheck.RestoreSessionState)' (elapsed: ${elapsed}s)." -LogFile $LogFile

        if ($waitCheck.WaitingDetected) {
            Write-MigrationLog "[$VMName] Instant Recovery in waiting mode (source=$($waitCheck.DetectionSource))." -Level SUCCESS -LogFile $LogFile
            return $waitCheck
        }

        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $elapsed += $WaitingPollIntervalSeconds
    } while ($elapsed -lt $WaitingTimeoutSeconds)

    throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for WaitingForUserAction."
}

# ============================================================================
# Complete-InstantRecovery
# Commit (finalize) the Instant Recovery session and wait for restore completion.
# Context-based wrapper combining Complete-VeeamInstantRecovery + Wait-VeeamRestoreSession.
# ============================================================================
function Complete-InstantRecovery {
    <#
    .SYNOPSIS
        Finalize the Veeam Instant Recovery session and wait for the restore to complete.

    .DESCRIPTION
        Verifies the IR session and SCVMM VM exist, calls Start-VBRHvInstantRecoveryMigration
        to commit, then polls the restore session until it reaches Success, Warning, or Failed.

    .PARAMETER Context
        Hashtable with keys: VMName, VMMServerName, WaitingTimeoutSeconds (default 1800),
        WaitingPollIntervalSeconds (default 15), LogFile.

    .PARAMETER Result
        Task result object (not modified by this function; phase tracking is
        handled by the orchestrator via Invoke-Phase).

    .EXAMPLE
        Complete-InstantRecovery -Context $context -Result $result
    #>

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Result
    )

    $VMName                     = $Context.VMName
    $VMMServerName              = $Context.VMMServerName
    $WaitingTimeoutSeconds      = if ($Context.ContainsKey('WaitingTimeoutSeconds'))      { $Context.WaitingTimeoutSeconds      } else { 1800 }
    $WaitingPollIntervalSeconds = if ($Context.ContainsKey('WaitingPollIntervalSeconds')) { $Context.WaitingPollIntervalSeconds } else { 15 }
    $LogFile                    = $Context.LogFile

    if (-not $PSCmdlet.ShouldProcess($VMName, "Finalize Veeam Instant Recovery")) {
        return
    }

    # ── Step 1: Validate IR session ────────────────────────────────────────

    $IRSession = Invoke-VeeamCommand -ScriptBlock {
        param($Vm)
        Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } |
            Select-Object -First 1 -Property VMName, State
    } -ArgumentList @($VMName)

    if (-not $IRSession) {
        $msg = "[$VMName] No active Instant Recovery session."
        Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
        throw $msg
    }

    # ── Step 2: Validate VM in SCVMM ───────────────────────────────────────

    $vmInScvmm = Invoke-SCVMMCommand -ScriptBlock {
        param($Name, $ServerName)
        $server = Get-SCVMMServer -ComputerName $ServerName
        Get-SCVirtualMachine -Name $Name -VMMServer $server
    } -ArgumentList @($VMName, $VMMServerName)

    if (-not $vmInScvmm) {
        $msg = "[$VMName] VM missing from SCVMM, finalization impossible."
        Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
        throw $msg
    }

    # ── Step 3: Commit the IR session ──────────────────────────────────────

    Write-MigrationLog "[$VMName] Finalizing Instant Recovery..." -LogFile $LogFile

    try {
        Invoke-VeeamCommand -ScriptBlock {
            param($Vm)
            $irSession = Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } | Select-Object -First 1
            if (-not $irSession) {
                throw "No active Instant Recovery session for VM '$Vm'."
            }
            Start-VBRHvInstantRecoveryMigration -InstantRecovery $irSession | Out-Null
        } -ArgumentList @($VMName)

        Write-MigrationLog "[$VMName] Finalization completed." -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-MigrationLog "[$VMName] Finalization error: $_" -Level ERROR -LogFile $LogFile
        throw
    }

    # ── Step 4: Wait for restore session to reach terminal state ───────────

    Write-MigrationLog "[$VMName] Waiting for restore session to complete..." -LogFile $LogFile

    $elapsed = 0
    do {
        $check = Invoke-VeeamCommand -ScriptBlock (New-VeeamScriptBlock @'
            param($Vm)

            $restoreSession = Find-VmRestoreSession -Vm $Vm

            if (-not $restoreSession) {
                return [PSCustomObject]@{
                    Found  = $false
                    Name   = $null
                    State  = $null
                    Result = $null
                }
            }

            [PSCustomObject]@{
                Found  = $true
                Name   = [string]$restoreSession.Name
                State  = [string]$restoreSession.State
                Result = [string]$restoreSession.Result
            }
'@) -ArgumentList @($VMName)

        if (-not $check.Found) {
            Write-MigrationLog "[$VMName] Restore session not yet visible (elapsed: ${elapsed}s)." -Level WARNING -LogFile $LogFile
        } else {
            Write-MigrationLog "[$VMName] Restore session '$($check.Name)' status: State='$($check.State)', Result='$($check.Result)' (elapsed: ${elapsed}s)." -LogFile $LogFile

            if ($check.Result -eq "Success") {
                Write-MigrationLog "[$VMName] VM restored permanently; ready for next phase." -Level SUCCESS -LogFile $LogFile
                return $check
            }

            if ($check.Result -eq "Warning") {
                Write-MigrationLog "[$VMName] Restore session '$($check.Name)' ended with result 'Warning'. Continuing but this may indicate a degraded state." -Level WARNING -LogFile $LogFile
                return $check
            }

            if ($check.Result -eq "Failed") {
                throw "Restore session '$($check.Name)' ended with result 'Failed'."
            }
        }

        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $elapsed += $WaitingPollIntervalSeconds
    } while ($elapsed -lt $WaitingTimeoutSeconds)

    throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for restore session completion."
}