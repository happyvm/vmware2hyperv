<#
.SYNOPSIS
    Tests for the VMware NIC connection state helpers (lib.ps1).
.DESCRIPTION
    Covers the distinction that matters for a migration: Connected is the live
    link, StartConnected is what decides whether a powered-off source VM rejoins
    the network the next time somebody boots it.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MigrationRoot = Join-Path $script:RepoRoot 'powershell-migration'
    . (Join-Path $script:MigrationRoot 'lib.ps1')
}

Describe 'Get-VmwareAdapterConnectionState' {

    It 'reads the PowerCLI NicConnectionState shape' {
        $adapter = [pscustomobject]@{
            Name = 'Network adapter 1'
            ConnectionState = [pscustomobject]@{ Connected = $true; StartConnected = $true; AllowGuestControl = $true }
        }
        $state = Get-VmwareAdapterConnectionState -Adapter $adapter
        $state.Connected | Should -BeTrue
        $state.StartConnected | Should -BeTrue
        $state.Source | Should -Be 'ConnectionState'
    }

    It 'reads flattened adapter properties' {
        $adapter = [pscustomobject]@{ Name = 'nic1'; Connected = $false; StartConnected = $true }
        $state = Get-VmwareAdapterConnectionState -Adapter $adapter
        $state.Connected | Should -BeFalse
        $state.StartConnected | Should -BeTrue
        $state.Source | Should -Be 'Adapter'
    }

    It 'falls back to the raw vSphere Connectable object' {
        $adapter = [pscustomobject]@{
            Name = 'nic1'
            ExtensionData = [pscustomobject]@{
                Connectable = [pscustomobject]@{ Connected = $true; StartConnected = $false }
            }
        }
        $state = Get-VmwareAdapterConnectionState -Adapter $adapter
        $state.Connected | Should -BeTrue
        $state.StartConnected | Should -BeFalse
        $state.Source | Should -Be 'ExtensionData'
    }

    It 'returns nulls rather than throwing on an unknown adapter shape' {
        $state = Get-VmwareAdapterConnectionState -Adapter ([pscustomobject]@{ Name = 'mystery' })
        $state.Connected | Should -BeNullOrEmpty
        $state.StartConnected | Should -BeNullOrEmpty
        $state.Source | Should -Be 'unknown'
    }

    It 'returns nulls for a null adapter' {
        $state = Get-VmwareAdapterConnectionState -Adapter $null
        $state.Connected | Should -BeNullOrEmpty
        $state.StartConnected | Should -BeNullOrEmpty
    }
}

Describe 'Set-VmwareVmNetworkAdapterConnection' {

    BeforeAll {
        # Stubs must declare the parameters, otherwise nothing binds and
        # $PesterBoundParameters comes back empty.
        function script:Get-NetworkAdapter {
            [CmdletBinding()]
            param($VM)
        }
        function script:Set-NetworkAdapter {
            # SupportsShouldProcess only so the production call's -Confirm:$false
            # binds; this stub has no side effect to protect.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Test stub for the PowerCLI cmdlet; no action is performed.')]
            [CmdletBinding(SupportsShouldProcess = $true)]
            param($NetworkAdapter, $Connected, $StartConnected)
        }
    }

    BeforeEach {
        $script:SetCalls = [System.Collections.Generic.List[hashtable]]::new()
    }

    Context 'disconnecting a powered-off source VM' {

        # The whole point of the change: a VM that is already off has a
        # meaningless live link state, but its StartConnected flag is exactly
        # what makes it rejoin the network on the next power on.
        It 'clears StartConnected and does not touch the runtime link' {
            $adapter = [pscustomobject]@{
                Name = 'Network adapter 1'
                ConnectionState = [pscustomobject]@{ Connected = $false; StartConnected = $true }
            }
            $vm = [pscustomobject]@{ Name = 'SRV-WEB01'; PowerState = 'PoweredOff' }

            Mock Get-NetworkAdapter { @($adapter) }
            Mock Set-NetworkAdapter { $script:SetCalls.Add($PesterBoundParameters) }

            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-WEB01' -VmObject $vm -Connected $false

            $result.ChangedCount | Should -Be 1
            $result.FailedCount | Should -Be 0
            $script:SetCalls.Count | Should -Be 1
            $script:SetCalls[0].StartConnected | Should -BeFalse
            $script:SetCalls[0].ContainsKey('Connected') | Should -BeFalse
        }

        It 'acts even when the live link is already down' {
            # The previous implementation returned early here ("All NICs are
            # already disconnected") and left StartConnected = $true.
            $adapter = [pscustomobject]@{ Name = 'nic1'; Connected = $false; StartConnected = $true }
            $vm = [pscustomobject]@{ Name = 'SRV-DB01'; PowerState = 'PoweredOff' }

            Mock Get-NetworkAdapter { @($adapter) }
            Mock Set-NetworkAdapter { $script:SetCalls.Add($PesterBoundParameters) }

            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-DB01' -VmObject $vm -Connected $false
            $result.ChangedCount | Should -Be 1
        }
    }

    Context 'disconnecting a running VM' {

        It 'clears both the runtime link and StartConnected' {
            $adapter = [pscustomobject]@{
                Name = 'nic1'
                ConnectionState = [pscustomobject]@{ Connected = $true; StartConnected = $true }
            }
            $vm = [pscustomobject]@{ Name = 'SRV-APP01'; PowerState = 'PoweredOn' }

            Mock Get-NetworkAdapter { @($adapter) }
            Mock Set-NetworkAdapter { $script:SetCalls.Add($PesterBoundParameters) }

            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-APP01' -VmObject $vm -Connected $false

            $result.ChangedCount | Should -Be 1
            $script:SetCalls[0].StartConnected | Should -BeFalse
            $script:SetCalls[0].Connected | Should -BeFalse
        }
    }

    Context 'when nothing needs changing' {

        It 'leaves an already fully disconnected adapter alone' {
            $adapter = [pscustomobject]@{
                Name = 'nic1'
                ConnectionState = [pscustomobject]@{ Connected = $false; StartConnected = $false }
            }
            $vm = [pscustomobject]@{ Name = 'SRV-WEB02'; PowerState = 'PoweredOff' }

            Mock Get-NetworkAdapter { @($adapter) }
            Mock Set-NetworkAdapter { $script:SetCalls.Add($PesterBoundParameters) }

            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-WEB02' -VmObject $vm -Connected $false

            $result.ChangedCount | Should -Be 0
            $result.UnchangedCount | Should -Be 1
            $script:SetCalls.Count | Should -Be 0
        }
    }

    Context 'reconnecting for a rollback' {

        It 'sets StartConnected back to true' {
            $adapter = [pscustomobject]@{
                Name = 'nic1'
                ConnectionState = [pscustomobject]@{ Connected = $false; StartConnected = $false }
            }
            $vm = [pscustomobject]@{ Name = 'SRV-WEB01'; PowerState = 'PoweredOff' }

            Mock Get-NetworkAdapter { @($adapter) }
            Mock Set-NetworkAdapter { $script:SetCalls.Add($PesterBoundParameters) }

            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-WEB01' -VmObject $vm -Connected $true

            $result.ChangedCount | Should -Be 1
            $script:SetCalls[0].StartConnected | Should -BeTrue
        }
    }

    Context 'failure handling' {

        # A NIC that stays plugged in is exactly the case the operator must hear
        # about: the source VM can rejoin the network behind their back.
        It 'counts failures instead of swallowing them' {
            $adapter = [pscustomobject]@{ Name = 'nic1'; Connected = $true; StartConnected = $true }
            $vm = [pscustomobject]@{ Name = 'SRV-KO'; PowerState = 'PoweredOn' }

            Mock Get-NetworkAdapter { @($adapter) }
            Mock Set-NetworkAdapter { throw 'vCenter said no' }

            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-KO' -VmObject $vm -Connected $false

            $result.FailedCount | Should -Be 1
            $result.ChangedCount | Should -Be 0
        }

        It 'reports no adapter without throwing' {
            $vm = [pscustomobject]@{ Name = 'SRV-NONIC'; PowerState = 'PoweredOff' }
            Mock Get-NetworkAdapter { @() }
            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-NONIC' -VmObject $vm -Connected $false
            $result.AdapterCount | Should -Be 0
        }

        It 'reports a null VM without throwing' {
            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-GONE' -VmObject $null -Connected $false
            $result.AdapterCount | Should -Be 0
        }
    }

    Context 'multiple adapters' {

        It 'processes every NIC of the VM' {
            $adapters = @(
                [pscustomobject]@{ Name = 'nic1'; Connected = $true; StartConnected = $true },
                [pscustomobject]@{ Name = 'nic2'; Connected = $true; StartConnected = $true },
                [pscustomobject]@{ Name = 'nic3'; Connected = $false; StartConnected = $false }
            )
            $vm = [pscustomobject]@{ Name = 'SRV-MULTI'; PowerState = 'PoweredOn' }

            Mock Get-NetworkAdapter { $adapters }
            Mock Set-NetworkAdapter { $script:SetCalls.Add($PesterBoundParameters) }

            $result = Set-VmwareVmNetworkAdapterConnection -VmName 'SRV-MULTI' -VmObject $vm -Connected $false

            $result.AdapterCount | Should -Be 3
            $result.ChangedCount | Should -Be 2
            $result.UnchangedCount | Should -Be 1
        }
    }
}

Describe 'step2 and rollback wiring' {

    BeforeAll {
        $script:Step2Source = Get-Content -Path (Join-Path $script:MigrationRoot 'step2-ShutdownVM_StartBackupVeeam.ps1') -Raw
        $script:RollbackSource = Get-Content -Path (Join-Path $script:MigrationRoot 'Invoke-Rollback.ps1') -Raw
    }

    It 'step2 unplugs NICs through the shared helper' {
        $script:Step2Source | Should -Match 'Set-VmwareVmNetworkAdapterConnection -VmName \$VmName -VmObject \$VmObject -Connected \$false'
    }

    It 'step2 no longer flips only the runtime link' {
        $script:Step2Source | Should -Not -Match 'Set-NetworkAdapter -NetworkAdapter \$adapter -Connected:\$false'
    }

    It 'step2 escalates a NIC it could not unplug' {
        $script:Step2Source | Should -Match 'may rejoin the network if it is powered on again'
    }

    # Clearing StartConnected without this would make Layer 1 restore a VM with
    # no network at all.
    It 'the rollback plugs the NICs back in before powering the VM on' {
        $script:RollbackSource | Should -Match 'Set-VmwareVmNetworkAdapterConnection -VmName \$VMName -VmObject \$vm -Connected \$true'
        $reconnectIndex = $script:RollbackSource.IndexOf('-VmObject $vm -Connected $true')
        $startIndex = $script:RollbackSource.IndexOf('Start-VM -VM $vm')
        $reconnectIndex | Should -BeGreaterThan 0
        $reconnectIndex | Should -BeLessThan $startIndex
    }

    It 'the rollback also reconnects an already-running VM' {
        $script:RollbackSource | Should -Match 'Set-VmwareVmNetworkAdapterConnection -VmName \$VMName -VmObject \$runningVm -Connected \$true'
    }

    It 'the rollback respects -DryRun for the reconnect' {
        $script:RollbackSource | Should -Match 'DRY-RUN\] Would reconnect the NICs'
    }
}
