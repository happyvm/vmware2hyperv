<#
.SYNOPSIS
    Tests for the Instant Recovery dashboard columns.
.DESCRIPTION
    The InstantRecovery and Progress columns showed '<none>' and '-' for entire
    runs: the Instant Recovery session was matched on a single name property and
    its state read from a single 'State' property, and progress was read only
    from a flat 'Progress'. None of those exist on every Veeam build.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MigrationRoot = Join-Path $script:RepoRoot 'powershell-migration'
    . (Join-Path $script:MigrationRoot 'step3/Step3.VeeamRecovery.ps1')
    $script:BulkSource = Get-Content -Path (Join-Path $script:MigrationRoot 'step3-StartInstantRecovery.ps1') -Raw
}

Describe 'Get-VeeamPropertyValue' {

    It 'returns the first candidate that carries a value' {
        $o = [pscustomobject]@{ Status = 'Working' }
        Get-VeeamPropertyValue -InputObject $o -PropertyPaths @('State', 'Status') | Should -Be 'Working'
    }

    It 'walks a dotted path' {
        $o = [pscustomobject]@{ Progress = [pscustomobject]@{ Percents = 42 } }
        Get-VeeamPropertyValue -InputObject $o -PropertyPaths @('Progress.Percents') | Should -Be 42
    }

    It 'skips a candidate whose value is empty' {
        $o = [pscustomobject]@{ State = '   '; Status = 'Starting' }
        Get-VeeamPropertyValue -InputObject $o -PropertyPaths @('State', 'Status') | Should -Be 'Starting'
    }

    It 'returns null when no candidate resolves, without throwing under StrictMode' {
        $o = [pscustomobject]@{ Unrelated = 1 }
        Get-VeeamPropertyValue -InputObject $o -PropertyPaths @('State', 'Progress.Percents') | Should -BeNullOrEmpty
    }

    It 'tolerates a null input object' {
        Get-VeeamPropertyValue -InputObject $null -PropertyPaths @('State') | Should -BeNullOrEmpty
    }

    It 'tolerates a dotted path whose first segment is null' {
        $o = [pscustomobject]@{ Progress = $null }
        Get-VeeamPropertyValue -InputObject $o -PropertyPaths @('Progress.Percents') | Should -BeNullOrEmpty
    }
}

Describe 'Find-VmInstantRecoverySession' {

    It 'matches a session that names the machine VmName' {
        $sessions = @([pscustomobject]@{ VmName = 'testjcv-mighyp03'; State = 'Mounting' })
        (Find-VmInstantRecoverySession -VmName 'testjcv-mighyp03' -InstantRecoverySessions $sessions).State |
            Should -Be 'Mounting'
    }

    It 'matches a session that names it MachineName' {
        $sessions = @([pscustomobject]@{ MachineName = 'testjcv-mighyp03'; State = 'Mounting' })
        Find-VmInstantRecoverySession -VmName 'testjcv-mighyp03' -InstantRecoverySessions $sessions |
            Should -Not -BeNullOrEmpty
    }

    It 'matches a session that only carries Name' {
        $sessions = @([pscustomobject]@{ Name = 'testjcv-mighyp03'; State = 'Mounting' })
        Find-VmInstantRecoverySession -VmName 'testjcv-mighyp03' -InstantRecoverySessions $sessions |
            Should -Not -BeNullOrEmpty
    }

    It 'accepts the -migrationhyp suffix Veeam appends' {
        $sessions = @([pscustomobject]@{ VmName = 'testjcv-mighyp03-migrationhyp' })
        Find-VmInstantRecoverySession -VmName 'testjcv-mighyp03' -InstantRecoverySessions $sessions |
            Should -Not -BeNullOrEmpty
    }

    It 'does not let a prefix match another VM' {
        # WEB1 must never pick up WEB10's session.
        $sessions = @([pscustomobject]@{ VmName = 'WEB10' })
        Find-VmInstantRecoverySession -VmName 'WEB1' -InstantRecoverySessions $sessions |
            Should -BeNullOrEmpty
    }

    It 'returns null on an empty session list' {
        Find-VmInstantRecoverySession -VmName 'anything' -InstantRecoverySessions @() | Should -BeNullOrEmpty
    }

    It 'skips sessions exposing no name property at all' {
        $sessions = @([pscustomobject]@{ Id = 'x' }, [pscustomobject]@{ VmName = 'testjcv-mighyp03' })
        Find-VmInstantRecoverySession -VmName 'testjcv-mighyp03' -InstantRecoverySessions $sessions |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-VeeamObjectPropertySummary' {

    It 'names the type and its properties' {
        $summary = Get-VeeamObjectPropertySummary -InputObject ([pscustomobject]@{ VmName = 'x'; State = 'y' })
        $summary | Should -Match 'VmName'
        $summary | Should -Match 'State'
    }

    It 'reports a null object rather than throwing' {
        Get-VeeamObjectPropertySummary -InputObject $null | Should -Be '<null>'
    }

    It 'caps the list and says how many were elided' {
        $many = [pscustomobject]@{}
        1..10 | ForEach-Object { $many | Add-Member -NotePropertyName "P$_" -NotePropertyValue $_ }
        $summary = Get-VeeamObjectPropertySummary -InputObject $many -MaxProperties 3
        $summary | Should -Match '\+7 more'
    }
}

Describe 'step3 dashboard wiring' {

    It 'resolves the Instant Recovery session through the shared helper' {
        $script:BulkSource | Should -Match 'Find-VmInstantRecoverySession -VmName \$vmName -InstantRecoverySessions \$irSessions'
        $script:BulkSource | Should -Not -Match "Where-Object \{ \`$_\.PSObject\.Properties\['VMName'\] -and \[string\]\`$_\.VMName -eq \`$vmName \}"
    }

    It 'reads the Instant Recovery state from several candidates' {
        $script:BulkSource | Should -Match "PropertyPaths @\('State', 'Status', 'SessionState'\)"
    }

    It 'reads progress from the dotted candidates first' {
        $script:BulkSource | Should -Match "'Progress\.Percents', 'Progress\.Percent', 'ProgressPercent', 'CompletionPercentage', 'Progress'"
    }

    It 'reports once which properties Veeam exposes when a column stays empty' {
        $script:BulkSource | Should -Match 'Instant Recovery dashboard: \$diagnosticText'
        $script:BulkSource | Should -Match '\$loggedDiagnostics'
        $script:BulkSource | Should -Match '\(\$elapsed -eq 0\)'
    }

    It 'only appends a percent sign to a numeric progress' {
        $expected = [regex]::Escape('[string]$tracked.Progress -match ''^\d+(\.\d+)?$''')
        $script:BulkSource | Should -Match $expected
    }
}
