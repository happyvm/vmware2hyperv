Set-StrictMode -Version Latest

# Tests for Find-VmRestoreSession — bounded pattern matching.
# Focus: the regex pattern that prevents false positives when VM names share prefixes.

Describe 'Find-VmRestoreSession - Bounded pattern matching' {
    BeforeAll {
        # Dot-source the function under test
        . $PSScriptRoot/../powershell-migration/step3/Step3.VeeamRecovery.ps1

        # Helper: create a mock session object with a Name and CreationTime
        function New-MockRestoreSession {
            param(
                [string]$Name,
                [datetime]$CreationTime = (Get-Date)
            )
            $obj = [PSCustomObject]@{
                Name         = $Name
                CreationTime = $CreationTime
                State        = 'Working'
                Result       = 'None'
            }
            # Add PSTypeName so Where-Object / Sort-Object see it as a custom object
            $obj.PSTypeNames.Insert(0, 'Veeam.Backup.Core.CRestoreSession')
            return $obj
        }
    }

    Context 'Bounded pattern — exact match' {
        It 'Matches exact VM name' {
            $sessions = @(
                (New-MockRestoreSession -Name 'WEB1' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'WEB1' -RestoreSessions $sessions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be 'WEB1'
        }

        It 'Matches VMName-migrationhyp suffix' {
            $sessions = @(
                (New-MockRestoreSession -Name 'WEB1-migrationhyp' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'WEB1' -RestoreSessions $sessions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be 'WEB1-migrationhyp'
        }

        It 'Matches bounded pattern: VMName (Instant Recovery) suffix' {
            $sessions = @(
                (New-MockRestoreSession -Name 'WEB1 (Instant Recovery)' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'WEB1' -RestoreSessions $sessions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be 'WEB1 (Instant Recovery)'
        }
    }

    Context 'Bounded pattern — prefix collision avoidance' {
        It 'WEB1 does NOT match WEB10' {
            $sessions = @(
                (New-MockRestoreSession -Name 'WEB10' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'WEB1' -RestoreSessions $sessions
            $result | Should -BeNullOrEmpty
        }

        It 'WEB10 does NOT match WEB1' {
            $sessions = @(
                (New-MockRestoreSession -Name 'WEB1' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'WEB10' -RestoreSessions $sessions
            $result | Should -BeNullOrEmpty
        }

        It 'SRV01 matches SRV01 but not SRV011' {
            $sessions = @(
                (New-MockRestoreSession -Name 'SRV01' -CreationTime (Get-Date '2026-01-01')),
                (New-MockRestoreSession -Name 'SRV011' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'SRV01' -RestoreSessions $sessions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be 'SRV01'
        }

        It 'DB-PROD matches DB-PROD but not DB-PROD-BACKUP' {
            $sessions = @(
                (New-MockRestoreSession -Name 'DB-PROD-BACKUP' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'DB-PROD' -RestoreSessions $sessions
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Bounded pattern — edge cases' {
        It 'VM name with special regex characters is escaped' {
            # VM names with dots, parentheses, etc. should not break the regex
            $sessions = @(
                (New-MockRestoreSession -Name 'VM.01' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'VM.01' -RestoreSessions $sessions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be 'VM.01'
        }

        It 'Returns the most recent session when multiple match' {
            $older = New-MockRestoreSession -Name 'WEB1' -CreationTime (Get-Date '2026-01-01')
            $newer = New-MockRestoreSession -Name 'WEB1' -CreationTime (Get-Date '2026-06-01')
            $sessions = @($older, $newer)
            $result = Find-VmRestoreSession -VmName 'WEB1' -RestoreSessions $sessions
            $result | Should -Not -BeNullOrEmpty
            $result.CreationTime | Should -Be (Get-Date '2026-06-01')
        }

        It 'Returns $null when no session matches' {
            $sessions = @(
                (New-MockRestoreSession -Name 'OTHERVM' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'WEB1' -RestoreSessions $sessions
            $result | Should -BeNullOrEmpty
        }

        It 'Returns $null when sessions array is empty' {
            $result = Find-VmRestoreSession -VmName 'WEB1' -RestoreSessions @()
            $result | Should -BeNullOrEmpty
        }

        It 'VM name with underscore matches correctly' {
            $sessions = @(
                (New-MockRestoreSession -Name 'VM_PROD_01' -CreationTime (Get-Date '2026-01-01'))
            )
            $result = Find-VmRestoreSession -VmName 'VM_PROD_01' -RestoreSessions $sessions
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Be 'VM_PROD_01'
        }
    }
}