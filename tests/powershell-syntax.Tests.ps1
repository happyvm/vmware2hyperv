Set-StrictMode -Version Latest

Describe 'PowerShell scripts syntax' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptFiles = @(
            Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'powershell-migration') -Filter '*.ps1' -File
            Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'tests') -Filter '*.ps1' -File
        )
    }

    It 'parses all tracked .ps1 files without syntax errors' {
        foreach ($scriptFile in $scriptFiles) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$null, [ref]$errors)

            $errors | Should -BeNullOrEmpty -Because "Unexpected parser error in $($scriptFile.Name): $($errors -join '; ')"
        }
    }
}
