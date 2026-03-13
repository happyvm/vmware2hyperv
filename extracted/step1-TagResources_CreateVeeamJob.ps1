#requires -Version 7.0

param (
    [string]$VCenterServer,
    [string]$CsvFile,
    [string]$TagCategory,
    [string]$BackupRepoName,
    [string]$Tag,      # Optionnel - pour contextualiser le log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $CsvFile)       { $CsvFile       = $Config.Paths.CsvFile }
if (-not $TagCategory)   { $TagCategory   = $Config.Tags.Category }
if (-not $BackupRepoName){ $BackupRepoName = $Config.Veeam.BackupRepo }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step1-tag-veeam$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }

$TagNamePattern = $Config.Migration.TagNamePattern
$BackupJobPrefix = $Config.Migration.BackupJobPrefix

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile
Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback


Write-Log "Démarrage step1 - tagging et création jobs Veeam" -LogFile $LogFile
Assert-FileExists -Path $CsvFile -Label "CSV lotissement" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

# Vérifier / créer la catégorie de tag
$category = Get-TagCategory -Name $TagCategory -ErrorAction SilentlyContinue
if (-not $category) {
    Write-Log "Création de la catégorie de tag : $TagCategory" -LogFile $LogFile
    New-TagCategory -Name $TagCategory -Cardinality Single -EntityType VirtualMachine
}

$csvData = Import-Csv -Path $CsvFile -Delimiter ";"

foreach ($entry in $csvData) {
    $vmName  = $entry.VMName
    $tagName = $entry.Tag.Trim()

    $tag = Get-Tag -Name $tagName -ErrorAction SilentlyContinue
    if (-not $tag) {
        Write-Log "Création du tag : $tagName" -LogFile $LogFile
        New-Tag -Name $tagName -Category $TagCategory
    }

    $existingTags = Get-TagAssignment -Entity (VMware.VimAutomation.Core\Get-VM -Name $vmName) | Where-Object { $_.Tag.Category -eq $TagCategory }
    foreach ($existingTag in $existingTags) {
        Write-Log "Suppression du tag existant $($existingTag.Tag.Name) sur $vmName" -Level WARNING -LogFile $LogFile
        Remove-TagAssignment -TagAssignment $existingTag -Confirm:$false
    }

    $vm = VMware.VimAutomation.Core\Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Log "Ajout du tag $tagName à $vmName" -LogFile $LogFile
        New-TagAssignment -Tag $tagName -Entity $vm
    } else {
        Write-Log "VM non trouvée : $vmName" -Level WARNING -LogFile $LogFile
    }
}

# Création des jobs Veeam par tag
$backupRepo = Get-VBRBackupRepository -Name $BackupRepoName
$vmwareTags = Find-VBRViEntity -Tags -Server $VCenterServer | Where-Object { $_.Name -like $TagNamePattern }

foreach ($tag in $vmwareTags) {
    $jobName = "$BackupJobPrefix$($tag.Name)"
    $job     = Get-VBRJob -Name $jobName -ErrorAction SilentlyContinue

    if (-not $job) {
        Write-Log "Création du job de sauvegarde : $jobName" -LogFile $LogFile
        Add-VBRViBackupJob -Name $jobName -Description "Sauvegarde pour le tag $($tag.Name)" -BackupRepository $backupRepo -Entity $tag | Out-Null
    } else {
        Write-Log "Le job $jobName existe déjà." -LogFile $LogFile
    }
}

Disconnect-VCenter -LogFile $LogFile
Write-Log "step1 terminé." -Level SUCCESS -LogFile $LogFile
