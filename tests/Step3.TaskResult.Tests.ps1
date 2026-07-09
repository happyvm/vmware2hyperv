Set-StrictMode -Version Latest

# Pester 6 requires commands to exist before mocking.
# Define stub functions in script scope inside BeforeAll.

Describe 'New-Step3TaskResult' {
    BeforeAll {
        # Dot-source the module under test
        $modulePath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'step3' 'Step3.TaskResult.ps1'
        . $modulePath
    }

    It 'creates a result object with Running status' {
        $result = New-Step3TaskResult -Context @{ VMName = 'TEST-VM' }
        $result.Status | Should -Be 'Running'
    }

    It 'stores the context' {
        $ctx = @{ VMName = 'TEST-VM'; VlanId = '100' }
        $result = New-Step3TaskResult -Context $ctx
        $result.Context.VMName | Should -Be 'TEST-VM'
        $result.Context.VlanId | Should -Be '100'
    }

    It 'has a StartedAt timestamp' {
        $result = New-Step3TaskResult -Context @{}
        [DateTime]::Parse($result.StartedAt) | Should -BeOfType [DateTime]
    }

    It 'initialises Phases as an empty ordered dictionary' {
        $result = New-Step3TaskResult -Context @{}
        $result.Phases.Count | Should -Be 0
    }
}

Describe 'Add-Step3PhaseResult' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'step3' 'Step3.TaskResult.ps1'
        . $modulePath
    }

    BeforeEach {
        $script:result = New-Step3TaskResult -Context @{ VMName = 'TEST-VM' }
    }

    It 'adds a Success phase without changing overall status from Running' {
        Add-Step3PhaseResult -Result $result -Phase 'TestPhase' -Status 'Success' -Message 'OK'
        $result.Phases.TestPhase.Status | Should -Be 'Success'
        $result.Status | Should -Be 'Running'
    }

    It 'adds a Failed phase and sets overall status to Failed' {
        Add-Step3PhaseResult -Result $result -Phase 'CriticalPhase' -Status 'Failed' -Message 'Boom'
        $result.Phases.CriticalPhase.Status | Should -Be 'Failed'
        $result.Status | Should -Be 'Failed'
    }

    It 'adds a Warning phase and sets overall to CompletedWithWarnings' {
        Add-Step3PhaseResult -Result $result -Phase 'WarningPhase' -Status 'Warning' -Message 'Degraded'
        $result.Status | Should -Be 'CompletedWithWarnings'
    }

    It 'does not downgrade Failed to CompletedWithWarnings on subsequent Warning' {
        Add-Step3PhaseResult -Result $result -Phase 'First' -Status 'Failed' -Message 'Boom'
        Add-Step3PhaseResult -Result $result -Phase 'Second' -Status 'Warning' -Message 'Degraded'
        $result.Status | Should -Be 'Failed'
    }

    It 'records Skipped phase without affecting overall status' {
        Add-Step3PhaseResult -Result $result -Phase 'SkipMe' -Status 'Skipped' -Message 'N/A'
        $result.Phases.SkipMe.Status | Should -Be 'Skipped'
        $result.Status | Should -Be 'Running'
    }

    It 'stores message and timestamp' {
        Add-Step3PhaseResult -Result $result -Phase 'Test' -Status 'Success' -Message 'Hello'
        $result.Phases.Test.Message | Should -Be 'Hello'
        [DateTime]::Parse($result.Phases.Test.Timestamp) | Should -BeOfType [DateTime]
    }

    It 'stores metadata in Data' {
        Add-Step3PhaseResult -Result $result -Phase 'Net' -Status 'Success' `
            -Message 'OK' -Data @{ MacCount = 2; Vlan = '100' }
        $result.Phases.Net.Data.MacCount | Should -Be 2
        $result.Phases.Net.Data.Vlan | Should -Be '100'
    }

    It 'rejects invalid status values' {
        { Add-Step3PhaseResult -Result $result -Phase 'Bad' -Status 'Error' } |
            Should -Throw
    }

    It 'handles multiple phases independently' {
        Add-Step3PhaseResult -Result $result -Phase 'Phase1' -Status 'Success' -Message 'One'
        Add-Step3PhaseResult -Result $result -Phase 'Phase2' -Status 'Warning' -Message 'Two'
        Add-Step3PhaseResult -Result $result -Phase 'Phase3' -Status 'Success' -Message 'Three'

        $result.Phases.Count | Should -Be 3
        $result.Status | Should -Be 'CompletedWithWarnings'
    }
}

Describe 'Complete-Step3TaskResult' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'step3' 'Step3.TaskResult.ps1'
        . $modulePath
    }

    It 'sets Running → Success and adds CompletedAt' {
        $result = New-Step3TaskResult -Context @{}
        Complete-Step3TaskResult -Result $result
        $result.Status | Should -Be 'Success'
        [DateTime]::Parse($result.CompletedAt) | Should -BeOfType [DateTime]
    }

    It 'preserves Failed status' {
        $result = New-Step3TaskResult -Context @{}
        Add-Step3PhaseResult -Result $result -Phase 'Fail' -Status 'Failed' -Message 'Boom'
        Complete-Step3TaskResult -Result $result
        $result.Status | Should -Be 'Failed'
    }

    It 'preserves CompletedWithWarnings status' {
        $result = New-Step3TaskResult -Context @{}
        Add-Step3PhaseResult -Result $result -Phase 'Warn' -Status 'Warning' -Message 'oops'
        Complete-Step3TaskResult -Result $result
        $result.Status | Should -Be 'CompletedWithWarnings'
    }
}

Describe 'Get-Step3NetworkConfigurationState' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'step3' 'Step3.TaskResult.ps1'
        . $modulePath
    }

    It 'returns Configured for successful NetworkConfiguration phase' {
        $result = New-Step3TaskResult -Context @{}
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Success' -Message 'Network configured'
        Get-Step3NetworkConfigurationState -Result $result | Should -Be 'Configured'
    }

    It 'returns ConfiguredWithWarning for Warning NetworkConfiguration phase' {
        $result = New-Step3TaskResult -Context @{}
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Warning' -Message 'Fallback used'
        Get-Step3NetworkConfigurationState -Result $result | Should -Be 'ConfiguredWithWarning'
    }

    It 'returns NotDetected for Failed NetworkConfiguration phase' {
        $result = New-Step3TaskResult -Context @{}
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Failed' -Message 'Config failed'
        Get-Step3NetworkConfigurationState -Result $result | Should -Be 'NotDetected'
    }

    It 'returns NotDetected for Skipped NetworkConfiguration phase' {
        $result = New-Step3TaskResult -Context @{}
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Skipped' -Message 'N/A'
        Get-Step3NetworkConfigurationState -Result $result | Should -Be 'NotDetected'
    }

    It 'returns NotDetected when no NetworkConfiguration phase exists' {
        $result = New-Step3TaskResult -Context @{}
        Add-Step3PhaseResult -Result $result -Phase 'OtherPhase' `
            -Status 'Success' -Message 'Done'
        Get-Step3NetworkConfigurationState -Result $result | Should -Be 'NotDetected'
    }
}

Describe 'Write-Step3TaskResult' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'step3' 'Step3.TaskResult.ps1'
        . $modulePath
    }

    It 'writes a valid JSON file' {
        $result = New-Step3TaskResult -Context @{ VMName = 'TEST-VM' }
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Success' -Message 'OK' -Data @{ Vlan = '100' }
        Complete-Step3TaskResult -Result $result

        $tempFile = Join-Path $TestDrive 'result.json'
        Write-Step3TaskResult -Result $result -Path $tempFile

        Test-Path $tempFile | Should -BeTrue
        $reRead = Get-Content $tempFile -Raw | ConvertFrom-Json
        $reRead.Status | Should -Be 'Success'
        $reRead.Context.VMName | Should -Be 'TEST-VM'
        $reRead.Phases.NetworkConfiguration.Status | Should -Be 'Success'
        $reRead.Phases.NetworkConfiguration.Data.Vlan | Should -Be '100'
    }

    It 'creates parent directories if needed' {
        $result = New-Step3TaskResult -Context @{}
        Complete-Step3TaskResult -Result $result

        $nestedPath = Join-Path $TestDrive 'sub' 'deep' 'result.json'
        Write-Step3TaskResult -Result $result -Path $nestedPath

        Test-Path $nestedPath | Should -BeTrue
    }
}

Describe 'End-to-end TaskResult lifecycle' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'step3' 'Step3.TaskResult.ps1'
        . $modulePath
    }

    It 'simulates a complete successful migration (all phases)' {
        $ctx = @{
            VMName       = 'SRV-WEB01'
            VlanId       = '100'
            HyperVHost   = 'hv01'
            HyperVHost2  = 'hv02'
            BackupJobName = 'Backup-Lot1'
        }
        $result = New-Step3TaskResult -Context $ctx

        # Instant Recovery phases
        Add-Step3PhaseResult -Result $result -Phase 'InstantRecoveryStart' `
            -Status 'Success' -Message 'IR mount started'
        Add-Step3PhaseResult -Result $result -Phase 'InstantRecoveryWait' `
            -Status 'Success' -Message 'IR reached WaitingForUserAction'
        Add-Step3PhaseResult -Result $result -Phase 'InstantRecoveryFinalization' `
            -Status 'Success' -Message 'IR committed, restore session Success'

        # Network
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Success' -Message 'Network configured (default VLAN 100)' `
            -Data @{
                MacMatchedCount  = 2
                FallbackCount    = 0
                AdapterCount     = 2
                DefaultVlan      = '100'
            }
        Add-Step3PhaseResult -Result $result -Phase 'IntegrationServices' `
            -Status 'Success' -Message 'Integration Services configured'

        # Post-config
        Add-Step3PhaseResult -Result $result -Phase 'OperatingSystem' `
            -Status 'Success' -Message 'SCVMM OS set to Windows Server 2022'
        Add-Step3PhaseResult -Result $result -Phase 'HighAvailability' `
            -Status 'Success' -Message 'VM made highly available'
        Add-Step3PhaseResult -Result $result -Phase 'LiveMigration' `
            -Status 'Success' -Message 'Migrated to hv02'
        Add-Step3PhaseResult -Result $result -Phase 'BackupTag' `
            -Status 'Success' -Message 'Tag applied'

        Complete-Step3TaskResult -Result $result

        # Assertions
        $result.Status | Should -Be 'Success'
        $result.Phases.Count | Should -Be 9
        [DateTime]::Parse($result.CompletedAt) | Should -BeOfType [DateTime]

        # Network state extraction
        $state = Get-Step3NetworkConfigurationState -Result $result
        $state | Should -Be 'Configured'
    }

    It 'simulates a migration with network warning' {
        $result = New-Step3TaskResult -Context @{ VMName = 'SRV-DB01' }
        Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
            -Status 'Warning' -Message 'Fallback mapping used for adapter 1' `
            -Data @{ FallbackCount = 1; MacMatchedCount = 1; AdapterCount = 2 }
        Complete-Step3TaskResult -Result $result

        $result.Status | Should -Be 'CompletedWithWarnings'
        Get-Step3NetworkConfigurationState -Result $result | Should -Be 'ConfiguredWithWarning'
    }

    It 'simulates a failed migration' {
        $result = New-Step3TaskResult -Context @{ VMName = 'SRV-BAD' }
        Add-Step3PhaseResult -Result $result -Phase 'InstantRecoveryStart' `
            -Status 'Success' -Message 'Started'
        Add-Step3PhaseResult -Result $result -Phase 'InstantRecoveryFinalization' `
            -Status 'Failed' -Message 'Restore session Failed'
        Complete-Step3TaskResult -Result $result

        $result.Status | Should -Be 'Failed'
        Get-Step3NetworkConfigurationState -Result $result | Should -Be 'NotDetected'
    }
}
