<#
.SYNOPSIS
    Pester tests for Get-AdapterMappingPlan — pure adapter matching algorithm.
#>

BeforeAll {
    . "$PSScriptRoot/../powershell-migration/step3/Step3.NetworkMapping.ps1"
}

Describe 'Get-AdapterMappingPlan — MAC exact match' {

    It 'matches a single target to a single source by MAC' {
        $targets = @(@{ Index = 0; MacAddress = '001122334455' })
        $sources = @(@{ MacAddress = '001122334455'; VlanId = '100'; NetworkName = 'DMZ' })

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan.Count | Should -Be 1
        $plan[0].TargetIndex | Should -Be 0
        $plan[0].Resolution | Should -Be 'mac'
        $plan[0].SourceAdapter.VlanId | Should -Be '100'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'DMZ'
    }

    It 'matches multiple targets to multiple sources by MAC (order-independent)' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AABBCCDDEEFF' }
            @{ Index = 1; MacAddress = '001122334455' }
        )
        $sources = @(
            @{ MacAddress = '001122334455'; VlanId = '200'; NetworkName = 'Net1' }
            @{ MacAddress = 'AABBCCDDEEFF'; VlanId = '100'; NetworkName = 'Net2' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan.Count | Should -Be 2
        ($plan | Where-Object Resolution -eq 'mac').Count | Should -Be 2
    }

    It 'first MAC match wins when duplicate MACs exist in sources' {
        $targets = @(@{ Index = 0; MacAddress = 'AAAAAAAAAAAA' })
        $sources = @(
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '100'; NetworkName = 'First' }
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '200'; NetworkName = 'Second' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'mac'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'First'
    }

    It 'each source adapter is consumed at most once' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 1; MacAddress = 'AAAAAAAAAAAA' }
        )
        $sources = @(
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '100'; NetworkName = 'First' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        # First target gets the MAC match, second gets default
        $macCount = ($plan | Where-Object Resolution -eq 'mac').Count
        $macCount | Should -Be 1

        $defaultCount = ($plan | Where-Object Resolution -eq 'default').Count
        $defaultCount | Should -Be 1
    }

    It 'skips null MAC addresses in pass 1' {
        $targets = @(
            @{ Index = 0; MacAddress = $null }
            @{ Index = 1; MacAddress = 'AABBCCDDEEFF' }
        )
        $sources = @(
            @{ MacAddress = 'AABBCCDDEEFF'; VlanId = '100'; NetworkName = 'Net1' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'default'  # null MAC skipped
        $plan[1].Resolution | Should -Be 'mac'
    }

    It 'skips zero MAC addresses (000000000000) in pass 1' {
        $targets = @(
            @{ Index = 0; MacAddress = '000000000000' }
            @{ Index = 1; MacAddress = 'AABBCCDDEEFF' }
        )
        $sources = @(
            @{ MacAddress = 'AABBCCDDEEFF'; VlanId = '100'; NetworkName = 'Net1' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'default'  # zero MAC skipped
        $plan[1].Resolution | Should -Be 'mac'
    }

    It 'skips empty string MAC addresses' {
        $targets = @(
            @{ Index = 0; MacAddress = '' }
            @{ Index = 1; MacAddress = 'AABBCCDDEEFF' }
        )
        $sources = @(
            @{ MacAddress = 'AABBCCDDEEFF'; VlanId = '100'; NetworkName = 'Net1' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'default'
        $plan[1].Resolution | Should -Be 'mac'
    }

    It 'skips whitespace-only MAC addresses' {
        $targets = @(
            @{ Index = 0; MacAddress = '   ' }
            @{ Index = 1; MacAddress = 'AABBCCDDEEFF' }
        )
        $sources = @(
            @{ MacAddress = 'AABBCCDDEEFF'; VlanId = '100'; NetworkName = 'Net1' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'default'
        $plan[1].Resolution | Should -Be 'mac'
    }
}

Describe 'Get-AdapterMappingPlan — index fallback' {

    It 'falls back to index order when no MACs match' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 1; MacAddress = 'BBBBBBBBBBBB' }
        )
        $sources = @(
            @{ MacAddress = 'CCCCCCCCCCCC'; VlanId = '100'; NetworkName = 'Net1' }
            @{ MacAddress = 'DDDDDDDDDDDD'; VlanId = '200'; NetworkName = 'Net2' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan.Count | Should -Be 2
        $plan[0].Resolution | Should -Be 'index'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'Net1'
        $plan[1].Resolution | Should -Be 'index'
        $plan[1].SourceAdapter.NetworkName | Should -Be 'Net2'
    }

    It 'index fallback pairs first remaining target with first remaining source' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 1; MacAddress = 'BBBBBBBBBBBB' }
            @{ Index = 2; MacAddress = 'CCCCCCCCCCCC' }
        )
        $sources = @(
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '10'; NetworkName = 'Matched' }
            @{ MacAddress = 'EEEEEEEEEEEE'; VlanId = '20'; NetworkName = 'Fallback1' }
            @{ MacAddress = 'FFFFFFFFFFFF'; VlanId = '30'; NetworkName = 'Fallback2' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        # Target 0: MAC match with source 0
        $plan[0].Resolution | Should -Be 'mac'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'Matched'

        # Target 1: index fallback with source 1 (first remaining)
        $plan[1].Resolution | Should -Be 'index'
        $plan[1].SourceAdapter.NetworkName | Should -Be 'Fallback1'

        # Target 2: index fallback with source 2 (second remaining)
        $plan[2].Resolution | Should -Be 'index'
        $plan[2].SourceAdapter.NetworkName | Should -Be 'Fallback2'
    }
}

Describe 'Get-AdapterMappingPlan — default VLAN fallback' {

    It 'returns default resolution when more targets than sources' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 1; MacAddress = 'BBBBBBBBBBBB' }
            @{ Index = 2; MacAddress = 'CCCCCCCCCCCC' }
        )
        $sources = @(
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '100'; NetworkName = 'Net1' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'mac'
        $plan[1].Resolution | Should -Be 'default'
        $plan[1].SourceAdapter | Should -Be $null
        $plan[2].Resolution | Should -Be 'default'
        $plan[2].SourceAdapter | Should -Be $null
    }

    It 'returns all default when no sources provided' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 1; MacAddress = 'BBBBBBBBBBBB' }
        )
        $sources = @()

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan.Count | Should -Be 2
        ($plan | Where-Object Resolution -eq 'default').Count | Should -Be 2
    }

    It 'returns index fallback when all sources have null MACs (no MAC match possible, index pair)' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
        )
        $sources = @(
            @{ MacAddress = $null; VlanId = '100'; NetworkName = 'Net1' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'index'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'Net1'
    }

    It 'returns index fallback when source MAC is null (pairs by position)' {
        $targets = @(@{ Index = 0; MacAddress = 'AAAAAAAAAAAA' })
        $sources = @(@{ MacAddress = $null; VlanId = '100'; NetworkName = 'Net1' })

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].Resolution | Should -Be 'index'
        $plan[0].SourceAdapter.VlanId | Should -Be '100'
    }
}

Describe 'Get-AdapterMappingPlan — edge cases' {

    It 'handles empty target array' {
        $plan = Get-AdapterMappingPlan -TargetAdapters @() -SourceAdapters @(@{MacAddress='AA';VlanId='1';NetworkName='N'}) -DefaultVlan '0'
        $plan.Count | Should -Be 0
    }

    It 'handles empty source array' {
        $plan = Get-AdapterMappingPlan -TargetAdapters @(@{Index=0;MacAddress='AA'}) -SourceAdapters @() -DefaultVlan '0'
        $plan.Count | Should -Be 1
        $plan[0].Resolution | Should -Be 'default'
    }

    It 'handles both empty arrays' {
        $plan = Get-AdapterMappingPlan -TargetAdapters @() -SourceAdapters @() -DefaultVlan '0'
        $plan.Count | Should -Be 0
    }

    It 'is deterministic (same input = same output)' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 1; MacAddress = 'BBBBBBBBBBBB' }
        )
        $sources = @(
            @{ MacAddress = 'BBBBBBBBBBBB'; VlanId = '100'; NetworkName = 'Net1' }
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '200'; NetworkName = 'Net2' }
        )

        $plan1 = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'
        $plan2 = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        for ($i = 0; $i -lt $plan1.Count; $i++) {
            $plan1[$i].TargetIndex | Should -Be $plan2[$i].TargetIndex
            $plan1[$i].Resolution | Should -Be $plan2[$i].Resolution
        }
    }

    It 'preserves all source adapter properties in the output plan' {
        $targets = @(@{ Index = 0; MacAddress = 'AABBCCDDEEFF' })
        $sources = @(@{
            MacAddress  = 'AABBCCDDEEFF'
            VlanId      = '123'
            NetworkName = 'Production Network'
            ExtraField  = 'should-be-preserved'
        })

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].SourceAdapter.MacAddress | Should -Be 'AABBCCDDEEFF'
        $plan[0].SourceAdapter.VlanId | Should -Be '123'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'Production Network'
        $plan[0].SourceAdapter.ExtraField | Should -Be 'should-be-preserved'
    }

    It 'uses target Index from the object, not array position' {
        $targets = @(
            @{ Index = 5; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 2; MacAddress = 'BBBBBBBBBBBB' }
        )
        $sources = @(
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '100'; NetworkName = 'Net1' }
            @{ MacAddress = 'BBBBBBBBBBBB'; VlanId = '200'; NetworkName = 'Net2' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan[0].TargetIndex | Should -Be 5
        $plan[1].TargetIndex | Should -Be 2
    }

    It 'handles more sources than targets (extra sources unused)' {
        $targets = @(@{ Index = 0; MacAddress = 'AAAAAAAAAAAA' })
        $sources = @(
            @{ MacAddress = 'AAAAAAAAAAAA'; VlanId = '100'; NetworkName = 'Net1' }
            @{ MacAddress = 'BBBBBBBBBBBB'; VlanId = '200'; NetworkName = 'Net2' }
            @{ MacAddress = 'CCCCCCCCCCCC'; VlanId = '300'; NetworkName = 'Net3' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan.Count | Should -Be 1
        $plan[0].Resolution | Should -Be 'mac'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'Net1'
    }

    It 'mixed scenario: MAC match + index fallback + default' {
        $targets = @(
            @{ Index = 0; MacAddress = 'AAAAAAAAAAAA' }
            @{ Index = 1; MacAddress = 'BBBBBBBBBBBB' }
            @{ Index = 2; MacAddress = 'CCCCCCCCCCCC' }
            @{ Index = 3; MacAddress = 'DDDDDDDDDDDD' }
        )
        $sources = @(
            @{ MacAddress = 'CCCCCCCCCCCC'; VlanId = '30'; NetworkName = 'Net3' }
            @{ MacAddress = 'EEEEEEEEEEEE'; VlanId = '50'; NetworkName = 'Net5' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        # Target 0: MAC AAAA... no match → index fallback with source 0? No, source 0 is matched by MAC to target 2.
        # Wait let me re-think:
        # Pass 1: target 0 (AAAA) no match, target 1 (BBBB) no match, target 2 (CCCC) matches source[0] (CCCC), target 3 (DDDD) no match
        # Pass 2: remaining targets = [0, 1, 3], remaining sources = [1] (EEEE)
        # Only 1 index fallback pair: target 0 gets source[1]
        # Targets 1 and 3 get default

        $plan[0].TargetIndex | Should -Be 0
        $plan[0].Resolution | Should -Be 'index'
        $plan[0].SourceAdapter.NetworkName | Should -Be 'Net5'

        $plan[1].TargetIndex | Should -Be 1
        $plan[1].Resolution | Should -Be 'default'

        $plan[2].TargetIndex | Should -Be 2
        $plan[2].Resolution | Should -Be 'mac'
        $plan[2].SourceAdapter.NetworkName | Should -Be 'Net3'

        $plan[3].TargetIndex | Should -Be 3
        $plan[3].Resolution | Should -Be 'default'
    }
}

Describe 'Get-AdapterMappingPlan — integration readiness' {

    It 'accepts pscustomobject input (the format used by the orchestrator)' {
        $targets = @(
            [pscustomobject]@{ Index = 0; MacAddress = 'AABBCCDDEEFF' }
            [pscustomobject]@{ Index = 1; MacAddress = '112233445566' }
        )
        $sources = @(
            [pscustomobject]@{ MacAddress = '112233445566'; VlanId = '200'; NetworkName = 'DMZ' }
            [pscustomobject]@{ MacAddress = 'AABBCCDDEEFF'; VlanId = '100'; NetworkName = 'Prod' }
        )

        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources -DefaultVlan '0'

        $plan.Count | Should -Be 2
        ($plan | Where-Object Resolution -eq 'mac').Count | Should -Be 2
    }

    It 'returns objects with accessible properties (not scriptblock-scoped hashtables)' {
        $plan = Get-AdapterMappingPlan -TargetAdapters @(@{Index=0;MacAddress='AA'}) -SourceAdapters @(@{MacAddress='AA';VlanId='1';NetworkName='N'}) -DefaultVlan '0'

        $plan[0].TargetIndex | Should -BeOfType [int]
        $plan[0].Resolution | Should -BeOfType [string]
        $plan[0].PSObject.Properties.Name | Should -Contain 'TargetIndex'
        $plan[0].PSObject.Properties.Name | Should -Contain 'SourceAdapter'
        $plan[0].PSObject.Properties.Name | Should -Contain 'Resolution'
    }
}