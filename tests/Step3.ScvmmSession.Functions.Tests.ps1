Set-StrictMode -Version Latest

# Tests for Resolve-ScvmmVlanMapping — pure function, no SCVMM dependency.
# The function operates on a pre-built inventory cache object (data only).
# Source: Step3.ScvmmSession.Functions.ps1

Describe 'Resolve-ScvmmVlanMapping' {
    BeforeAll {
        $modulePath = [System.IO.Path]::GetFullPath(
            (Join-Path $PWD.Path 'powershell-migration' 'step3' 'Step3.ScvmmSession.Functions.ps1')
        )
        . $modulePath
    }

    Context 'Real VLAN ID resolution (VMSubnetsByRealVlan)' {

        It 'resolves via real VLAN ID and returns VMNetwork/VMSubnet pair' {
            $fakeNetwork = [pscustomobject]@{
                ID   = 'net-1'
                Name = 'VM Network 42'
            }
            $fakeSubnet = [pscustomobject]@{
                Name        = 'Subnet-42'
                Description = 'VLAN 42 subnet'
                VMNetwork   = [pscustomobject]@{ ID = 'net-1' }
            }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{ '42' = @($fakeSubnet) }
                VMNetworksById         = @{ 'net-1' = $fakeNetwork }
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{}
                VMSubnetsByVlan        = @{}
                AllVMNetworks          = @()
                AllVMSubnets           = @()
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '42'
            $result | Should -Not -BeNullOrEmpty
            $result.ResolutionMode | Should -Be 'real-vlan-id'
            $result.VMNetwork.Name | Should -Be 'VM Network 42'
            $result.VMSubnet.Name | Should -Be 'Subnet-42'
            $result.Vlan | Should -Be '42'
            $result.Ambiguous | Should -BeFalse
        }

        It 'detects ambiguity when multiple subnets share the same real VLAN' {
            $fakeNetwork = [pscustomobject]@{
                ID   = 'net-1'
                Name = 'VM Network 100'
            }
            $fakeSubnetA = [pscustomobject]@{
                Name      = 'SubnetA'
                VMNetwork = [pscustomobject]@{ ID = 'net-1' }
            }
            $fakeSubnetB = [pscustomobject]@{
                Name      = 'SubnetB'
                VMNetwork = [pscustomobject]@{ ID = 'net-1' }
            }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{ '100' = @($fakeSubnetA, $fakeSubnetB) }
                VMNetworksById         = @{ 'net-1' = $fakeNetwork }
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{}
                VMSubnetsByVlan        = @{}
                AllVMNetworks          = @()
                AllVMSubnets           = @()
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '100'
            $result.Ambiguous | Should -BeTrue
            $result.CandidateVMSubnetNames.Count | Should -Be 2
            $result.CandidateVMSubnetNames | Should -Contain 'SubnetA'
            $result.CandidateVMSubnetNames | Should -Contain 'SubnetB'
        }

        It 'picks the first pair when multiple matches exist (deterministic)' {
            $fakeNetwork = [pscustomobject]@{ ID = 'net-1'; Name = 'Net' }
            $subnetFirst = [pscustomobject]@{ Name = 'First'; VMNetwork = [pscustomobject]@{ ID = 'net-1' } }
            $subnetSecond = [pscustomobject]@{ Name = 'Second'; VMNetwork = [pscustomobject]@{ ID = 'net-1' } }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{ '42' = @($subnetFirst, $subnetSecond) }
                VMNetworksById         = @{ 'net-1' = $fakeNetwork }
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{}
                VMSubnetsByVlan        = @{}
                AllVMNetworks          = @()
                AllVMSubnets           = @()
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '42'
            $result.VMSubnet.Name | Should -Be 'First'
        }

        It 'falls back to VMNetworksByExactName when VMNetworksById misses' {
            $fakeNetwork = [pscustomobject]@{ ID = 'net-1'; Name = 'My Network' }
            $fakeSubnet = [pscustomobject]@{
                Name          = 'Sub'
                VMNetwork     = [pscustomobject]@{ ID = 'net-1' }
                VMNetworkName = 'My Network'
            }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{ '42' = @($fakeSubnet) }
                VMNetworksById         = @{}  # missing!
                VMNetworksByExactName  = @{ 'My Network' = $fakeNetwork }
                VMNetworksByVlan       = @{}
                VMSubnetsByVlan        = @{}
                AllVMNetworks          = @()
                AllVMSubnets           = @()
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '42'
            $result | Should -Not -BeNullOrEmpty
            $result.VMNetwork.Name | Should -Be 'My Network'
            $result.ResolutionMode | Should -Be 'real-vlan-id'
        }

        It 'skips pairs with no resolvable VMNetwork (neither ID nor name match)' {
            $fakeSubnet = [pscustomobject]@{
                Name      = 'Orphan'
                VMNetwork = [pscustomobject]@{ ID = 'ghost-id' }
            }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{ '42' = @($fakeSubnet) }
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{}
                VMSubnetsByVlan        = @{}
                AllVMNetworks          = @()
                AllVMSubnets           = @()
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '42'
            # Falls through real-vlan-id since no resolvable pair; goes to name-parsed fallback
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Name-parsed VLAN fallback (VMNetworksByVlan / VMSubnetsByVlan)' {

        It 'resolves via VMNetworksByVlan and VMSubnetsByVlan' {
            $fakeNetwork = [pscustomobject]@{ ID = 'net-1'; Name = 'Network-200' }
            $fakeSubnet  = [pscustomobject]@{ Name = 'Subnet-200' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '200' = @($fakeNetwork) }
                VMSubnetsByVlan        = @{ '200' = @($fakeSubnet) }
                AllVMNetworks          = @($fakeNetwork)
                AllVMSubnets           = @($fakeSubnet)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '200'
            $result | Should -Not -BeNullOrEmpty
            $result.ResolutionMode | Should -Be 'name-parsed-vlan'
            $result.VMNetwork.Name | Should -Be 'Network-200'
            $result.VMSubnet.Name | Should -Be 'Subnet-200'
            $result.Ambiguous | Should -BeFalse
        }

        It 'returns null when only network matches but no subnet matches' {
            $fakeNetwork = [pscustomobject]@{ ID = 'net-1'; Name = 'Network-300' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '300' = @($fakeNetwork) }
                VMSubnetsByVlan        = @{}  # no subnet
                AllVMNetworks          = @($fakeNetwork)
                AllVMSubnets           = @()
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '300'
            $result | Should -BeNullOrEmpty
        }

        It 'returns null when only subnet matches but no network matches' {
            $fakeSubnet = [pscustomobject]@{ Name = 'Subnet-400' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{}  # no network
                VMSubnetsByVlan        = @{ '400' = @($fakeSubnet) }
                AllVMNetworks          = @()
                AllVMSubnets           = @($fakeSubnet)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '400'
            $result | Should -BeNullOrEmpty
        }

        It 'detects ambiguity when multiple networks match a VLAN key' {
            $net1 = [pscustomobject]@{ ID = 'net-a'; Name = 'Prod-500' }
            $net2 = [pscustomobject]@{ ID = 'net-b'; Name = 'Dev-500' }
            $sub  = [pscustomobject]@{ Name = 'Sub-500' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '500' = @($net1, $net2) }
                VMSubnetsByVlan        = @{ '500' = @($sub) }
                AllVMNetworks          = @($net1, $net2)
                AllVMSubnets           = @($sub)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '500'
            $result.Ambiguous | Should -BeTrue
            $result.CandidateVMNetworkNames | Should -Contain 'Prod-500'
            $result.CandidateVMNetworkNames | Should -Contain 'Dev-500'
        }
    }

    Context 'Wildcard fallback (like-pattern on AllVMNetworks/Subnets)' {

        It 'falls back to wildcard-like matching on names when lookup hashes miss' {
            $fakeNetwork = [pscustomobject]@{ ID = 'net-w'; Name = 'SomeNetwork999'; Description = 'desc' }
            $fakeSubnet  = [pscustomobject]@{ Name = 'SomeSubnet999'; Description = 'desc' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{}  # misses!
                VMSubnetsByVlan        = @{}  # misses!
                AllVMNetworks          = @($fakeNetwork)
                AllVMSubnets           = @($fakeSubnet)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '999'
            $result | Should -Not -BeNullOrEmpty
            $result.ResolutionMode | Should -Be 'name-parsed-vlan'
            $result.VMNetwork.Name | Should -Be 'SomeNetwork999'
            $result.VMSubnet.Name | Should -Be 'SomeSubnet999'
        }
    }

    Context 'No match' {

        It 'returns null when no resolution path finds a match' {
            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{}
                VMNetworksById         = @{}
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{}
                VMSubnetsByVlan        = @{}
                AllVMNetworks          = @()
                AllVMSubnets           = @()
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '9999'
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Real VLAN takes priority over name-parsed' {

        It 'prefers real-vlan-id mode over name-parsed-vlan when both match' {
            $fakeNetworkReal = [pscustomobject]@{ ID = 'net-real'; Name = 'Real Network' }
            $fakeSubnetReal = [pscustomobject]@{
                Name      = 'Real Subnet'
                VMNetwork = [pscustomobject]@{ ID = 'net-real' }
            }
            $fakeNetworkParsed = [pscustomobject]@{ ID = 'net-parsed'; Name = 'Parsed Network 42' }
            $fakeSubnetParsed  = [pscustomobject]@{ Name = 'Parsed Subnet 42' }

            $cache = [pscustomobject]@{
                VMSubnetsByRealVlan    = @{ '42' = @($fakeSubnetReal) }
                VMNetworksById         = @{ 'net-real' = $fakeNetworkReal }
                VMNetworksByExactName  = @{}
                VMNetworksByVlan       = @{ '42' = @($fakeNetworkParsed) }
                VMSubnetsByVlan        = @{ '42' = @($fakeSubnetParsed) }
                AllVMNetworks          = @($fakeNetworkReal, $fakeNetworkParsed)
                AllVMSubnets           = @($fakeSubnetReal, $fakeSubnetParsed)
            }

            $result = Resolve-ScvmmVlanMapping -InventoryCache $cache -VlanKey '42'
            $result.ResolutionMode | Should -Be 'real-vlan-id'
            $result.VMNetwork.Name | Should -Be 'Real Network'
            $result.VMSubnet.Name | Should -Be 'Real Subnet'
        }
    }
}
