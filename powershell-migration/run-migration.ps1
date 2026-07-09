<#
.SYNOPSIS
    VMware to Hyper-V migration orchestrator.

.DESCRIPTION
    Orchestrates the full 3-step migration pipeline: (1) tag VMware VMs and create
    Veeam backup jobs, (2) shut down VMs and trigger Veeam backups, (3) run Instant
    Recovery and post-migration configuration. Supports resumption from any step,
    single-VM incident recovery, and automation-friendly non-interactive mode.

    Invoked with no arguments at all, it switches to an interactive mode: it first
    checks config.local.psd1 for missing values (running configure-migration.ps1's
    wizard if needed), then prompts for -Tag, -StartFrom, and -RecipientGroup
    before starting. Pass any parameter explicitly (or -NonInteractive) to skip
    straight to automation-friendly behavior.

.PARAMETER Tag
    Batch tag to migrate (e.g. HypMig-lot-118). Mandatory, but can be supplied
    interactively when the script is run with no arguments.

.PARAMETER StartFrom
    Step to start from: step1, step2, or step3. Default: step1.

.PARAMETER RecipientGroup
    Recipient group for the pre-migration email notification. Default: infogerant.

.PARAMETER ConfigFile
    Optional path to a PSD1 configuration file override.

.PARAMETER ForceNetworkConfigOnly
    Re-run only the network/OS/post-configuration part of step3.

.PARAMETER Step3VmName
    Restrict step3 execution to a single VM (incident recovery mode).

.PARAMETER Step3RecoveryMode
    Incident recovery mode: Standard, FullStep3 (re-run complete step3), or
    CommitAndNetwork (re-run instant recovery commit + network/post-config).
    Default: Standard.

.PARAMETER NonInteractive
    Disable all interactive prompts for automation-friendly execution.

.PARAMETER SkipManualValidation
    Skip the manual validation pause between step2 and step3.

.EXAMPLE
    .\run-migration.ps1
    # Interactive mode: completes config.local.psd1 if needed, then prompts for -Tag etc.

.EXAMPLE
    .\run-migration.ps1 -Tag HypMig-lot-118

.EXAMPLE
    .\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3 -NonInteractive

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI and Veeam.Backup.PowerShell modules.
#>

# run-migration.ps1 — VMware → Hyper-V migration orchestrator
#
# Usage:
#   .\run-migration.ps1                      # interactive: config wizard + prompts
#   .\run-migration.ps1 -Tag HypMig-lot-118
#   .\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3
#   .\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step2 -RecipientGroup internal

param (
    # Name of the batch to migrate (e.g. HypMig-lot-118). Not [Parameter(Mandatory)]
    # so that invoking the script with zero arguments falls through to interactive
    # mode below instead of PowerShell's raw "Supply values for..." prompt.
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
    [string]$Step3RecoveryMode = "Standard",

    # Disable all interactive prompts (automation-friendly mode)
    [switch]$NonInteractive,

    # Skip the manual validation pause between step2 and step3
    [switch]$SkipManualValidation
)

# Remove Mark-of-the-Web from every file in the toolkit (recursively, including step3\ modules
# and config.psd1) before anything is dot-sourced or invoked. Must run first: files copied from a
# zip download or a network share are flagged "downloaded from the internet" and, under a
# RemoteSigned execution policy, fail to run until unblocked — including lib.ps1 itself.
Get-ChildItem -Path $PSScriptRoot -File -Recurse -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

if ($PSBoundParameters.Count -eq 0 -and -not $NonInteractive) {
    Write-Host ""
    Write-Host "=== VMware -> Hyper-V migration — mode interactif ===" -ForegroundColor Cyan

    $missingKeys = Get-MigrationConfigMissingKeys -ConfigFile $ConfigFile
    if ($missingKeys.Count -gt 0) {
        Write-Host "Configuration locale incomplète : $($missingKeys.Count) valeur(s) à renseigner dans config.local.psd1." -ForegroundColor Yellow
        Invoke-MigrationConfigWizard -ConfigFile $ConfigFile
    }

    Write-Host ""
    while ([string]::IsNullOrWhiteSpace($Tag)) {
        $Tag = Read-Host "Tag du lot à migrer (ex: HypMig-lot-118)"
    }

    $startFromAnswer = Read-Host "Étape de départ [step1/step2/step3] (Entrée = $StartFrom)"
    if ($startFromAnswer) {
        if ($startFromAnswer -notin @("step1", "step2", "step3")) {
            throw "Étape de départ invalide : '$startFromAnswer'. Valeurs possibles : step1, step2, step3."
        }
        $StartFrom = $startFromAnswer
    }

    $recipientGroupAnswer = Read-Host "Groupe destinataires pour l'email pré-migration (Entrée = $RecipientGroup)"
    if ($recipientGroupAnswer) { $RecipientGroup = $recipientGroupAnswer }
    Write-Host ""
} elseif ([string]::IsNullOrWhiteSpace($Tag)) {
    if ($NonInteractive) {
        throw "-Tag is mandatory (pass it explicitly when -NonInteractive is set)."
    }
    while ([string]::IsNullOrWhiteSpace($Tag)) {
        $Tag = Read-Host "Tag du lot à migrer (ex: HypMig-lot-118)"
    }
}

$Config  = Import-MigrationConfig -ConfigFile $ConfigFile
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
        # 'exit <n>' in a script invoked with '&' ends only that script and never reaches
        # the catch below; reset then check $LASTEXITCODE so such failures cannot be
        # silently reported as a successful step.
        $global:LASTEXITCODE = 0
        & $Action
        if ($LASTEXITCODE -ne 0) {
            throw "$Step ended with exit code $LASTEXITCODE."
        }
        Write-MigrationLog "--- $Step completed successfully ---" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-MigrationLog "$Step failed : $_. Migration stopped." -Level ERROR -LogFile $LogFile
        Write-MigrationLog "To resume from this step: .\run-migration.ps1 -Tag $Tag -StartFrom $Step" -Level WARNING -LogFile $LogFile
        throw
    }
}

function Initialize-Directory {
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
    if ($NonInteractive -or $SkipManualValidation) {
        Write-Warning ">>> NON-INTERACTIVE MODE: Skipping manual validation before step3 (Instant Recovery)"
        Write-Warning "    Check in the Veeam console that job 'Backup-$Tag' is completed."
        Write-MigrationLog "NonInteractive/SkipManualValidation — skipping manual validation, launching step3." -LogFile $LogFile
    }
    else {
        Write-Warning ">>> PAUSE before step3 (Instant Recovery)"
        Write-Warning "    Check in the Veeam console that job 'Backup-$Tag' is completed."
        Read-Host "    Press Enter to continue"
        Write-MigrationLog "Manual validation confirmed — launching step3." -LogFile $LogFile
    }
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
        } catch {
            Write-Verbose "DVS VLAN spec unavailable for port group '$networkName': $($_.Exception.Message)"
        }

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
    try { $backing = $Adapter.ExtensionData.Backing } catch {
        Write-Verbose "Adapter backing data unavailable: $($_.Exception.Message)"
    }
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
            } catch {
                Write-Verbose "Port group view VLAN spec unavailable: $($_.Exception.Message)"
            }
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

# Only migrate VMs belonging to this batch: filter on the CSV Tag column when it is populated.
# CSVs without a Tag column keep the previous behavior (all rows).
$rowsWithTag = @($vmRows | Where-Object { $_.PSObject.Properties['Tag'] -and -not [string]::IsNullOrWhiteSpace($_.Tag) })
if ($rowsWithTag) {
    $taggedRows = @($rowsWithTag | Where-Object { $_.Tag.Trim() -eq $Tag })
    if (-not $taggedRows) {
        Write-MigrationLog "No CSV row carries tag '$Tag'; nothing to migrate for this batch." -Level ERROR -LogFile $LogFile
        throw "No CSV row carries tag '$Tag'; nothing to migrate for this batch."
    }

    $excludedCount = $vmRows.Count - $taggedRows.Count
    if ($excludedCount -gt 0) {
        Write-MigrationLog "$excludedCount CSV row(s) excluded from step3 dispatch: tag differs from '$Tag' or tag missing." -Level WARNING -LogFile $LogFile
    }
    $vmRows = $taggedRows
}

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
    throw "No VM found in CSV."
}

Write-MigrationLog "Retrieving VMware VLANs for $($vmNames.Count) VMs..." -LogFile $LogFile
Import-RequiredModule -Name "VMware.VimAutomation.Core" -LogFile $LogFile -UseWindowsPowerShellFallback
Connect-VCenter -Server $Config.VCenter.Server -LogFile $LogFile

function Get-VMwareClusterNameForVm {
    param(
        [Parameter(Mandatory = $true)]
        $VMObject
    )

    try {
        $cluster = VMware.VimAutomation.Core\Get-Cluster -VM $VMObject -ErrorAction Stop | Select-Object -First 1
        if ($cluster -and -not [string]::IsNullOrWhiteSpace([string]$cluster.Name)) {
            return [string]$cluster.Name
        }
    } catch {
        Write-Verbose "Get-Cluster lookup failed for VM '$($VMObject.Name)'; falling back to parent traversal: $($_.Exception.Message)"
    }

    $parent = $VMObject.VMHost.Parent
    while ($parent) {
        if ($parent.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string]$parent.Name)) {
            if ([string]$parent.GetType().Name -match 'Cluster|ClusterImpl') {
                return [string]$parent.Name
            }
        }

        if ($parent.PSObject.Properties['Parent']) {
            $parent = $parent.Parent
        } else {
            break
        }
    }

    return $null
}

$vmVlans = @{}
$vmAdapterVlans = @{}
$vmOperatingSystems = @{}
$vmRemarks = @{}
$vmwareClusters = @{}
$migrationTargets = @{}
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
        $vmwareCluster = Get-VMwareClusterNameForVm -VMObject $VMObject
        $vmwareClusters[$vmName] = $vmwareCluster
        $migrationTargets[$vmName] = Resolve-MigrationTarget -Config $Config -VmwareClusterName $vmwareCluster -LogFile $LogFile
        Write-MigrationLog "VMware cluster $vmName : $vmwareCluster" -LogFile $LogFile
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
        $vmwareClusters[$vmName] = $null
        $migrationTargets[$vmName] = Resolve-MigrationTarget -Config $Config -VmwareClusterName $null -LogFile $LogFile
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
    Write-MigrationLog "Step3 phase 1/2: bulk Instant Recovery start (all mounts launched from a single console, unified progress monitoring)." -LogFile $LogFile

    $irTasks = @(foreach ($vmName in $vmNames) {
        [pscustomobject]@{
            VMName         = $vmName
            HyperVHost     = $migrationTargets[$vmName].HyperVHost
            ClusterStorage = $migrationTargets[$vmName].ClusterStorage
        }
    })

    $irTasksFile = Join-Path $Config.Paths.LogDir ("step3-ir-tasks-{0}-{1}.json" -f (Convert-ToSafeFileName -Value $Tag), (Get-Date -Format 'yyyyMMdd-HHmmss'))
    ConvertTo-Json -InputObject $irTasks -Depth 4 | Set-Content -Path $irTasksFile -Encoding utf8

    $irStartDelaySeconds = if ($Config.Orchestrator -and $Config.Orchestrator.ContainsKey('InstantRecoveryStartDelaySec') -and [int]$Config.Orchestrator.InstantRecoveryStartDelaySec -ge 0) {
        [int]$Config.Orchestrator.InstantRecoveryStartDelaySec
    } else {
        2
    }

    # Abort step3 if the bulk start fails (including a parse error in the child
    # script): the workers would otherwise commit mounts that never started.
    try {
        & "$PSScriptRoot\step3-StartInstantRecovery.ps1" `
            -BackupJobName "Backup-$Tag" `
            -TasksFile $irTasksFile `
            -StartDelaySeconds $irStartDelaySeconds `
            -LogFile $LogFile
    } catch {
        $message = "Step3 phase 1/2 (bulk Instant Recovery start) failed: $($_.Exception.Message)"
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
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

$queueRoot = Join-Path $Config.Paths.LogDir ("step3-worker-queue-{0}-{1}" -f (Convert-ToSafeFileName -Value $Tag), (Get-Date -Format 'yyyyMMdd-HHmmss'))
$pendingDir = Join-Path $queueRoot "pending"
$processingDir = Join-Path $queueRoot "processing"
$doneDir = Join-Path $queueRoot "done"
$failedDir = Join-Path $queueRoot "failed"

Initialize-Directory -Path $queueRoot
Initialize-Directory -Path $pendingDir
Initialize-Directory -Path $processingDir
Initialize-Directory -Path $doneDir
Initialize-Directory -Path $failedDir

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
        VmwareCluster          = $vmwareClusters[$vmName]
        HyperVHost             = $migrationTargets[$vmName].HyperVHost
        HyperVHost2            = $migrationTargets[$vmName].HyperVHost2
        HyperVCluster          = $migrationTargets[$vmName].HyperVCluster
        ClusterStorage         = $migrationTargets[$vmName].ClusterStorage
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
    throw $message
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
    throw "Worker-based step3 execution reported failures for: $failedVmList"
}

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "Migration of batch $Tag completed successfully." -Level SUCCESS -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile
