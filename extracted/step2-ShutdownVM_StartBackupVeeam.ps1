#requires -Version 7.0

param (
    # Name of the batch/tag to migrate (e.g. HypMig-lot-118) — required
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

Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile


$JobName = "Backup-$Tag"

Write-Log "Starting step2 - VM shutdown and Veeam backup for tag $Tag" -LogFile $LogFile
Assert-FileExists -Path $CsvFile -Label "batch CSV" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$vmList = Import-Csv -Path $CsvFile -Delimiter ";"

foreach ($vmEntry in $vmList) {
    Write-Log "Graceful shutdown of VM: $($vmEntry.VMName)" -LogFile $LogFile
    $vmObj = VMware.VimAutomation.Core\Get-VM -Name $vmEntry.VMName -ErrorAction SilentlyContinue
    if (-not $vmObj) {
        Write-Log "VM not found: $($vmEntry.VMName)" -Level WARNING -LogFile $LogFile
        continue
    }
    if ($vmObj.PowerState -ne "PoweredOff") {
        Shutdown-VMGuest -VM $vmObj -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $timeout = 300   # secondes
        $elapsed = 0
        do {
            Start-Sleep -Seconds 10
            $elapsed += 10
            $vmObj = VMware.VimAutomation.Core\Get-VM -Name $vmEntry.VMName
        } while ($vmObj.PowerState -ne "PoweredOff" -and $elapsed -lt $timeout)

        if ($vmObj.PowerState -ne "PoweredOff") {
            Write-Log "VM $($vmEntry.VMName) not powered off after ${timeout}s — forced power-off." -Level WARNING -LogFile $LogFile
            VMware.VimAutomation.Core\Stop-VM -VM $vmEntry.VMName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Write-Log "VM $($vmEntry.VMName) powered off." -Level SUCCESS -LogFile $LogFile
}

Disconnect-VCenter -LogFile $LogFile

Write-Log "Sending pre-migration email" -LogFile $LogFile
& $PreMigrationMailScript -tagName $Tag -recipientGroup $RecipientGroup -vCenterServer $VCenterServer -SkipVCenterLogin

$Job = Get-VBRJob -Name $JobName
if ($Job) {
    Start-VBRJob -Job $Job
    Write-Log "Job Veeam '$JobName' started successfully." -Level SUCCESS -LogFile $LogFile
} else {
    Write-Log "Job '$JobName' not found in Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}
