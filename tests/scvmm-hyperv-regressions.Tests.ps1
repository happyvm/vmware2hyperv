<#
.SYNOPSIS
    Regression tests for the SCVMM / Hyper-V bugs fixed in the
    claude/scvmm-hyperv-bugs pass.
.DESCRIPTION
    Each Context maps to one defect. Behavioural tests are used wherever the
    logic is reachable without a live SCVMM; the remaining cases are guarded by
    source assertions, the same approach as tests/step3-MigrateVM.Tests.ps1.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MigrationRoot = Join-Path $script:RepoRoot 'powershell-migration'

    . (Join-Path $script:MigrationRoot 'lib.ps1')
    . (Join-Path $script:MigrationRoot 'step3' 'Step3.ScvmmSession.Functions.ps1')

    function script:Get-MigrationSource {
        param([Parameter(Mandatory = $true)][string]$RelativePath)
        Get-Content -Path (Join-Path $script:MigrationRoot $RelativePath) -Raw
    }
}

Describe 'SCVMM VM memory reported in megabytes' {

    # SCVMM exposes VirtualMachine.Memory in MB. Dividing it by 1GB rounded every
    # VM down to 0 GB, so step5's MemoryGB check failed for the whole batch.
    It 'converts a 4096 MB VM to 4 GB' {
        ConvertTo-ScvmmMemoryGigabytes -Value 4096 | Should -Be 4
    }

    It 'converts a 6144 MB VM to 6 GB' {
        ConvertTo-ScvmmMemoryGigabytes -Value 6144 | Should -Be 6
    }

    It 'never rounds a realistic VM down to zero' {
        foreach ($megabytes in @(512, 1024, 2048, 4096, 8192, 16384, 131072)) {
            ConvertTo-ScvmmMemoryGigabytes -Value $megabytes | Should -BeGreaterThan 0
        }
    }

    It 'still converts correctly if a VMM version ever reports bytes' {
        ConvertTo-ScvmmMemoryGigabytes -Value 4294967296 | Should -Be 4
    }

    It 'returns null for unreadable values' {
        ConvertTo-ScvmmMemoryGigabytes -Value 'n/a' | Should -BeNullOrEmpty
        ConvertTo-ScvmmMemoryGigabytes -Value $null | Should -BeNullOrEmpty
        ConvertTo-ScvmmMemoryGigabytes -Value -1 | Should -BeNullOrEmpty
    }

    It 'no longer divides the SCVMM VM memory by 1GB in step5' {
        $source = Get-MigrationSource -RelativePath 'step5-ValidateMigration.ps1'
        $source | Should -Not -Match '\$vm\.Memory\s*/\s*1GB'
        $source | Should -Match 'ConvertTo-ScvmmMemoryGigabytes -Value \$vm\.Memory'
    }
}

Describe 'Resolve-ScvmmVlanMapping name-parsed fallback' {

    # The VMNetwork and the VMSubnet used to be picked from two independent
    # lists, so an adapter could be attached to a subnet owned by a different
    # VM network.
    Context 'when several subnets carry the VLAN digits' {

        BeforeAll {
            $script:NetworkB = [pscustomobject]@{ ID = 'net-b'; Name = 'VLAN-400-B' }
            # Sorted by name, 'Subnet-400-A' comes first but belongs to another network.
            $script:SubnetA = [pscustomobject]@{ Name = 'Subnet-400-A'; VMNetworkID = 'net-a' }
            $script:SubnetB = [pscustomobject]@{ Name = 'Subnet-400-B'; VMNetworkID = 'net-b' }

            $script:Cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '400' = @($script:NetworkB) }
                VMSubnetsByVlan        = @{ '400' = @($script:SubnetA, $script:SubnetB) }
                AllVMNetworks          = @($script:NetworkB)
                AllVMSubnets           = @($script:SubnetA, $script:SubnetB)
            }
        }

        It 'selects the subnet that belongs to the selected VM network' {
            $result = Resolve-ScvmmVlanMapping -InventoryCache $script:Cache -VlanKey '400'
            $result.VMNetwork.Name | Should -Be 'VLAN-400-B'
            $result.VMSubnet.Name | Should -Be 'Subnet-400-B'
            $result.ResolutionMode | Should -Be 'name-parsed-vlan'
        }
    }

    Context 'when the network is matched by name rather than by ID' {

        It 'pairs on VMNetworkName' {
            $network = [pscustomobject]@{ ID = 'net-1'; Name = 'VLAN-500' }
            $wrongSubnet = [pscustomobject]@{ Name = 'Subnet-500-A'; VMNetworkName = 'VLAN-500-OTHER' }
            $rightSubnet = [pscustomobject]@{ Name = 'Subnet-500-B'; VMNetworkName = 'VLAN-500' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '500' = @($network) }
                VMSubnetsByVlan        = @{ '500' = @($wrongSubnet, $rightSubnet) }
                AllVMNetworks          = @($network)
                AllVMSubnets           = @($wrongSubnet, $rightSubnet)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '500'
            $result.VMSubnet.Name | Should -Be 'Subnet-500-B'
        }
    }

    Context 'when no candidate subnet belongs to any candidate network' {

        It 'still returns a mapping but flags it as ambiguous' {
            $network = [pscustomobject]@{ ID = 'net-1'; Name = 'VLAN-600' }
            $foreignSubnet = [pscustomobject]@{ Name = 'Subnet-600'; VMNetworkID = 'net-elsewhere' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '600' = @($network) }
                VMSubnetsByVlan        = @{ '600' = @($foreignSubnet) }
                AllVMNetworks          = @($network)
                AllVMSubnets           = @($foreignSubnet)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '600'
            $result | Should -Not -BeNullOrEmpty
            $result.VMSubnet.Name | Should -Be 'Subnet-600'
            $result.Ambiguous | Should -BeTrue
        }
    }

    Context 'when the subnets expose no ownership information at all' {

        It 'keeps the forced pair non-ambiguous' {
            $network = [pscustomobject]@{ ID = 'net-1'; Name = 'VLAN-700' }
            $subnet = [pscustomobject]@{ Name = 'Subnet-700' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '700' = @($network) }
                VMSubnetsByVlan        = @{ '700' = @($subnet) }
                AllVMNetworks          = @($network)
                AllVMSubnets           = @($subnet)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '700'
            $result.Ambiguous | Should -BeFalse
        }
    }
}

Describe 'Invoke-Rollback SCVMM connection' {

    BeforeAll {
        $script:RollbackSource = Get-MigrationSource -RelativePath 'Invoke-Rollback.ps1'
    }

    # Without -VMMServer the SCVMM cmdlets target the local machine: the Hyper-V
    # copy was reported absent, never stopped, and the VMware source was powered
    # back on beside it.
    It 'passes -VMMServer to every Get-SCVirtualMachine call' {
        $calls = [regex]::Matches($script:RollbackSource, 'Get-SCVirtualMachine[^\r\n]*')
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            $call.Value | Should -Match '-VMMServer\s+\$server'
        }
    }

    It 'resolves the configured SCVMM server before any rollback action' {
        $script:RollbackSource | Should -Match "Get-MigrationConfigValue -Config \`$Config -Path 'SCVMM\.Server'"
    }

    It 'refuses to power on the VMware VM when the SCVMM state is unknown' {
        $script:RollbackSource | Should -Match 'QueryFailed'
        $script:RollbackSource | Should -Match 'refusing to power on the VMware VM'
    }

    It 'returns the same object shape whether or not the VM was found' {
        $script:RollbackSource | Should -Match 'Found\s*=\s*\$false;\s*Running\s*=\s*\$false;\s*Host\s*=\s*\$null;\s*ID\s*=\s*\$null'
    }
}

Describe 'step4 compliance polling' {

    BeforeAll {
        $script:Step4Source = Get-MigrationSource -RelativePath 'step4-StartVM.ps1'
    }

    # VMs absent from SCVMM when the initial snapshot was taken used to be
    # excluded from every later refresh, so the default unlimited loop could
    # never terminate and never noticed them appearing.
    It 'refreshes every non-compliant VM, not only the ones already found' {
        $script:Step4Source | Should -Not -Match '\$vmInventory\s*\|\s*\r?\n\s*Where-Object \{ \$_\.VmFound -and -not \$_\.DisplayCompleted \}\s*\|\s*\r?\n\s*Select-Object -ExpandProperty VMName'
        $script:Step4Source | Should -Match 'Where-Object \{ -not \$_\.DisplayCompleted \}\s*\|\s*\r?\n\s*Select-Object -ExpandProperty VMName'
    }

    It 'updates VmFound from each refreshed snapshot' {
        $script:Step4Source | Should -Match '\$vmItem\.VmFound = \[bool\]\$snapshot\.Exists'
    }

    It 'starts VMs that only appear in SCVMM after the initial start pass' {
        $script:Step4Source | Should -Match '\$vmsAppearedInScvmm'
        $script:Step4Source | Should -Match '\$lateVmsToStart'
    }
}

Describe 'SCVMM property reads under StrictMode' {

    # $vm.VMHost is $null for a VM with no host (library, broken cluster state)
    # and $null.ComputerName throws under StrictMode, which aborted the SCVMM
    # inventory for the whole batch.
    It 'guards VMHost before reading ComputerName' {
        foreach ($relativePath in @('step4-StartVM.ps1', 'step5-ValidateMigration.ps1', 'Invoke-Rollback.ps1')) {
            $source = Get-MigrationSource -RelativePath $relativePath
            $unguarded = [regex]::Matches($source, '(?<!\$vm\.VMHost\) \{ )\[string\]\$vm\.VMHost\.(ComputerName|Name)')
            $unguarded.Count | Should -Be 0 -Because "$relativePath must not dereference a possibly-null VMHost"
        }
    }
}

Describe 'step3 source adapter mapping' {

    BeforeAll {
        $script:NetworkConfigSource = Get-Content -Path (Join-Path $script:MigrationRoot 'step3' 'Step3.NetworkConfig.ps1') -Raw
    }

    # run-migration.ps1 stores 'PortGroup not found' as the VlanId when the port
    # group cannot be resolved. Dropping those adapters lost their MAC and
    # NetworkName mappings and shifted the index fallback for the other NICs.
    It 'keeps source adapters that carry a network name or a MAC but no numeric VLAN' {
        $script:NetworkConfigSource | Should -Match '\$_\.NetworkName'
        $script:NetworkConfigSource | Should -Match '\$_\.MacAddress'
    }

    It 'only tries to resolve numeric VLAN ids' {
        $expected = [regex]::Escape('if ($mappingVlan -match ''^\d+$'' -and -not $networkMappingsByVlan.ContainsKey($mappingVlan))')
        $script:NetworkConfigSource | Should -Match $expected
    }
}

Describe 'Get-ScvmmSubnetRealVlanId' {

    # The VLAN tag pushed to Set-SCVirtualNetworkAdapter must come from the subnet
    # the NIC is attached to, not from the VM's default VLAN.
    It 'reads the VLAN from SubnetVLans' {
        $subnet = [pscustomobject]@{ Name = 'Subnet-A'; SubnetVLans = @([pscustomobject]@{ VLanID = 812 }) }
        Get-ScvmmSubnetRealVlanId -Subnet $subnet | Should -Be '812'
    }

    It 'falls back to the subnet VLanID property' {
        $subnet = [pscustomobject]@{ Name = 'Subnet-B'; VLanID = 44 }
        Get-ScvmmSubnetRealVlanId -Subnet $subnet | Should -Be '44'
    }

    It 'ignores VLAN 0 (untagged in SCVMM)' {
        $subnet = [pscustomobject]@{ Name = 'Subnet-C'; SubnetVLans = @([pscustomobject]@{ VLanID = 0 }) }
        Get-ScvmmSubnetRealVlanId -Subnet $subnet | Should -BeNullOrEmpty
    }

    It 'returns null for a subnet exposing no VLAN information' {
        Get-ScvmmSubnetRealVlanId -Subnet ([pscustomobject]@{ Name = 'Subnet-D' }) | Should -BeNullOrEmpty
        Get-ScvmmSubnetRealVlanId -Subnet $null | Should -BeNullOrEmpty
    }

    It 'is used by the source-network-name mapping in Step3.NetworkConfig.ps1' {
        $source = Get-Content -Path (Join-Path $script:MigrationRoot 'step3' 'Step3.NetworkConfig.ps1') -Raw
        $source | Should -Match 'Get-ScvmmSubnetRealVlanId -Subnet \$selectedSubnetByName'
    }
}
