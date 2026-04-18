#requires -Version 7.0

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
Assert-FileExists -Path $ConfigFile -Label "Configuration file"

$Config  = Import-PowerShellDataFile $ConfigFile
$LogFile = "$($Config.Paths.LogDir)\run-migration-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-Log "======================================================" -LogFile $LogFile
Write-Log "Starting migration for batch: $Tag" -LogFile $LogFile
Write-Log "Starting step: $StartFrom" -LogFile $LogFile
Write-Log "Force network-only replay: $ForceNetworkConfigOnly" -LogFile $LogFile
Write-Log "======================================================" -LogFile $LogFile

$steps = @("step1", "step2", "step3")
$startIndex = [array]::IndexOf($steps, $StartFrom)

function Invoke-OrchestratorStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Step,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Log "--- Starting $Step ---" -LogFile $LogFile
    try {
        & $Action
        Write-Log "--- $Step completed successfully ---" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-Log "$Step failed : $_. Migration stopped." -Level ERROR -LogFile $LogFile
        Write-Log "To resume from this step: .\run-migration.ps1 -Tag $Tag -StartFrom $Step" -Level WARNING -LogFile $LogFile
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
    Write-Log "Manual validation confirmed — launching step3." -LogFile $LogFile
}

# ── Retrieving VMware VLANs (single connection, before parallel processing) ──

$csvFile = $Config.Paths.CsvFile
Assert-FileExists -Path $csvFile -Label "batch CSV" -LogFile $LogFile

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

$csvRows = Import-Csv -Path $csvFile -Delimiter ";"
$vmRows = @($csvRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })
$vmNames = @($vmRows | Select-Object -ExpandProperty VMName | Sort-Object -Unique)

if (-not $vmNames) {
    Write-Log "No VM found in CSV." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-Log "Retrieving VMware VLANs for $($vmNames.Count) VMs..." -LogFile $LogFile
Import-RequiredModule -Name "VMware.VimAutomation.Core" -LogFile $LogFile -UseWindowsPowerShellFallback
Connect-VCenter -Server $Config.VCenter.Server -LogFile $LogFile

$vmVlans = @{}
$vmOperatingSystems = @{}

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

    Write-Log "Loaded $($cmdbOperatingSystems.Count) operating system entries from CMDB extract '$cmdbPath'." -LogFile $LogFile
} elseif (-not [string]::IsNullOrWhiteSpace($cmdbPath)) {
    Write-Log "CMDB extract not found at '$cmdbPath'; falling back to OperatingSystem values from the batch CSV only." -Level WARNING -LogFile $LogFile
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
    if ($VMObject) {
        $NetworkAdapter = Get-NetworkAdapter -VM $VMObject -ErrorAction SilentlyContinue
        if ($NetworkAdapter -and $NetworkAdapter.NetworkName) {
            $DVPortGroup = Get-VDPortgroup -Name $NetworkAdapter.NetworkName -ErrorAction SilentlyContinue
            $vlanId = if ($DVPortGroup -and $DVPortGroup.VlanConfiguration -match "\d+") { $matches[0] } else { "PortGroup not found" }
        } else {
            $vlanId = if ($NetworkAdapter) { "Not connected to a network" } else { "No network adapter" }
        }
    } else {
        $vlanId = "VM not found"
    }
    Write-Log "VLAN $vmName : $vlanId" -LogFile $LogFile
    $vmVlans[$vmName] = $vlanId
}

Disconnect-VCenter -LogFile $LogFile

# ── Parallel execution per VM ────────────────────────────────────────────────

Write-Log "Parallel execution per VM (step3)..." -LogFile $LogFile
Write-Log "Targeted VMs: $($vmNames -join ', ')" -LogFile $LogFile

$jobs = foreach ($vmName in $vmNames) {
    $vmLogFile       = "$($Config.Paths.LogDir)\migration-$Tag-$vmName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $vlanId          = $vmVlans[$vmName]
    $operatingSystem = $vmOperatingSystems[$vmName]

    Start-Job -Name "migration-$vmName" -ScriptBlock {
        param(
            [string]$ScriptsRoot,
            [string]$Tag,
            [string]$VmName,
            [string]$VlanId,
            [string]$OperatingSystem,
            [bool]$ForceNetworkConfigOnly,
            [string]$VmLogFile
        )

        $ErrorActionPreference = "Stop"

        # Avoid interactive security prompts in background jobs when scripts carry a Mark-of-the-Web.
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force | Out-Null
        Get-ChildItem -Path $ScriptsRoot -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue

        & "$ScriptsRoot\step3-MigrateVM.ps1" -BackupJobName "Backup-$Tag" -VMName $VmName -VlanId $VlanId -OperatingSystem $OperatingSystem -Tag $Tag -ForceNetworkConfigOnly:$ForceNetworkConfigOnly -LogFile $VmLogFile
    } -ArgumentList $PSScriptRoot, $Tag, $vmName, $vlanId, $operatingSystem, $ForceNetworkConfigOnly.IsPresent, $vmLogFile
}

Wait-Job -Job $jobs | Out-Null

foreach ($job in $jobs) {
    $jobOutput = Receive-Job -Job $job
    if ($jobOutput) {
        $jobOutput | ForEach-Object { Write-Log "[$($job.Name)] $_" -LogFile $LogFile }
    }
}

$failedJobs = $jobs | Where-Object { $_.State -ne "Completed" }
if ($failedJobs) {
    $failedNames = $failedJobs.Name -join ", "
    Write-Log "Parallel execution incomplete. Failed jobs: $failedNames" -Level ERROR -LogFile $LogFile
    Remove-Job -Job $jobs -Force
    exit 1
}

Remove-Job -Job $jobs -Force

Write-Log "======================================================" -LogFile $LogFile
Write-Log "Migration of batch $Tag completed successfully." -Level SUCCESS -LogFile $LogFile
Write-Log "======================================================" -LogFile $LogFile
