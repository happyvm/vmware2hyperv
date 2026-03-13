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
    [ValidateSet("step1", "step2", "step3")]
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
$LogFile = "$($Config.Paths.LogDir)\run-migration-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

Write-Log "======================================================" -LogFile $LogFile
Write-Log "Démarrage migration pour le lot : $Tag" -LogFile $LogFile
Write-Log "Étape de départ : $StartFrom" -LogFile $LogFile
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

    Write-Log "--- Démarrage $Step ---" -LogFile $LogFile
    try {
        & $Action
        Write-Log "--- $Step terminé avec succès ---" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-Log "$Step a échoué : $_. Migration interrompue." -Level ERROR -LogFile $LogFile
        Write-Log "Pour reprendre depuis cette étape : .\run-migration.ps1 -Tag $Tag -StartFrom $Step" -Level WARNING -LogFile $LogFile
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

    Write-Host ""
    Write-Host ">>> PAUSE avant step3 (Instant Recovery)" -ForegroundColor Yellow
    Write-Host "    Vérifiez dans la console Veeam que le job 'Backup-$Tag' est bien terminé." -ForegroundColor Yellow
    Read-Host "    Appuyez sur Entrée pour continuer"
    Write-Log "Validation manuelle confirmée — lancement step3." -LogFile $LogFile
}

# ── Récupération des VLANs VMware (une seule connexion, avant le parallèle) ──

$csvFile = $Config.Paths.CsvFile
Assert-FileExists -Path $csvFile -Label "CSV lotissement" -LogFile $LogFile

$vmNames = (Import-Csv -Path $csvFile -Delimiter ";" |
    Select-Object -ExpandProperty VMName |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique)

if (-not $vmNames) {
    Write-Log "Aucune VM trouvée dans le CSV." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-Log "Récupération des VLANs VMware pour $($vmNames.Count) VMs..." -LogFile $LogFile
Import-RequiredModule -Name "VMware.VimAutomation.Core" -LogFile $LogFile -UseWindowsPowerShellFallback
Connect-VCenter -Server $Config.VCenter.Server -LogFile $LogFile

$vmVlans = @{}
foreach ($vmName in $vmNames) {
    $VMObject = VMware.VimAutomation.Core\Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($VMObject) {
        $NetworkAdapter = Get-NetworkAdapter -VM $VMObject -ErrorAction SilentlyContinue
        if ($NetworkAdapter -and $NetworkAdapter.NetworkName) {
            $DVPortGroup = Get-VDPortgroup -Name $NetworkAdapter.NetworkName -ErrorAction SilentlyContinue
            $vlanId = if ($DVPortGroup -and $DVPortGroup.VlanConfiguration -match "\d+") { $matches[0] } else { "PortGroup non trouvé" }
        } else {
            $vlanId = if ($NetworkAdapter) { "Non attaché à un réseau" } else { "Pas d'adaptateur réseau" }
        }
    } else {
        $vlanId = "VM introuvable"
    }
    Write-Log "VLAN $vmName : $vlanId" -LogFile $LogFile
    $vmVlans[$vmName] = $vlanId
}

Disconnect-VCenter -LogFile $LogFile

# ── Exécution parallèle par VM ────────────────────────────────────────────────

Write-Log "Exécution parallèle par VM (step3)..." -LogFile $LogFile
Write-Log "VMs ciblées : $($vmNames -join ', ')" -LogFile $LogFile

$jobs = foreach ($vmName in $vmNames) {
    $vmLogFile = "$($Config.Paths.LogDir)\migration-$Tag-$vmName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $vlanId    = $vmVlans[$vmName]

    Start-Job -Name "migration-$vmName" -ScriptBlock {
        param(
            [string]$ScriptsRoot,
            [string]$Tag,
            [string]$VmName,
            [string]$VlanId,
            [string]$VmLogFile
        )

        $ErrorActionPreference = "Stop"
        & "$ScriptsRoot\step3-MigrateVM.ps1" -BackupJobName "Backup-$Tag" -VMName $VmName -VlanId $VlanId -Tag $Tag -LogFile $VmLogFile
    } -ArgumentList $PSScriptRoot, $Tag, $vmName, $vlanId, $vmLogFile
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
    Write-Log "Exécution parallèle incomplète. Jobs en échec: $failedNames" -Level ERROR -LogFile $LogFile
    Remove-Job -Job $jobs -Force
    exit 1
}

Remove-Job -Job $jobs -Force

Write-Log "======================================================" -LogFile $LogFile
Write-Log "Migration du lot $Tag terminée avec succès." -Level SUCCESS -LogFile $LogFile
Write-Log "======================================================" -LogFile $LogFile
