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
    $script:LogFilePath    = $null
    $script:LogWriteWarned = $false
    $script:FailedHosts    = [ordered]@{}
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
