Set-StrictMode -Version Latest

Describe 'step1 Veeam job creation' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path -Path $repoRoot -ChildPath 'powershell-migration/step1-TagResources_CreateVeeamJob.ps1'
        $source = Get-Content -Path $scriptPath -Raw
    }

    It 'creates VMware backup jobs without passing the unsupported Proxy parameter' {
        $addJobCalls = [regex]::Matches(
            $source,
            '(?m)^\s*\$job\s*=\s*Add-VBRViBackupJob[^\r\n]*$'
        )

        $addJobCalls.Count | Should -Be 2
        foreach ($call in $addJobCalls) {
            $call.Value | Should -Not -Match '(?i)\s-Proxy\b'
        }
    }

    It 'assigns the configured VMware proxy with Set-VBRJobProxy in both execution paths' {
        $proxyAssignments = [regex]::Matches(
            $source,
            '(?m)^\s*Set-VBRJobProxy\s+-Job\s+\$job\s+-Proxy\s+\$backupProxy\b'
        )

        $proxyAssignments.Count | Should -Be 2
    }

    It 'makes the Windows PowerShell child process fail closed on Veeam errors' {
        $source | Should -Match '(?m)^\$ErrorActionPreference\s*=\s*''Stop''$'
        $source | Should -Match '(?m)^\s*Write-Output "\[ERROR\] \$\(\$_.Exception.Message\)"$'
        $source | Should -Match '(?m)^\s*exit 1$'
        $source | Should -Match ([regex]::Escape('if ($line -match ''^\[ERROR\]\s+(.*)$'')'))
    }
}
