#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester unit tests for the helper functions of Invoke-SCVMMHostPatchBaseline.ps1.

.DESCRIPTION
    The script cannot be dot-sourced directly (#Requires -Modules
    VirtualMachineManager, mandatory parameters, main body with SCVMM calls).
    Instead, the function definitions are extracted from the script's AST and
    loaded individually — this keeps the tests in sync with the real code
    without requiring the VMM module.

    Wait-SCJobBatch is exercised against a stub Get-SCJob defined in the test
    scope, so the batch logic (shared deadline, SucceedWithInfo handling,
    per-job success/failure reporting) is tested without SCVMM.

.EXAMPLE
    Invoke-Pester -Path scripts/tests/Invoke-SCVMMHostPatchBaseline.Tests.ps1
#>

BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-SCVMMHostPatchBaseline.ps1'

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) {
        throw "Parse error in ${scriptPath}: $($parseErrors[0].Message)"
    }

    # Load every function definition without executing the script body.
    $functionAsts = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($functionAst in $functionAsts) {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    # Script-scope state normally initialized by the script preamble.
    $script:LogFilePath        = $null
    $script:LogWriteWarned     = $false
    $script:FailedHosts        = [ordered]@{}
    $script:CentreonOutputMode = $false
    $script:WarningCount       = 0
}

Describe 'Get-ObjectName' {
    It 'prefers Name over the other properties' {
        Get-ObjectName -InputObject ([pscustomobject]@{ Name = 'hv01'; ComputerName = 'other' }) |
            Should -BeExactly 'hv01'
    }
    It 'falls back to ComputerName when Name is empty' {
        Get-ObjectName -InputObject ([pscustomobject]@{ Name = ''; ComputerName = 'hv02.contoso.local' }) |
            Should -BeExactly 'hv02.contoso.local'
    }
    It 'falls back to the string representation when no known property exists' {
        Get-ObjectName -InputObject 'plainstring' | Should -BeExactly 'plainstring'
    }
}

Describe 'Get-VMHostAliasSet' {
    It 'collects all naming properties and matches case-insensitively' {
        $aliases = Get-VMHostAliasSet -VMHost ([pscustomobject]@{
            Name                     = 'HV01'
            ComputerName             = 'hv01'
            FullyQualifiedDomainName = 'hv01.contoso.local'
        })
        $aliases.Contains('hv01')               | Should -BeTrue
        $aliases.Contains('HV01.CONTOSO.LOCAL') | Should -BeTrue
        $aliases.Contains('hv02')               | Should -BeFalse
    }
    It 'skips empty properties' {
        $aliases = Get-VMHostAliasSet -VMHost ([pscustomobject]@{ Name = 'hv03'; ComputerName = '' })
        $aliases.Count | Should -Be 1
    }
}

Describe 'Add-HostFailure' {
    BeforeEach {
        $script:FailedHosts = [ordered]@{}
    }
    It 'records the host with its reason' {
        Add-HostFailure -HostName 'hv01' -Reason 'scan failed'
        $script:FailedHosts.Contains('hv01') | Should -BeTrue
        $script:FailedHosts['hv01'] | Should -BeExactly 'scan failed'
    }
    It 'keeps the first recorded reason for a host' {
        Add-HostFailure -HostName 'hv01' -Reason 'first'
        Add-HostFailure -HostName 'hv01' -Reason 'second'
        $script:FailedHosts['hv01'] | Should -BeExactly 'first'
        $script:FailedHosts.Count   | Should -Be 1
    }
}

Describe 'Write-PatchLog' {
    It 'appends a timestamped line to the log file' {
        $script:LogFilePath    = Join-Path ([System.IO.Path]::GetTempPath()) "patchlog-$([guid]::NewGuid()).log"
        $script:LogWriteWarned = $false
        try {
            Write-PatchLog -Message 'hello' -Level WARN
            $content = Get-Content -LiteralPath $script:LogFilePath -Raw
            $content | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[WARN \] hello'
        } finally {
            Remove-Item -LiteralPath $script:LogFilePath -ErrorAction SilentlyContinue
            $script:LogFilePath = $null
        }
    }
    It 'degrades to console-only on an unwritable path without throwing (single warning)' {
        $script:LogFilePath    = Join-Path ([System.IO.Path]::GetTempPath()) "missing-dir-$([guid]::NewGuid())/patch.log"
        $script:LogWriteWarned = $false
        try {
            { Write-PatchLog -Message 'first' 3>$null } | Should -Not -Throw
            $script:LogWriteWarned | Should -BeTrue
            { Write-PatchLog -Message 'second' 3>$null } | Should -Not -Throw
        } finally {
            $script:LogFilePath = $null
        }
    }
}

Describe 'Wait-SCJobBatch' {
    BeforeAll {
        # Stub the SCVMM cmdlet: Wait-SCJobBatch re-polls jobs through Get-SCJob,
        # so the stub returns the current state stored in $script:JobTable.
        function Get-SCJob {
            param($ID, $ErrorAction)
            $script:JobTable[$ID]
        }

        function New-FakeJob {
            param([string]$Id, [string]$Status, [string]$ErrorInfo = '')
            $job = [pscustomobject]@{ ID = $Id; Status = $Status; ErrorInfo = $ErrorInfo }
            $script:JobTable[$Id] = $job
            return $job
        }
    }
    BeforeEach {
        $script:JobTable = @{}
    }

    It 'returns an empty result set for an empty batch' {
        @(Wait-SCJobBatch -Entries @() -TimeoutMinutes 1 -Activity 'Test' -IntervalSeconds 5) |
            Should -HaveCount 0
    }

    It 'reports success and failure per job in one pass' {
        $entries = @(
            [pscustomobject]@{ Name = 'hv01'; Job = (New-FakeJob -Id 'j1' -Status 'Completed') }
            [pscustomobject]@{ Name = 'hv02'; Job = (New-FakeJob -Id 'j2' -Status 'Failed' -ErrorInfo 'boom') }
        )
        $results = @(Wait-SCJobBatch -Entries $entries -TimeoutMinutes 1 -Activity 'Test' -IntervalSeconds 5)

        $results | Should -HaveCount 2
        ($results | Where-Object { $_.Name -eq 'hv01' }).Succeeded | Should -BeTrue
        $failed = $results | Where-Object { $_.Name -eq 'hv02' }
        $failed.Succeeded | Should -BeFalse
        $failed.Detail    | Should -Match 'boom'
    }

    It 'treats SucceedWithInfo as success' {
        $entries = @(
            [pscustomobject]@{ Name = 'hv01'; Job = (New-FakeJob -Id 'j1' -Status 'SucceedWithInfo' -ErrorInfo 'info') }
        )
        $results = @(Wait-SCJobBatch -Entries $entries -TimeoutMinutes 1 -Activity 'Test' -IntervalSeconds 5)

        $results[0].Succeeded | Should -BeTrue
        $results[0].Status    | Should -BeExactly 'SucceedWithInfo'
    }

    It 'polls until a running job reaches a terminal state' {
        # The stub flips the job to Completed when it is first polled as Running.
        $script:PollCount = 0
        function Get-SCJob {
            param($ID, $ErrorAction)
            $script:PollCount++
            if ($script:PollCount -ge 2) {
                $script:JobTable[$ID].Status = 'Completed'
            }
            $script:JobTable[$ID]
        }

        $entries = @(
            [pscustomobject]@{ Name = 'hv01'; Job = (New-FakeJob -Id 'j1' -Status 'Running') }
        )
        $results = @(Wait-SCJobBatch -Entries $entries -TimeoutMinutes 1 -Activity 'Test' -IntervalSeconds 5)

        $results[0].Succeeded | Should -BeTrue
        $script:PollCount     | Should -BeGreaterOrEqual 2
    }
}

Describe 'Test-VMHostLiveMigrationReadiness' {
    It 'keeps non-clustered hosts patchable but warns about saved state (no Live Migration)' {
        # Regression: standalone hosts used to be excluded from patching entirely.
        $result = Test-VMHostLiveMigrationReadiness -VMHost ([pscustomobject]@{ Name = 'hv01'; Status = 'OK'; AgentStatus = 'UpToDate' })
        $result.Ready | Should -BeTrue
        $result.Warnings -join '; ' | Should -Match 'hors cluster'
    }

    It 'blocks a host that is already in maintenance mode' {
        $result = Test-VMHostLiveMigrationReadiness -VMHost ([pscustomobject]@{ Name = 'hv01'; HostCluster = [pscustomobject]@{ Name = 'CL01' }; MaintenanceHost = $true })
        $result.Ready | Should -BeFalse
        $result.Issues -join '; ' | Should -Match 'maintenance'
    }

    Context 'VM inspection with stubbed VMM cmdlets' {
        BeforeAll {
            function Get-SCVirtualMachine {
                param($VMHost, $ErrorAction)
                $script:FakeVms
            }
            function Get-SCVirtualDVDDrive {
                param($VM, $ErrorAction)
                if ($script:FakeDrivesByVm.ContainsKey($VM.Name)) { $script:FakeDrivesByVm[$VM.Name] } else { @() }
            }
            function Set-SCVirtualDVDDrive {
                param($VirtualDVDDrive, [switch]$NoMedia, $ErrorAction)
                $script:DismountedDrives += $VirtualDVDDrive
            }
        }
        BeforeEach {
            $script:FakeVms          = @()
            $script:FakeDrivesByVm   = @{}
            $script:DismountedDrives = @()
        }

        It 'warns about an attached ISO on a running VM without -DismountIso' {
            $script:FakeVms = @([pscustomobject]@{ Name = 'vm1'; VirtualMachineState = 'Running'; IsHighlyAvailable = $true })
            $script:FakeDrivesByVm['vm1'] = @([pscustomobject]@{ ISO = 'install.iso' })

            $result = Test-VMHostLiveMigrationReadiness -VMHost ([pscustomobject]@{ Name = 'hv01'; HostCluster = [pscustomobject]@{ Name = 'CL01' } })
            $result.Ready | Should -BeTrue
            $result.Warnings -join '; ' | Should -Match 'DismountIso'
            $script:DismountedDrives | Should -HaveCount 0
        }

        It 'ejects the attached media with -DismountIso and reports the fix' {
            $script:FakeVms = @([pscustomobject]@{ Name = 'vm1'; VirtualMachineState = 'Running'; IsHighlyAvailable = $true })
            $script:FakeDrivesByVm['vm1'] = @([pscustomobject]@{ ISO = 'install.iso' })

            $result = Test-VMHostLiveMigrationReadiness -VMHost ([pscustomobject]@{ Name = 'hv01'; HostCluster = [pscustomobject]@{ Name = 'CL01' } }) -DismountIso
            $result.Fixed -join '; ' | Should -Match 'vm1'
            $script:DismountedDrives | Should -HaveCount 1
        }

        It 'warns about running non-highly-available VMs on a clustered host' {
            $script:FakeVms = @(
                [pscustomobject]@{ Name = 'vm1'; VirtualMachineState = 'Running'; IsHighlyAvailable = $false }
                [pscustomobject]@{ Name = 'vm2'; VirtualMachineState = 'PowerOff'; IsHighlyAvailable = $false }
            )

            $result = Test-VMHostLiveMigrationReadiness -VMHost ([pscustomobject]@{ Name = 'hv01'; HostCluster = [pscustomobject]@{ Name = 'CL01' } })
            $result.Ready | Should -BeTrue
            $result.Warnings -join '; ' | Should -Match '1 VM non hautement disponible'
        }

        It 'ignores stopped VMs when checking DVD media' {
            $script:FakeVms = @([pscustomobject]@{ Name = 'vm1'; VirtualMachineState = 'PowerOff' })
            $script:FakeDrivesByVm['vm1'] = @([pscustomobject]@{ ISO = 'install.iso' })

            $result = Test-VMHostLiveMigrationReadiness -VMHost ([pscustomobject]@{ Name = 'hv01'; HostCluster = [pscustomobject]@{ Name = 'CL01' } })
            $result.Warnings -join '; ' | Should -Not -Match 'DismountIso'
        }
    }
}

Describe 'Test-DvdDriveHasMedia' {
    It 'detects an ISO, a host drive and a non-None connection' {
        Test-DvdDriveHasMedia -Drive ([pscustomobject]@{ ISO = 'x.iso' })        | Should -BeTrue
        Test-DvdDriveHasMedia -Drive ([pscustomobject]@{ HostDrive = 'D:' })     | Should -BeTrue
        Test-DvdDriveHasMedia -Drive ([pscustomobject]@{ Connection = 'ISOImage' }) | Should -BeTrue
    }
    It 'reports no media for an empty drive' {
        Test-DvdDriveHasMedia -Drive ([pscustomobject]@{ ISO = $null; Connection = 'None' }) | Should -BeFalse
    }
}

Describe 'New-ClusterRemediationBatch' {
    It 'allows hosts from different clusters in the same parallel batch but limits each cluster to two hosts' {
        $hosts = @(
            [pscustomobject]@{ Name = 'a1'; ClusterName = 'A'; TotalMemory = 100 }
            [pscustomobject]@{ Name = 'a2'; ClusterName = 'A'; TotalMemory = 100 }
            [pscustomobject]@{ Name = 'a3'; ClusterName = 'A'; TotalMemory = 100 }
            [pscustomobject]@{ Name = 'b1'; ClusterName = 'B'; TotalMemory = 100 }
            [pscustomobject]@{ Name = 'b2'; ClusterName = 'B'; TotalMemory = 100 }
        )

        $batches = @(New-ClusterRemediationBatch -CandidateHosts $hosts -MaxParallelHostsPerCluster 2 -MinimumClusterAvailableResourcePercent 50)
        @($batches[0] | Where-Object { $_.ClusterName -eq 'A' }) | Should -HaveCount 1
        @($batches[0] | Where-Object { $_.ClusterName -eq 'B' }) | Should -HaveCount 1
        @($batches | ForEach-Object { $_ } | ForEach-Object { $_.Name }) | Should -Contain 'a3'
    }

    It 'computes the 50% threshold against the whole cluster membership, not only the targeted hosts' {
        # Regression: targeting 2 hosts of a 4-node cluster only removes 50% of
        # the cluster capacity, so both must fit in a single batch.
        $targeted = @(
            [pscustomobject]@{ Name = 'a1'; ClusterName = 'A'; TotalMemory = 100 }
            [pscustomobject]@{ Name = 'a2'; ClusterName = 'A'; TotalMemory = 100 }
        )
        $allHosts = $targeted + @(
            [pscustomobject]@{ Name = 'a3'; ClusterName = 'A'; TotalMemory = 100 }
            [pscustomobject]@{ Name = 'a4'; ClusterName = 'A'; TotalMemory = 100 }
        )

        $batches = @(New-ClusterRemediationBatch -CandidateHosts $targeted -MaxParallelHostsPerCluster 2 -MinimumClusterAvailableResourcePercent 50 -AllClusterHosts $allHosts)
        $batches | Should -HaveCount 1
        @($batches[0]) | Should -HaveCount 2
    }

    It 'excludes non-responding or in-maintenance nodes from the cluster capacity' {
        $targeted = @(
            [pscustomobject]@{ Name = 'a1'; ClusterName = 'A'; TotalMemory = 100 }
            [pscustomobject]@{ Name = 'a2'; ClusterName = 'A'; TotalMemory = 100 }
        )
        $allHosts = $targeted + @(
            [pscustomobject]@{ Name = 'a3'; ClusterName = 'A'; TotalMemory = 100; CommunicationState = 'NotResponding' }
            [pscustomobject]@{ Name = 'a4'; ClusterName = 'A'; TotalMemory = 100; MaintenanceHost = $true }
        )

        # Only a1+a2 contribute capacity: taking both would leave 0% — they
        # must land in separate batches.
        $batches = @(New-ClusterRemediationBatch -CandidateHosts $targeted -MaxParallelHostsPerCluster 2 -MinimumClusterAvailableResourcePercent 50 -AllClusterHosts $allHosts)
        $batches | Should -HaveCount 2
    }

    It 'falls back to one host per batch with a warning when the threshold cannot be met' {
        $hosts = @([pscustomobject]@{ Name = 'solo'; ClusterName = 'A'; TotalMemory = 100 })
        $warningsBefore = $script:WarningCount
        $batches = @(New-ClusterRemediationBatch -CandidateHosts $hosts -MaxParallelHostsPerCluster 2 -MinimumClusterAvailableResourcePercent 50)
        $batches | Should -HaveCount 1
        @($batches[0]).Name | Should -BeExactly 'solo'
        $script:WarningCount | Should -BeGreaterThan $warningsBefore
    }

    It 'returns no batches for an empty candidate list' {
        @(New-ClusterRemediationBatch -CandidateHosts @() -MaxParallelHostsPerCluster 2 -MinimumClusterAvailableResourcePercent 50 |
            Where-Object { @($_).Count -gt 0 }) | Should -HaveCount 0
    }
}

Describe 'ConvertTo-MemoryMegabytes' {
    It 'converts byte values (VMM TotalMemory) to megabytes' {
        # 128 GB in bytes -> 131072 MB
        ConvertTo-MemoryMegabytes -Value 137438953472 | Should -Be 131072
    }
    It 'passes through megabyte values (VMM AvailableMemory)' {
        ConvertTo-MemoryMegabytes -Value 65536 | Should -Be 65536
    }
    It 'keeps zero as zero (fully loaded host)' {
        ConvertTo-MemoryMegabytes -Value 0 | Should -Be 0
    }
    It 'returns -1 for null or unparseable values' {
        ConvertTo-MemoryMegabytes -Value $null    | Should -Be -1
        ConvertTo-MemoryMegabytes -Value 'oops'   | Should -Be -1
        ConvertTo-MemoryMegabytes -Value -5       | Should -Be -1
    }
}

Describe 'Get-ClusterLiveCapacityPercent' {
    It 'computes the live available-memory percentage across active nodes' {
        # Two 128 GB nodes (bytes) with 96 GB and 32 GB available (MB) -> 50%.
        $members = @(
            [pscustomobject]@{ Name = 'a1'; TotalMemory = 137438953472; AvailableMemory = 98304 }
            [pscustomobject]@{ Name = 'a2'; TotalMemory = 137438953472; AvailableMemory = 32768 }
        )
        Get-ClusterLiveCapacityPercent -ClusterHosts $members | Should -Be 50
    }
    It 'excludes the batch hosts and non-contributing nodes from the measure' {
        $members = @(
            [pscustomobject]@{ Name = 'a1'; TotalMemory = 137438953472; AvailableMemory = 98304 }
            [pscustomobject]@{ Name = 'a2'; TotalMemory = 137438953472; AvailableMemory = 0 }
            [pscustomobject]@{ Name = 'a3'; TotalMemory = 137438953472; AvailableMemory = 131072; MaintenanceHost = $true }
        )
        # a2 excluded (in the batch), a3 excluded (maintenance): only a1 counts -> 75%.
        Get-ClusterLiveCapacityPercent -ClusterHosts $members -ExcludedHostNames @('a2') | Should -Be 75
    }
    It 'returns $null when the memory is not readable or no node contributes' {
        Get-ClusterLiveCapacityPercent -ClusterHosts @([pscustomobject]@{ Name = 'a1'; TotalMemory = $null; AvailableMemory = 100 }) | Should -BeNullOrEmpty
        Get-ClusterLiveCapacityPercent -ClusterHosts @() | Should -BeNullOrEmpty
    }
}

Describe 'Test-VMHostInMaintenance' {
    It 'detects any of the maintenance flags' {
        Test-VMHostInMaintenance -VMHost ([pscustomobject]@{ Name = 'hv01'; MaintenanceHost = $true })    | Should -BeTrue
        Test-VMHostInMaintenance -VMHost ([pscustomobject]@{ Name = 'hv01'; InMaintenanceMode = $true })  | Should -BeTrue
    }
    It 'reports false for a normal host' {
        Test-VMHostInMaintenance -VMHost ([pscustomobject]@{ Name = 'hv01'; MaintenanceHost = $false }) | Should -BeFalse
        Test-VMHostInMaintenance -VMHost ([pscustomobject]@{ Name = 'hv01' })                            | Should -BeFalse
    }
}

Describe 'Centreon output' {
    It 'maps failure and warning counts to the plugin state' {
        Get-CentreonState -FailureCount 1 -WarningCount 0 | Should -BeExactly 'CRITICAL'
        Get-CentreonState -FailureCount 0 -WarningCount 2 | Should -BeExactly 'WARNING'
        Get-CentreonState -FailureCount 0 -WarningCount 0 | Should -BeExactly 'OK'
    }

    It 'maps plugin states to Nagios exit codes (0/1/2/3)' {
        Get-CentreonExitCode -State 'OK'       | Should -Be 0
        Get-CentreonExitCode -State 'WARNING'  | Should -Be 1
        Get-CentreonExitCode -State 'CRITICAL' | Should -Be 2
        Get-CentreonExitCode -State 'UNKNOWN'  | Should -Be 3
    }

    It 'formats a Centreon-compatible summary with perfdata' {
        Format-CentreonSummary -State 'CRITICAL' -TargetedCount 3 -RemediatedCount 2 -FailureCount 1 -WarningCount 4 -DurationMinutes 12.5 |
            Should -BeExactly 'CRITICAL - Hyper-V/SCVMM patching: targeted=3 remediated=2 failed=1 warnings=4 | targeted=3 remediated=2 failed=1 warnings=4 duration_min=12.5'
    }
}
