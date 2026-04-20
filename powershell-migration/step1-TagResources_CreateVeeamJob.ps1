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
if ($PSVersionTable.PSEdition -eq "Core") {
    Write-MigrationLog "PowerShell 7 detected: skipping direct import of Veeam.Backup.PowerShell to avoid VMware/Veeam VimService assembly conflicts." -Level WARNING -LogFile $LogFile
    Write-MigrationLog "Veeam commands will run in Windows PowerShell for this step." -Level WARNING -LogFile $LogFile
} else {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
}


Write-MigrationLog "Starting step1 - tagging and creating Veeam jobs" -LogFile $LogFile
Assert-PathPresent -Path $CsvFile -Label "batch CSV" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

# Check / create the tag category
$category = Get-TagCategory -Name $TagCategory -ErrorAction SilentlyContinue
if (-not $category) {
    Write-MigrationLog "Creating tag category: $TagCategory" -LogFile $LogFile
    New-TagCategory -Name $TagCategory -Cardinality Single -EntityType VirtualMachine
}

$csvData = Import-Csv -Path $CsvFile -Delimiter ";"
$csvTags = $csvData |
    ForEach-Object { $_.Tag } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim() } |
    Sort-Object -Unique

foreach ($entry in $csvData) {
    $vmName  = $entry.VMName
    if ([string]::IsNullOrWhiteSpace($entry.Tag)) {
        Write-MigrationLog "Missing tag in CSV for VM '$vmName'. Skipping this entry." -Level WARNING -LogFile $LogFile
        continue
    }

    $tagName = $entry.Tag.Trim()

    $existingTag = Get-Tag -Name $tagName -ErrorAction SilentlyContinue
    if (-not $existingTag) {
        Write-MigrationLog "Creating tag: $tagName" -LogFile $LogFile
        New-Tag -Name $tagName -Category $TagCategory
    }

    $existingTags = Get-TagAssignment -Entity (VMware.VimAutomation.Core\Get-VM -Name $vmName) | Where-Object { $_.Tag.Category -eq $TagCategory }
    foreach ($existingTag in $existingTags) {
        Write-MigrationLog "Removing existing tag $($existingTag.Tag.Name) from $vmName" -Level WARNING -LogFile $LogFile
        Remove-TagAssignment -TagAssignment $existingTag -Confirm:$false
    }

    $vm = VMware.VimAutomation.Core\Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-MigrationLog "Adding tag $tagName to $vmName" -LogFile $LogFile
        New-TagAssignment -Tag $tagName -Entity $vm
    } else {
        Write-MigrationLog "VM not found: $vmName" -Level WARNING -LogFile $LogFile
    }
}

# Creating Veeam jobs by tag from CSV (configurable and deterministic)
if ($PSVersionTable.PSEdition -eq "Core") {
    Write-MigrationLog "PowerShell 7 detected: creating Veeam jobs in Windows PowerShell to avoid deserialized repository objects." -Level WARNING -LogFile $LogFile

    $tagsJson = $csvTags | ConvertTo-Json -Compress
    $jobCreationScript = @'
$BackupRepoName = $env:VMW2HV_BACKUP_REPO_NAME
$VCenterServer = $env:VMW2HV_VCENTER_SERVER
$TagsJson = $env:VMW2HV_TAGS_JSON

Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop
$backupRepo = Get-VBRBackupRepository -Name $BackupRepoName -ErrorAction Stop
$availableVeeamTags = Find-VBRViEntity -Tags -Server $VCenterServer
$tags = @()
if (-not [string]::IsNullOrWhiteSpace($TagsJson)) {
    $tags = ConvertFrom-Json -InputObject $TagsJson
}

if ($tags -isnot [System.Array]) {
    $tags = @($tags)
}

foreach ($tagName in $tags) {
    $vmwareTag = $availableVeeamTags | Where-Object { $_.Name -eq $tagName } | Select-Object -First 1
    if (-not $vmwareTag) {
        Write-Output "[WARNING] Tag '$tagName' not found in VMware/Veeam inventory. Skipping job creation for this tag."
        continue
    }

    $jobName = "Backup-$tagName"
    $job = Get-VBRJob -Name $jobName -ErrorAction SilentlyContinue

    if (-not $job) {
        Add-VBRViBackupJob -Name $jobName -Description "Backup for tag $tagName" -BackupRepository $backupRepo -Entity $vmwareTag | Out-Null
        Write-Output "[SUCCESS] Created backup job: $jobName"
    } else {
        Write-Output "[INFO] The job $jobName already exists."
    }
}
'@

    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($jobCreationScript))
    $previousBackupRepoName = $env:VMW2HV_BACKUP_REPO_NAME
    $previousVCenterServer = $env:VMW2HV_VCENTER_SERVER
    $previousTagsJson = $env:VMW2HV_TAGS_JSON

    $env:VMW2HV_BACKUP_REPO_NAME = $BackupRepoName
    $env:VMW2HV_VCENTER_SERVER = $VCenterServer
    $env:VMW2HV_TAGS_JSON = $tagsJson

    try {
        $winPsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript 2>&1
        $winPsExitCode = $LASTEXITCODE
    }
    finally {
        $env:VMW2HV_BACKUP_REPO_NAME = $previousBackupRepoName
        $env:VMW2HV_VCENTER_SERVER = $previousVCenterServer
        $env:VMW2HV_TAGS_JSON = $previousTagsJson
    }

    foreach ($line in $winPsOutput) {
        if ($line -match '^\[WARNING\]\s+(.*)$') {
            Write-MigrationLog $Matches[1] -Level WARNING -LogFile $LogFile
        } elseif ($line -match '^\[SUCCESS\]\s+(.*)$') {
            Write-MigrationLog $Matches[1] -Level SUCCESS -LogFile $LogFile
        } elseif ($line -match '^\[INFO\]\s+(.*)$') {
            Write-MigrationLog $Matches[1] -Level INFO -LogFile $LogFile
        } elseif (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-MigrationLog "Windows PowerShell: $line" -Level INFO -LogFile $LogFile
        }
    }

    if ($winPsExitCode -ne 0) {
        $message = "Veeam job creation failed in Windows PowerShell (exit code $winPsExitCode)."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }
} else {
    $backupRepo = Get-VBRBackupRepository -Name $BackupRepoName
    $availableVeeamTags = Find-VBRViEntity -Tags -Server $VCenterServer

    foreach ($tagName in $csvTags) {
        $vmwareTag = $availableVeeamTags | Where-Object { $_.Name -eq $tagName } | Select-Object -First 1
        if (-not $vmwareTag) {
            Write-MigrationLog "Tag '$tagName' not found in VMware/Veeam inventory. Skipping job creation for this tag." -Level WARNING -LogFile $LogFile
            continue
        }

        $jobName = "Backup-$tagName"
        $job     = Get-VBRJob -Name $jobName -ErrorAction SilentlyContinue

        if (-not $job) {
            Write-MigrationLog "Creating backup job: $jobName" -LogFile $LogFile
            Add-VBRViBackupJob -Name $jobName -Description "Backup for tag $tagName" -BackupRepository $backupRepo -Entity $vmwareTag | Out-Null
        } else {
            Write-MigrationLog "The job $jobName already exists." -LogFile $LogFile
        }
    }
}

Disconnect-VCenter -LogFile $LogFile
Write-MigrationLog "step1 completed." -Level SUCCESS -LogFile $LogFile
