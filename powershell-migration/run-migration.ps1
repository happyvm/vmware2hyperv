# run-migration.ps1 — VMware → Hyper-V migration orchestrator
#
# Usage:
#   .\run-migration.ps1 -Tag HypMig-lot-118
#   .\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3
#   .\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step2 -RecipientGroup internal

param (
    # Name of the batch to migrate (e.g. HypMig-lot-118) — required
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    # Step to start from (useful when resuming)
    [ValidateSet("step1", "step2", "step3")]
    [string]$StartFrom = "step1",

    # Recipient group for the pre-migration email
    [string]$RecipientGroup = "infogerant",

    # Optional config file override
    [string]$ConfigFile,

    # Re-run only the network/OS/post-configuration part of step3
    [switch]$ForceNetworkConfigOnly,

    # Restrict step3 execution to a single VM (incident recovery mode)
    [string]$Step3VmName,

    # Incident recovery mode for a single VM:
    # - FullStep3: re-run complete step3
    # - CommitAndNetwork: re-run only instant recovery commit + network/post-config
    [ValidateSet("Standard", "FullStep3", "CommitAndNetwork")]
    [string]$Step3RecoveryMode = "Standard"
)

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config  = Import-PowerShellDataFile $ConfigFile
$LogFile = "$($Config.Paths.LogDir)\run-migration-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "Starting migration for batch: $Tag" -LogFile $LogFile
Write-MigrationLog "Starting step: $StartFrom" -LogFile $LogFile
Write-MigrationLog "Force network-only replay: $ForceNetworkConfigOnly" -LogFile $LogFile
Write-MigrationLog "Step3 VM filter: $Step3VmName" -LogFile $LogFile
Write-MigrationLog "Step3 recovery mode: $Step3RecoveryMode" -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile

$steps = @("step1", "step2", "step3")
$startIndex = [array]::IndexOf($steps, $StartFrom)

function Invoke-OrchestratorStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Step,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-MigrationLog "--- Starting $Step ---" -LogFile $LogFile
    try {
        & $Action
        Write-MigrationLog "--- $Step completed successfully ---" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-MigrationLog "$Step failed : $_. Migration stopped." -Level ERROR -LogFile $LogFile
        Write-MigrationLog "To resume from this step: .\run-migration.ps1 -Tag $Tag -StartFrom $Step" -Level WARNING -LogFile $LogFile
        throw
    }
}

function Ensure-DirectoryPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Convert-ToSafeFileName {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "unnamed"
    }

    $safeValue = $Value
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safeValue = $safeValue.Replace([string]$invalidChar, "-")
    }

    return $safeValue
}

if ($startIndex -le 0) {
    Invoke-OrchestratorStep -Step "step1" -Action {
        & "$PSScriptRoot\step1-TagResources_CreateVeeamJob.ps1" -Tag $Tag -LogFile $LogFile
    }
}

if ($startIndex -le 1) {
    Invoke-OrchestratorStep -Step "step2" -Action {
        & "$PSScriptRoot\step2-ShutdownVM_StartBackupVeeam.ps1" -Tag $Tag -RecipientGroup $RecipientGroup -LogFile $LogFile
    }

    Write-Information "" -InformationAction Continue
    Write-Warning ">>> PAUSE before step3 (Instant Recovery)"
    Write-Warning "    Check in the Veeam console that job 'Backup-$Tag' is completed."
    Read-Host "    Press Enter to continue"
    Write-MigrationLog "Manual validation confirmed — launching step3." -LogFile $LogFile
}

# ── Retrieving VMware VLANs (single connection, before worker dispatch) ──

$csvFile = $Config.Paths.CsvFile
Assert-PathPresent -Path $csvFile -Label "batch CSV" -LogFile $LogFile

function Resolve-AdapterVlanId {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter,

        [Parameter(Mandatory = $true)]
        [hashtable]$DistributedPortGroupCache,

        [Parameter(Mandatory = $true)]
        [hashtable]$StandardPortGroupCache
    )

    $networkName = [string]$Adapter.NetworkName
    if ([string]::IsNullOrWhiteSpace($networkName)) {
        return "Not connected to a network"
    }

    if (-not $DistributedPortGroupCache.ContainsKey($networkName)) {
        $DistributedPortGroupCache[$networkName] = @(Get-VDPortgroup -Name $networkName -ErrorAction SilentlyContinue)
    }
    $distributedPortGroups = @($DistributedPortGroupCache[$networkName])
    foreach ($distributedPortGroup in $distributedPortGroups) {
        # Prefer direct integer property on the DVS VLAN spec (avoids string-parsing ambiguity)
        try {
            $vlanSpec = $distributedPortGroup.ExtensionData.Config.DefaultPortConfig.Vlan
            if ($vlanSpec -and $vlanSpec.PSObject.Properties['VlanId']) {
                $rawId = [int]$vlanSpec.VlanId
                if ($rawId -ge 1 -and $rawId -le 4094) {
                    return [string]$rawId
                }
            }
        } catch { }

        if ([string]$distributedPortGroup.VlanConfiguration -match '\d+') {
            return [string]$matches[0]
        }
    }

    if (-not $StandardPortGroupCache.ContainsKey($networkName)) {
        $StandardPortGroupCache[$networkName] = @(Get-VirtualPortGroup -Name $networkName -ErrorAction SilentlyContinue)
    }
    $standardPortGroups = @($StandardPortGroupCache[$networkName])
    foreach ($standardPortGroup in $standardPortGroups) {
        if ([string]$standardPortGroup.VLanId -match '^\d+$') {
            return [string]$standardPortGroup.VLanId
        }
    }

    $backing = $null
    try { $backing = $Adapter.ExtensionData.Backing } catch { }
    if ($backing -and $backing.PSObject.Properties['Port'] -and $backing.Port -and $backing.Port.PortgroupKey) {
        $portGroupView = Get-View -Id $backing.Port.PortgroupKey -ErrorAction SilentlyContinue
        if ($portGroupView -and $portGroupView.Config) {
            try {
                $vlanSpec = $portGroupView.Config.DefaultPortConfig.Vlan
                if ($vlanSpec -and $vlanSpec.PSObject.Properties['VlanId']) {
                    $rawId = [int]$vlanSpec.VlanId
                    if ($rawId -ge 1 -and $rawId -le 4094) {
                        return [string]$rawId
                    }
                }
            } catch { }
            if ([string]$portGroupView.Config.DefaultPortConfig.Vlan -match '\d+') {
                return [string]$matches[0]
            }
        }
    }

    # Last resort: extract VLAN from port group name (e.g. "dvPG-LAN_1816" → "1816")
    if ($networkName -match '_(\d{1,4})$') {
        return $matches[1]
    }

    return "PortGroup not found"
}

$csvRows = Import-Csv -Path $csvFile -Delimiter ";"
$vmRows = @($csvRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })
$vmNames = @($vmRows | Select-Object -ExpandProperty VMName | Sort-Object -Unique)

if ($Step3RecoveryMode -ne "Standard" -and [string]::IsNullOrWhiteSpace($Step3VmName)) {
    throw "Step3RecoveryMode '$Step3RecoveryMode' requires -Step3VmName."
}

if (-not [string]::IsNullOrWhiteSpace($Step3VmName)) {
    $vmRows = @($vmRows | Where-Object { $_.VMName -eq $Step3VmName })
    $vmNames = @($vmRows | Select-Object -ExpandProperty VMName | Sort-Object -Unique)
}

if (-not $vmNames) {
    Write-MigrationLog "No VM found in CSV." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-MigrationLog "Retrieving VMware VLANs for $($vmNames.Count) VMs..." -LogFile $LogFile
Import-RequiredModule -Name "VMware.VimAutomation.Core" -LogFile $LogFile -UseWindowsPowerShellFallback
Connect-VCenter -Server $Config.VCenter.Server -LogFile $LogFile

$vmVlans = @{}
$vmAdapterVlans = @{}
$vmOperatingSystems = @{}
$vmRemarks = @{}
$distributedPortGroupCache = @{}
$standardPortGroupCache = @{}

$cmdbPath = $Config.Paths.CmdbExtractCsv
$cmdbOperatingSystems = @{}
if (-not [string]::IsNullOrWhiteSpace($cmdbPath) -and (Test-Path $cmdbPath)) {
    $cmdbRows = Import-Csv -Path $cmdbPath -Delimiter ";"
    foreach ($cmdbRow in $cmdbRows) {
        $cmdbVmName = Get-FirstPropertyValue -InputObject $cmdbRow -PropertyNames @("VMName", "Name")
        if ([string]::IsNullOrWhiteSpace($cmdbVmName) -or $cmdbOperatingSystems.ContainsKey($cmdbVmName)) {
            continue
        }

        $cmdbOperatingSystem = Get-FirstPropertyValue -InputObject $cmdbRow -PropertyNames @("OperatingSystem", "Operating system")
        if (-not [string]::IsNullOrWhiteSpace($cmdbOperatingSystem)) {
            $cmdbOperatingSystems[$cmdbVmName] = $cmdbOperatingSystem
        }
    }

    Write-MigrationLog "Loaded $($cmdbOperatingSystems.Count) operating system entries from CMDB extract '$cmdbPath'." -LogFile $LogFile
} elseif (-not [string]::IsNullOrWhiteSpace($cmdbPath)) {
    Write-MigrationLog "CMDB extract not found at '$cmdbPath'; falling back to OperatingSystem values from the batch CSV only." -Level WARNING -LogFile $LogFile
}

foreach ($row in $vmRows) {
    if (-not $vmOperatingSystems.ContainsKey($row.VMName)) {
        $vmOperatingSystems[$row.VMName] = if ($cmdbOperatingSystems.ContainsKey($row.VMName)) {
            $cmdbOperatingSystems[$row.VMName]
        } else {
            $row.OperatingSystem
        }
    }
}

$vmObjectsByName = @{}
$batchVmObjects = @(VMware.VimAutomation.Core\Get-VM -Name $vmNames -ErrorAction SilentlyContinue)
foreach ($vmObject in $batchVmObjects) {
    if ($vmObject -and -not $vmObjectsByName.ContainsKey($vmObject.Name)) {
        $vmObjectsByName[$vmObject.Name] = $vmObject
    }
}

$networkAdaptersByVmName = @{}
if ($batchVmObjects.Count -gt 0) {
    $allNetworkAdapters = @(Get-NetworkAdapter -VM $batchVmObjects -ErrorAction SilentlyContinue)
    foreach ($networkAdapter in $allNetworkAdapters) {
        $adapterVmName = $null
        if ($networkAdapter.PSObject.Properties['Parent'] -and $networkAdapter.Parent) {
            $adapterVmName = [string]$networkAdapter.Parent.Name
        }
        if ([string]::IsNullOrWhiteSpace($adapterVmName) -and $networkAdapter.PSObject.Properties['VM'] -and $networkAdapter.VM) {
            $adapterVmName = [string]$networkAdapter.VM.Name
        }
        if ([string]::IsNullOrWhiteSpace($adapterVmName)) {
            continue
        }

        if (-not $networkAdaptersByVmName.ContainsKey($adapterVmName)) {
            $networkAdaptersByVmName[$adapterVmName] = New-Object System.Collections.ArrayList
        }
        [void]$networkAdaptersByVmName[$adapterVmName].Add($networkAdapter)
    }
}

foreach ($vmName in $vmNames) {
    $VMObject = $null
    if ($vmObjectsByName.ContainsKey($vmName)) {
        $VMObject = $vmObjectsByName[$vmName]
    }
    $remark = $null
    $adapterMappings = @()
    if ($VMObject) {
        $remark = [string]$VMObject.ExtensionData.Summary.Config.Annotation
        $networkAdapters = if ($networkAdaptersByVmName.ContainsKey($vmName)) {
            @($networkAdaptersByVmName[$vmName])
        } else {
            @()
        }
        if ($networkAdapters) {
            foreach ($networkAdapter in $networkAdapters) {
                $macAddress = [string]$networkAdapter.MacAddress
                $vlanIdForAdapter = "PortGroup not found"
                try {
                    $vlanIdForAdapter = Resolve-AdapterVlanId `
                        -Adapter $networkAdapter `
                        -DistributedPortGroupCache $distributedPortGroupCache `
                        -StandardPortGroupCache $standardPortGroupCache
                } catch {
                    Write-MigrationLog "Error resolving VLAN for adapter '$macAddress' on VM '$vmName': $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
                }

                $adapterMappings += [pscustomobject]@{
                    MacAddress  = $macAddress
                    NetworkName = [string]$networkAdapter.NetworkName
                    VlanId      = [string]$vlanIdForAdapter
                }
            }

            $firstNumericVlan = $adapterMappings |
                Where-Object { $_.VlanId -match '^\d+$' } |
                Select-Object -First 1 -ExpandProperty VlanId

            if (-not [string]::IsNullOrWhiteSpace($firstNumericVlan)) {
                $vlanId = $firstNumericVlan
            } else {
                $vlanId = [string]($adapterMappings | Select-Object -First 1 -ExpandProperty VlanId)
            }
        } else {
            $vlanId = "No network adapter"
        }
    } else {
        $vlanId = "VM not found"
    }

    if ($adapterMappings.Count -gt 0) {
        $vlanSummary = ($adapterMappings | ForEach-Object { "$($_.VlanId)" }) -join ", "
        Write-MigrationLog "VLAN $vmName : $vlanSummary" -LogFile $LogFile
    } else {
        Write-MigrationLog "VLAN $vmName : $vlanId" -LogFile $LogFile
    }

    $vmVlans[$vmName] = $vlanId
    $vmAdapterVlans[$vmName] = $adapterMappings
    $vmRemarks[$vmName] = $remark
}

Disconnect-VCenter -LogFile $LogFile

$runInstantRecoveryStartOutsideWorkers = $false
$workerForceNetworkOnly = [bool]$ForceNetworkConfigOnly
$workerSkipInstantRecoveryStart = $false

switch ($Step3RecoveryMode) {
    "Standard" {
        if (-not $ForceNetworkConfigOnly) {
            $runInstantRecoveryStartOutsideWorkers = $true
            $workerSkipInstantRecoveryStart = $true
        }
    }
    "FullStep3" {
        if ($ForceNetworkConfigOnly) {
            throw "Step3RecoveryMode 'FullStep3' is incompatible with -ForceNetworkConfigOnly."
        }

        $runInstantRecoveryStartOutsideWorkers = $true
        $workerForceNetworkOnly = $false
        $workerSkipInstantRecoveryStart = $true
    }
    "CommitAndNetwork" {
        if ($ForceNetworkConfigOnly) {
            throw "Step3RecoveryMode 'CommitAndNetwork' is incompatible with -ForceNetworkConfigOnly."
        }

        $runInstantRecoveryStartOutsideWorkers = $false
        $workerForceNetworkOnly = $false
        $workerSkipInstantRecoveryStart = $true
    }
}

# ── Instant Recovery outside workers (step3) ─────────────────────────────────

if ($runInstantRecoveryStartOutsideWorkers) {
    Write-MigrationLog "Step3 phase 1/2: launching Instant Recovery start outside workers (commit/bascule remains in workers)." -LogFile $LogFile

    foreach ($vmName in $vmNames) {
        $vmLogFile = "$($Config.Paths.LogDir)\migration-$Tag-$vmName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        $adapterVlanMapJson = ConvertTo-Json -InputObject $vmAdapterVlans[$vmName] -Depth 4 -Compress

        & "$PSScriptRoot\step3-MigrateVM.ps1" `
            -BackupJobName "Backup-$Tag" `
            -VMName $vmName `
            -VlanId $vmVlans[$vmName] `
            -AdapterVlanMapJson $adapterVlanMapJson `
            -OperatingSystem $vmOperatingSystems[$vmName] `
            -Remark $vmRemarks[$vmName] `
            -SkipInstantRecoveryFinalization `
            -SkipNetworkAndPostConfig `
            -LogFile $vmLogFile
    }
}

# ── Worker-based commit+bascule and network/post-configuration execution (step3) ─────────

Write-MigrationLog "Step3 phase 2/2: worker-based execution per VM for commit/bascule and network/post-configuration..." -LogFile $LogFile
Write-MigrationLog "Targeted VMs: $($vmNames -join ', ')" -LogFile $LogFile

$step3WorkerCount = if ($Config.Orchestrator.Step3MaxParallelJobs) { [int]$Config.Orchestrator.Step3MaxParallelJobs } else { 5 }
$step3WorkerStartupDelaySec = if ($Config.Orchestrator.Step3JobStartupDelaySec -ge 0) { [int]$Config.Orchestrator.Step3JobStartupDelaySec } else { 2 }

if ($step3WorkerCount -lt 1) {
    $step3WorkerCount = 1
}

if ($step3WorkerCount -gt $vmNames.Count) {
    $step3WorkerCount = $vmNames.Count
}

$workerScriptPath = "$PSScriptRoot\worker-step3.ps1"
Assert-PathPresent -Path $workerScriptPath -Label "step3 worker script" -LogFile $LogFile

Write-MigrationLog "Step3 worker pool size: $step3WorkerCount persistent worker(s) (startup delay: ${step3WorkerStartupDelaySec}s)." -LogFile $LogFile

# Remove Mark-of-the-Web once, before starting persistent workers.
Get-ChildItem -Path $PSScriptRoot -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

$queueRoot = Join-Path $Config.Paths.LogDir ("step3-worker-queue-{0}-{1}" -f (Convert-ToSafeFileName -Value $Tag), (Get-Date -Format 'yyyyMMdd-HHmmss'))
$pendingDir = Join-Path $queueRoot "pending"
$processingDir = Join-Path $queueRoot "processing"
$doneDir = Join-Path $queueRoot "done"
$failedDir = Join-Path $queueRoot "failed"

Ensure-DirectoryPresent -Path $queueRoot
Ensure-DirectoryPresent -Path $pendingDir
Ensure-DirectoryPresent -Path $processingDir
Ensure-DirectoryPresent -Path $doneDir
Ensure-DirectoryPresent -Path $failedDir

Write-MigrationLog "Step3 queue root: $queueRoot" -LogFile $LogFile

$taskIndex = 0
foreach ($vmName in $vmNames) {
    $taskIndex++
    $adapterVlanMapJson = ConvertTo-Json -InputObject $vmAdapterVlans[$vmName] -Depth 4 -Compress
    $vmLogFile = "$($Config.Paths.LogDir)\migration-$Tag-$vmName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $taskFileName = "{0:D4}-{1}.json" -f $taskIndex, (Convert-ToSafeFileName -Value $vmName)
    $taskFilePath = Join-Path $pendingDir $taskFileName

    $taskPayload = [ordered]@{
        TaskId                 = "{0:D4}" -f $taskIndex
        Tag                    = $Tag
        BackupJobName          = "Backup-$Tag"
        VMName                 = $vmName
        VlanId                 = $vmVlans[$vmName]
        AdapterVlanMapJson     = $adapterVlanMapJson
        OperatingSystem        = $vmOperatingSystems[$vmName]
        Remark                 = $vmRemarks[$vmName]
        ForceNetworkConfigOnly = $workerForceNetworkOnly
        SkipInstantRecoveryStart = $workerSkipInstantRecoveryStart
        VmLogFile              = $vmLogFile
        CreatedAt              = (Get-Date).ToString("o")
    }

    $taskPayload | ConvertTo-Json -Depth 8 | Set-Content -Path $taskFilePath -Encoding utf8
}

$dispatchCompleteFlag = Join-Path $queueRoot "dispatch.complete"
New-Item -ItemType File -Path $dispatchCompleteFlag -Force | Out-Null
Write-MigrationLog "Queued $taskIndex step3 task(s) for persistent workers." -LogFile $LogFile

$pwshCommand = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pwshCommand) {
    $message = "PowerShell 7 executable 'pwsh' not found; unable to start persistent step3 workers."
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    throw $message
}

$workerProcesses = @()
for ($workerIndex = 1; $workerIndex -le $step3WorkerCount; $workerIndex++) {
    $workerName = "step3-worker-{0:D2}" -f $workerIndex
    $workerLogFile = "$($Config.Paths.LogDir)\$workerName-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $workerArguments = @(
        "-NoProfile"
        "-File"
        $workerScriptPath
        "-QueueRoot"
        $queueRoot
        "-WorkerName"
        $workerName
        "-LogFile"
        $workerLogFile
    )

    $workerProcess = Start-Process -FilePath $pwshCommand.Source -ArgumentList $workerArguments -PassThru
    $workerProcesses += [pscustomobject]@{
        Name    = $workerName
        Process = $workerProcess
        LogFile = $workerLogFile
    }

    Write-MigrationLog "Started persistent step3 worker '$workerName' (PID=$($workerProcess.Id))." -LogFile $LogFile

    if ($step3WorkerStartupDelaySec -gt 0) {
        Start-Sleep -Seconds $step3WorkerStartupDelaySec
    }
}

$workerMonitorPollIntervalSeconds = 5
$lastProgressSnapshot = $null

do {
    $pendingCount = @(Get-ChildItem -Path $pendingDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
    $processingCount = @(Get-ChildItem -Path $processingDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
    $doneCount = @(Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
    $failedCount = @(Get-ChildItem -Path $failedDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count

    $progressSnapshot = "$pendingCount|$processingCount|$doneCount|$failedCount"
    if ($progressSnapshot -ne $lastProgressSnapshot) {
        Write-MigrationLog "Step3 queue status: pending=$pendingCount, processing=$processingCount, done=$doneCount, failed=$failedCount." -LogFile $LogFile
        $lastProgressSnapshot = $progressSnapshot
    }

    foreach ($workerEntry in $workerProcesses) {
        $workerEntry.Process.Refresh()
    }

    $runningWorkers = @($workerProcesses | Where-Object { -not $_.Process.HasExited })
    if ($runningWorkers.Count -eq 0) {
        break
    }

    Start-Sleep -Seconds $workerMonitorPollIntervalSeconds
} while ($true)

foreach ($workerEntry in $workerProcesses) {
    $workerEntry.Process.Refresh()
    Write-MigrationLog "Worker '$($workerEntry.Name)' exited with code $($workerEntry.Process.ExitCode). Log: $($workerEntry.LogFile)" -LogFile $LogFile
}

$finalPendingCount = @(Get-ChildItem -Path $pendingDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
$finalProcessingCount = @(Get-ChildItem -Path $processingDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
$finalDoneCount = @(Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
$finalFailedCount = @(Get-ChildItem -Path $failedDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count

Write-MigrationLog "Final step3 queue status: pending=$finalPendingCount, processing=$finalProcessingCount, done=$finalDoneCount, failed=$finalFailedCount." -LogFile $LogFile

$networkStateSummary = @{}
$completedTaskFiles = @(Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -Path $failedDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
foreach ($taskFile in $completedTaskFiles) {
    try {
        $taskState = Get-Content -Path $taskFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $networkState = [string]$taskState.NetworkConfigurationState
        if ([string]::IsNullOrWhiteSpace($networkState)) {
            $networkState = "Unknown"
        }

        if (-not $networkStateSummary.ContainsKey($networkState)) {
            $networkStateSummary[$networkState] = 0
        }
        $networkStateSummary[$networkState]++
    } catch {
        if (-not $networkStateSummary.ContainsKey("Unknown")) {
            $networkStateSummary["Unknown"] = 0
        }
        $networkStateSummary["Unknown"]++
    }
}

if ($networkStateSummary.Count -gt 0) {
    $summaryText = ($networkStateSummary.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
    Write-MigrationLog "Step3 worker network configuration state summary: $summaryText" -LogFile $LogFile
}

if ($finalPendingCount -gt 0 -or $finalProcessingCount -gt 0) {
    $message = "Worker execution stopped before the queue fully drained (pending=$finalPendingCount, processing=$finalProcessingCount)."
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    exit 1
}

if ($finalFailedCount -gt 0) {
    $failedTasks = @(Get-ChildItem -Path $failedDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            try {
                $failedTask = Get-Content -Path $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($failedTask -and $failedTask.VMName) {
                    [string]$failedTask.VMName
                } else {
                    $_.BaseName
                }
            } catch {
                $_.BaseName
            }
        })

    $failedVmList = if ($failedTasks) { $failedTasks -join ", " } else { "<unknown>" }
    Write-MigrationLog "Worker-based step3 execution reported failures for: $failedVmList" -Level ERROR -LogFile $LogFile
    exit 1
}

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "Migration of batch $Tag completed successfully." -Level SUCCESS -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile
