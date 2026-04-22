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
    [switch]$ForceNetworkConfigOnly
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

# ── Retrieving VMware VLANs (single connection, before parallel processing) ──

$csvFile = $Config.Paths.CsvFile
Assert-PathPresent -Path $csvFile -Label "batch CSV" -LogFile $LogFile

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return $null
}

function Resolve-AdapterVlanId {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter
    )

    $networkName = [string]$Adapter.NetworkName
    if ([string]::IsNullOrWhiteSpace($networkName)) {
        return "Not connected to a network"
    }

    $distributedPortGroups = @(Get-VDPortgroup -Name $networkName -ErrorAction SilentlyContinue)
    foreach ($distributedPortGroup in $distributedPortGroups) {
        if ([string]$distributedPortGroup.VlanConfiguration -match '\d+') {
            return [string]$matches[0]
        }
    }

    $standardPortGroups = @(Get-VirtualPortGroup -Name $networkName -ErrorAction SilentlyContinue)
    foreach ($standardPortGroup in $standardPortGroups) {
        if ([string]$standardPortGroup.VLanId -match '^\d+$') {
            return [string]$standardPortGroup.VLanId
        }
    }

    $backing = $Adapter.ExtensionData.Backing
    if ($backing -and $backing.PSObject.Properties['Port'] -and $backing.Port -and $backing.Port.PortgroupKey) {
        $portGroupView = Get-View -Id $backing.Port.PortgroupKey -ErrorAction SilentlyContinue
        if ($portGroupView -and $portGroupView.Config -and [string]$portGroupView.Config.DefaultPortConfig.Vlan -match '\d+') {
            return [string]$matches[0]
        }
    }

    return "PortGroup not found"
}

$csvRows = Import-Csv -Path $csvFile -Delimiter ";"
$vmRows = @($csvRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })
$vmNames = @($vmRows | Select-Object -ExpandProperty VMName | Sort-Object -Unique)

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

foreach ($vmName in $vmNames) {
    $VMObject = VMware.VimAutomation.Core\Get-VM -Name $vmName -ErrorAction SilentlyContinue
    $remark = $null
    $adapterMappings = @()
    if ($VMObject) {
        $remark = [string]$VMObject.ExtensionData.Summary.Config.Annotation
        $networkAdapters = @(Get-NetworkAdapter -VM $VMObject -ErrorAction SilentlyContinue)
        if ($networkAdapters) {
            foreach ($networkAdapter in $networkAdapters) {
                $macAddress = [string]$networkAdapter.MacAddress
                $vlanIdForAdapter = Resolve-AdapterVlanId -Adapter $networkAdapter

                $adapterMappings += [pscustomobject]@{
                    MacAddress = $macAddress
                    NetworkName = [string]$networkAdapter.NetworkName
                    VlanId = [string]$vlanIdForAdapter
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

# ── Parallel execution per VM ────────────────────────────────────────────────

Write-MigrationLog "Parallel execution per VM (step3)..." -LogFile $LogFile
Write-MigrationLog "Targeted VMs: $($vmNames -join ', ')" -LogFile $LogFile

$step3MaxParallelJobs = if ($Config.Orchestrator.Step3MaxParallelJobs) { [int]$Config.Orchestrator.Step3MaxParallelJobs } else { 5 }
$step3JobStartupDelaySec = if ($Config.Orchestrator.Step3JobStartupDelaySec -ge 0) { [int]$Config.Orchestrator.Step3JobStartupDelaySec } else { 2 }

if ($step3MaxParallelJobs -lt 1) {
    $step3MaxParallelJobs = 1
}

Write-MigrationLog "Step3 concurrency limit: $step3MaxParallelJobs parallel jobs (startup delay: ${step3JobStartupDelaySec}s)." -LogFile $LogFile

$jobs = @()
foreach ($vmName in $vmNames) {
    while (($jobs | Where-Object { $_.State -eq "Running" }).Count -ge $step3MaxParallelJobs) {
        Wait-Job -Job $jobs -Any | Out-Null
    }

    $vmLogFile       = "$($Config.Paths.LogDir)\migration-$Tag-$vmName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $vlanId          = $vmVlans[$vmName]
    $adapterVlanMapJson = ConvertTo-Json -InputObject $vmAdapterVlans[$vmName] -Depth 4 -Compress
    $operatingSystem = $vmOperatingSystems[$vmName]
    $remark          = $vmRemarks[$vmName]

    $jobs += Start-Job -Name "migration-$vmName" -ScriptBlock {
            $ErrorActionPreference = "Stop"

            # Avoid interactive security prompts in background jobs when scripts carry a Mark-of-the-Web.
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force | Out-Null
            Get-ChildItem -Path $using:PSScriptRoot -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
                Unblock-File -ErrorAction SilentlyContinue

            & "$using:PSScriptRoot\step3-MigrateVM.ps1" -BackupJobName "Backup-$using:Tag" -VMName $using:vmName -VlanId $using:vlanId -AdapterVlanMapJson $using:adapterVlanMapJson -OperatingSystem $using:operatingSystem -Remark $using:remark -ForceNetworkConfigOnly:$using:ForceNetworkConfigOnly -LogFile $using:vmLogFile
        }

    if ($step3JobStartupDelaySec -gt 0) {
        Start-Sleep -Seconds $step3JobStartupDelaySec
    }
}

Wait-Job -Job $jobs | Out-Null

foreach ($job in $jobs) {
    $jobOutput = Receive-Job -Job $job
    if ($jobOutput) {
        $jobOutput | ForEach-Object { Write-MigrationLog "[$($job.Name)] $_" -LogFile $LogFile }
    }
}

$failedJobs = $jobs | Where-Object { $_.State -ne "Completed" }
if ($failedJobs) {
    $failedNames = $failedJobs.Name -join ", "
    Write-MigrationLog "Parallel execution incomplete. Failed jobs: $failedNames" -Level ERROR -LogFile $LogFile
    Remove-Job -Job $jobs -Force
    exit 1
}

Remove-Job -Job $jobs -Force

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "Migration of batch $Tag completed successfully." -Level SUCCESS -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile
