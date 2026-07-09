Set-StrictMode -Version Latest

# Tests for step3-StartInstantRecovery.ps1 — static analysis of the Veeam scriptblocks.
#
# The scriptblocks passed to Invoke-VeeamCommand run in a separate Veeam session:
# they cannot see the caller's variables, so every variable they read must be
# declared as a param or assigned inside the scriptblock itself. Step3.VeeamRecovery.ps1
# enables Set-StrictMode, so any unresolved variable fails at runtime
# ("The variable '$restoreSessions' cannot be retrieved because it has not been set")
# and silently breaks the monitoring loop. These tests catch that class of bug
# without needing a live Veeam server.

Describe 'step3-StartInstantRecovery.ps1 - Veeam scriptblock self-containment' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../powershell-migration/step3-StartInstantRecovery.ps1"

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty

        # Every scriptblock literal passed to an Invoke-VeeamCommand call.
        $script:veeamScriptBlocks = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-VeeamCommand'
        }, $true) | ForEach-Object {
            $_.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
            } | ForEach-Object { $_.ScriptBlock }
        }

        # Variables PowerShell provides regardless of scope.
        $script:automaticVariables = @(
            '_', 'PSItem', 'null', 'true', 'false', 'args', 'input', 'this',
            'Error', 'LASTEXITCODE', 'Matches', 'MyInvocation', 'PSBoundParameters',
            'PSCmdlet', 'PSScriptRoot', 'PSCommandPath', 'ErrorActionPreference',
            'VerbosePreference', 'WarningPreference', 'PSVersionTable', 'HOME', 'PWD'
        )

        function Get-UnresolvedVariable {
            param([System.Management.Automation.Language.ScriptBlockAst]$ScriptBlock)

            $defined = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($name in $script:automaticVariables) { $null = $defined.Add($name) }

            if ($ScriptBlock.ParamBlock) {
                foreach ($p in $ScriptBlock.ParamBlock.Parameters) {
                    $null = $defined.Add($p.Name.VariablePath.UserPath)
                }
            }

            # Assignment targets ($x = ..., $x += ...), including multi-target forms.
            foreach ($assignment in $ScriptBlock.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true)) {
                foreach ($target in $assignment.Left.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true)) {
                    $null = $defined.Add($target.VariablePath.UserPath)
                }
            }

            # foreach ($x in ...) loop variables.
            foreach ($loop in $ScriptBlock.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ForEachStatementAst]
            }, $true)) {
                $null = $defined.Add($loop.Variable.VariablePath.UserPath)
            }

            # Nested function/scriptblock params count for their own bodies; this file's
            # Veeam scriptblocks don't nest params, so a flat scan keeps the test simple.

            $ScriptBlock.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst]
            }, $true) | Where-Object {
                -not $defined.Contains($_.VariablePath.UserPath)
            } | ForEach-Object {
                "line $($_.Extent.StartLineNumber): `$$($_.VariablePath.UserPath)"
            }
        }
    }

    It 'Contains at least two Invoke-VeeamCommand scriptblocks (start + monitoring)' {
        @($script:veeamScriptBlocks).Count | Should -BeGreaterOrEqual 2
    }

    It 'Every variable read inside a Veeam scriptblock is defined within it' {
        $unresolved = foreach ($sb in $script:veeamScriptBlocks) {
            Get-UnresolvedVariable -ScriptBlock $sb
        }
        $unresolved | Should -BeNullOrEmpty
    }

    It 'Monitoring scriptblock fetches restore sessions before calling Find-VmRestoreSession' {
        $monitoring = $script:veeamScriptBlocks | Where-Object {
            $_.Extent.Text -match 'Find-VmRestoreSession'
        }
        $monitoring | Should -Not -BeNullOrEmpty
        # Regression: BEA-270 refactor dropped the Get-VBRRestoreSession fetch, leaving
        # $restoreSessions undefined and the progress loop stuck at 0/N under StrictMode.
        $monitoring.Extent.Text | Should -Match '\$restoreSessions\s*=\s*@\(Get-VBRRestoreSession\)'
    }
}
