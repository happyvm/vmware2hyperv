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

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile
if ($PSVersionTable.PSEdition -eq "Core") {
    Write-MigrationLog "PowerShell 7 detected: skipping direct import of Veeam.Backup.PowerShell to avoid VMware/Veeam VimService assembly conflicts." -Level WARNING -LogFile $LogFile
    Write-MigrationLog "Veeam commands will run in Windows PowerShell for this step." -Level WARNING -LogFile $LogFile
} else {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
}


$JobName = "Backup-$Tag"

Write-MigrationLog "Starting step2 - VM shutdown and Veeam backup for tag $Tag" -LogFile $LogFile
Assert-PathPresent -Path $CsvFile -Label "batch CSV" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$vmList = Import-Csv -Path $CsvFile -Delimiter ";"

foreach ($vmEntry in $vmList) {
    Write-MigrationLog "Graceful shutdown of VM: $($vmEntry.VMName)" -LogFile $LogFile
    $vmObj = VMware.VimAutomation.Core\Get-VM -Name $vmEntry.VMName -ErrorAction SilentlyContinue
    if (-not $vmObj) {
        Write-MigrationLog "VM not found: $($vmEntry.VMName)" -Level WARNING -LogFile $LogFile
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
            Write-MigrationLog "VM $($vmEntry.VMName) not powered off after ${timeout}s — forced power-off." -Level WARNING -LogFile $LogFile
            VMware.VimAutomation.Core\Stop-VM -VM $vmEntry.VMName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Write-MigrationLog "VM $($vmEntry.VMName) powered off." -Level SUCCESS -LogFile $LogFile
}

Disconnect-VCenter -LogFile $LogFile

Write-MigrationLog "Sending pre-migration email" -LogFile $LogFile
& $PreMigrationMailScript -tagName $Tag -recipientGroup $RecipientGroup -vCenterServer $VCenterServer -SkipVCenterLogin

if ($PSVersionTable.PSEdition -eq "Core") {
    Write-MigrationLog "PowerShell 7 detected: starting the Veeam job in Windows PowerShell to avoid deserialized objects." -Level WARNING -LogFile $LogFile

    $startJobScript = @'
$JobName = $env:VMW2HV_JOB_NAME

Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop
$job = Get-VBRJob -Name $JobName -ErrorAction SilentlyContinue
if (-not $job) {
    Write-Output "[ERROR] Job '$JobName' not found in Veeam."
    exit 1
}

Start-VBRJob -Job $job | Out-Null
Write-Output "[SUCCESS] Job Veeam '$JobName' started successfully."
'@

    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($startJobScript))
    $previousJobName = $env:VMW2HV_JOB_NAME
    $env:VMW2HV_JOB_NAME = $JobName

    try {
        $winPsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript 2>&1
        $winPsExitCode = $LASTEXITCODE
    }
    finally {
        $env:VMW2HV_JOB_NAME = $previousJobName
    }

    foreach ($line in $winPsOutput) {
        if ($line -match '^\[ERROR\]\s+(.*)$') {
            Write-MigrationLog $Matches[1] -Level ERROR -LogFile $LogFile
        } elseif ($line -match '^\[SUCCESS\]\s+(.*)$') {
            Write-MigrationLog $Matches[1] -Level SUCCESS -LogFile $LogFile
        } elseif (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-MigrationLog "Windows PowerShell: $line" -Level INFO -LogFile $LogFile
        }
    }

    if ($winPsExitCode -ne 0) {
        $message = "Failed to start Veeam job '$JobName' in Windows PowerShell (exit code $winPsExitCode)."
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        exit 1
    }
} else {
    $Job = Get-VBRJob -Name $JobName
    if ($Job) {
        Start-VBRJob -Job $Job
        Write-MigrationLog "Job Veeam '$JobName' started successfully." -Level SUCCESS -LogFile $LogFile
    } else {
        Write-MigrationLog "Job '$JobName' not found in Veeam." -Level ERROR -LogFile $LogFile
        exit 1
    }
}
