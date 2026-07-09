Set-StrictMode -Version Latest

# All tests share the same module — dot-sourced once in BeforeAll.
# This is the recommended Pester 6 pattern for loading function definitions.

Describe 'ConvertTo-NormalizedMacAddress' {
    BeforeAll {
        $modulePath = [System.IO.Path]::GetFullPath((Join-Path $PWD.Path 'powershell-migration' 'step3' 'Step3.NetworkMapping.ps1'))
        . $modulePath
    }

    It 'returns null for null input' {
        ConvertTo-NormalizedMacAddress -Value $null | Should -BeNullOrEmpty
    }

    It 'returns null for empty string' {
        ConvertTo-NormalizedMacAddress -Value '' | Should -BeNullOrEmpty
    }

    It 'returns null for whitespace' {
        ConvertTo-NormalizedMacAddress -Value '   ' | Should -BeNullOrEmpty
    }

    It 'strips colons and uppercases' {
        ConvertTo-NormalizedMacAddress -Value '00:50:56:aa:bb:cc' | Should -Be '005056AABBCC'
    }

    It 'strips dashes and uppercases' {
        ConvertTo-NormalizedMacAddress -Value '00-50-56-AA-BB-CC' | Should -Be '005056AABBCC'
    }

    It 'strips dots and uppercases' {
        ConvertTo-NormalizedMacAddress -Value '0050.56aa.bbcc' | Should -Be '005056AABBCC'
    }

    It 'handles already-normalized MAC' {
        ConvertTo-NormalizedMacAddress -Value '005056AABBCC' | Should -Be '005056AABBCC'
    }

    It 'handles mixed weird format' {
        ConvertTo-NormalizedMacAddress -Value '0-0:5-0:5-6:A-A:B-B:C-C' | Should -Be '005056AABBCC'
    }
}

Describe 'Test-IsZeroMacAddress' {
    BeforeAll {
        $modulePath = [System.IO.Path]::GetFullPath((Join-Path $PWD.Path 'powershell-migration' 'step3' 'Step3.NetworkMapping.ps1'))
        . $modulePath
    }

    It 'returns true for all-zero MAC with colons' {
        Test-IsZeroMacAddress -Value '00:00:00:00:00:00' | Should -BeTrue
    }

    It 'returns true for all-zero MAC with dashes' {
        Test-IsZeroMacAddress -Value '00-00-00-00-00-00' | Should -BeTrue
    }

    It 'returns true for all-zero MAC without separators' {
        Test-IsZeroMacAddress -Value '000000000000' | Should -BeTrue
    }

    It 'returns false for a normal MAC' {
        Test-IsZeroMacAddress -Value '00:50:56:AA:BB:CC' | Should -BeFalse
    }

    It 'returns false for null input' {
        Test-IsZeroMacAddress -Value $null | Should -BeFalse
    }

    It 'returns false for empty string' {
        Test-IsZeroMacAddress -Value '' | Should -BeFalse
    }
}

Describe 'Convert-ToScvmmStaticMacAddress' {
    BeforeAll {
        $modulePath = [System.IO.Path]::GetFullPath((Join-Path $PWD.Path 'powershell-migration' 'step3' 'Step3.ScvmmSession.Functions.ps1'))
        . $modulePath
    }

    It 'returns null for null input' {
        Convert-ToScvmmStaticMacAddress -Value $null | Should -BeNullOrEmpty
    }

    It 'returns null for empty string' {
        Convert-ToScvmmStaticMacAddress -Value '' | Should -BeNullOrEmpty
    }

    It 'returns null for whitespace' {
        Convert-ToScvmmStaticMacAddress -Value '   ' | Should -BeNullOrEmpty
    }

    It 'returns null when input is too short (less than 12 hex chars)' {
        Convert-ToScvmmStaticMacAddress -Value '00:50:56:AA:BB' | Should -BeNullOrEmpty
    }

    It 'returns null when input is too long (more than 12 hex chars)' {
        Convert-ToScvmmStaticMacAddress -Value '00:50:56:AA:BB:CC:DD' | Should -BeNullOrEmpty
    }

    It 'returns null for non-hex input' {
        Convert-ToScvmmStaticMacAddress -Value 'not-a-mac-address' | Should -BeNullOrEmpty
    }

    It 'formats colon-separated MAC with dashes' {
        Convert-ToScvmmStaticMacAddress -Value '00:50:56:AA:BB:CC' | Should -Be '00-50-56-AA-BB-CC'
    }

    It 'formats dash-separated MAC (same output)' {
        Convert-ToScvmmStaticMacAddress -Value '00-50-56-AA-BB-CC' | Should -Be '00-50-56-AA-BB-CC'
    }

    It 'formats dot-separated MAC' {
        Convert-ToScvmmStaticMacAddress -Value '0050.56AA.BBCC' | Should -Be '00-50-56-AA-BB-CC'
    }

    It 'formats already-normalized 12-char hex to dashed' {
        Convert-ToScvmmStaticMacAddress -Value '005056AABBCC' | Should -Be '00-50-56-AA-BB-CC'
    }

    It 'uppercases lowercase input' {
        Convert-ToScvmmStaticMacAddress -Value '00:50:56:aa:bb:cc' | Should -Be '00-50-56-AA-BB-CC'
    }

    It 'handles mixed weird separators' {
        Convert-ToScvmmStaticMacAddress -Value '0-0:5-0:5-6:A-A:B-B:C-C' | Should -Be '00-50-56-AA-BB-CC'
    }

    It 'handles all-zero MAC' {
        Convert-ToScvmmStaticMacAddress -Value '00:00:00:00:00:00' | Should -Be '00-00-00-00-00-00'
    }
}

Describe 'Get-AdapterMappingPlan' {
    BeforeAll {
        $modulePath = [System.IO.Path]::GetFullPath((Join-Path $PWD.Path 'powershell-migration' 'step3' 'Step3.NetworkMapping.ps1'))
        . $modulePath
    }

    Context 'Pass 1: Exact MAC address match' {

        It 'matches a single adapter by exact MAC' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-1816'; VlanId = '1816' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 1
            $plan[0].Resolution | Should -Be 'mac'
            $plan[0].SourceIndex | Should -Be 0
            $plan[0].SourceVlanId | Should -Be '1816'
            $plan[0].TargetIndex | Should -Be 0
            $plan[0].SourceNetworkName | Should -Be 'dvPG-1816'
        }

        It 'matches MAC with different formatting (dash vs colon)' {
            $targets = @(
                @{ Index = 0; MacAddress = '00-50-56-AA-BB-CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:aa:bb:cc'; NetworkName = 'dvPG-1816'; VlanId = '1816' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].Resolution | Should -Be 'mac'
        }

        It 'matches MAC case-insensitively' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:aa:bb:cc'; NetworkName = 'dvPG-1816'; VlanId = '1816' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].Resolution | Should -Be 'mac'
        }

        It 'matches multiple adapters by MAC independently' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:DD:EE:FF' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:DD:EE:FF'; NetworkName = 'dvPG-200'; VlanId = '200' },
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-100'; VlanId = '100' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 2

            $t0 = $plan | Where-Object { $_.TargetIndex -eq 0 }
            $t0.Resolution | Should -Be 'mac'
            $t0.SourceIndex | Should -Be 1

            $t1 = $plan | Where-Object { $_.TargetIndex -eq 1 }
            $t1.Resolution | Should -Be 'mac'
            $t1.SourceIndex | Should -Be 0
        }

        It 'does NOT reuse a source MAC across multiple targets' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:AA:BB:CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-100'; VlanId = '100' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 2
            $t0 = $plan | Where-Object { $_.TargetIndex -eq 0 }
            $t0.Resolution | Should -Be 'mac'
            $t1 = $plan | Where-Object { $_.TargetIndex -eq 1 }
            $t1.Resolution | Should -Not -Be 'mac'
        }
    }

    Context 'Zero MAC handling' {

        It 'skips MAC match for all-zero target MAC' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:00:00:00:00:00' }
            )
            $sources = @(
                @{ MacAddress = '00:00:00:00:00:00'; NetworkName = 'none'; VlanId = '0' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].Resolution | Should -Not -Be 'mac'
            $plan[0].IsZeroMac | Should -BeTrue
        }

        It 'skips MAC match for target with empty MAC' {
            $targets = @(
                @{ Index = 0; MacAddress = '' }
            )
            $sources = @(
                @{ MacAddress = ''; NetworkName = 'none'; VlanId = '0' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].Resolution | Should -Not -Be 'mac'
        }

        It 'skips MAC match for target with null MAC' {
            $targets = @(
                @{ Index = 0; MacAddress = $null }
            )
            $sources = @(
                @{ MacAddress = $null; NetworkName = 'none'; VlanId = '0' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].Resolution | Should -Not -Be 'mac'
        }
    }

    Context 'Pass 2: Index-order fallback' {

        It 'falls back to index order when no MAC matches' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:11:22:33' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:XX:YY:ZZ'; NetworkName = 'dvPG-100'; VlanId = '100' },
                @{ MacAddress = '00:50:56:UU:VV:WW'; NetworkName = 'dvPG-200'; VlanId = '200' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 2

            $t0 = $plan | Where-Object { $_.TargetIndex -eq 0 }
            $t0.Resolution | Should -Be 'index'
            $t0.SourceIndex | Should -Be 0

            $t1 = $plan | Where-Object { $_.TargetIndex -eq 1 }
            $t1.Resolution | Should -Be 'index'
            $t1.SourceIndex | Should -Be 1
        }

        It 'pairs remaining unmatched adapters by order after some MAC matches' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:11:22:33' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-mac'; VlanId = '100' },
                @{ MacAddress = '00:50:56:DD:EE:FF'; NetworkName = 'dvPG-idx'; VlanId = '200' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources

            $t0 = $plan | Where-Object { $_.TargetIndex -eq 0 }
            $t0.Resolution | Should -Be 'mac'
            $t0.SourceIndex | Should -Be 0

            $t1 = $plan | Where-Object { $_.TargetIndex -eq 1 }
            $t1.Resolution | Should -Be 'index'
            $t1.SourceIndex | Should -Be 1
        }

        It 'handles more targets than sources (remaining targets get default)' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:11:22:33' },
                @{ Index = 2; MacAddress = '00:50:56:44:55:66' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-100'; VlanId = '100' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 3

            $t0 = $plan | Where-Object { $_.TargetIndex -eq 0 }
            $t0.Resolution | Should -Be 'mac'

            $t1 = $plan | Where-Object { $_.TargetIndex -eq 1 }
            $t1.Resolution | Should -Be 'default'

            $t2 = $plan | Where-Object { $_.TargetIndex -eq 2 }
            $t2.Resolution | Should -Be 'default'
        }

        It 'handles more sources than targets (extra sources are simply unused)' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-match'; VlanId = '100' },
                @{ MacAddress = '00:50:56:DD:EE:FF'; NetworkName = 'dvPG-extra'; VlanId = '200' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 1
            $plan[0].Resolution | Should -Be 'mac'
            $plan[0].SourceIndex | Should -Be 0
        }
    }

    Context 'Pass 3: Default VLAN fallback' {

        It 'assigns default for a target with no source adapter at all' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters @()
            $plan.Count | Should -Be 1
            $plan[0].Resolution | Should -Be 'default'
            $plan[0].SourceIndex | Should -BeNullOrEmpty
            $plan[0].SourceMacAddress | Should -BeNullOrEmpty
        }

        It 'assigns default for targets with no MAC and no remaining source by index' {
            $targets = @(
                @{ Index = 0; MacAddress = '' },
                @{ Index = 1; MacAddress = '00:00:00:00:00:00' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-100'; VlanId = '100' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 2

            $t0 = $plan | Where-Object { $_.TargetIndex -eq 0 }
            $t0.Resolution | Should -Be 'index'

            $t1 = $plan | Where-Object { $_.TargetIndex -eq 1 }
            $t1.Resolution | Should -Be 'default'
        }
    }

    Context 'Mixed resolution types' {

        It 'handles a mix of mac, index, and default in one call' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:11:22:33' },
                @{ Index = 2; MacAddress = '00:50:56:44:55:66' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-mac'; VlanId = '100' },
                @{ MacAddress = '00:50:56:XX:YY:ZZ'; NetworkName = 'dvPG-idx'; VlanId = '200' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan.Count | Should -Be 3

            $resolutions = $plan | ForEach-Object { $_.Resolution } | Sort-Object
            ($resolutions -join ',') | Should -Be 'default,index,mac'
        }
    }

    Context 'Edge cases' {

        It 'handles empty target array via empty collection' {
            $plan = Get-AdapterMappingPlan -TargetAdapters @() -SourceAdapters @(@{ MacAddress = '00:50:56:AA:BB:CC' })
            $plan.Count | Should -Be 0
        }

        It 'returns default-only when no source adapters but targets present' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:DD:EE:FF' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters @()
            $plan.Count | Should -Be 2
            ($plan | Where-Object { $_.Resolution -eq 'default' }).Count | Should -Be 2
        }

        It 'preserves original Index from target adapter object' {
            $targets = @(
                @{ Index = 5; MacAddress = '00:50:56:AA:BB:CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG'; VlanId = '100' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].TargetIndex | Should -Be 5
        }

        It 'uses positional index when Index property is missing' {
            $targets = @(
                @{ MacAddress = '00:50:56:AA:BB:CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG'; VlanId = '100' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].TargetIndex | Should -Be 0
        }

        It 'carries SourceNetworkName and SourceVlanId through for reference' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-LAN_1816'; VlanId = '1816' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].SourceNetworkName | Should -Be 'dvPG-LAN_1816'
            $plan[0].SourceVlanId | Should -Be '1816'
        }

        It 'handles adapter objects with additional properties gracefully' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC'; ExtraField = 'ignored' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG'; VlanId = '100'; Extra = 'also ignored' }
            )
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].Resolution | Should -Be 'mac'
            $plan[0].TargetIndex | Should -Be 0
        }

        It 'deterministic: same inputs always produce same output' {
            $targets = @(
                @{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' },
                @{ Index = 1; MacAddress = '00:50:56:11:22:33' },
                @{ Index = 2; MacAddress = '00:50:56:44:55:66' }
            )
            $sources = @(
                @{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'a'; VlanId = '1' },
                @{ MacAddress = '00:50:56:XX:YY:ZZ'; NetworkName = 'b'; VlanId = '2' }
            )
            $plan1 = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan2 = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources

            for ($i = 0; $i -lt $plan1.Count; $i++) {
                $plan1[$i].TargetIndex | Should -Be $plan2[$i].TargetIndex
                $plan1[$i].SourceIndex | Should -Be $plan2[$i].SourceIndex
                $plan1[$i].Resolution | Should -Be $plan2[$i].Resolution
            }
        }
    }

    Context 'NetworkName scenarios (carried through for caller use)' {

        It 'carries null NetworkName when source has none' {
            $targets = @(@{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' })
            $sources = @(@{ MacAddress = '00:50:56:AA:BB:CC'; VlanId = '100' })
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].SourceNetworkName | Should -BeNullOrEmpty
        }

        It 'carries null SourceVlanId when source has none' {
            $targets = @(@{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' })
            $sources = @(@{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG' })
            $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
            $plan[0].SourceVlanId | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-AdapterMappingPlan — PSObject input compatibility' {
    BeforeAll {
        $modulePath = [System.IO.Path]::GetFullPath((Join-Path $PWD.Path 'powershell-migration' 'step3' 'Step3.NetworkMapping.ps1'))
        . $modulePath
    }

    It 'accepts [pscustomobject] target adapters' {
        $targets = @(
            [pscustomobject]@{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' }
        )
        $sources = @(
            [pscustomobject]@{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-1816'; VlanId = '1816' }
        )
        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
        $plan.Count | Should -Be 1
        $plan[0].Resolution | Should -Be 'mac'
    }

    It 'accepts [pscustomobject] source adapters with VlanId as integer' {
        $targets = @(
            [pscustomobject]@{ Index = 0; MacAddress = '00:50:56:AA:BB:CC' }
        )
        $sources = @(
            [pscustomobject]@{ MacAddress = '00:50:56:AA:BB:CC'; NetworkName = 'dvPG-1816'; VlanId = 1816 }
        )
        $plan = Get-AdapterMappingPlan -TargetAdapters $targets -SourceAdapters $sources
        $plan[0].SourceVlanId | Should -Be '1816'
    }
}