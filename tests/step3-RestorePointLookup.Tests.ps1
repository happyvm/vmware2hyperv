<#
.SYNOPSIS
    Tests for the Veeam restore point lookup used by step3 Instant Recovery.
.DESCRIPTION
    Reproduces the "No restore point found for VM 'x' in job 'y'" failure and
    the two code-level causes behind it: only the first backup carrying the job
    name was considered, and the machine name was only ever read from .Name.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MigrationRoot = Join-Path $script:RepoRoot 'powershell-migration'

    # The restore point resolution runs inside a Veeam compat-session scriptblock,
    # so it is exercised here through a faithful transcription of that block,
    # guarded by the source assertions in the last Describe.
    function script:Resolve-TestRestorePoint {
        param(
            [Parameter(Mandatory = $true)][string]$JobName,
            [Parameter(Mandatory = $true)][string]$Vm,
            [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AllBackups,
            [Parameter(Mandatory = $true)][hashtable]$RestorePointsByBackupId
        )

        $backups = @($AllBackups | Where-Object { $_.Name -eq $JobName })
        if ($backups.Count -eq 0) {
            throw "Backup job '$JobName' not found in Veeam."
        }

        $restorePoints = @(foreach ($backupEntry in $backups) {
            if ($RestorePointsByBackupId.ContainsKey($backupEntry.Id)) { $RestorePointsByBackupId[$backupEntry.Id] }
        })

        $restorePointsByName = @{}
        foreach ($restorePointEntry in $restorePoints) {
            foreach ($namePropertyName in @('Name', 'VmName')) {
                $nameProperty = $restorePointEntry.PSObject.Properties[$namePropertyName]
                if (-not $nameProperty) { continue }
                $machineName = [string]$nameProperty.Value
                if ([string]::IsNullOrWhiteSpace($machineName)) { continue }
                $machineKey = $machineName.Trim().ToLowerInvariant()
                if (-not $restorePointsByName.ContainsKey($machineKey)) {
                    $restorePointsByName[$machineKey] = New-Object System.Collections.ArrayList
                }
                [void]$restorePointsByName[$machineKey].Add($restorePointEntry)
            }
        }

        $vmKey = $Vm.Trim().ToLowerInvariant()
        if (-not $restorePointsByName.ContainsKey($vmKey)) {
            return $null
        }

        return @($restorePointsByName[$vmKey]) |
            Sort-Object -Property CreationTime -Descending |
            Select-Object -First 1
    }

    function script:New-TestRestorePoint {
        param([string]$Name, [datetime]$CreationTime, [switch]$UseVmNameProperty)
        if ($UseVmNameProperty) {
            return [pscustomobject]@{ VmName = $Name; CreationTime = $CreationTime }
        }
        return [pscustomobject]@{ Name = $Name; CreationTime = $CreationTime }
    }
}

Describe 'Restore point lookup across same-named backups' {

    # Deleting and recreating a job leaves the previous backup behind under the
    # same name. Taking Select-Object -First 1 among them picked an arbitrary
    # one, so a lot whose restore points were visible in the Veeam console could
    # still report "no restore point found".
    It 'finds the restore point even when an older empty backup shares the job name' {
        $backups = @(
            [pscustomobject]@{ Name = 'Backup-HypMig-lot-test'; Id = 'stale' },
            [pscustomobject]@{ Name = 'Backup-HypMig-lot-test'; Id = 'current' }
        )
        $points = @{
            'stale'   = @()
            'current' = @(New-TestRestorePoint -Name 'testjcv-mighyp03' -CreationTime (Get-Date))
        }

        $result = Resolve-TestRestorePoint -JobName 'Backup-HypMig-lot-test' -Vm 'testjcv-mighyp03' `
            -AllBackups $backups -RestorePointsByBackupId $points
        $result | Should -Not -BeNullOrEmpty
    }

    It 'finds it whichever of the two backups Veeam enumerates first' {
        $backups = @(
            [pscustomobject]@{ Name = 'Backup-HypMig-lot-test'; Id = 'current' },
            [pscustomobject]@{ Name = 'Backup-HypMig-lot-test'; Id = 'stale' }
        )
        $points = @{
            'current' = @(New-TestRestorePoint -Name 'testjcv-mighyp03' -CreationTime (Get-Date))
            'stale'   = @()
        }

        Resolve-TestRestorePoint -JobName 'Backup-HypMig-lot-test' -Vm 'testjcv-mighyp03' `
            -AllBackups $backups -RestorePointsByBackupId $points | Should -Not -BeNullOrEmpty
    }

    It 'takes the most recent restore point when several exist' {
        $old = New-TestRestorePoint -Name 'testjcv-mighyp03' -CreationTime (Get-Date).AddDays(-3)
        $new = New-TestRestorePoint -Name 'testjcv-mighyp03' -CreationTime (Get-Date)
        $backups = @([pscustomobject]@{ Name = 'J'; Id = 'b1' })

        $result = Resolve-TestRestorePoint -JobName 'J' -Vm 'testjcv-mighyp03' `
            -AllBackups $backups -RestorePointsByBackupId @{ 'b1' = @($old, $new) }
        $result.CreationTime | Should -Be $new.CreationTime
    }

    It 'matches a restore point that exposes the machine as VmName' {
        $backups = @([pscustomobject]@{ Name = 'J'; Id = 'b1' })
        $points = @{ 'b1' = @(New-TestRestorePoint -Name 'testjcv-mighyp08' -CreationTime (Get-Date) -UseVmNameProperty) }

        Resolve-TestRestorePoint -JobName 'J' -Vm 'testjcv-mighyp08' `
            -AllBackups $backups -RestorePointsByBackupId $points | Should -Not -BeNullOrEmpty
    }

    It 'ignores case and surrounding whitespace on the VM name' {
        $backups = @([pscustomobject]@{ Name = 'J'; Id = 'b1' })
        $points = @{ 'b1' = @(New-TestRestorePoint -Name 'TestJCV-MigHyp16' -CreationTime (Get-Date)) }

        Resolve-TestRestorePoint -JobName 'J' -Vm '  testjcv-mighyp16 ' `
            -AllBackups $backups -RestorePointsByBackupId $points | Should -Not -BeNullOrEmpty
    }

    It 'still returns nothing for a VM that genuinely has no restore point' {
        $backups = @([pscustomobject]@{ Name = 'J'; Id = 'b1' })
        $points = @{ 'b1' = @(New-TestRestorePoint -Name 'other-vm' -CreationTime (Get-Date)) }

        Resolve-TestRestorePoint -JobName 'J' -Vm 'testjcv-mighyp03' `
            -AllBackups $backups -RestorePointsByBackupId $points | Should -BeNullOrEmpty
    }

    It 'still reports a job that does not exist at all' {
        { Resolve-TestRestorePoint -JobName 'Missing' -Vm 'x' -AllBackups @() -RestorePointsByBackupId @{} } |
            Should -Throw "*not found in Veeam*"
    }
}

Describe 'step3 Instant Recovery source' {

    BeforeAll {
        $script:BulkSource = Get-Content -Path (Join-Path $script:MigrationRoot 'step3-StartInstantRecovery.ps1') -Raw
        $script:RecoverySource = Get-Content -Path (Join-Path $script:MigrationRoot 'step3/Step3.VeeamRecovery.ps1') -Raw
    }

    It 'no longer picks a single arbitrary backup by name' {
        foreach ($source in @($script:BulkSource, $script:RecoverySource)) {
            $source | Should -Not -Match 'Get-VBRBackup \| Where-Object \{ \$_\.Name -eq \$JobName \} \| Select-Object -First 1'
            $source | Should -Match '\$backups = @\(Get-VBRBackup \| Where-Object \{ \$_\.Name -eq \$JobName \}\)'
        }
    }

    It 'matches the machine on Name or VmName' {
        foreach ($source in @($script:BulkSource, $script:RecoverySource)) {
            $source | Should -Match "@\('Name', 'VmName'\)"
        }
    }

    It 'reports what Veeam actually holds when a VM has no restore point' {
        $script:BulkSource | Should -Match 'Machines with a restore point in this job'
        $script:RecoverySource | Should -Match 'Machines with a restore point in this job'
    }

    It 'logs the Veeam inventory once before the per-VM outcomes' {
        $script:BulkSource | Should -Match 'InventoryLine'
        $script:BulkSource | Should -Match 'backup\(s\), \$\(\$restorePoints\.Count\) restore point\(s\)'
    }
}

Describe 'Write-MigrationLog ERROR rendering' {

    BeforeAll {
        . (Join-Path $script:MigrationRoot 'lib.ps1')
        $script:LibSource = Get-Content -Path (Join-Path $script:MigrationRoot 'lib.ps1') -Raw
    }

    # Write-Error turned every reported failure into a PowerShell error record
    # pointing at the logger's own call site, burying the message under a
    # source-line block and a squiggle underline.
    It 'does not raise a PowerShell error record for a logged ERROR line' {
        $script:LibSource | Should -Not -Match 'Write-Error -Message \$entry'
        $script:LibSource | Should -Match '\$Host\.UI\.WriteErrorLine\(\$entry\)'
    }

    It 'still writes the ERROR line to the log file' {
        $logFile = Join-Path $TestDrive 'migration.log'
        Write-MigrationLog 'boom' -Level ERROR -LogFile $logFile
        (Get-Content -Path $logFile -Raw) | Should -Match '\[ERROR\] boom'
    }

    It 'does not populate $Error with the log line' {
        $Error.Clear()
        Write-MigrationLog 'handled failure' -Level ERROR
        @($Error | Where-Object { "$_" -match 'handled failure' }).Count | Should -Be 0
    }
}
