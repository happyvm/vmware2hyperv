#requires -Version 7.0

param (
    [string]$SCVMMServer,
    [string]$HyperVHost,
    [string]$CsvFile,
    [string]$Tag,      # Optionnel - pour contextualiser le log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $SCVMMServer) { $SCVMMServer = $Config.SCVMM.Server }
if (-not $HyperVHost)  { $HyperVHost  = $Config.HyperV.Host1 }
if (-not $CsvFile)     { $CsvFile     = $Config.Paths.CsvFile }
if (-not $LogFile)     { $LogFile     = "$($Config.Paths.LogDir)\step4-instant-restore-finish$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }

Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

Write-Log "Démarrage step4 - finalisation Instant Recovery" -LogFile $LogFile

Assert-FileExists -Path $CsvFile -Label "CSV lotissement" -LogFile $LogFile
$vmNames = (Import-Csv -Path $CsvFile -Delimiter ";").VMName

$VMMServer  = Get-SCVMMServer -ComputerName $SCVMMServer
$IRSessions = Get-VBRInstantRecovery | Where-Object { $_.VMName -in $vmNames }

if (!$IRSessions) {
    Write-Log "Aucune VM du lot en Instant Recovery à finaliser." -Level WARNING -LogFile $LogFile
    exit 0
}
Write-Log "Nombre de VM en Instant Recovery : $($IRSessions.Count)" -LogFile $LogFile

$IRSessions | ForEach-Object {
    $VMName   = $_.VMName
    $VMExists = Get-SCVirtualMachine -Name $VMName

    if ($VMExists) {
        Write-Log "Finalisation de l'Instant Recovery pour $VMName..." -LogFile $LogFile
        try {
            Start-VBRHvInstantRecoveryMigration -InstantRecovery $_
            Write-Log "Finalisation complète pour $VMName." -Level SUCCESS -LogFile $LogFile
        } catch {
            Write-Log "Erreur lors de la finalisation de $VMName : $_" -Level ERROR -LogFile $LogFile
        }
    } else {
        Write-Log "La VM $VMName n'existe pas dans Hyper-V, ignorée." -Level WARNING -LogFile $LogFile
    }
}

Write-Log "step4 terminé - toutes les VMs valides finalisées." -Level SUCCESS -LogFile $LogFile
