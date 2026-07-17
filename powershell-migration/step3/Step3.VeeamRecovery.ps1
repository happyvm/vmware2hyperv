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

Set-StrictMode -Version Latest

# ============================================================================
# Find-VmRestoreSession
# Bounded-name restore session lookup to avoid prefix collisions
# (e.g. WEB1 matching WEB10's session).
# ============================================================================
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
    $WaitingTimeoutSeconds      = if ($Context.ContainsKey('WaitingTimeoutSeconds'))      { $Context.WaitingTimeoutSeconds      } else { [int](Get-MigrationConfigValue -Config $Context.Config -Path 'Timeouts.InstantRecovery.WaitingSeconds' -Default 1800) }
    $WaitingPollIntervalSeconds = if ($Context.ContainsKey('WaitingPollIntervalSeconds')) { $Context.WaitingPollIntervalSeconds } else { 15 }
    $LogFile                    = $Context.LogFile

    Write-MigrationLog "[$VMName] Waiting for Instant Recovery mount..." -LogFile $LogFile

    # $elapsed only sums the sleep intervals; the Veeam queries themselves can take
    # a long time, so the loop is also bounded by wall-clock time.
    $waitStartedAt = Get-Date
    $elapsed = 0
    do {
        $waitCheck = Invoke-VeeamCommand -ScriptBlock {
            param($Vm)

            $instantRecoverySession = Get-VBRInstantRecovery |
                Where-Object { $_.VMName -eq $Vm } |
                Select-Object -First 1

            # Property guard: Get-VBRInstantRecovery / Get-VBRRestoreSession can return objects
            # that don't (yet) expose a 'State' property (e.g. while the session is still being
            # created), and StrictMode throws PropertyNotFoundException on direct access.
            $irState = if ($instantRecoverySession -and $instantRecoverySession.PSObject.Properties['State']) { [string]$instantRecoverySession.State } else { $null }
            $currentState = if ($irState) { $irState } else { "<none>" }
            $restoreSessionState = "<none>"
            $waitingDetected = $false
            $detectionSource = $null

            if ($irState -eq "WaitingForUserAction") {
                $waitingDetected = $true
                $detectionSource = "instant-recovery-state"
            }

            if (-not $waitingDetected) {
                # Same bounded matching used by Find-VmRestoreSession: never follow a
                # session belonging to another VM whose name shares this VM's prefix.
                $vmSessionPattern = '^{0}($|[^\w-])' -f [regex]::Escape($Vm)
                $restoreSession = Get-VBRRestoreSession |
                    Where-Object {
                        $_.Name -eq $Vm -or
                        $_.Name -eq "$Vm-migrationhyp" -or
                        $_.Name -match $vmSessionPattern
                    } |
                    Sort-Object -Property CreationTime -Descending |
                    Select-Object -First 1

                if ($restoreSession) {
                    if ($restoreSession.PSObject.Properties['State']) {
                        $restoreSessionState = [string]$restoreSession.State
                    }
                    $sessionLog = $restoreSession.Logger.GetLog()
                    $logRecords = @()
                    # Property guard: on this Veeam module, GetLog() only exposes
                    # 'UpdatedRecords' — 'Records' doesn't exist on the object, and
                    # StrictMode throws PropertyNotFoundException on direct access.
                    if ($sessionLog.PSObject.Properties['UpdatedRecords'] -and $sessionLog.UpdatedRecords) {
                        $logRecords += $sessionLog.UpdatedRecords
                    }
                    if ($sessionLog.PSObject.Properties['Records'] -and $sessionLog.Records) {
                        $logRecords += $sessionLog.Records
                    }

                    # Property guard: record objects on this Veeam module don't all expose
                    # the same fields (e.g. 'Message' can be absent) — read only what exists.
                    $logText = ($logRecords | ForEach-Object {
                        $record = $_
                        @('Title', 'Description', 'Message', 'Text') | ForEach-Object {
                            if ($record.PSObject.Properties[$_]) { $record.$_ }
                        }
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
        } -ArgumentList @($VMName)

        Write-MigrationLog "[$VMName] Current states: InstantRecovery='$($waitCheck.CurrentState)', RestoreSession='$($waitCheck.RestoreSessionState)' (elapsed: ${elapsed}s)." -LogFile $LogFile

        if ($waitCheck.WaitingDetected) {
            Write-MigrationLog "[$VMName] Instant Recovery in waiting mode (source=$($waitCheck.DetectionSource))." -Level SUCCESS -LogFile $LogFile
            return $waitCheck
        }

        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $elapsed += $WaitingPollIntervalSeconds
    } while ($elapsed -lt $WaitingTimeoutSeconds -and ((Get-Date) - $waitStartedAt).TotalSeconds -lt $WaitingTimeoutSeconds)

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
    $WaitingTimeoutSeconds      = if ($Context.ContainsKey('WaitingTimeoutSeconds'))      { $Context.WaitingTimeoutSeconds      } else { [int](Get-MigrationConfigValue -Config $Context.Config -Path 'Timeouts.InstantRecovery.WaitingSeconds' -Default 1800) }
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

    # Same wall-clock bound as Wait-InstantRecoveryUserAction: $elapsed alone
    # ignores the duration of the Veeam queries.
    $waitStartedAt = Get-Date
    $elapsed = 0
    do {
        $check = Invoke-VeeamCommand -ScriptBlock {
            param($Vm)

            $vmSessionPattern = '^{0}($|[^\w-])' -f [regex]::Escape($Vm)
            $restoreSession = Get-VBRRestoreSession |
                Where-Object {
                    $_.Name -eq $Vm -or
                    $_.Name -eq "$Vm-migrationhyp" -or
                    $_.Name -match $vmSessionPattern
                } |
                Sort-Object -Property CreationTime -Descending |
                Select-Object -First 1

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
                State  = if ($restoreSession.PSObject.Properties['State']) { [string]$restoreSession.State } else { $null }
                Result = if ($restoreSession.PSObject.Properties['Result']) { [string]$restoreSession.Result } else { $null }
            }
        } -ArgumentList @($VMName)

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
    } while ($elapsed -lt $WaitingTimeoutSeconds -and ((Get-Date) - $waitStartedAt).TotalSeconds -lt $WaitingTimeoutSeconds)

    throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for restore session completion."
}
