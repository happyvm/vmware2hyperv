#requires -Version 7.0

param (
    # Nom du lot/tag à migrer (ex: HypMig-lot-118) — obligatoire
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

$BackupJobPrefix = $Config.Migration.BackupJobPrefix
$VmShutdownTimeoutSeconds = $Config.Migration.VmShutdownTimeoutSeconds

Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile


$JobName = "$BackupJobPrefix$Tag"

Write-Log "Démarrage step2 - arrêt VMs et backup Veeam pour le tag $Tag" -LogFile $LogFile
Assert-FileExists -Path $CsvFile -Label "CSV lotissement" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$vmList = Import-Csv -Path $CsvFile -Delimiter ";"

foreach ($vm in $vmList) {
    Write-Log "Arrêt propre de la VM : $($vm.VMName)" -LogFile $LogFile
    $vmObj = VMware.VimAutomation.Core\Get-VM -Name $vm.VMName -ErrorAction SilentlyContinue
    if (-not $vmObj) {
        Write-Log "VM introuvable : $($vm.VMName)" -Level WARNING -LogFile $LogFile
        continue
    }
    if ($vmObj.PowerState -ne "PoweredOff") {
        Shutdown-VMGuest -VM $vmObj -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $timeout = $VmShutdownTimeoutSeconds
        $elapsed = 0
        do {
            Start-Sleep -Seconds 10
            $elapsed += 10
            $vmObj = VMware.VimAutomation.Core\Get-VM -Name $vm.VMName
        } while ($vmObj.PowerState -ne "PoweredOff" -and $elapsed -lt $timeout)

        if ($vmObj.PowerState -ne "PoweredOff") {
            Write-Log "VM $($vm.VMName) non éteinte après ${timeout}s — power-off forcé." -Level WARNING -LogFile $LogFile
            VMware.VimAutomation.Core\Stop-VM -VM $vm.VMName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Write-Log "VM $($vm.VMName) éteinte." -Level SUCCESS -LogFile $LogFile
}

Disconnect-VCenter -LogFile $LogFile

Write-Log "Envoi du mail de pré-migration" -LogFile $LogFile
& $PreMigrationMailScript -tagName $Tag -recipientGroup $RecipientGroup -vCenterServer $VCenterServer -SkipVCenterLogin

$Job = Get-VBRJob -Name $JobName
if ($Job) {
    Start-VBRJob -Job $Job
    Write-Log "Job Veeam '$JobName' démarré avec succès." -Level SUCCESS -LogFile $LogFile
} else {
    Write-Log "Job '$JobName' introuvable dans Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}
