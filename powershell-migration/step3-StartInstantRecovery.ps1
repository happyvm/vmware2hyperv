<#
.SYNOPSIS
    Bulk Veeam Instant Recovery start with unified progress monitoring.

.DESCRIPTION
    Starts the Instant Recovery of every VM listed in the tasks file. Launches mounts
    asynchronously when the Veeam module supports -RunAsync, or synchronously otherwise.
    Follows every mount session from a single console until each reaches the
    'WaitingForUserAction' state expected by the step3 workers.

.PARAMETER BackupJobName
    Name of the Veeam backup job. Mandatory.

.PARAMETER TasksFile
    Path to the JSON tasks file containing VM entries. Mandatory.

.PARAMETER StartDelaySeconds
    Pause between two Start-VBRHvInstantRecovery calls to smooth Veeam load. Default: 2.

.PARAMETER WaitingTimeoutSeconds
    Maximum time to wait for mounts to reach WaitingForUserAction state. Default: 1800.

.PARAMETER WaitingPollIntervalSeconds
    Interval between mount state polls. Default: 15.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step3-StartInstantRecovery.ps1 -BackupJobName Backup-HypMig-lot-118 -TasksFile D:\Scripts\Logs\ir-tasks.json

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with Veeam.Backup.PowerShell module.
#>

# step3-StartInstantRecovery.ps1 — Bulk Veeam Instant Recovery start with unified progress monitoring
#
# Starts the Instant Recovery of every VM listed in the tasks file (asynchronously when the
# Veeam module supports -RunAsync, otherwise one synchronous start after another), then follows
# every mount session from this single console until each one reaches the "WaitingForUserAction"
# state expected by the step3 workers — no extra PowerShell window needed.
#
# Tasks file: JSON array of objects { VMName, HyperVHost, ClusterStorage }.
#
# Standalone usage:
#   pwsh ./step3-StartInstantRecovery.ps1 -BackupJobName Backup-HypMig-lot-118 -TasksFile D:\Scripts\Logs\ir-tasks.json

param (
    [Parameter(Mandatory = $true)]
    [string]$BackupJobName,

    [Parameter(Mandatory = $true)]
    [string]$TasksFile,

    # Pause between two Start-VBRHvInstantRecovery calls to smooth the load on Veeam/mount hosts
    [int]$StartDelaySeconds = 2,

    [int]$WaitingTimeoutSeconds = 0,
    [int]$WaitingPollIntervalSeconds = 15,
    [string]$LogFile
)

# Explicite (les modules Step3.* dot-sourcés l'activaient déjà de facto).
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib.ps1"
Get-ChildItem "$PSScriptRoot\step3\Step3.*.ps1" |
    Where-Object Name -ne 'Step3.ScvmmSession.Functions.ps1' |
    ForEach-Object { . $_.FullName }
$Config = Import-MigrationConfig -ConfigFile "$PSScriptRoot\config.psd1"
if (-not $PSBoundParameters.ContainsKey('WaitingTimeoutSeconds')) {
    $WaitingTimeoutSeconds = [int](Get-MigrationConfigValue -Config $Config -Path 'Timeouts.InstantRecovery.WaitingSeconds' -Default 1800)
}

if (-not $LogFile) { $LogFile = "$($Config.Paths.LogDir)\step3-ir-start-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" }

Assert-PathPresent -Path $TasksFile -Label "Instant Recovery tasks file" -LogFile $LogFile

$tasks = @(Get-Content -Path $TasksFile -Raw | ConvertFrom-Json) |
    Where-Object { $_.PSObject.Properties['VMName'] -and -not [string]::IsNullOrWhiteSpace([string]$_.VMName) }
$tasks = @($tasks)
if (-not $tasks) {
    $message = "No VM entry found in tasks file '$TasksFile'."
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    throw $message
}

Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback

Write-MigrationLog "Bulk Instant Recovery: starting $($tasks.Count) mount(s) from job '$BackupJobName'." -LogFile $LogFile

# Start every Instant Recovery inside a single Veeam call so live restore point objects
# never cross a WinPS compatibility session boundary (they would arrive deserialized).
$startResults = @(Invoke-VeeamCommand -ScriptBlock {
    param($JobName, $TaskList, $DelaySeconds)

    $TaskList = @($TaskList)

    $backup = Get-VBRBackup | Where-Object { $_.Name -eq $JobName } | Select-Object -First 1
    if (-not $backup) {
        throw "Backup job '$JobName' not found in Veeam."
    }

    $restorePoints = @(Get-VBRRestorePoint -Backup $backup)
    $supportsRunAsync = (Get-Command -Name Start-VBRHvInstantRecovery).Parameters.ContainsKey('RunAsync')

    $taskIndex = 0
    foreach ($task in $TaskList) {
        $taskIndex++
        $vmName = [string]$task.VMName

        $restorePoint = $restorePoints |
            Where-Object { $_.Name -eq $vmName } |
            Sort-Object -Property CreationTime -Descending |
            Select-Object -First 1

        if (-not $restorePoint) {
            [pscustomobject]@{
                VMName   = $vmName
                Started  = $false
                RunAsync = $supportsRunAsync
                Error    = "No restore point found for VM '$vmName' in job '$JobName'."
            }
            continue
        }

        $startError = $null
        try {
            $startParameters = @{
                RestorePoint = $restorePoint
                Server       = [string]$task.HyperVHost
                Path         = "$([string]$task.ClusterStorage)\$vmName"
                PowerUp      = $false
                NICsEnabled  = $true
                PreserveMACs = $true
                PreserveVmID = $true
            }
            if ($supportsRunAsync) {
                $startParameters['RunAsync'] = $true
            }

            Start-VBRHvInstantRecovery @startParameters | Out-Null
        } catch {
            $startError = $_.Exception.Message
        }

        [pscustomobject]@{
            VMName   = $vmName
            Started  = (-not $startError)
            RunAsync = $supportsRunAsync
            Error    = $startError
        }

        if ($DelaySeconds -gt 0 -and $taskIndex -lt $TaskList.Count) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }
} -ArgumentList @($BackupJobName, $tasks, $StartDelaySeconds))

$failedStarts = @($startResults | Where-Object { -not $_.Started })
$startedVmNames = @($startResults | Where-Object { $_.Started } | ForEach-Object { [string]$_.VMName })

foreach ($startResult in $startResults) {
    if ($startResult.Started) {
        $mode = if ($startResult.RunAsync) { "asynchronously" } else { "synchronously (RunAsync unsupported by this Veeam module)" }
        Write-MigrationLog "[$($startResult.VMName)] Instant Recovery started $mode." -Level SUCCESS -LogFile $LogFile
    } else {
        Write-MigrationLog "[$($startResult.VMName)] Instant Recovery start failed: $($startResult.Error)" -Level ERROR -LogFile $LogFile
    }
}

# ── Unified monitoring: one Veeam query per poll covering every pending VM ──

$vmStatuses = @{}
foreach ($vmName in $startedVmNames) {
    $vmStatuses[$vmName] = [pscustomobject]@{
        VMName       = $vmName
        Status       = 'Mounting'
        IrState      = '<none>'
        SessionState = '<none>'
        Progress     = $null
        Source       = $null
    }
}

# $elapsed only sums the sleep intervals; the bulk Veeam polls themselves can take
# a long time, so the timeout is also bounded by wall-clock time.
$monitorStartedAt = Get-Date
$elapsed = 0
while ($true) {
    $pendingNames = @($vmStatuses.Keys | Where-Object { $vmStatuses[$_].Status -eq 'Mounting' } | Sort-Object)
    if (-not $pendingNames) { break }

    if ($elapsed -ge $WaitingTimeoutSeconds -or ((Get-Date) - $monitorStartedAt).TotalSeconds -ge $WaitingTimeoutSeconds) {
        foreach ($vmName in $pendingNames) {
            $vmStatuses[$vmName].Status = 'TimedOut'
            Write-MigrationLog "[$vmName] Timeout of $WaitingTimeoutSeconds seconds reached while waiting for WaitingForUserAction." -Level ERROR -LogFile $LogFile
        }
        break
    }

    $step3VeeamRecoveryPath = "$PSScriptRoot\step3\Step3.VeeamRecovery.ps1"

    $snapshots = @(Invoke-VeeamCommand -ScriptBlock {
        param($VmNames, $VeeamRecoveryPath)

        . $VeeamRecoveryPath

        $irSessions = @(Get-VBRInstantRecovery)
        # Fetch once per poll and pass to Find-VmRestoreSession to avoid one
        # Get-VBRRestoreSession round-trip per VM.
        $restoreSessions = @(Get-VBRRestoreSession)

        foreach ($vmName in @($VmNames)) {
            # Property guard: the dot-sourced module enables StrictMode in this session,
            # and Get-VBRInstantRecovery can return objects without a VMName property.
            $irSession = $irSessions |
                Where-Object { $_.PSObject.Properties['VMName'] -and [string]$_.VMName -eq $vmName } |
                Select-Object -First 1
            # Use the shared bounded-name helper to avoid matching another VM whose
            # name shares a prefix (WEB1 vs WEB10).
            $restoreSession = Find-VmRestoreSession -VmName $vmName -RestoreSessions $restoreSessions

            # Same property guard as VMName above: Get-VBRInstantRecovery / Get-VBRRestoreSession
            # can return objects that don't (yet) expose a 'State' property (e.g. while the
            # session is still being created), and StrictMode throws PropertyNotFoundException
            # on direct access.
            $irState = if ($irSession -and $irSession.PSObject.Properties['State']) { [string]$irSession.State } else { $null }
            $restoreSessionStateRaw = if ($restoreSession -and $restoreSession.PSObject.Properties['State']) { [string]$restoreSession.State } else { $null }
            $restoreSessionResultRaw = if ($restoreSession -and $restoreSession.PSObject.Properties['Result']) { [string]$restoreSession.Result } else { $null }

            $waitingDetected = $false
            $detectionSource = $null
            if ($irState -eq 'WaitingForUserAction') {
                $waitingDetected = $true
                $detectionSource = 'instant-recovery-state'
            }

            $sessionState = if ($restoreSessionStateRaw) { $restoreSessionStateRaw } else { '<none>' }
            $sessionResult = $restoreSessionResultRaw
            $progress = $null
            if ($restoreSession -and $restoreSession.PSObject.Properties['Progress'] -and $null -ne $restoreSession.Progress) {
                $progress = [string]$restoreSession.Progress
            }

            $logReadError = $null
            if (-not $waitingDetected -and $restoreSession) {
                try {
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

                    if ($logText -match 'Waiting for user action') {
                        $waitingDetected = $true
                        $detectionSource = 'restore-session-log'
                    }
                } catch {
                    # This is the only remaining detection path when the IR session exposes
                    # no usable 'State' (common on this Veeam module — see guard above), so a
                    # silently swallowed failure here means the VM sits in "Mounting" until
                    # the timeout even though Veeam already reached WaitingForUserAction.
                    # Surface it instead of Write-Verbose (invisible by default, and easy to
                    # lose across the Invoke-VeeamCommand remoting boundary).
                    $logReadError = $_.Exception.Message
                }
            }

            [pscustomobject]@{
                VMName          = $vmName
                IrState         = if ($irState) { $irState } else { '<none>' }
                SessionState    = $sessionState
                SessionResult   = $sessionResult
                Progress        = $progress
                WaitingDetected = $waitingDetected
                DetectionSource = $detectionSource
                LogReadError    = $logReadError
            }
        }
    } -ArgumentList @([string[]]$pendingNames, $step3VeeamRecoveryPath))

    foreach ($snapshot in $snapshots) {
        $tracked = $vmStatuses[[string]$snapshot.VMName]
        if (-not $tracked) {
            # A snapshot that maps to no tracked VM means the poll payload is malformed
            # (e.g. argument binding regression) — surface it instead of dropping it.
            Write-MigrationLog "Monitoring snapshot ignored: unknown VM '$($snapshot.VMName)' (tracked: $($vmStatuses.Keys -join ', '))." -Level WARNING -LogFile $LogFile
            continue
        }

        $tracked.IrState = [string]$snapshot.IrState
        $tracked.SessionState = [string]$snapshot.SessionState
        $tracked.Progress = $snapshot.Progress

        if ($snapshot.WaitingDetected) {
            $tracked.Status = 'Ready'
            $tracked.Source = [string]$snapshot.DetectionSource
            Write-MigrationLog "[$($snapshot.VMName)] Instant Recovery in waiting mode (source=$($snapshot.DetectionSource), elapsed: ${elapsed}s)." -Level SUCCESS -LogFile $LogFile
        } elseif ([string]$snapshot.SessionResult -eq 'Failed') {
            $tracked.Status = 'Failed'
            Write-MigrationLog "[$($snapshot.VMName)] Restore session ended with result 'Failed' during Instant Recovery mount." -Level ERROR -LogFile $LogFile
        } elseif ($snapshot.PSObject.Properties['LogReadError'] -and $snapshot.LogReadError) {
            Write-MigrationLog "[$($snapshot.VMName)] Unable to read restore session log while checking for 'Waiting for user action': $($snapshot.LogReadError) (elapsed: ${elapsed}s)." -Level WARNING -LogFile $LogFile
        }
    }

    # Progress dashboard: one row per VM, refreshed at every poll in the same console.
    $dashboardRows = foreach ($vmName in @($vmStatuses.Keys | Sort-Object)) {
        $tracked = $vmStatuses[$vmName]
        [pscustomobject]@{
            VM              = $tracked.VMName
            Status          = $tracked.Status
            InstantRecovery = $tracked.IrState
            RestoreSession  = $tracked.SessionState
            Progress        = if ($null -ne $tracked.Progress -and $tracked.Progress -ne '') { "$($tracked.Progress)%" } else { '-' }
        }
    }

    $readyCount = @($vmStatuses.Values | Where-Object { $_.Status -eq 'Ready' }).Count
    Write-Information "Instant Recovery progress: $readyCount/$($vmStatuses.Count) ready (elapsed: ${elapsed}s / timeout: ${WaitingTimeoutSeconds}s)" -InformationAction Continue
    $dashboardRows |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        ForEach-Object { Write-Information $_ -InformationAction Continue }

    $stillPending = @($vmStatuses.Keys | Where-Object { $vmStatuses[$_].Status -eq 'Mounting' })
    if (-not $stillPending) { break }

    Start-Sleep -Seconds $WaitingPollIntervalSeconds
    $elapsed += $WaitingPollIntervalSeconds
}

# ── Final summary ──

$readyVms = @($vmStatuses.Values | Where-Object { $_.Status -eq 'Ready' } | ForEach-Object { $_.VMName })
$failedMountVms = @($vmStatuses.Values | Where-Object { $_.Status -in @('Failed', 'TimedOut') } | ForEach-Object { $_.VMName })
$failedStartVms = @($failedStarts | ForEach-Object { [string]$_.VMName })

Write-MigrationLog "Bulk Instant Recovery summary: ready=$($readyVms.Count), startFailed=$($failedStartVms.Count), mountFailedOrTimedOut=$($failedMountVms.Count)." -LogFile $LogFile

$allFailedVms = @($failedStartVms + $failedMountVms)
if ($allFailedVms) {
    $message = "Instant Recovery failed for: $($allFailedVms -join ', ')."
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    throw $message
}

Write-MigrationLog "All $($readyVms.Count) Instant Recovery session(s) are mounted and waiting for user action." -Level SUCCESS -LogFile $LogFile
