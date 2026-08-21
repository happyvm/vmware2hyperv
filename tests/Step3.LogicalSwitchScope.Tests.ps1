<#
.SYNOPSIS
    Tests for the logical switch -> logical network resolution used to scope
    SCVMM network discovery.
.DESCRIPTION
    The helper returned its HashSet with a bare 'return', so PowerShell unrolled
    it: zero logical networks arrived as $null and ONE arrived as a bare string.
    The caller's '.Count -gt 0' then raised a non-terminating
    PropertyNotFoundException, which aborts the whole if statement -- so the
    logical switch filter was silently skipped and VM network discovery ran
    against the unfiltered inventory.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'powershell-migration/step3/Step3.ScvmmSession.Functions.ps1'
    . $script:ModulePath

    function script:Get-SCLogicalSwitch { }
    function script:Get-SCUplinkPortProfileSet { }
    function script:Get-SCVMNetwork { }
    function script:Get-SCVMSubnet { }
    function script:Get-SCPortClassification { }

    function script:New-TestUplinkSet {
        param([string[]]$LogicalNetworkIds)
        [pscustomobject]@{
            NativeUplinkPortProfile = [pscustomobject]@{
                LogicalNetworkDefinitions = @(
                    $LogicalNetworkIds | ForEach-Object {
                        [pscustomobject]@{ LogicalNetwork = [pscustomobject]@{ ID = $_ } }
                    }
                )
            }
        }
    }
}

Describe 'Get-ScvmmLogicalSwitchLogicalNetworkIds' {

    It 'returns a real set for a switch backed by ONE logical network' {
        # The production case: a single uplink profile with a single logical
        # network. A bare return unrolled this to a [string].
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS_SET_VMNetwork' } }
        Mock Get-SCUplinkPortProfileSet { @(New-TestUplinkSet -LogicalNetworkIds @('ln-1415')) }

        $result = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'LS_SET_VMNetwork'

        $result | Should -Not -BeNullOrEmpty
        $result.GetType().Name | Should -Be 'HashSet`1'
        $result.Count | Should -Be 1
        $result.Contains('ln-1415') | Should -BeTrue
    }

    It 'returns an empty set, not $null, when the switch resolves to nothing' {
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS_SET_VMNetwork' } }
        Mock Get-SCUplinkPortProfileSet { @() }

        $result = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'LS_SET_VMNetwork'

        $null -eq $result | Should -BeFalse
        $result.GetType().Name | Should -Be 'HashSet`1'
        $result.Count | Should -Be 0
    }

    It 'returns an empty set, not $null, when the switch does not exist' {
        Mock Get-SCLogicalSwitch { $null }
        $warnings = New-Object 'System.Collections.Generic.List[string]'

        $result = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'Missing' -WarningSink $warnings

        $null -eq $result | Should -BeFalse
        $result.GetType().Name | Should -Be 'HashSet`1'
        $result.Count | Should -Be 0
        $warnings.Count | Should -BeGreaterThan 0
    }

    It 'keeps set membership semantics rather than substring matching' {
        # A single unrolled string would answer .Contains() as a SUBSTRING test.
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS' } }
        Mock Get-SCUplinkPortProfileSet { @(New-TestUplinkSet -LogicalNetworkIds @('ln-1415')) }

        $result = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'LS'

        $result.Contains('ln-14') | Should -BeFalse
        $result.Contains('ln-1415') | Should -BeTrue
    }

    It 'collects several logical networks across uplink profiles' {
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS' } }
        Mock Get-SCUplinkPortProfileSet {
            @(
                (New-TestUplinkSet -LogicalNetworkIds @('ln-a')),
                (New-TestUplinkSet -LogicalNetworkIds @('ln-b', 'ln-c'))
            )
        }

        $result = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'LS'
        $result.Count | Should -Be 3
    }

    It 'does not throw when its result is used the way the caller uses it' {
        # Reproduces the failing statement itself: the .Count read is what raised
        # PropertyNotFoundException in production.
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS' } }
        Mock Get-SCUplinkPortProfileSet { @(New-TestUplinkSet -LogicalNetworkIds @('ln-1415')) }

        {
            $ids = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'LS'
            if ($ids.Count -gt 0) { $null = $ids.Contains('ln-1415') }
        } | Should -Not -Throw
    }
}

Describe 'Inventory warning sink' {

    # An EMPTY List is falsy in PowerShell, so 'if ($WarningSink)' discarded every
    # warning: the sink only becomes truthy once it already holds something.
    It 'records the warning when the logical switch is missing' {
        Mock Get-SCLogicalSwitch { $null }
        $warnings = New-Object 'System.Collections.Generic.List[string]'

        $null = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'Missing' -WarningSink $warnings

        $warnings.Count | Should -Be 1
        $warnings[0] | Should -Match 'not found in SCVMM'
    }

    It 'records the warning when the switch resolves to no logical network' {
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS' } }
        Mock Get-SCUplinkPortProfileSet { @() }
        $warnings = New-Object 'System.Collections.Generic.List[string]'

        $null = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'LS' -WarningSink $warnings

        $warnings.Count | Should -Be 1
        $warnings[0] | Should -Match 'No logical network resolved'
    }

    It 'records the warning when the uplink enumeration fails' {
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS' } }
        Mock Get-SCUplinkPortProfileSet { throw 'VMM refused' }
        $warnings = New-Object 'System.Collections.Generic.List[string]'

        $null = Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'LS' -WarningSink $warnings

        @($warnings | Where-Object { $_ -match 'Unable to enumerate uplink port profiles' }).Count | Should -Be 1
    }

    It 'still works without a sink' {
        Mock Get-SCLogicalSwitch { $null }
        { Get-ScvmmLogicalSwitchLogicalNetworkIds -Server 'vmm' -LogicalSwitchName 'Missing' } | Should -Not -Throw
    }
}

Describe 'Get-ScvmmInventoryCache logical switch filtering' {

    BeforeEach {
        # The cache is script-scoped and persists across calls in a worker.
        Set-Variable -Name ScvmmInventoryCacheByServer -Scope Script -Value @{}

        $script:NetOnSwitch = [pscustomobject]@{
            Name = 'LAN_1415'; ID = 'net-1415'
            LogicalNetwork = [pscustomobject]@{ ID = 'ln-1415' }
        }
        $script:NetElsewhere = [pscustomobject]@{
            Name = 'LAN_9999'; ID = 'net-9999'
            LogicalNetwork = [pscustomobject]@{ ID = 'ln-other' }
        }
        $script:SubnetOnSwitch = [pscustomobject]@{
            Name = 'LAN_1415_0'; ID = 'sub-1415'
            VMNetwork = [pscustomobject]@{ ID = 'net-1415' }
            SubnetVLans = @([pscustomobject]@{ VLanID = 1415 })
        }
        $script:SubnetElsewhere = [pscustomobject]@{
            Name = 'LAN_9999_0'; ID = 'sub-9999'
            VMNetwork = [pscustomobject]@{ ID = 'net-9999' }
            SubnetVLans = @([pscustomobject]@{ VLanID = 9999 })
        }

        Mock Get-SCVMNetwork { @($script:NetOnSwitch, $script:NetElsewhere) }
        Mock Get-SCVMSubnet { @($script:SubnetOnSwitch, $script:SubnetElsewhere) }
        Mock Get-SCPortClassification { @([pscustomobject]@{ Name = 'PC_VMNetwork' }) }
        Mock Get-SCLogicalSwitch { [pscustomobject]@{ Name = 'LS_SET_VMNetwork' } }
    }

    It 'restricts discovery to the networks behind the switch when it resolves to ONE' {
        # This is the regression: the filter used to be skipped entirely, leaving
        # LAN_9999 as a candidate for every VLAN lookup.
        Mock Get-SCUplinkPortProfileSet { @(New-TestUplinkSet -LogicalNetworkIds @('ln-1415')) }

        $cache = Get-ScvmmInventoryCache -Server ([pscustomobject]@{ Name = 'vmm01' }) -LogicalSwitch 'LS_SET_VMNetwork'

        @($cache.AllVMNetworks).Count | Should -Be 1
        [string]@($cache.AllVMNetworks)[0].Name | Should -Be 'LAN_1415'
        @($cache.AllVMSubnets).Count | Should -Be 1
    }

    It 'keeps the unfiltered inventory when the switch resolves to nothing' {
        Mock Get-SCUplinkPortProfileSet { @() }
        $warnings = New-Object 'System.Collections.Generic.List[string]'

        $cache = Get-ScvmmInventoryCache -Server ([pscustomobject]@{ Name = 'vmm01' }) -LogicalSwitch 'LS_SET_VMNetwork' -WarningSink $warnings

        @($cache.AllVMNetworks).Count | Should -Be 2
    }

    It 'does not raise a PropertyNotFoundException while building the cache' {
        Mock Get-SCUplinkPortProfileSet { @(New-TestUplinkSet -LogicalNetworkIds @('ln-1415')) }

        $Error.Clear()
        $null = Get-ScvmmInventoryCache -Server ([pscustomobject]@{ Name = 'vmm01' }) -LogicalSwitch 'LS_SET_VMNetwork'
        @($Error | Where-Object { $_.Exception -is [System.Management.Automation.PropertyNotFoundException] }).Count |
            Should -Be 0
    }
}
