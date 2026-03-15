#requires -Version 7.0

param (
    [string]$VCenterServer,
    [string]$CsvFile,
    [string]$TagCategory,
    [string]$BackupRepoName,
    [string]$Tag,      # Optional - to add context to the log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $CsvFile)       { $CsvFile       = $Config.Paths.CsvFile }
if (-not $TagCategory)   { $TagCategory   = $Config.Tags.Category }
if (-not $BackupRepoName){ $BackupRepoName = $Config.Veeam.BackupRepo }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step1-tag-veeam$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile
Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback


Write-Log "Starting step1 - tagging and creating Veeam jobs" -LogFile $LogFile
Assert-FileExists -Path $CsvFile -Label "batch CSV" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

# Check / create the tag category
$category = Get-TagCategory -Name $TagCategory -ErrorAction SilentlyContinue
if (-not $category) {
    Write-Log "Creating tag category: $TagCategory" -LogFile $LogFile
    New-TagCategory -Name $TagCategory -Cardinality Single -EntityType VirtualMachine
}

$csvData = Import-Csv -Path $CsvFile -Delimiter ";"

foreach ($entry in $csvData) {
    $vmName  = $entry.VMName
    $tagName = $entry.Tag.Trim()

    $existingTag = Get-Tag -Name $tagName -ErrorAction SilentlyContinue
    if (-not $existingTag) {
        Write-Log "Creating tag: $tagName" -LogFile $LogFile
        New-Tag -Name $tagName -Category $TagCategory
    }

    $existingTags = Get-TagAssignment -Entity (VMware.VimAutomation.Core\Get-VM -Name $vmName) | Where-Object { $_.Tag.Category -eq $TagCategory }
    foreach ($existingTag in $existingTags) {
        Write-Log "Removing existing tag $($existingTag.Tag.Name) from $vmName" -Level WARNING -LogFile $LogFile
        Remove-TagAssignment -TagAssignment $existingTag -Confirm:$false
    }

    $vm = VMware.VimAutomation.Core\Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Log "Adding tag $tagName to $vmName" -LogFile $LogFile
        New-TagAssignment -Tag $tagName -Entity $vm
    } else {
        Write-Log "VM not found: $vmName" -Level WARNING -LogFile $LogFile
    }
}

# Creating Veeam jobs by tag
$backupRepo = Get-VBRBackupRepository -Name $BackupRepoName
$vmwareTags = Find-VBRViEntity -Tags -Server $VCenterServer | Where-Object { $_.Name -like "HypMig-lot-*" }

foreach ($vmwareTag in $vmwareTags) {
    $jobName = "Backup-$($vmwareTag.Name)"
    $job     = Get-VBRJob -Name $jobName -ErrorAction SilentlyContinue

    if (-not $job) {
        Write-Log "Creating backup job: $jobName" -LogFile $LogFile
        Add-VBRViBackupJob -Name $jobName -Description "Backup for tag $($vmwareTag.Name)" -BackupRepository $backupRepo -Entity $vmwareTag | Out-Null
    } else {
        Write-Log "The job $jobName already exists." -LogFile $LogFile
    }
}

Disconnect-VCenter -LogFile $LogFile
Write-Log "step1 completed." -Level SUCCESS -LogFile $LogFile
