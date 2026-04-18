Set-StrictMode -Version Latest

Describe 'install-powershell.sh' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path -Path $repoRoot -ChildPath 'scripts/install-powershell.sh'
    }

    It 'exists in scripts/' {
        Test-Path -Path $scriptPath -PathType Leaf | Should -BeTrue
    }

    It 'uses strict Bash settings' {
        $content = Get-Content -Path $scriptPath -Raw
        $content | Should -Match 'set -euo pipefail'
    }

    It 'is idempotent when pwsh already exists' {
        $content = Get-Content -Path $scriptPath -Raw
        $content | Should -Match 'command -v pwsh'
        $content | Should -Match 'PowerShell already installed'
        $content | Should -Match 'exit 0'
    }

    It 'installs powershell package via apt-get' {
        $content = Get-Content -Path $scriptPath -Raw
        $content | Should -Match 'apt-get install -y powershell'
    }
}
