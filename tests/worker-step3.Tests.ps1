Set-StrictMode -Version Latest

# worker-step3.Tests.ps1 — Tests for Get-NetworkConfigurationState in worker-step3.ps1
#
# The worker script cannot be dot-sourced directly (mandatory params, infinite loop).
# We replicate Get-NetworkConfigurationState here to test its logic.
# Keep in sync with worker-step3.ps1.

Describe 'worker-step3 — Get-NetworkConfigurationState' {

    BeforeAll {
        # Dot-source Step3.TaskResult.ps1 — the canonical source
        $modulePath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'step3' 'Step3.TaskResult.ps1'
        . $modulePath

        # Replicate Get-NetworkConfigurationState exactly as defined in worker-step3.ps1 (BEA-282).
        function Get-NetworkConfigurationState {
            param(
                [AllowNull()]
                [string]$VmLogFile
            )

            if ([string]::IsNullOrWhiteSpace($VmLogFile)) {
                return "Unknown"
            }

            # Preferred path: read the structured TaskResult JSON
            $resultFilePath = "$VmLogFile.result.json"
            if (Test-Path -Path $resultFilePath -PathType Leaf) {
                try {
                    $result = Get-Content -Path $resultFilePath -Raw -ErrorAction Stop |
                        ConvertFrom-Json -ErrorAction Stop

                    return Get-Step3NetworkConfigurationState -Result $result
                } catch {
                    # Write-MigrationLog would be called here in the real worker;
                    # we just fall through to legacy fallback.
                }
            }

            # Legacy fallback: grep the VM log
            if (-not (Test-Path -Path $VmLogFile)) {
                return "Unknown"
            }

            $successMatch = Select-String -Path $VmLogFile -Pattern "Network configured (default VLAN" -SimpleMatch -Quiet -ErrorAction SilentlyContinue
            $warningMatch = Select-String -Path $VmLogFile -Pattern "fallback mapping used" -SimpleMatch -Quiet -ErrorAction SilentlyContinue

            if ($successMatch) {
                if ($warningMatch) {
                    return "ConfiguredWithWarning"
                }
                return "Configured"
            }

            return "NotDetected"
        }

        # ── Helper to create a TaskResult JSON fixture ──────────────────────
        function New-TaskResultJson {
            param(
                [string]$NetworkStatus = 'Success',
                [hashtable]$ExtraPhases = @{}
            )

            $result = New-Step3TaskResult -Context @{ VMName = 'TEST-VM' }
            Add-Step3PhaseResult -Result $result -Phase 'NetworkConfiguration' `
                -Status $NetworkStatus -Message "Test network config"

            foreach ($phaseName in $ExtraPhases.Keys) {
                Add-Step3PhaseResult -Result $result -Phase $phaseName `
                    -Status $ExtraPhases[$phaseName] -Message "Test $phaseName"
            }

            Complete-Step3TaskResult -Result $result
            return $result
        }

        # ── Helper to create a log file fixture ─────────────────────────────
        function New-LogFileFixture {
            param(
                [string]$Path,
                [bool]$HasSuccess = $false,
                [bool]$HasWarning = $false
            )

            $lines = @()
            if ($HasWarning) {
                $lines += "[2026-07-09 10:00:00] WARNING: fallback mapping used for adapter Ethernet0"
            }
            if ($HasSuccess) {
                $lines += "[2026-07-09 10:00:01] SUCCESS: Network configured (default VLAN 100)"
            }
            if ($lines.Count -eq 0) {
                $lines += "[2026-07-09 10:00:00] INFO: Starting migration"
            }
            $lines -join "`n" | Set-Content -Path $Path -Encoding utf8
        }
    }

    Context 'TaskResult JSON path (preferred)' {

        It 'returns Configured when NetworkConfiguration phase is Success' {
            $result = New-TaskResultJson -NetworkStatus 'Success'
            $logPath = Join-Path $TestDrive 'task.log'
            $resultPath = "$logPath.result.json"
            Write-Step3TaskResult -Result $result -Path $resultPath

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'Configured'
        }

        It 'returns ConfiguredWithWarning when NetworkConfiguration phase is Warning' {
            $result = New-TaskResultJson -NetworkStatus 'Warning'
            $logPath = Join-Path $TestDrive 'task.log'
            $resultPath = "$logPath.result.json"
            Write-Step3TaskResult -Result $result -Path $resultPath

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'ConfiguredWithWarning'
        }

        It 'returns NotDetected when NetworkConfiguration phase is Failed' {
            $result = New-TaskResultJson -NetworkStatus 'Failed'
            $logPath = Join-Path $TestDrive 'task.log'
            $resultPath = "$logPath.result.json"
            Write-Step3TaskResult -Result $result -Path $resultPath

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'NotDetected'
        }

        It 'returns NotDetected when NetworkConfiguration phase is Skipped' {
            $result = New-TaskResultJson -NetworkStatus 'Skipped'
            $logPath = Join-Path $TestDrive 'task.log'
            $resultPath = "$logPath.result.json"
            Write-Step3TaskResult -Result $result -Path $resultPath

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'NotDetected'
        }

        It 'returns NotDetected when result.json exists but has no NetworkConfiguration phase' {
            $result = New-Step3TaskResult -Context @{ VMName = 'TEST-VM' }
            Add-Step3PhaseResult -Result $result -Phase 'OtherPhase' -Status 'Success' -Message 'Done'
            Complete-Step3TaskResult -Result $result

            $logPath = Join-Path $TestDrive 'task.log'
            $resultPath = "$logPath.result.json"
            Write-Step3TaskResult -Result $result -Path $resultPath

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'NotDetected'
        }
    }

    Context 'Legacy log-grep fallback' {

        It 'returns Configured when log has success line without warning' {
            $logPath = Join-Path $TestDrive 'task.log'
            New-LogFileFixture -Path $logPath -HasSuccess $true -HasWarning $false

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'Configured'
        }

        It 'returns ConfiguredWithWarning when log has both success and warning lines' {
            $logPath = Join-Path $TestDrive 'task.log'
            New-LogFileFixture -Path $logPath -HasSuccess $true -HasWarning $true

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'ConfiguredWithWarning'
        }

        It 'returns NotDetected when log has no network-related lines' {
            $logPath = Join-Path $TestDrive 'task.log'
            New-LogFileFixture -Path $logPath -HasSuccess $false -HasWarning $false

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'NotDetected'
        }
    }

    Context 'Edge cases' {

        It 'returns Unknown when VmLogFile is $null' {
            Get-NetworkConfigurationState -VmLogFile $null | Should -Be 'Unknown'
        }

        It 'returns Unknown when VmLogFile is empty string' {
            Get-NetworkConfigurationState -VmLogFile '' | Should -Be 'Unknown'
        }

        It 'returns Unknown when VmLogFile is whitespace' {
            Get-NetworkConfigurationState -VmLogFile '   ' | Should -Be 'Unknown'
        }

        It 'returns Unknown when neither result.json nor log file exists' {
            $nonExistentPath = Join-Path $TestDrive 'nonexistent.log'
            Get-NetworkConfigurationState -VmLogFile $nonExistentPath | Should -Be 'Unknown'
        }

        It 'prefers result.json over log-grep when both exist (Success in JSON, Warning in log)' {
            $result = New-TaskResultJson -NetworkStatus 'Success'
            $logPath = Join-Path $TestDrive 'task.log'
            $resultPath = "$logPath.result.json"
            Write-Step3TaskResult -Result $result -Path $resultPath
            New-LogFileFixture -Path $logPath -HasSuccess $true -HasWarning $true

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'Configured'
        }

        It 'falls through to legacy when result.json is corrupted' {
            $logPath = Join-Path $TestDrive 'task.log'
            $resultPath = "$logPath.result.json"
            Set-Content -Path $resultPath -Value '{ this is not valid json ' -Encoding utf8
            New-LogFileFixture -Path $logPath -HasSuccess $true -HasWarning $false

            Get-NetworkConfigurationState -VmLogFile $logPath | Should -Be 'Configured'
        }
    }

    Context 'Delegation to Get-Step3NetworkConfigurationState' {

        It 'delegates all 4 phase statuses correctly' {
            $statusMap = @{
                'Success' = 'Configured'
                'Warning' = 'ConfiguredWithWarning'
                'Failed'  = 'NotDetected'
                'Skipped' = 'NotDetected'
            }

            foreach ($phaseStatus in $statusMap.Keys) {
                $result = New-TaskResultJson -NetworkStatus $phaseStatus
                $logPath = Join-Path $TestDrive "task_${phaseStatus}.log"
                $resultPath = "$logPath.result.json"
                Write-Step3TaskResult -Result $result -Path $resultPath

                $actual = Get-NetworkConfigurationState -VmLogFile $logPath
                $expected = $statusMap[$phaseStatus]
                $actual | Should -Be $expected -Because "Phase status '$phaseStatus' should map to '$expected'"
            }
        }
    }
}