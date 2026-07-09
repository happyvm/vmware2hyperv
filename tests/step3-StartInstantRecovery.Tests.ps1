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

    It 'Monitoring poll yields one snapshot per VM, with string VMName (argument binding)' {
        # Regression: -ArgumentList @(, [string[]]$pendingNames, $path) double-wrapped the
        # name array, so the scriptblock iterated ONCE with the whole array as $vmName:
        # no Veeam match ('<none>' everywhere), and the caller dropped the snapshot because
        # its key was the space-joined names. Progress stayed at 0/N with no error shown.
        $monitoringCommand = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-VeeamCommand' -and
            $node.Extent.Text -match 'Find-VmRestoreSession'
        }, $true) | Select-Object -First 1
        $monitoringCommand | Should -Not -BeNullOrEmpty

        $sbAst = $monitoringCommand.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
        } | Select-Object -First 1
        $argListIndex = 0..($monitoringCommand.CommandElements.Count - 1) | Where-Object {
            $el = $monitoringCommand.CommandElements[$_]
            $el -is [System.Management.Automation.Language.CommandParameterAst] -and
            $el.ParameterName -eq 'ArgumentList'
        } | Select-Object -First 1
        $argListAst = $monitoringCommand.CommandElements[$argListIndex + 1]

        # Rebuild the caller's context, then evaluate the file's own ArgumentList expression
        # and invoke the file's own scriptblock exactly like Invoke-VeeamCommand does locally.
        $pendingNames = @('WEB1', 'WEB2')
        $step3VeeamRecoveryPath = "$PSScriptRoot/../powershell-migration/step3/Step3.VeeamRecovery.ps1"
        $argumentList = Invoke-Expression $argListAst.Extent.Text

        function global:Get-VBRInstantRecovery {
            [pscustomobject]@{ VMName = 'WEB1'; State = 'WaitingForUserAction' }
        }
        function global:Get-VBRRestoreSession {
            [pscustomobject]@{ Name = 'WEB2'; CreationTime = Get-Date; State = 'Working'; Result = 'None' }
        }
        try {
            $snapshots = @(& $sbAst.ScriptBlock.GetScriptBlock() @argumentList)
        } finally {
            Remove-Item function:global:Get-VBRInstantRecovery, function:global:Get-VBRRestoreSession
        }

        @($snapshots).Count | Should -Be 2
        foreach ($snapshot in $snapshots) { $snapshot.VMName | Should -BeOfType [string] }
        ($snapshots | ForEach-Object VMName) | Should -Be @('WEB1', 'WEB2')
        ($snapshots | Where-Object VMName -eq 'WEB1').WaitingDetected | Should -BeTrue
        ($snapshots | Where-Object VMName -eq 'WEB2').SessionState | Should -Be 'Working'
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
