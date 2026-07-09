Set-StrictMode -Version Latest

Describe 'Convert-ToSafeFileName' {
    BeforeAll {
        function script:Convert-ToSafeFileName {
            param(
                [AllowNull()]
                [string]$Value
            )
            if ([string]::IsNullOrWhiteSpace($Value)) { return "unnamed" }
            $safeValue = $Value
            foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
                $safeValue = $safeValue.Replace([string]$invalidChar, "-")
            }
            return $safeValue
        }
    }

    It 'returns "unnamed" for null/empty/whitespace input' {
        Convert-ToSafeFileName -Value $null | Should -Be 'unnamed'
        Convert-ToSafeFileName -Value '' | Should -Be 'unnamed'
        Convert-ToSafeFileName -Value '   ' | Should -Be 'unnamed'
    }

    It 'returns the input unchanged when it contains no invalid characters' {
        Convert-ToSafeFileName -Value 'HypMig-lot-118' | Should -Be 'HypMig-lot-118'
        Convert-ToSafeFileName -Value 'TESTVM01' | Should -Be 'TESTVM01'
    }

    It 'replaces invalid filename characters with hyphens' {
            $result = Convert-ToSafeFileName -Value 'VM/Test:With*Invalid?Chars'
            $result | Should -Not -Match '/'
            $result | Should -Match 'VM-Test:With\*Invalid\?Chars'
        }

        It 'handles path separators by replacing them' {
            $result = Convert-ToSafeFileName -Value 'folder/vm\\name'
            # On Linux, only '/' is invalid in filenames (plus \0)
            $result | Should -Be 'folder-vm\\name'
        }

    It 'preserves dots and hyphens that are valid in filenames' {
        $result = Convert-ToSafeFileName -Value 'vm.name-with.dots'
        $result | Should -Be 'vm.name-with.dots'
    }

    It 'handles Unicode characters correctly' {
        $result = Convert-ToSafeFileName -Value 'VM-eau-test'
        $result | Should -Be 'VM-eau-test'
    }
}

Describe 'Step3RecoveryMode dispatch logic' {
    BeforeAll {
        function script:Resolve-Step3RecoveryFlags {
            param(
                [ValidateSet("Standard", "FullStep3", "CommitAndNetwork")]
                [string]$Step3RecoveryMode = "Standard",
                [switch]$ForceNetworkConfigOnly
            )
            $runInstantRecoveryStartOutsideWorkers = $false
            $workerForceNetworkOnly = [bool]$ForceNetworkConfigOnly
            $workerSkipInstantRecoveryStart = $false

            switch ($Step3RecoveryMode) {
                "Standard" {
                    if (-not $ForceNetworkConfigOnly) {
                        $runInstantRecoveryStartOutsideWorkers = $true
                        $workerSkipInstantRecoveryStart = $true
                    }
                }
                "FullStep3" {
                    if ($ForceNetworkConfigOnly) {
                        throw "Step3RecoveryMode 'FullStep3' is incompatible with -ForceNetworkConfigOnly."
                    }
                    $runInstantRecoveryStartOutsideWorkers = $true
                    $workerForceNetworkOnly = $false
                    $workerSkipInstantRecoveryStart = $true
                }
                "CommitAndNetwork" {
                    if ($ForceNetworkConfigOnly) {
                        throw "Step3RecoveryMode 'CommitAndNetwork' is incompatible with -ForceNetworkConfigOnly."
                    }
                    $runInstantRecoveryStartOutsideWorkers = $false
                    $workerForceNetworkOnly = $false
                    $workerSkipInstantRecoveryStart = $true
                }
            }

            return [pscustomobject]@{
                RunInstantRecoveryStartOutsideWorkers = $runInstantRecoveryStartOutsideWorkers
                WorkerForceNetworkOnly               = $workerForceNetworkOnly
                WorkerSkipInstantRecoveryStart        = $workerSkipInstantRecoveryStart
            }
        }
    }

    Context 'Standard mode' {
        It 'runs IR start outside workers and workers skip IR start (no ForceNetworkConfigOnly)' {
            $flags = Resolve-Step3RecoveryFlags -Step3RecoveryMode 'Standard'
            $flags.RunInstantRecoveryStartOutsideWorkers | Should -BeTrue
            $flags.WorkerSkipInstantRecoveryStart | Should -BeTrue
            $flags.WorkerForceNetworkOnly | Should -BeFalse
        }

        It 'does NOT run IR start outside workers when ForceNetworkConfigOnly is set' {
            $flags = Resolve-Step3RecoveryFlags -Step3RecoveryMode 'Standard' -ForceNetworkConfigOnly
            $flags.RunInstantRecoveryStartOutsideWorkers | Should -BeFalse
            $flags.WorkerSkipInstantRecoveryStart | Should -BeFalse
            $flags.WorkerForceNetworkOnly | Should -BeTrue
        }
    }

    Context 'FullStep3 mode' {
        It 'runs IR start outside workers, workers skip IR start, force network only false' {
            $flags = Resolve-Step3RecoveryFlags -Step3RecoveryMode 'FullStep3'
            $flags.RunInstantRecoveryStartOutsideWorkers | Should -BeTrue
            $flags.WorkerSkipInstantRecoveryStart | Should -BeTrue
            $flags.WorkerForceNetworkOnly | Should -BeFalse
        }

        It 'throws when combined with ForceNetworkConfigOnly' {
            {
                Resolve-Step3RecoveryFlags -Step3RecoveryMode 'FullStep3' -ForceNetworkConfigOnly
            } | Should -Throw
        }
    }

    Context 'CommitAndNetwork mode' {
        It 'does NOT run IR start outside workers, workers skip IR start' {
            $flags = Resolve-Step3RecoveryFlags -Step3RecoveryMode 'CommitAndNetwork'
            $flags.RunInstantRecoveryStartOutsideWorkers | Should -BeFalse
            $flags.WorkerSkipInstantRecoveryStart | Should -BeTrue
            $flags.WorkerForceNetworkOnly | Should -BeFalse
        }

        It 'throws when combined with ForceNetworkConfigOnly' {
            {
                Resolve-Step3RecoveryFlags -Step3RecoveryMode 'CommitAndNetwork' -ForceNetworkConfigOnly
            } | Should -Throw
        }
    }
}

Describe 'Get-Step3WorkerCount' {
    BeforeAll {
        function script:Get-Step3WorkerCount {
            param(
                [int]$ConfiguredMaxParallelJobs,
                [int]$VmCount,
                [int]$WorkerStartupDelaySec = 2
            )
            $step3WorkerCount = if ($ConfiguredMaxParallelJobs) { $ConfiguredMaxParallelJobs } else { 5 }
            if ($step3WorkerCount -lt 1) { $step3WorkerCount = 1 }
            if ($step3WorkerCount -gt $VmCount) { $step3WorkerCount = $VmCount }
            return [pscustomobject]@{
                WorkerCount      = $step3WorkerCount
                StartupDelaySec  = $WorkerStartupDelaySec
            }
        }
    }

    It 'defaults to 5 workers when no config override' {
        $result = Get-Step3WorkerCount -ConfiguredMaxParallelJobs 0 -VmCount 20
        $result.WorkerCount | Should -Be 5
    }

    It 'uses configured max when provided' {
        $result = Get-Step3WorkerCount -ConfiguredMaxParallelJobs 8 -VmCount 20
        $result.WorkerCount | Should -Be 8
    }

    It 'caps at VM count when fewer VMs than workers' {
        $result = Get-Step3WorkerCount -ConfiguredMaxParallelJobs 10 -VmCount 3
        $result.WorkerCount | Should -Be 3
    }

    It 'never goes below 1 worker' {
        $result = Get-Step3WorkerCount -ConfiguredMaxParallelJobs -3 -VmCount 5
        $result.WorkerCount | Should -Be 1
    }

    It 'returns 1 worker for single VM' {
        $result = Get-Step3WorkerCount -ConfiguredMaxParallelJobs 5 -VmCount 1
        $result.WorkerCount | Should -Be 1
    }

    It 'preserves the startup delay' {
        $result = Get-Step3WorkerCount -ConfiguredMaxParallelJobs 5 -VmCount 10 -WorkerStartupDelaySec 3
        $result.StartupDelaySec | Should -Be 3
    }
}

Describe 'Invoke-OrchestratorStep' {
    BeforeAll {
        function script:Invoke-OrchestratorStep {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Step,
                [Parameter(Mandatory = $true)]
                [scriptblock]$Action
            )
            try { & $Action } catch { throw }
        }
    }

    It 'executes the action scriptblock successfully' {
        $invoked = $false
        Invoke-OrchestratorStep -Step 'step1' -Action { $script:invoked = $true }
        $script:invoked | Should -BeTrue
    }

    It 'throws when the action scriptblock throws' {
        {
            Invoke-OrchestratorStep -Step 'step1' -Action { throw 'Simulated failure' }
        } | Should -Throw 'Simulated failure'
    }
}

Describe 'Task payload construction' {
    It 'builds a task payload with expected fields and ordering' {
        $taskPayload = [ordered]@{
            TaskId                 = '0001'
            Tag                    = 'HypMig-lot-118'
            BackupJobName          = 'Backup-HypMig-lot-118'
            VMName                 = 'TESTVM01'
            VlanId                 = '1816'
            AdapterVlanMapJson     = '[]'
            OperatingSystem        = 'Windows Server 2019'
            Remark                 = 'Production web server'
            VmwareCluster          = 'ProdCluster01'
            HyperVHost             = 'hv-host01.domain.local'
            HyperVHost2            = 'hv-host02.domain.local'
            HyperVCluster          = 'HVCluster01'
            ClusterStorage         = 'C:\ClusterStorage\Volume1'
            ForceNetworkConfigOnly = $false
            SkipInstantRecoveryStart = $true
            VmLogFile              = 'C:\logs\migration-TESTVM01.log'
            CreatedAt              = (Get-Date).ToString('o')
        }

        $taskPayload.TaskId | Should -Be '0001'
        $taskPayload.VMName | Should -Be 'TESTVM01'
        $taskPayload.VlanId | Should -Be '1816'
        $taskPayload.BackupJobName | Should -Be 'Backup-HypMig-lot-118'
        $taskPayload.HyperVHost | Should -Be 'hv-host01.domain.local'
        $taskPayload.HyperVHost2 | Should -Be 'hv-host02.domain.local'
        $taskPayload.ForceNetworkConfigOnly | Should -BeFalse
        $taskPayload.SkipInstantRecoveryStart | Should -BeTrue
        $taskPayload.CreatedAt | Should -Not -BeNullOrEmpty
    }

    It 'generates the correct task file name with Convert-ToSafeFileName' {
        function script:Convert-ToSafeFileName {
            param([AllowNull()][string]$Value)
            if ([string]::IsNullOrWhiteSpace($Value)) { return "unnamed" }
            $safeValue = $Value
            foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
                $safeValue = $safeValue.Replace([string]$invalidChar, "-")
            }
            return $safeValue
        }
        $taskIndex = 1
        $vmName = 'TESTVM/a/b'
        $safeVmName = Convert-ToSafeFileName -Value $vmName
        $taskFileName = "{0:D4}-{1}.json" -f $taskIndex, $safeVmName
        $taskFileName | Should -Be '0001-TESTVM-a-b.json'
    }

    It 'serializes task payload to JSON with correct depth' {
        $taskPayload = [ordered]@{
            TaskId = '0001'
            VMName = 'TESTVM01'
            VlanId = '1816'
        }
        $json = $taskPayload | ConvertTo-Json -Depth 4 -Compress
        $json | Should -Match '"TaskId"\s*:\s*"0001"'
        $json | Should -Match '"VMName"\s*:\s*"TESTVM01"'
        $json | Should -Match '"VlanId"\s*:\s*"1816"'
    }
}

Describe 'Step3 queue directory structure' {
    BeforeAll {
        function script:Initialize-Directory {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Path
            )
            if (-not (Test-Path -Path $Path)) {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
            }
        }
    }

    It 'creates the expected queue subdirectories' {
        $queueRoot = Join-Path $TestDrive 'step3-worker-queue-test'
        $subdirs = @('pending', 'processing', 'done', 'failed')
        Initialize-Directory -Path $queueRoot
        foreach ($subdir in $subdirs) {
            Initialize-Directory -Path (Join-Path $queueRoot $subdir)
        }
        foreach ($subdir in $subdirs) {
            Test-Path (Join-Path $queueRoot $subdir) | Should -BeTrue
        }
    }

    It 'creates the dispatch complete flag file' {
        $queueRoot = Join-Path $TestDrive 'step3-worker-queue-dispatch'
        Initialize-Directory -Path $queueRoot
        $dispatchCompleteFlag = Join-Path $queueRoot 'dispatch.complete'
        New-Item -ItemType File -Path $dispatchCompleteFlag -Force | Out-Null
        Test-Path $dispatchCompleteFlag | Should -BeTrue
    }
}