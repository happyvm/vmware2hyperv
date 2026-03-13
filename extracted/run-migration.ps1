#requires -Version 7.0

# run-migration.ps1 — Orchestrateur de migration VMware → Hyper-V
#
# Usage:
#   .\run-migration.ps1 -Tag HypMig-lot-118
#   .\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3
#   .\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step2 -RecipientGroup internal

param (
    # Nom du lot à migrer (ex: HypMig-lot-118) — obligatoire
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    # Étape à partir de laquelle démarrer (utile en cas de reprise)
    [ValidateSet("step1", "step2", "step3", "step4", "step5")]
    [string]$StartFrom = "step1",

    # Groupe de destinataires pour le mail de pré-migration
    [string]$RecipientGroup = "infogerant",

    # Surcharge optionnelle du fichier de config
    [string]$ConfigFile
)

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-FileExists -Path $ConfigFile -Label "Fichier de configuration"

$Config  = Import-PowerShellDataFile $ConfigFile
$BackupJobPrefix = $Config.Migration.BackupJobPrefix
$LogFile = "$($Config.Paths.LogDir)\run-migration-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-Log "======================================================" -LogFile $LogFile
Write-Log "Démarrage migration pour le lot : $Tag" -LogFile $LogFile
Write-Log "Étape de départ : $StartFrom" -LogFile $LogFile
Write-Log "======================================================" -LogFile $LogFile

$steps = @("step1", "step2", "step3", "step4", "step5")
$run   = $false

foreach ($step in $steps) {
    if ($step -eq $StartFrom) { $run = $true }
    if (-not $run) { continue }

    Write-Log "--- Démarrage $step ---" -LogFile $LogFile

    try {
        switch ($step) {
            "step1" {
                & "$PSScriptRoot\step1-TagResources_CreateVeeamJob.ps1" -Tag $Tag -LogFile $LogFile
            }
            "step2" {
                & "$PSScriptRoot\step2-ShutdownVM_StartBackupVeeam.ps1" -Tag $Tag -RecipientGroup $RecipientGroup -LogFile $LogFile
            }
            "step3" {
                & "$PSScriptRoot\step3-InstantRestoreStartVeeam.ps1" -BackupJobName "$BackupJobPrefix$Tag" -LogFile $LogFile
            }
            "step4" {
                & "$PSScriptRoot\step4-InstantRestoreFinishVeeam.ps1" -Tag $Tag -LogFile $LogFile
            }
            "step5" {
                & "$PSScriptRoot\step5-MapVMwareToHyper-v.ps1" -Tag $Tag -LogFile $LogFile
            }
        }
    } catch {
        Write-Log "$step a échoué : $_. Migration interrompue." -Level ERROR -LogFile $LogFile
        Write-Log "Pour reprendre depuis cette étape : .\run-migration.ps1 -Tag $Tag -StartFrom $step" -Level WARNING -LogFile $LogFile
        exit 1
    }

    Write-Log "--- $step terminé avec succès ---" -Level SUCCESS -LogFile $LogFile

    # Points de contrôle manuels avant les étapes critiques
    if ($step -eq "step2") {
        Write-Host ""
        Write-Host ">>> PAUSE avant step3 (Instant Recovery)" -ForegroundColor Yellow
        Write-Host "    Vérifiez dans la console Veeam que le job '$BackupJobPrefix$Tag' est bien terminé." -ForegroundColor Yellow
        Read-Host "    Appuyez sur Entrée pour continuer"
        Write-Log "Validation manuelle confirmée — lancement step3." -LogFile $LogFile
    }
    if ($step -eq "step3") {
        Write-Host ""
        Write-Host ">>> PAUSE avant step4 (bascule Instant Recovery)" -ForegroundColor Yellow
        Write-Host "    Vérifiez dans la console Veeam que l'Instant Recovery est opérationnel et validé." -ForegroundColor Yellow
        Read-Host "    Appuyez sur Entrée pour lancer la bascule"
        Write-Log "Validation manuelle confirmée — lancement step4." -LogFile $LogFile
    }
}

Write-Log "======================================================" -LogFile $LogFile
Write-Log "Migration du lot $Tag terminée avec succès." -Level SUCCESS -LogFile $LogFile
Write-Log "======================================================" -LogFile $LogFile
