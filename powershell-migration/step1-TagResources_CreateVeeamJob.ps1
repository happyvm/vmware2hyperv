<#
.SYNOPSIS
    Tag VMware resources and create Veeam backup jobs for a migration batch.

.DESCRIPTION
    Reads the batch CSV, applies VMware tags to the listed VMs under a configurable
    tag category, and creates or updates the corresponding Veeam backup job(s) for
    the batch. Handles tag cleanup of previous assignments before applying the new set.

.PARAMETER VCenterServer
    vCenter server name or IP. Defaults to Config.VCenter.Server.

.PARAMETER CsvFile
    Path to the batch CSV file. Defaults to Config.Paths.CsvFile.

.PARAMETER TagCategory
    VMware tag category name. Defaults to Config.Tags.Category.

.PARAMETER BackupRepoName
    Veeam backup repository name. Defaults to Config.Veeam.BackupRepo.

.PARAMETER BackupProxyName
    Veeam backup proxy name. Defaults to Config.Veeam.BackupProxy.

.PARAMETER Tag
    Optional batch tag for log file naming context.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step1-TagResources_CreateVeeamJob.ps1 -Tag HypMig-lot-118

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI and Veeam.Backup.PowerShell modules.
#>

param (
    [string]$VCenterServer,
    [string]$CsvFile,
    [string]$TagCategory,
    [string]$BackupRepoName,
    [string]$BackupProxyName,
    [string]$Tag,      # Optional - to add context to the log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $CsvFile)       { $CsvFile       = $Config.Paths.CsvFile }
if (-not $TagCategory)   { $TagCategory   = $Config.Tags.Category }
if (-not $BackupRepoName){ $BackupRepoName = $Config.Veeam.BackupRepo }
if (-not $BackupProxyName){ $BackupProxyName = $Config.Veeam.BackupProxy }
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

# VMware cleanup: remove tag assignments from any VM currently carrying one of the tags defined in the CSV.
# This ensures we reset the batching scope before re-applying the desired CSV state.
# Assignments are collected for all tags first, then their VMs are resolved in a single
# bulk Get-VM call (the previous version issued one Get-VM per assignment).
$cleanupEntries = @(foreach ($csvTag in $csvTags) {
    $existingCsvTag = Get-Tag -Name $csvTag -Category $TagCategory -ErrorAction SilentlyContinue
    if (-not $existingCsvTag) {
        Write-MigrationLog "Cleanup: tag '$csvTag' does not exist yet in VMware. Nothing to remove for this tag." -LogFile $LogFile
        continue
    }

    $taggedVmAssignments = @(Get-TagAssignment -Tag $existingCsvTag -ErrorAction SilentlyContinue |
        Where-Object { $_.Entity -and $_.Entity.GetType().Name -eq 'VirtualMachine' })

    if (-not $taggedVmAssignments) {
        Write-MigrationLog "Cleanup: no VMware VM found with tag '$csvTag'." -LogFile $LogFile
        continue
    }

    foreach ($assignment in $taggedVmAssignments) {
        [pscustomobject]@{ Tag = $csvTag; Assignment = $assignment }
    }
})

if ($cleanupEntries) {
    $cleanupVmNamesByEntityId = @{}
    $cleanupEntityIds = @($cleanupEntries | ForEach-Object { [string]$_.Assignment.Entity.Id } | Select-Object -Unique)
    foreach ($cleanupVm in @(VMware.VimAutomation.Core\Get-VM -Id $cleanupEntityIds -ErrorAction SilentlyContinue)) {
        $cleanupVmNamesByEntityId[[string]$cleanupVm.Id] = [string]$cleanupVm.Name
    }

    foreach ($cleanupEntry in $cleanupEntries) {
        $csvTag = $cleanupEntry.Tag
        $entityId = [string]$cleanupEntry.Assignment.Entity.Id
        if (-not $cleanupVmNamesByEntityId.ContainsKey($entityId)) {
            Write-MigrationLog "Cleanup: unable to resolve VM from tag assignment for tag '$csvTag'. Skipping." -Level WARNING -LogFile $LogFile
            continue
        }

        $taggedVmName = $cleanupVmNamesByEntityId[$entityId]
        Write-MigrationLog "Cleanup: removing CSV tag '$csvTag' from VMware VM '$taggedVmName'." -Level WARNING -LogFile $LogFile
        Remove-TagAssignment -TagAssignment $cleanupEntry.Assignment -Confirm:$false -ErrorAction Stop
        Write-MigrationLog "Cleanup: tag '$csvTag' removed from VMware VM '$taggedVmName'." -Level SUCCESS -LogFile $LogFile
    }
}

# Bulk lookups before the assignment loop (previously one Get-VM and one
# Get-TagAssignment per CSV row): resolve all batch VMs in one call and load every
# assignment of the category once, indexed by entity Id.
$csvVmNames = @($csvData | ForEach-Object { $_.VMName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$vmsByName = @{}
if ($csvVmNames) {
    foreach ($vmObject in @(VMware.VimAutomation.Core\Get-VM -Name $csvVmNames -ErrorAction SilentlyContinue)) {
        if ($vmObject -and -not $vmsByName.ContainsKey($vmObject.Name)) {
            $vmsByName[$vmObject.Name] = $vmObject
        }
    }
}

$assignmentsByEntityId = @{}
try {
    foreach ($assignment in @(Get-TagAssignment -Category $TagCategory -ErrorAction Stop)) {
        $entityId = [string]$assignment.Entity.Id
        if (-not $assignmentsByEntityId.ContainsKey($entityId)) {
            $assignmentsByEntityId[$entityId] = New-Object System.Collections.ArrayList
        }
        [void]$assignmentsByEntityId[$entityId].Add($assignment)
    }
} catch {
    Write-MigrationLog "Bulk tag assignment lookup failed ($($_.Exception.Message)); falling back to per-VM queries." -Level WARNING -LogFile $LogFile
    $assignmentsByEntityId = $null
}

$processedVmNames = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($entry in $csvData) {
    $vmName  = $entry.VMName
    if ([string]::IsNullOrWhiteSpace($entry.Tag)) {
        Write-MigrationLog "Missing tag in CSV for VM '$vmName'. Skipping this entry." -Level WARNING -LogFile $LogFile
        continue
    }

    if (-not [string]::IsNullOrWhiteSpace($vmName) -and -not $processedVmNames.Add($vmName)) {
        Write-MigrationLog "Duplicate CSV row for VM '$vmName'. Skipping this entry." -Level WARNING -LogFile $LogFile
        continue
    }

    $tagName = $entry.Tag.Trim()

    $existingTag = Get-Tag -Name $tagName -Category $TagCategory -ErrorAction SilentlyContinue
    if (-not $existingTag) {
        Write-MigrationLog "Creating tag: $tagName" -LogFile $LogFile
        $existingTag = New-Tag -Name $tagName -Category $TagCategory
    }

    $vm = $null
    if (-not [string]::IsNullOrWhiteSpace($vmName) -and $vmsByName.ContainsKey($vmName)) {
        $vm = $vmsByName[$vmName]
    }
    if (-not $vm) {
        Write-MigrationLog "VM not found: $vmName" -Level WARNING -LogFile $LogFile
        continue
    }

    $existingAssignments = if ($null -ne $assignmentsByEntityId) {
        $vmEntityId = [string]$vm.Id
        if ($assignmentsByEntityId.ContainsKey($vmEntityId)) { @($assignmentsByEntityId[$vmEntityId]) } else { @() }
    } else {
        @(Get-TagAssignment -Entity $vm -ErrorAction SilentlyContinue | Where-Object { $_.Tag.Category -eq $TagCategory })
    }
    foreach ($existingAssignment in $existingAssignments) {
        Write-MigrationLog "Removing existing tag $($existingAssignment.Tag.Name) from $vmName" -Level WARNING -LogFile $LogFile
        Remove-TagAssignment -TagAssignment $existingAssignment -Confirm:$false
    }

    Write-MigrationLog "Adding tag $tagName to $vmName" -LogFile $LogFile
    # Assign the resolved tag object: a bare name is ambiguous when a same-named tag
    # exists in another category.
    New-TagAssignment -Tag $existingTag -Entity $vm | Out-Null
}

# Creating Veeam jobs by tag from CSV (configurable and deterministic)
if ($PSVersionTable.PSEdition -eq "Core") {
    Write-MigrationLog "PowerShell 7 detected: creating Veeam jobs in Windows PowerShell to avoid deserialized repository objects." -Level WARNING -LogFile $LogFile

    $tagsJson = $csvTags | ConvertTo-Json -Compress
    $jobCreationScript = @'
$BackupRepoName = $env:VMW2HV_BACKUP_REPO_NAME
$VCenterServer = $env:VMW2HV_VCENTER_SERVER
$TagsJson = $env:VMW2HV_TAGS_JSON
$BackupProxyName = $env:VMW2HV_BACKUP_PROXY_NAME

Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop
$backupRepo = Get-VBRBackupRepository -Name $BackupRepoName -ErrorAction Stop
$availableVeeamTags = Find-VBRViEntity -Tags -Server $VCenterServer
$backupProxy = $null
if (-not [string]::IsNullOrWhiteSpace($BackupProxyName)) {
    $backupProxy = Get-VBRViProxy -Name $BackupProxyName -ErrorAction SilentlyContinue
    if (-not $backupProxy) {
        Write-Output "[ERROR] Backup proxy '$BackupProxyName' not found in Veeam."
        exit 1
    }
    Write-Output "[INFO] Using backup proxy '$BackupProxyName' for newly created jobs."
}
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
        if ($backupProxy) {
            Add-VBRViBackupJob -Name $jobName -Description "Backup for tag $tagName" -BackupRepository $backupRepo -Entity $vmwareTag -Proxy $backupProxy | Out-Null
        } else {
            Add-VBRViBackupJob -Name $jobName -Description "Backup for tag $tagName" -BackupRepository $backupRepo -Entity $vmwareTag | Out-Null
        }
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
    $previousBackupProxyName = $env:VMW2HV_BACKUP_PROXY_NAME

    $env:VMW2HV_BACKUP_REPO_NAME = $BackupRepoName
    $env:VMW2HV_VCENTER_SERVER = $VCenterServer
    $env:VMW2HV_TAGS_JSON = $tagsJson
    $env:VMW2HV_BACKUP_PROXY_NAME = $BackupProxyName

    try {
        $winPsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript 2>&1
        $winPsExitCode = $LASTEXITCODE
    }
    finally {
        $env:VMW2HV_BACKUP_REPO_NAME = $previousBackupRepoName
        $env:VMW2HV_VCENTER_SERVER = $previousVCenterServer
        $env:VMW2HV_TAGS_JSON = $previousTagsJson
        $env:VMW2HV_BACKUP_PROXY_NAME = $previousBackupProxyName
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
$backupProxy = $null
    if (-not [string]::IsNullOrWhiteSpace($BackupProxyName)) {
        $backupProxy = Get-VBRViProxy -Name $BackupProxyName -ErrorAction SilentlyContinue
        if (-not $backupProxy) {
            $message = "Backup proxy '$BackupProxyName' not found in Veeam."
            Write-MigrationLog $message -Level ERROR -LogFile $LogFile
            throw $message
        }
        Write-MigrationLog "Using backup proxy '$BackupProxyName' for newly created jobs." -LogFile $LogFile
    }

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
            if ($backupProxy) {
                Add-VBRViBackupJob -Name $jobName -Description "Backup for tag $tagName" -BackupRepository $backupRepo -Entity $vmwareTag -Proxy $backupProxy | Out-Null
            } else {
                Add-VBRViBackupJob -Name $jobName -Description "Backup for tag $tagName" -BackupRepository $backupRepo -Entity $vmwareTag | Out-Null
            }
        } else {
            Write-MigrationLog "The job $jobName already exists." -LogFile $LogFile
        }
    }
}

Disconnect-VCenter -LogFile $LogFile
Write-MigrationLog "step1 completed." -Level SUCCESS -LogFile $LogFile
