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

    # ALL backups carrying this name, not just the first one Veeam happens to
    # enumerate. Deleting and recreating a job leaves the previous backup behind
    # under the same name, and picking one of the two arbitrarily is how a lot
    # whose restore points exist in the console still reports 'no restore point'.
    $backups = @(Get-VBRBackup | Where-Object { $_.Name -eq $JobName })
    if ($backups.Count -eq 0) {
        throw "Backup job '$JobName' not found in Veeam."
    }

    $restorePoints = @(foreach ($backupEntry in $backups) { Get-VBRRestorePoint -Backup $backupEntry })

    # Index by machine name. Veeam exposes it as Name, and as VmName on some
    # restore point types/versions, so both are indexed (property-guarded: a bare
    # access throws under StrictMode).
    $restorePointsByName = @{}
    foreach ($restorePointEntry in $restorePoints) {
        foreach ($namePropertyName in @('Name', 'VmName')) {
            $nameProperty = $restorePointEntry.PSObject.Properties[$namePropertyName]
            if (-not $nameProperty) { continue }

            $machineName = [string]$nameProperty.Value
            if ([string]::IsNullOrWhiteSpace($machineName)) { continue }

            $machineKey = $machineName.Trim().ToLowerInvariant()
            if (-not $restorePointsByName.ContainsKey($machineKey)) {
                $restorePointsByName[$machineKey] = New-Object System.Collections.ArrayList
            }
            [void]$restorePointsByName[$machineKey].Add($restorePointEntry)
        }
    }

    # Reported once, so the log says what Veeam actually holds before the
    # per-VM failures start scrolling past.
    $availableMachineNames = @($restorePointsByName.Keys | Sort-Object)
    Write-Output ([pscustomobject]@{
        VMName        = $null
        Started       = $false
        RunAsync      = $false
        Error         = $null
        InventoryLine = "Veeam inventory for '$JobName': $($backups.Count) backup(s), $($restorePoints.Count) restore point(s) covering $($availableMachineNames.Count) machine(s)."
    })

    $supportsRunAsync = (Get-Command -Name Start-VBRHvInstantRecovery).Parameters.ContainsKey('RunAsync')

    $taskIndex = 0
    foreach ($task in $TaskList) {
        $taskIndex++
        $vmName = [string]$task.VMName

        $vmKey = $vmName.Trim().ToLowerInvariant()
        $restorePoint = $null
        if ($restorePointsByName.ContainsKey($vmKey)) {
            $restorePoint = @($restorePointsByName[$vmKey]) |
                Sort-Object -Property CreationTime -Descending |
                Select-Object -First 1
        }

        if (-not $restorePoint) {
            # Name what Veeam DOES hold: 'no restore point found' on its own cannot
            # distinguish a VM missing from the job, a name that differs from the
            # CSV, and a backup that has not produced a restore point yet.
            $knownNames = if ($availableMachineNames.Count -gt 0) {
                ($availableMachineNames | Select-Object -First 20) -join ', '
            } else {
                '<none>'
            }
            [pscustomobject]@{
                VMName        = $vmName
                Started       = $false
                RunAsync      = $supportsRunAsync
                Error         = "No restore point found for VM '$vmName' in job '$JobName'. Machines with a restore point in this job: $knownNames."
                InventoryLine = $null
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
            VMName        = $vmName
            Started       = (-not $startError)
            RunAsync      = $supportsRunAsync
            Error         = $startError
            InventoryLine = $null
        }

        if ($DelaySeconds -gt 0 -and $taskIndex -lt $TaskList.Count) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }
} -ArgumentList @($BackupJobName, $tasks, $StartDelaySeconds))

# The scriptblock also emits one inventory record (VMName $null) describing what
# Veeam holds for this job: log it first so the per-VM outcomes below read
# against a known inventory.
foreach ($inventoryRecord in @($startResults | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InventoryLine) })) {
    Write-MigrationLog ([string]$inventoryRecord.InventoryLine) -LogFile $LogFile
}
$startResults = @($startResults | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.VMName) })

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
# Deduplicates the "column stayed empty" diagnostics: identical for every VM.
$loggedDiagnostics = New-Object 'System.Collections.Generic.HashSet[string]'
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
        param($VmNames, $VeeamRecoveryPath, $EmitDiagnostics)

        . $VeeamRecoveryPath

        $irSessions = @(Get-VBRInstantRecovery)
        # Fetch once per poll and pass to Find-VmRestoreSession to avoid one
        # Get-VBRRestoreSession round-trip per VM.
        $restoreSessions = @(Get-VBRRestoreSession)

        foreach ($vmName in @($VmNames)) {
            # Matched on whichever property carries the machine name in this module
            # version, with the same bounded pattern used for restore sessions
            # (WEB1 must not match WEB10).
            $irSession = Find-VmInstantRecoverySession -VmName $vmName -InstantRecoverySessions $irSessions
            $restoreSession = Find-VmRestoreSession -VmName $vmName -RestoreSessions $restoreSessions

            # Candidate paths rather than one hard-coded name: 'State' is absent on
            # several Veeam builds, and reading only it kept the InstantRecovery
            # column at '<none>' for the whole run.
            $irState = [string](Get-VeeamPropertyValue -InputObject $irSession -PropertyPaths @('State', 'Status', 'SessionState'))
            $restoreSessionStateRaw = [string](Get-VeeamPropertyValue -InputObject $restoreSession -PropertyPaths @('State', 'Status'))
            $restoreSessionResultRaw = [string](Get-VeeamPropertyValue -InputObject $restoreSession -PropertyPaths @('Result'))

            $waitingDetected = $false
            $detectionSource = $null
            if ($irState -eq 'WaitingForUserAction') {
                $waitingDetected = $true
                $detectionSource = 'instant-recovery-state'
            }

            $sessionState = if ($restoreSessionStateRaw) { $restoreSessionStateRaw } else { '<none>' }
            $sessionResult = $restoreSessionResultRaw

            # Veeam reports completion as Progress.Percents on some builds and as a
            # flat numeric property on others. Reading only 'Progress' returned an
            # object (or nothing), so the column showed '-' from start to finish.
            $progress = [string](Get-VeeamPropertyValue -InputObject $restoreSession -PropertyPaths @(
                'Progress.Percents', 'Progress.Percent', 'ProgressPercent', 'CompletionPercentage', 'Progress'
            ))

            # Emitted once per run, only for a column that stayed empty: names the
            # properties this Veeam module really exposes so the candidate lists
            # above can be corrected instead of guessed at.
            $irDiagnostic = $null
            $progressDiagnostic = $null
            if ($EmitDiagnostics) {
                if (-not $irSession) {
                    $sampleIrSession = @($irSessions) | Select-Object -First 1
                    $irDiagnostic = "no Instant Recovery session matched; Get-VBRInstantRecovery returned $(@($irSessions).Count) session(s), first: $(Get-VeeamObjectPropertySummary -InputObject $sampleIrSession)"
                } elseif ([string]::IsNullOrWhiteSpace($irState)) {
                    $irDiagnostic = "Instant Recovery session matched but exposes no state; $(Get-VeeamObjectPropertySummary -InputObject $irSession)"
                }

                if ($restoreSession -and [string]::IsNullOrWhiteSpace($progress)) {
                    $progressDiagnostic = "restore session exposes no progress; $(Get-VeeamObjectPropertySummary -InputObject $restoreSession)"
                }
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
                VMName             = $vmName
                IrState            = if ($irState) { $irState } else { '<none>' }
                SessionState       = $sessionState
                SessionResult      = $sessionResult
                Progress           = $progress
                WaitingDetected    = $waitingDetected
                DetectionSource    = $detectionSource
                LogReadError       = $logReadError
                IrDiagnostic       = $irDiagnostic
                ProgressDiagnostic = $progressDiagnostic
            }
        }
    } -ArgumentList @([string[]]$pendingNames, $step3VeeamRecoveryPath, ($elapsed -eq 0)))

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

        # One line per dead dashboard column, on the first poll only: a column that
        # shows '<none>' or '-' for an entire run is a lookup that found nothing,
        # and the message names the properties Veeam actually exposes.
        foreach ($diagnosticProperty in @('IrDiagnostic', 'ProgressDiagnostic')) {
            if (-not $snapshot.PSObject.Properties[$diagnosticProperty]) { continue }

            $diagnosticText = [string]$snapshot.$diagnosticProperty
            if ([string]::IsNullOrWhiteSpace($diagnosticText) -or $loggedDiagnostics.Contains($diagnosticText)) { continue }

            [void]$loggedDiagnostics.Add($diagnosticText)
            Write-MigrationLog "[$($snapshot.VMName)] Instant Recovery dashboard: $diagnosticText" -Level WARNING -LogFile $LogFile
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
            # '%' only when Veeam gave a number: some builds report a textual stage
            # there, and '-' stays the honest answer when nothing was reported.
            Progress        = if ([string]::IsNullOrWhiteSpace([string]$tracked.Progress)) {
                '-'
            } elseif ([string]$tracked.Progress -match '^\d+(\.\d+)?$') {
                "$($tracked.Progress)%"
            } else {
                [string]$tracked.Progress
            }
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
