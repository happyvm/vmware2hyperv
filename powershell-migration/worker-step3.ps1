param(
    [Parameter(Mandatory = $true)]
    [string]$QueueRoot,

    [string]$WorkerName = "step3-worker-01",

    [int]$PollIntervalSeconds = 3,

    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"

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

Write-MigrationLog "[$WorkerName] Persistent step3 worker starting. Queue root: $QueueRoot" -LogFile $LogFile

try {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
    Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback
    Write-MigrationLog "[$WorkerName] Veeam and SCVMM modules warmed up." -Level SUCCESS -LogFile $LogFile
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
            -ForceNetworkConfigOnly:$([bool]$task.ForceNetworkConfigOnly) `
            -LogFile ([string]$task.VmLogFile)

        $task | Add-Member -NotePropertyName Status -NotePropertyValue "Success" -Force
        $task | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date).ToString("o") -Force
        $task | Add-Member -NotePropertyName ErrorMessage -NotePropertyValue $null -Force

        Write-TaskStateFile -Path (Join-Path $doneDir $nextTask.Name) -TaskObject $task
        Remove-Item -Path $claimedTaskPath -Force -ErrorAction SilentlyContinue
        Write-MigrationLog "[$WorkerName] Step3 task completed successfully for VM '$vmName'." -Level SUCCESS -LogFile $LogFile
    } catch {
        $task | Add-Member -NotePropertyName Status -NotePropertyValue "Failed" -Force
        $task | Add-Member -NotePropertyName CompletedAt -NotePropertyValue (Get-Date).ToString("o") -Force
        $task | Add-Member -NotePropertyName ErrorMessage -NotePropertyValue $_.Exception.Message -Force
        $task | Add-Member -NotePropertyName ErrorRecord -NotePropertyValue ([string]$_) -Force

        Write-TaskStateFile -Path (Join-Path $failedDir $nextTask.Name) -TaskObject $task
        Remove-Item -Path $claimedTaskPath -Force -ErrorAction SilentlyContinue
        Write-MigrationLog "[$WorkerName] Step3 task failed for VM '$vmName': $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
    }
}

Write-MigrationLog "[$WorkerName] Worker stopped cleanly." -Level SUCCESS -LogFile $LogFile
