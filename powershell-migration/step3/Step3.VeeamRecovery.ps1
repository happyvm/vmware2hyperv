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

# ============================================================================
# Start-VeeamInstantRecovery
# Validate Veeam prerequisites and start the Instant Recovery mount.
# ============================================================================
function Start-VeeamInstantRecovery {
    <#
    .SYNOPSIS
        Start the Veeam Instant Recovery mount for a single VM.

    .DESCRIPTION
        Validates that SCVMM is registered in Veeam and the backup job exists,
        then calls Start-VBRHvInstantRecovery. Does NOT wait for the mount to
        become ready — call Wait-VeeamInstantRecoveryMount afterwards.

    .PARAMETER BackupJobName
        Name of the Veeam backup job. Mandatory.

    .PARAMETER VMName
        Target VM name. Mandatory.

    .PARAMETER HyperVHost
        Destination Hyper-V host. Mandatory.

    .PARAMETER ClusterStorage
        Cluster shared volume path (e.g. C:\ClusterStorage\Volume1). Mandatory.

    .PARAMETER SCVMMServer
        SCVMM server name for Veeam validation. Mandatory.

    .PARAMETER LogFile
        Path to the log file.

    .EXAMPLE
        Start-VeeamInstantRecovery -BackupJobName "Backup-HypMig-lot-118" `
            -VMName "SRV-WEB01" -HyperVHost "hv01" `
            -ClusterStorage "C:\ClusterStorage\Volume1" `
            -SCVMMServer "scvmm01" -LogFile $LogFile
    #>

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupJobName,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$HyperVHost,

        [Parameter(Mandatory = $true)]
        [string]$ClusterStorage,

        [Parameter(Mandatory = $true)]
        [string]$SCVMMServer,

        [string]$LogFile
    )

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
# Wait-VeeamInstantRecoveryMount
# Poll until the Instant Recovery mount reaches WaitingForUserAction.
# ============================================================================
function Wait-VeeamInstantRecoveryMount {
    <#
    .SYNOPSIS
        Wait for the Instant Recovery mount to reach the WaitingForUserAction state.

    .DESCRIPTION
        Polls Get-VBRInstantRecovery and Get-VBRRestoreSession logs until the
        mount is ready. Detects WaitingForUserAction either through the IR state
        or through the restore session log text.

    .PARAMETER VMName
        Target VM name. Mandatory.

    .PARAMETER WaitingTimeoutSeconds
        Maximum wait time in seconds. Default: 1800.

    .PARAMETER WaitingPollIntervalSeconds
        Poll interval in seconds. Default: 15.

    .PARAMETER LogFile
        Path to the log file.

    .EXAMPLE
        Wait-VeeamInstantRecoveryMount -VMName "SRV-WEB01" -LogFile $LogFile
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [int]$WaitingTimeoutSeconds = 1800,

        [int]$WaitingPollIntervalSeconds = 15,

        [string]$LogFile
    )

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
# Complete-VeeamInstantRecovery
# Commit/finalize the Instant Recovery session.
# ============================================================================
function Complete-VeeamInstantRecovery {
    <#
    .SYNOPSIS
        Finalize (commit) the Veeam Instant Recovery session.

    .DESCRIPTION
        Verifies the IR session and SCVMM VM exist, then calls
        Start-VBRHvInstantRecoveryMigration to commit. Does NOT wait for the
        restore session to complete — call Wait-VeeamRestoreSession afterwards.

    .PARAMETER VMName
        Target VM name. Mandatory.

    .PARAMETER VMMServerName
        SCVMM server name for VM validation. Mandatory.

    .PARAMETER LogFile
        Path to the log file.

    .EXAMPLE
        Complete-VeeamInstantRecovery -VMName "SRV-WEB01" `
            -VMMServerName "scvmm01" -LogFile $LogFile
    #>

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$VMMServerName,

        [string]$LogFile
    )

    if (-not $PSCmdlet.ShouldProcess($VMName, "Finalize Veeam Instant Recovery")) {
        return
    }

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
}

# ============================================================================
# Wait-VeeamRestoreSession
# Poll the restore session until Success, Warning, or Failed.
# ============================================================================
function Wait-VeeamRestoreSession {
    <#
    .SYNOPSIS
        Wait for the Veeam restore session to reach a terminal state.

    .DESCRIPTION
        Polls Get-VBRRestoreSession using bounded-name matching until the session
        reaches Success, Warning, or Failed. Returns the final session state.

    .PARAMETER VMName
        Target VM name. Mandatory.

    .PARAMETER WaitingTimeoutSeconds
        Maximum wait time in seconds. Default: 1800.

    .PARAMETER WaitingPollIntervalSeconds
        Poll interval in seconds. Default: 15.

    .PARAMETER LogFile
        Path to the log file.

    .OUTPUTS
        [PSCustomObject] with Found, Name, State, Result properties.

    .EXAMPLE
        $result = Wait-VeeamRestoreSession -VMName "SRV-WEB01" -LogFile $LogFile
        if ($result.Result -eq "Success") { Write-Host "Done" }
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [int]$WaitingTimeoutSeconds = 1800,

        [int]$WaitingPollIntervalSeconds = 15,

        [string]$LogFile
    )

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

# ============================================================================
# Invoke-VeeamRecoveryPhase
# Orchestrator: runs the full Veeam IR start → wait → finalize → wait cycle.
# ============================================================================
function Invoke-VeeamRecoveryPhase {
    <#
    .SYNOPSIS
        Run the complete Veeam Instant Recovery lifecycle for a single VM.

    .DESCRIPTION
        Orchestrates the full Veeam recovery flow: start IR mount, wait for
        WaitingForUserAction, finalize (commit), and wait for restore session
        completion. Respects skip flags for partial reruns.

    .PARAMETER BackupJobName
        Name of the Veeam backup job. Mandatory.

    .PARAMETER VMName
        Target VM name. Mandatory.

    .PARAMETER HyperVHost
        Primary Hyper-V host. Mandatory.

    .PARAMETER ClusterStorage
        Cluster shared volume path. Mandatory.

    .PARAMETER SCVMMServer
        SCVMM server name. Mandatory.

    .PARAMETER VMMServerName
        SCVMM server name as returned after connection (for finalization validation).

    .PARAMETER SkipInstantRecoveryStart
        Skip starting the Instant Recovery mount (assumes already mounted).

    .PARAMETER SkipInstantRecoveryFinalization
        Skip finalizing (committing) the IR session.

    .PARAMETER WaitingTimeoutSeconds
        Maximum wait time per phase. Default: 1800.

    .PARAMETER WaitingPollIntervalSeconds
        Poll interval per phase. Default: 15.

    .PARAMETER LogFile
        Path to the log file.

    .EXAMPLE
        Invoke-VeeamRecoveryPhase -BackupJobName "Backup-HypMig-lot-118" `
            -VMName "SRV-WEB01" -HyperVHost "hv01" `
            -ClusterStorage "C:\ClusterStorage\Volume1" `
            -SCVMMServer "scvmm01" -VMMServerName "scvmm01" `
            -LogFile $LogFile
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupJobName,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$HyperVHost,

        [Parameter(Mandatory = $true)]
        [string]$ClusterStorage,

        [Parameter(Mandatory = $true)]
        [string]$SCVMMServer,

        [Parameter(Mandatory = $true)]
        [string]$VMMServerName,

        [switch]$SkipInstantRecoveryStart,

        [switch]$SkipInstantRecoveryFinalization,

        [int]$WaitingTimeoutSeconds = 1800,

        [int]$WaitingPollIntervalSeconds = 15,

        [string]$LogFile
    )

    # ── Phase 1: Start ──

    if (-not $SkipInstantRecoveryStart) {
        try {
            Start-VeeamInstantRecovery -BackupJobName $BackupJobName `
                -VMName $VMName `
                -HyperVHost $HyperVHost `
                -ClusterStorage $ClusterStorage `
                -SCVMMServer $SCVMMServer `
                -LogFile $LogFile

            Wait-VeeamInstantRecoveryMount -VMName $VMName `
                -WaitingTimeoutSeconds $WaitingTimeoutSeconds `
                -WaitingPollIntervalSeconds $WaitingPollIntervalSeconds `
                -LogFile $LogFile
        } catch {
            Write-MigrationLog "[$VMName] Instant Recovery start/wait error: $_" -Level ERROR -LogFile $LogFile
            throw
        }
    } else {
        Write-MigrationLog "[$VMName] SkipInstantRecoveryStart enabled: skipping Instant Recovery start/wait phase." -Level WARNING -LogFile $LogFile
    }

    # ── Phase 2: Finalization ──

    if (-not $SkipInstantRecoveryFinalization) {
        try {
            Complete-VeeamInstantRecovery -VMName $VMName `
                -VMMServerName $VMMServerName `
                -LogFile $LogFile

            Wait-VeeamRestoreSession -VMName $VMName `
                -WaitingTimeoutSeconds $WaitingTimeoutSeconds `
                -WaitingPollIntervalSeconds $WaitingPollIntervalSeconds `
                -LogFile $LogFile
        } catch {
            Write-MigrationLog "[$VMName] Instant Recovery finalization error: $_" -Level ERROR -LogFile $LogFile
            throw
        }
    } else {
        Write-MigrationLog "[$VMName] SkipInstantRecoveryFinalization enabled: skipping Instant Recovery commit/finalization phase." -Level WARNING -LogFile $LogFile
    }
}