<#
.SYNOPSIS
    File-system queue worker that processes step3 migration tasks.

.DESCRIPTION
    Long-running worker that watches a file-system queue (pending/processing/done/failed
    directories) for step3 migration task files. Picks up pending tasks, executes
    step3-MigrateVM.ps1 for each, and moves them to done or failed based on the
    outcome. Supports the worker-pool pattern for parallel VM migration.

.PARAMETER QueueRoot
    Root directory of the file-system queue. Mandatory.

.PARAMETER WorkerName
    Unique worker name for log file identification. Default: step3-worker-01.

.PARAMETER PollIntervalSeconds
    Interval between queue polls in seconds. Default: 3.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\worker-step3.ps1 -QueueRoot D:\Scripts\Logs\step3-queue -WorkerName step3-worker-01

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$QueueRoot,

    [string]$WorkerName = "step3-worker-01",

    [int]$PollIntervalSeconds = 3,

    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
Get-ChildItem "$PSScriptRoot\step3\Step3.*.ps1" |
    Where-Object Name -ne 'Step3.ScvmmSession.Functions.ps1' |
    ForEach-Object { . $_.FullName }

if (-not $LogFile) {
    $LogFile = "$PSScriptRoot\$WorkerName.log"
}

$pendingDir = Join-Path $QueueRoot "pending"
$processingDir = Join-Path $QueueRoot "processing"
$doneDir = Join-Path $QueueRoot "done"
$failedDir = Join-Path $QueueRoot "failed"
$dispatchCompleteFlag = Join-Path $QueueRoot "dispatch.complete"
$step3ScriptPath = "$PSScriptRoot\step3-MigrateVM.ps1"

Assert-PathPresent -Path $pendingDir -Label "Worker pending queue" -LogFile $LogFile
Assert-PathPresent -Path $processingDir -Label "Worker processing queue" -LogFile $LogFile
Assert-PathPresent -Path $doneDir -Label "Worker done queue" -LogFile $LogFile
Assert-PathPresent -Path $failedDir -Label "Worker failed queue" -LogFile $LogFile
Assert-PathPresent -Path $step3ScriptPath -Label "step3 migration script" -LogFile $LogFile

function Write-TaskStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $TaskObject
    )

    $TaskObject | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
}

function Get-NetworkConfigurationState {
    <#
    .SYNOPSIS
        Determine the network configuration outcome from the structured step3 result.
        Falls back to legacy log grep when the JSON result file does not exist.
    #>
    param(
        [AllowNull()]
        [string]$VmLogFile
    )

    # Prefer the structured result written by step3-MigrateVM.ps1
    if (-not [string]::IsNullOrWhiteSpace($VmLogFile) -and (Test-Path -Path $VmLogFile)) {
        $structuredResult = Read-Step3TaskResult -VmLogFile $VmLogFile
        if ($structuredResult) {
            $networkPhase = $structuredResult.Phases.PSObject.Properties |
                Where-Object { $_.Name -like '*Network*' -or $_.Name -like '*PostConfig*' } |
                Select-Object -First 1

            if ($networkPhase) {
                $state = $networkPhase.Value.State
                $detail = $networkPhase.Value.Detail
                if ($state -eq 'Success' -and $detail -match 'fallback') {
                    return 'ConfiguredWithWarning'
                }
                if ($state -eq 'Success') { return 'Configured' }
                if ($state -eq 'Warning') { return 'ConfiguredWithWarning' }
                if ($state -eq 'Failed')  { return 'NotDetected' }
                if ($state -eq 'Skipped') { return 'NotDetected' }
            }
        }
    }

    # Legacy fallback: grep the VM log (kept for backward compatibility with
    # migrations that ran before TaskResult was introduced).
    if ([string]::IsNullOrWhiteSpace($VmLogFile) -or -not (Test-Path -Path $VmLogFile)) {
        return 'Unknown'
    }

    $successMatch = Select-String -Path $VmLogFile -Pattern "Network configured (default VLAN" -SimpleMatch -Quiet -ErrorAction SilentlyContinue
    $warningMatch = Select-String -Path $VmLogFile -Pattern "fallback mapping used" -SimpleMatch -Quiet -ErrorAction SilentlyContinue

    if ($successMatch) {
        if ($warningMatch) {
            return 'ConfiguredWithWarning'
        }
        return 'Configured'
    }

    return 'NotDetected'
}

Write-MigrationLog "[$WorkerName] Persistent step3 worker starting. Queue root: $QueueRoot" -LogFile $LogFile

try {
    Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback
    Write-MigrationLog "[$WorkerName] SCVMM module warmed up. Veeam will be loaded lazily only for non-network-only tasks." -Level SUCCESS -LogFile $LogFile
} catch {
    Write-MigrationLog "[$WorkerName] Worker initialization failed: $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
    throw
}

while ($true) {
    $nextTask = @(Get-ChildItem -Path $pendingDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1)

    if (-not $nextTask) {
        if (Test-Path -Path $dispatchCompleteFlag) {
            Write-MigrationLog "[$WorkerName] No pending step3 task remains. Worker stopping." -LogFile $LogFile
            break
        }

        Start-Sleep -Seconds $PollIntervalSeconds
        continue
    }

    $claimedTaskPath = Join-Path $processingDir $nextTask.Name
    try {
        Move-Item -Path $nextTask.FullName -Destination $claimedTaskPath -ErrorAction Stop
    } catch {
        Start-Sleep -Milliseconds 250
        continue
    }

    $task = $null
    try {
        $task = Get-Content -Path $claimedTaskPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $failedTask = [ordered]@{
            WorkerName   = $WorkerName
            Status       = "Failed"
            ErrorMessage = "Unable to parse task payload: $($_.Exception.Message)"
            TaskFileName = $nextTask.Name
            FailedAt     = (Get-Date).ToString("o")
        }

        Write-TaskStateFile -Path (Join-Path $failedDir $nextTask.Name) -TaskObject $failedTask
        Remove-Item -Path $claimedTaskPath -Force -ErrorAction SilentlyContinue
        Write-MigrationLog "[$WorkerName] Unable to parse task '$($nextTask.Name)'." -Level ERROR -LogFile $LogFile
        continue
    }

    $task | Add-Member -NotePropertyName WorkerName -NotePropertyValue $WorkerName -Force
    $task | Add-Member -NotePropertyName StartedAt -NotePropertyValue (Get-Date).ToString("o") -Force

    $vmName = [string]$task.VMName
    Write-MigrationLog "[$WorkerName] Starting step3 task for VM '$vmName'." -LogFile $LogFile

    try {
        & $step3ScriptPath `
            -BackupJobName ([string]$task.BackupJobName) `
            -VMName $vmName `
            -VlanId ([string]$task.VlanId) `
            -AdapterVlanMapJson ([string]$task.AdapterVlanMapJson) `
            -OperatingSystem ([string]$task.OperatingSystem) `
            -Remark ([string]$task.Remark) `
            -VmwareCluster ([string]$task.VmwareCluster) `
            -HyperVHost ([string]$task.HyperVHost) `
            -HyperVHost2 ([string]$task.HyperVHost2) `
            -HyperVCluster ([string]$task.HyperVCluster) `
            -ClusterStorage ([string]$task.ClusterStorage) `
            -SkipInstantRecoveryStart:$([bool]$task.SkipInstantRecoveryStart) `
            -ForceNetworkConfigOnly:$([bool]$task.ForceNetworkConfigOnly) `
            -LogFile ([string]$task.VmLogFile)

        $task | Add-Member -NotePropertyName Status -NotePropertyValue "Success" -Force
        $task | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date).ToString("o") -Force
        $task | Add-Member -NotePropertyName ErrorMessage -NotePropertyValue $null -Force
        $task | Add-Member -NotePropertyName NetworkConfigurationState -NotePropertyValue (Get-NetworkConfigurationState -VmLogFile ([string]$task.VmLogFile)) -Force
        $task | Add-Member -NotePropertyName Step3Result -NotePropertyValue (Read-Step3TaskResult -VmLogFile ([string]$task.VmLogFile)) -Force

        Write-TaskStateFile -Path (Join-Path $doneDir $nextTask.Name) -TaskObject $task
        Remove-Item -Path $claimedTaskPath -Force -ErrorAction SilentlyContinue
        Write-MigrationLog "[$WorkerName] Step3 task completed successfully for VM '$vmName'." -Level SUCCESS -LogFile $LogFile
    } catch {
        $task | Add-Member -NotePropertyName Status -NotePropertyValue "Failed" -Force
        $task | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date).ToString("o") -Force
        $task | Add-Member -NotePropertyName ErrorMessage -NotePropertyValue $_.Exception.Message -Force
        $task | Add-Member -NotePropertyName ErrorRecord -NotePropertyValue ([string]$_) -Force
        $task | Add-Member -NotePropertyName NetworkConfigurationState -NotePropertyValue (Get-NetworkConfigurationState -VmLogFile ([string]$task.VmLogFile)) -Force
        $task | Add-Member -NotePropertyName Step3Result -NotePropertyValue (Read-Step3TaskResult -VmLogFile ([string]$task.VmLogFile)) -Force

        Write-TaskStateFile -Path (Join-Path $failedDir $nextTask.Name) -TaskObject $task
        Remove-Item -Path $claimedTaskPath -Force -ErrorAction SilentlyContinue
        Write-MigrationLog "[$WorkerName] Step3 task failed for VM '$vmName': $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
    }
}

Write-MigrationLog "[$WorkerName] Worker stopped cleanly." -Level SUCCESS -LogFile $LogFile
