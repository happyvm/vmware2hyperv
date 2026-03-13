#requires -Version 7.0

param (
    # Nom du job Veeam à restaurer (ex: Backup-HypMig-lot-117) — obligatoire
    [Parameter(Mandatory = $true)]
    [string]$BackupJobName,

    [string]$SCVMMServer,
    [string]$HyperVHost,
    [string]$TargetPath,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $SCVMMServer) { $SCVMMServer = $Config.SCVMM.Server }
if (-not $HyperVHost)  { $HyperVHost  = $Config.HyperV.Host1 }
if (-not $TargetPath)  { $TargetPath  = $Config.HyperV.ClusterStorage }
if (-not $LogFile)     { $LogFile     = "$($Config.Paths.LogDir)\step3-instant-restore-start-$BackupJobName-$(Get-Date -Format 'yyyyMMdd').log" }

$PowerUp      = $Config.Veeam.InstantRecovery.PowerUp
$NICsEnabled  = $Config.Veeam.InstantRecovery.NICsEnabled
$PreserveMACs = $Config.Veeam.InstantRecovery.PreserveMACs
$PreserveVmID = $Config.Veeam.InstantRecovery.PreserveVmID

Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

Write-Log "Démarrage step3 - Instant Recovery pour le job $BackupJobName" -LogFile $LogFile

$VBRSCVMM = Get-VBRServer | Where-Object { $_.Name -eq $SCVMMServer -and $_.Type -eq "Scvmm" }
if (!$VBRSCVMM) {
    Write-Log "SCVMM $SCVMMServer n'est pas enregistré dans Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}
Write-Log "SCVMM validé : $SCVMMServer" -Level SUCCESS -LogFile $LogFile

$RestorePoints = Get-VBRRestorePoint | Where-Object { $_.GetBackup().Name -eq $BackupJobName }
if (!$RestorePoints) {
    Write-Log "Aucune VM trouvée dans les points de restauration pour le job $BackupJobName." -Level ERROR -LogFile $LogFile
    exit 1
}
Write-Log "Nombre de VM à restaurer : $($RestorePoints.Count)" -LogFile $LogFile

$RestorePoints | ForEach-Object {
    $VMName = $_.Name
    Write-Log "Instant Recovery pour $VMName via SCVMM ($SCVMMServer)..." -LogFile $LogFile

    try {
        Start-VBRHvInstantRecovery -RestorePoint $_ -Server $HyperVHost -Path "$TargetPath\$VMName" -PowerUp $PowerUp -NICsEnabled $NICsEnabled -PreserveMACs $PreserveMACs -PreserveVmID $PreserveVmID
        Write-Log "Instant Recovery lancé pour $VMName." -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-Log "Erreur lors de la restauration de $VMName : $_" -Level ERROR -LogFile $LogFile
    }
}

Write-Log "step3 terminé - toutes les VMs du job $BackupJobName restaurées." -Level SUCCESS -LogFile $LogFile
