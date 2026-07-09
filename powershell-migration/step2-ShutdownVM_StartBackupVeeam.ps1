<#
.SYNOPSIS
    Shut down VMware VMs and trigger Veeam backups for a migration batch.

.DESCRIPTION
    Gracefully shuts down (or powers off) every VM listed in the batch CSV for the
    given tag, sends a pre-migration email notification, then starts the corresponding
    Veeam backup job and waits for it to complete before proceeding to step3.

.PARAMETER Tag
    Batch tag to migrate (e.g. HypMig-lot-118). Mandatory.

.PARAMETER VCenterServer
    vCenter server name or IP. Defaults to Config.VCenter.Server.

.PARAMETER CsvFile
    Path to the batch CSV file. Defaults to Config.Paths.CsvFile.

.PARAMETER PreMigrationMailScript
    Path to the pre-migration email script. Defaults to stepx-premigration_mail.ps1.

.PARAMETER RecipientGroup
    Recipient group for the email notification. Default: infogerant.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step2-ShutdownVM_StartBackupVeeam.ps1 -Tag HypMig-lot-118

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI and Veeam.Backup.PowerShell modules.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [string]$VCenterServer,
    [string]$CsvFile,
    [string]$PreMigrationMailScript,
    [string]$RecipientGroup = "infogerant",
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer)          { $VCenterServer          = $Config.VCenter.Server }
if (-not $CsvFile)                { $CsvFile                = $Config.Paths.CsvFile }
if (-not $PreMigrationMailScript) { $PreMigrationMailScript = "$PSScriptRoot\stepx-premigration_mail.ps1" }
if (-not $LogFile)                { $LogFile                = "$($Config.Paths.LogDir)\step2-shutdown-backup-$Tag-$(Get-Date -Format 'yyyyMMdd').log" }

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile
if ($PSVersionTable.PSEdition -eq "Core") {
    Write-MigrationLog "PowerShell 7 detected: skipping direct import of Veeam.Backup.PowerShell to avoid VMware/Veeam VimService assembly conflicts." -Level WARNING -LogFile $LogFile
    Write-MigrationLog "Veeam commands will run in Windows PowerShell for this step." -Level WARNING -LogFile $LogFile
} else {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
}


$JobName = "Backup-$Tag"

Write-MigrationLog "Starting step2 - VM shutdown and Veeam backup for tag $Tag" -LogFile $LogFile
Assert-PathPresent -Path $CsvFile -Label "batch CSV" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$csvRows = Import-Csv -Path $CsvFile -Delimiter ";"
$vmList = @($csvRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })

# Only shut down VMs belonging to this batch: filter on the CSV Tag column when it is populated.
# CSVs without a Tag column keep the previous behavior (all rows).
$rowsWithTag = @($vmList | Where-Object { $_.PSObject.Properties['Tag'] -and -not [string]::IsNullOrWhiteSpace($_.Tag) })
if ($rowsWithTag) {
    $taggedRows = @($rowsWithTag | Where-Object { $_.Tag.Trim() -eq $Tag })
    if (-not $taggedRows) {
        Write-MigrationLog "No CSV row carries tag '$Tag'; refusing to shut down VMs from other batches." -Level ERROR -LogFile $LogFile
        exit 1
    }

    $excludedCount = $vmList.Count - $taggedRows.Count
    if ($excludedCount -gt 0) {
        Write-MigrationLog "$excludedCount CSV row(s) excluded from step2: tag differs from '$Tag' or tag missing." -Level WARNING -LogFile $LogFile
    }
    $vmList = $taggedRows
}

function Disconnect-VmNetworkAdapters {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [string]$LogFile
    )

    $vmObj = VMware.VimAutomation.Core\Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vmObj) {
        Write-MigrationLog "Unable to disconnect NICs: VM not found ($VmName)." -Level WARNING -LogFile $LogFile
        return
    }

    $networkAdapters = VMware.VimAutomation.Core\Get-NetworkAdapter -VM $vmObj -ErrorAction SilentlyContinue
    if (-not $networkAdapters) {
        Write-MigrationLog "No network adapter found on VM $VmName." -Level WARNING -LogFile $LogFile
        return
    }

    $connectedAdapters = $networkAdapters | Where-Object { $_.Connected }
    if (-not $connectedAdapters) {
        Write-MigrationLog "All NICs are already disconnected on VM $VmName." -Level INFO -LogFile $LogFile
        return
    }

    foreach ($adapter in $connectedAdapters) {
        VMware.VimAutomation.Core\Set-NetworkAdapter -NetworkAdapter $adapter -Connected:$false -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }

    Write-MigrationLog "Disconnected $($connectedAdapters.Count) NIC(s) on VM $VmName." -Level SUCCESS -LogFile $LogFile
}

$vmStates = @{}
$timeoutSeconds = 300
$pollIntervalSeconds = 10
$startTime = Get-Date

foreach ($vmEntry in $vmList) {
    $vmName = $vmEntry.VMName
    $vmObj = VMware.VimAutomation.Core\Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vmObj) {
        Write-MigrationLog "VM not found: $vmName" -Level WARNING -LogFile $LogFile
        continue
    }

    $vmStates[$vmName] = [PSCustomObject]@{
        Name            = $vmName
        TimeoutHandled  = $false
        PoweredOffLogged = $false
        NetworkDisconnected = $false
    }

    if ($vmObj.PowerState -eq "PoweredOff") {
        Write-MigrationLog "VM $vmName is already powered off." -Level SUCCESS -LogFile $LogFile
        $vmStates[$vmName].PoweredOffLogged = $true
        Disconnect-VmNetworkAdapters -VmName $vmName -LogFile $LogFile
        $vmStates[$vmName].NetworkDisconnected = $true
        continue
    }

    Write-MigrationLog "Graceful shutdown requested for VM: $vmName" -LogFile $LogFile
    VMware.VimAutomation.Core\Stop-VMGuest -VM $vmObj -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

if ($vmStates.Count -gt 0) {
    # Escape hatch: after the graceful timeout plus this grace period following forced
    # power-off, abort instead of looping forever on a VM that will not shut down.
    $forcedStopGraceSeconds = 300

    do {
        $allPoweredOff = $true
        $elapsedSeconds = [int]((Get-Date) - $startTime).TotalSeconds
        $pendingNames = @($vmStates.Keys | Where-Object { -not $vmStates[$_].PoweredOffLogged })

        $pendingVmsByName = @{}
        if ($pendingNames) {
            foreach ($pendingVm in @(VMware.VimAutomation.Core\Get-VM -Name $pendingNames -ErrorAction SilentlyContinue)) {
                if (-not $pendingVmsByName.ContainsKey($pendingVm.Name)) {
                    $pendingVmsByName[$pendingVm.Name] = $pendingVm
                }
            }
        }

        foreach ($vmName in $pendingNames) {
            $vmObj = $pendingVmsByName[$vmName]
            if (-not $vmObj) {
                Write-MigrationLog "VM not found during shutdown follow-up: $vmName" -Level WARNING -LogFile $LogFile
                $vmStates[$vmName].PoweredOffLogged = $true
                continue
            }

            if ($vmObj.PowerState -eq "PoweredOff") {
                Write-MigrationLog "VM $vmName powered off." -Level SUCCESS -LogFile $LogFile
                $vmStates[$vmName].PoweredOffLogged = $true
                if (-not $vmStates[$vmName].NetworkDisconnected) {
                    Disconnect-VmNetworkAdapters -VmName $vmName -LogFile $LogFile
                    $vmStates[$vmName].NetworkDisconnected = $true
                }
                continue
            }

            $allPoweredOff = $false

            if ($elapsedSeconds -ge $timeoutSeconds -and -not $vmStates[$vmName].TimeoutHandled) {
                Write-MigrationLog "VM $vmName not powered off after ${timeoutSeconds}s — forced power-off." -Level WARNING -LogFile $LogFile
                VMware.VimAutomation.Core\Stop-VM -VM $vmObj -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                $vmStates[$vmName].TimeoutHandled = $true
            }
        }

        if (-not $allPoweredOff) {
            if ($elapsedSeconds -ge ($timeoutSeconds + $forcedStopGraceSeconds)) {
                $stuckVms = @($vmStates.Keys | Where-Object { -not $vmStates[$_].PoweredOffLogged }) -join ', '
                Write-MigrationLog "Still powered on ${forcedStopGraceSeconds}s after forced power-off: $stuckVms. Aborting step2 before starting the backup." -Level ERROR -LogFile $LogFile
                exit 1
            }

            Start-Sleep -Seconds $pollIntervalSeconds
        }
    } while (-not $allPoweredOff)
}

Disconnect-VCenter -LogFile $LogFile

Write-MigrationLog "Sending pre-migration email" -LogFile $LogFile
& $PreMigrationMailScript -tagName $Tag -recipientGroup $RecipientGroup -vCenterServer $VCenterServer

if ($PSVersionTable.PSEdition -eq "Core") {
    Write-MigrationLog "PowerShell 7 detected: starting the Veeam job in Windows PowerShell to avoid deserialized objects." -Level WARNING -LogFile $LogFile

    $startJobScript = @'
$JobName = $env:VMW2HV_JOB_NAME

Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop
$job = Get-VBRJob -Name $JobName -ErrorAction SilentlyContinue
if (-not $job) {
    Write-Output "[ERROR] Job '$JobName' not found in Veeam."
    exit 1
}

Start-VBRJob -Job $job | Out-Null
Write-Output "[SUCCESS] Job Veeam '$JobName' started successfully."
'@

    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($startJobScript))
    $previousJobName = $env:VMW2HV_JOB_NAME
    $env:VMW2HV_JOB_NAME = $JobName

    try {
        $winPsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript 2>&1
        $winPsExitCode = $LASTEXITCODE
    }
    finally {
        $env:VMW2HV_JOB_NAME = $previousJobName
    }

    foreach ($line in $winPsOutput) {
        if ($line -match '^\[ERROR\]\s+(.*)$') {
            Write-MigrationLog $Matches[1] -Level ERROR -LogFile $LogFile
        } elseif ($line -match '^\[SUCCESS\]\s+(.*)$') {
            Write-MigrationLog $Matches[1] -Level SUCCESS -LogFile $LogFile
        } elseif (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-MigrationLog "Windows PowerShell: $line" -Level INFO -LogFile $LogFile
        }
    }

    if ($winPsExitCode -ne 0) {
        $message = "Failed to start Veeam job '$JobName' in Windows PowerShell (exit code $winPsExitCode)."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        exit 1
    }
} else {
    $Job = Get-VBRJob -Name $JobName
    if ($Job) {
        Start-VBRJob -Job $Job
        Write-MigrationLog "Job Veeam '$JobName' started successfully." -Level SUCCESS -LogFile $LogFile
    } else {
        Write-MigrationLog "Job '$JobName' not found in Veeam." -Level ERROR -LogFile $LogFile
        exit 1
    }
}
