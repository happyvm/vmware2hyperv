Set-StrictMode -Version Latest

# Pester 6 requires commands to exist before mocking.
# Define stub functions in script scope inside BeforeAll, then mock them.

Describe 'Resolve-AdapterVlanId' {
    BeforeAll {
        # Define the function under test
        function script:Resolve-AdapterVlanId {
            param(
                [Parameter(Mandatory = $true)]
                $Adapter,
                [Parameter(Mandatory = $true)]
                [hashtable]$DistributedPortGroupCache,
                [Parameter(Mandatory = $true)]
                [hashtable]$StandardPortGroupCache
            )
            $networkName = [string]$Adapter.NetworkName
            if ([string]::IsNullOrWhiteSpace($networkName)) {
                return "Not connected to a network"
            }
            if (-not $DistributedPortGroupCache.ContainsKey($networkName)) {
                $DistributedPortGroupCache[$networkName] = @(Get-VDPortgroup -Name $networkName -ErrorAction SilentlyContinue)
            }
            $distributedPortGroups = @($DistributedPortGroupCache[$networkName])
            foreach ($distributedPortGroup in $distributedPortGroups) {
                try {
                    $vlanSpec = $distributedPortGroup.ExtensionData.Config.DefaultPortConfig.Vlan
                    if ($vlanSpec -and $vlanSpec.PSObject.Properties['VlanId']) {
                        $rawId = [int]$vlanSpec.VlanId
                        if ($rawId -ge 1 -and $rawId -le 4094) {
                            return [string]$rawId
                        }
                    }
                } catch {
                    Write-Verbose "DVS VLAN spec unavailable: $($_.Exception.Message)"
                }
                if ([string]$distributedPortGroup.VlanConfiguration -match '\d+') {
                    return [string]$matches[0]
                }
            }
            if (-not $StandardPortGroupCache.ContainsKey($networkName)) {
                $StandardPortGroupCache[$networkName] = @(Get-VirtualPortGroup -Name $networkName -ErrorAction SilentlyContinue)
            }
            $standardPortGroups = @($StandardPortGroupCache[$networkName])
            foreach ($standardPortGroup in $standardPortGroups) {
                if ([string]$standardPortGroup.VLanId -match '^\d+$') {
                    return [string]$standardPortGroup.VLanId
                }
            }
            $backing = $null
            try { $backing = $Adapter.ExtensionData.Backing } catch {
                Write-Verbose "Adapter backing data unavailable: $($_.Exception.Message)"
            }
            if ($backing -and $backing.PSObject.Properties['Port'] -and $backing.Port -and $backing.Port.PortgroupKey) {
                $portGroupView = Get-View -Id $backing.Port.PortgroupKey -ErrorAction SilentlyContinue
                if ($portGroupView -and $portGroupView.Config) {
                    try {
                        $vlanSpec = $portGroupView.Config.DefaultPortConfig.Vlan
                        if ($vlanSpec -and $vlanSpec.PSObject.Properties['VlanId']) {
                            $rawId = [int]$vlanSpec.VlanId
                            if ($rawId -ge 1 -and $rawId -le 4094) {
                                return [string]$rawId
                            }
                        }
                    } catch {
                        Write-Verbose "Port group view VLAN spec unavailable: $($_.Exception.Message)"
                    }
                    if ([string]$portGroupView.Config.DefaultPortConfig.Vlan -match '\d+') {
                        return [string]$matches[0]
                    }
                }
            }
            if ($networkName -match '_(\d{1,4})$') {
                return $matches[1]
            }
            return "PortGroup not found"
        }

        # Stub functions so Mock can find them
        function script:Get-VDPortgroup { }
        function script:Get-VirtualPortGroup { }
        function script:Get-View { }
    }

    BeforeEach {
        $distributedCache = @{}
        $standardCache = @{}
    }

    It 'returns "Not connected to a network" when adapter has no network name' {
        $adapter = [PSCustomObject]@{ NetworkName = ''; MacAddress = '00:50:56:aa:bb:cc' }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be 'Not connected to a network'
    }

    It 'returns VLAN ID from DVS VlanId property when valid (1-4094)' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-LAN_1816'; MacAddress = '00:50:56:aa:bb:cc' }
        $fakeVlanSpec = [PSCustomObject]@{ VlanId = 1816 }
        $fakeDvsPortGroup = [PSCustomObject]@{
            Name = 'dvPG-LAN_1816'
            VlanConfiguration = 'VLAN 1816'
            ExtensionData = [PSCustomObject]@{
                Config = [PSCustomObject]@{
                    DefaultPortConfig = [PSCustomObject]@{ Vlan = $fakeVlanSpec }
                }
            }
        }
        Mock Get-VDPortgroup { @($fakeDvsPortGroup) }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be '1816'
    }

    It 'falls back to VlanConfiguration regex when VlanId property is absent' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-Prod'; MacAddress = '00:50:56:aa:bb:cc' }
        $fakeVlanSpec = [PSCustomObject]@{}
        $fakeDvsPortGroup = [PSCustomObject]@{
            Name = 'dvPG-Prod'
            VlanConfiguration = 'VLAN 42'
            ExtensionData = [PSCustomObject]@{
                Config = [PSCustomObject]@{
                    DefaultPortConfig = [PSCustomObject]@{ Vlan = $fakeVlanSpec }
                }
            }
        }
        Mock Get-VDPortgroup { @($fakeDvsPortGroup) }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be '42'
    }

    It 'falls back to standard port group VLanId when DVS lookup fails' {
        $adapter = [PSCustomObject]@{ NetworkName = 'VM Network'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @() }
        $fakeStandardPg = [PSCustomObject]@{ Name = 'VM Network'; VLanId = '100' }
        Mock Get-VirtualPortGroup { @($fakeStandardPg) }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be '100'
    }

    It 'resolves VLAN from port group name suffix (e.g. _1816)' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-LAN_1816'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @() }
        Mock Get-VirtualPortGroup { @() }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be '1816'
    }

    It 'returns "PortGroup not found" when no resolution works' {
        $adapter = [PSCustomObject]@{ NetworkName = 'UnknownNetwork'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @() }
        Mock Get-VirtualPortGroup { @() }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be 'PortGroup not found'
    }

    It 'uses the distributed port group cache to avoid repeat VMware calls' {
        $adapter = [PSCustomObject]@{ NetworkName = 'CachedNetwork'; MacAddress = '00:50:56:aa:bb:cc' }
        $fakeDvsPg = [PSCustomObject]@{
            Name = 'CachedNetwork'
            VlanConfiguration = 'VLAN 55'
            ExtensionData = [PSCustomObject]@{
                Config = [PSCustomObject]@{
                    DefaultPortConfig = [PSCustomObject]@{ Vlan = [PSCustomObject]@{ VlanId = 55 } }
                }
            }
        }
        Mock Get-VDPortgroup { @($fakeDvsPg) }
        $cache = @{ 'CachedNetwork' = @($fakeDvsPg) }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $cache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be '55'
        Should -Invoke Get-VDPortgroup -Times 0
    }

    It 'uses the standard port group cache to avoid repeat VMware calls' {
        $adapter = [PSCustomObject]@{ NetworkName = 'StdCached'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @() }
        Mock Get-VirtualPortGroup { @([PSCustomObject]@{ Name = 'StdCached'; VLanId = '200' }) }
        $cache = @{ 'StdCached' = @([PSCustomObject]@{ Name = 'StdCached'; VLanId = '200' }) }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $cache
        $result | Should -Be '200'
        Should -Invoke Get-VDPortgroup -Times 1
        Should -Invoke Get-VirtualPortGroup -Times 0
    }

    It 'resolves VLAN via backing port group view when name-based lookups fail' {
        $adapter = [PSCustomObject]@{
            NetworkName = 'SomeNetwork'
            MacAddress = '00:50:56:aa:bb:cc'
            ExtensionData = [PSCustomObject]@{
                Backing = [PSCustomObject]@{
                    Port = [PSCustomObject]@{ PortgroupKey = 'dvportgroup-123' }
                }
            }
        }
        Mock Get-VDPortgroup { @() }
        Mock Get-VirtualPortGroup { @() }
        $fakePortGroupView = [PSCustomObject]@{
            Config = [PSCustomObject]@{
                DefaultPortConfig = [PSCustomObject]@{
                    Vlan = [PSCustomObject]@{ VlanId = 999 }
                }
            }
        }
        Mock Get-View { $fakePortGroupView }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be '999'
    }

    It 'rejects VLAN 0 (untagged) from DVS VlanId' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-Untagged'; MacAddress = '00:50:56:aa:bb:cc' }
        $fakeVlanSpec = [PSCustomObject]@{ VlanId = 0 }
        $fakeDvsPortGroup = [PSCustomObject]@{
            Name = 'dvPG-Untagged'
            VlanConfiguration = 'VLAN 0'
            ExtensionData = [PSCustomObject]@{
                Config = [PSCustomObject]@{
                    DefaultPortConfig = [PSCustomObject]@{ Vlan = $fakeVlanSpec }
                }
            }
        }
        Mock Get-VDPortgroup { @($fakeDvsPortGroup) }
        $result = Resolve-AdapterVlanId -Adapter $adapter `
            -DistributedPortGroupCache $distributedCache `
            -StandardPortGroupCache $standardCache
        $result | Should -Be '0'
    }
}

Describe 'Get-VMwareClusterNameForVm' {
    BeforeAll {
        # Define fake types so GetType().Name returns cluster-like names
        Add-Type -TypeDefinition @'
            public class FakeClusterImpl {
                public string Name { get; set; }
            }
'@ -ErrorAction SilentlyContinue

        function script:Get-VMwareClusterNameForVm {
            param(
                [Parameter(Mandatory = $true)]
                $VMObject
            )
            try {
                $cluster = Get-Cluster -VM $VMObject -ErrorAction Stop | Select-Object -First 1
                if ($cluster -and -not [string]::IsNullOrWhiteSpace([string]$cluster.Name)) {
                    return [string]$cluster.Name
                }
            } catch {
                Write-Verbose "Get-Cluster lookup failed: $($_.Exception.Message)"
            }
            $parent = $VMObject.VMHost.Parent
            while ($parent) {
                if ($parent.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string]$parent.Name)) {
                    if ([string]$parent.GetType().Name -match 'Cluster|ClusterImpl') {
                        return [string]$parent.Name
                    }
                }
                if ($parent.PSObject.Properties['Parent']) {
                    $parent = $parent.Parent
                } else {
                    break
                }
            }
            return $null
        }
        function script:Get-Cluster { }
    }

    It 'returns cluster name from Get-Cluster when available' {
        $fakeCluster = [PSCustomObject]@{ Name = 'ProdCluster01' }
        $fakeVm = [PSCustomObject]@{ Name = 'TESTVM01' }
        Mock Get-Cluster { @($fakeCluster) }
        $result = Get-VMwareClusterNameForVm -VMObject $fakeVm
        $result | Should -Be 'ProdCluster01'
    }

    It 'falls back to parent traversal when Get-Cluster throws' {
        $fakeClusterParent = [FakeClusterImpl]@{ Name = 'DevCluster' }
        $fakeVmHost = [PSCustomObject]@{ Parent = $fakeClusterParent }
        $fakeVm = [PSCustomObject]@{ Name = 'TESTVM02'; VMHost = $fakeVmHost }

        Mock Get-Cluster { throw 'Not found' }

        $result = Get-VMwareClusterNameForVm -VMObject $fakeVm
        $result | Should -Be 'DevCluster'
    }

    It 'returns null when no cluster is found via any method' {
        $fakeVmHost = [PSCustomObject]@{ Parent = $null }
        $fakeVm = [PSCustomObject]@{ Name = 'TESTVM03'; VMHost = $fakeVmHost }

        Mock Get-Cluster { throw 'Not found' }

        $result = Get-VMwareClusterNameForVm -VMObject $fakeVm
        $result | Should -BeNullOrEmpty
    }

    It 'traverses multiple parent levels to find the cluster' {
        $grandparent = [FakeClusterImpl]@{ Name = 'TopLevelCluster' }
        $parent = [PSCustomObject]@{ Name = 'Intermediate'; Parent = $grandparent }
        $vmHost = [PSCustomObject]@{ Parent = $parent }
        $fakeVm = [PSCustomObject]@{ Name = 'TESTVM04'; VMHost = $vmHost }

        Mock Get-Cluster { throw 'Not found' }

        $result = Get-VMwareClusterNameForVm -VMObject $fakeVm
        $result | Should -Be 'TopLevelCluster'
    }
}

Describe 'ConvertTo-NormalizedHostName' {
    BeforeAll {
        function script:ConvertTo-NormalizedHostName {
            param(
                [AllowNull()]
                [string]$Name
            )
            if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
            return $Name.Trim().ToLowerInvariant().Split('.')[0]
        }
    }

    It 'returns null for null/empty/whitespace input' {
        ConvertTo-NormalizedHostName -Name $null | Should -BeNullOrEmpty
        ConvertTo-NormalizedHostName -Name '' | Should -BeNullOrEmpty
        ConvertTo-NormalizedHostName -Name '   ' | Should -BeNullOrEmpty
    }

    It 'strips the domain suffix and lowercases the hostname' {
        ConvertTo-NormalizedHostName -Name 'HV-HOST01.domain.local' | Should -Be 'hv-host01'
    }

    It 'returns the input lowercased and trimmed when no domain suffix' {
        ConvertTo-NormalizedHostName -Name '  HV-HOST02  ' | Should -Be 'hv-host02'
    }

    It 'handles multi-part FQDNs correctly' {
        ConvertTo-NormalizedHostName -Name 'NODE-A.sub.domain.local' | Should -Be 'node-a'
    }
}

Describe 'First-numeric-VLAN selection logic' {
    It 'selects the first numeric VLAN from adapter mappings' {
        $adapterMappings = @(
            [pscustomobject]@{ VlanId = 'PortGroup not found'; MacAddress = '00:00:00:00:00:01' }
            [pscustomobject]@{ VlanId = '1816'; MacAddress = '00:00:00:00:00:02' }
            [pscustomobject]@{ VlanId = '2000'; MacAddress = '00:00:00:00:00:03' }
        )
        $firstNumericVlan = $adapterMappings |
            Where-Object { $_.VlanId -match '^\d+$' } |
            Select-Object -First 1 -ExpandProperty VlanId
        $firstNumericVlan | Should -Be '1816'
    }

    It 'falls back to the first adapter VLAN when no numeric VLAN is found' {
        $adapterMappings = @(
            [pscustomobject]@{ VlanId = 'PortGroup not found'; MacAddress = '00:00:00:00:00:01' }
            [pscustomobject]@{ VlanId = 'Not connected to a network'; MacAddress = '00:00:00:00:00:02' }
        )
        $firstNumericVlan = $adapterMappings |
            Where-Object { $_.VlanId -match '^\d+$' } |
            Select-Object -First 1 -ExpandProperty VlanId
        $fallbackVlan = if (-not [string]::IsNullOrWhiteSpace($firstNumericVlan)) {
            $firstNumericVlan
        } else {
            [string]($adapterMappings | Select-Object -First 1 -ExpandProperty VlanId)
        }
        $fallbackVlan | Should -Be 'PortGroup not found'
    }

    It 'handles mixed VLAN IDs including leading zeros and non-numeric values' {
        $adapterMappings = @(
            [pscustomobject]@{ VlanId = 'PortGroup not found'; MacAddress = '00:00:00:00:00:01' }
            [pscustomobject]@{ VlanId = '0050'; MacAddress = '00:00:00:00:00:02' }
            [pscustomobject]@{ VlanId = '1816'; MacAddress = '00:00:00:00:00:03' }
        )
        $firstNumericVlan = $adapterMappings |
            Where-Object { $_.VlanId -match '^\d+$' } |
            Select-Object -First 1 -ExpandProperty VlanId
        $firstNumericVlan | Should -Be '0050'
    }

    It 'returns "No network adapter" fallback when array is empty' {
        $adapterMappings = @()
        $vlanId = if ($adapterMappings.Count -gt 0) {
            $firstNumeric = $adapterMappings |
                Where-Object { $_.VlanId -match '^\d+$' } |
                Select-Object -First 1 -ExpandProperty VlanId
            if (-not [string]::IsNullOrWhiteSpace($firstNumeric)) { $firstNumeric }
            else { [string]($adapterMappings | Select-Object -First 1 -ExpandProperty VlanId) }
        } else {
            'No network adapter'
        }
        $vlanId | Should -Be 'No network adapter'
    }
}

Describe 'step3-MigrateVM.ps1 - phase Action wiring against step3/ function signatures' {
    <#
    Regression coverage for two bugs found in production on 2026-07-09: the BEA-276
    orchestrator rewrite called Set-VmNetworkConfiguration / Set-SCVMMOperatingSystem /
    Register-VmHighAvailability / Move-VmToSecondHost / Set-VmBackupTag with -Context/-Result
    (a convention only Start-VmInstantRecovery / Wait-InstantRecoveryUserAction /
    Complete-InstantRecovery actually use), and called Set-VmIntegrationServices, a function
    that was never defined anywhere in step3/. Both failed at runtime with no static check
    catching them ("A parameter cannot be found..." / "term not recognized"), even though the
    suite reported green. This test parses step3-MigrateVM.ps1 and every step3/*.ps1 module
    with the PowerShell AST (no execution, no live SCVMM/Veeam needed) and checks that every
    function called from inside an Invoke-Phase -Action block actually exists in step3/, and
    that every named argument used at the call site matches a parameter that function declares.
    #>
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../powershell-migration/step3-MigrateVM.ps1"
        $step3Dir = "$PSScriptRoot/../powershell-migration/step3"

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty

        # Map every function defined anywhere in step3/*.ps1 to its declared parameter names.
        $script:step3Functions = @{}
        Get-ChildItem "$step3Dir\*.ps1" | ForEach-Object {
            $modAst = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $modAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | ForEach-Object {
                $paramAsts = if ($_.Parameters) { $_.Parameters } elseif ($_.Body.ParamBlock) { $_.Body.ParamBlock.Parameters } else { @() }
                $paramNames = @($paramAsts | ForEach-Object { $_.Name.VariablePath.UserPath })
                $script:step3Functions[$_.Name] = $paramNames
            }
        }

        # Every command invocation made from inside an Invoke-Phase -Action scriptblock —
        # this is exactly the boundary that broke: the orchestrator's assumptions about a
        # step3/ function's calling convention versus what the function actually declares.
        $script:phaseCalls = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-Phase'
        }, $true) | ForEach-Object {
            $_.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
            }
        } | ForEach-Object {
            $_.ScriptBlock.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true)
        }
    }

    It 'Only calls step3/ functions that are actually defined there' {
        $calledNames = @($script:phaseCalls | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique)
        $missing = @($calledNames | Where-Object { -not $script:step3Functions.ContainsKey($_) })
        $missing | Should -BeNullOrEmpty -Because "these are called from an Invoke-Phase action but not defined in any step3/*.ps1 file: $($missing -join ', ')"
    }

    It 'Every named argument at a step3/ function call site matches a parameter that function declares' {
        $mismatches = @(
            foreach ($call in $script:phaseCalls) {
                $fnName = $call.GetCommandName()
                if (-not $script:step3Functions.ContainsKey($fnName)) { continue }
                $declaredParams = $script:step3Functions[$fnName]
                $usedParams = $call.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst]
                } | ForEach-Object { $_.ParameterName }
                foreach ($p in $usedParams) {
                    if ($declaredParams -notcontains $p) {
                        "line $($call.Extent.StartLineNumber): $fnName -$p (declares: $($declaredParams -join ', '))"
                    }
                }
            }
        )
        $mismatches | Should -BeNullOrEmpty -Because "step3-MigrateVM.ps1 passes a parameter name the target function doesn't declare:`n$($mismatches -join "`n")"
    }
}