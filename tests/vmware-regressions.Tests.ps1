<#
.SYNOPSIS
    Regression tests for the VMware/PowerCLI bugs fixed in the
    claude/scvmm-hyperv-bugs pass.
.DESCRIPTION
    Behavioural tests wherever the logic is reachable without a live vCenter;
    source assertions for the rest, as in tests/step3-MigrateVM.Tests.ps1.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MigrationRoot = Join-Path $script:RepoRoot 'powershell-migration'

    . (Join-Path $script:MigrationRoot 'lib.ps1')

    function script:Get-MigrationSource {
        param([Parameter(Mandatory = $true)][string]$RelativePath)
        Get-Content -Path (Join-Path $script:MigrationRoot $RelativePath) -Raw
    }

    # PowerCLI never hands back the bare interface name: Get-TagAssignment entities
    # are concrete impl classes whose names carry a suffix (and a prefix on
    # vSphere 6.5+). These fakes reproduce the real runtime type names.
    Add-Type -TypeDefinition @'
        public class UniversalVirtualMachineImpl { public string Id { get; set; } }
        public class VirtualMachineImpl { public string Id { get; set; } }
        public class TemplateImpl { public string Id { get; set; } }
        public class DatastoreImpl { public string Id { get; set; } }
'@ -ErrorAction SilentlyContinue
}

Describe 'Test-VmwareVirtualMachineEntity' {

    # The three tag-driven code paths (step1 cleanup, step2 email, step6 delete)
    # all filtered on GetType().Name -eq 'VirtualMachine', which is never true.
    It 'accepts the PowerCLI 12/13 universal VM impl type' {
        $entity = [UniversalVirtualMachineImpl]@{ Id = 'VirtualMachine-vm-1234' }
        Test-VmwareVirtualMachineEntity -Entity $entity | Should -BeTrue
    }

    It 'accepts the classic VM impl type' {
        $entity = [VirtualMachineImpl]@{ Id = 'VirtualMachine-vm-42' }
        Test-VmwareVirtualMachineEntity -Entity $entity | Should -BeTrue
    }

    It 'accepts an entity recognisable only by its managed object Id' {
        $entity = [TemplateImpl]@{ Id = 'VirtualMachine-vm-7' }
        Test-VmwareVirtualMachineEntity -Entity $entity | Should -BeTrue
    }

    It 'rejects a non-VM entity' {
        $entity = [DatastoreImpl]@{ Id = 'Datastore-datastore-9' }
        Test-VmwareVirtualMachineEntity -Entity $entity | Should -BeFalse
    }

    It 'rejects a null entity' {
        Test-VmwareVirtualMachineEntity -Entity $null | Should -BeFalse
    }

    It 'still accepts an entity whose type is literally VirtualMachine' {
        $entity = [pscustomobject]@{ Id = 'VirtualMachine-vm-1' }
        $entity.PSObject.TypeNames.Insert(0, 'VirtualMachine')
        # PSObject type names do not change GetType(), so this one is matched on Id.
        Test-VmwareVirtualMachineEntity -Entity $entity | Should -BeTrue
    }

    It 'is used by every tag-driven VMware code path' {
        foreach ($relativePath in @(
            'step1-TagResources_CreateVeeamJob.ps1',
            'step2-ShutdownVM_StartBackupVeeam.ps1',
            'step6-CleanupVmware.ps1'
        )) {
            $source = Get-MigrationSource -RelativePath $relativePath
            $source | Should -Match 'Test-VmwareVirtualMachineEntity -Entity \$_\.Entity' -Because "$relativePath filters tag assignments"
            $source | Should -Not -Match "GetType\(\)\.Name -eq 'VirtualMachine'" -Because "$relativePath must not compare against the interface name"
        }
    }
}

Describe 'Resolve-AdapterVlanId VLAN sanity' {

    BeforeAll {
        function script:Get-VDPortgroup { }
        function script:Get-VirtualPortGroup { }
        function script:Get-View { }
    }

    BeforeEach {
        $script:DistributedCache = @{}
        $script:StandardCache = @{}
    }

    function script:Invoke-VlanResolution {
        param($Adapter)
        Resolve-AdapterVlanId -Adapter $Adapter `
            -DistributedPortGroupCache $script:DistributedCache `
            -StandardPortGroupCache $script:StandardCache
    }

    # VLAN 0 is untagged. Get-ScvmmInventoryCache drops it as a mapping key, so a
    # '0' reaching step3 falls through to name matching and attaches the NIC to
    # any VM network whose name happens to contain a zero.
    It 'never returns VLAN 0 from the VlanConfiguration string' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-Untagged'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @([PSCustomObject]@{
            Name = 'dvPG-Untagged'
            VlanConfiguration = 'VLAN 0'
            ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{
                DefaultPortConfig = [PSCustomObject]@{ Vlan = [PSCustomObject]@{ VlanId = 0 } } } }
        }) }
        Mock Get-VirtualPortGroup { @() }
        Invoke-VlanResolution -Adapter $adapter | Should -Be 'PortGroup not found'
    }

    It 'never scrapes a VLAN out of a trunk range' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-Trunk'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @([PSCustomObject]@{
            Name = 'dvPG-Trunk'
            VlanConfiguration = 'Trunk (0-4094)'
            ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{
                DefaultPortConfig = [PSCustomObject]@{ Vlan = [PSCustomObject]@{} } } }
        }) }
        Mock Get-VirtualPortGroup { @() }
        Invoke-VlanResolution -Adapter $adapter | Should -Be 'PortGroup not found'
    }

    It 'rejects the 4095 "all VLANs" value on a standard port group' {
        $adapter = [PSCustomObject]@{ NetworkName = 'StdTrunk'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @() }
        Mock Get-VirtualPortGroup { @([PSCustomObject]@{ Name = 'StdTrunk'; VLanId = '4095' }) }
        Invoke-VlanResolution -Adapter $adapter | Should -Be 'PortGroup not found'
    }

    It 'still resolves a normal tagged port group' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-Prod'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @([PSCustomObject]@{
            Name = 'dvPG-Prod'
            VlanConfiguration = 'VLAN 1816'
            ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{
                DefaultPortConfig = [PSCustomObject]@{ Vlan = [PSCustomObject]@{ VlanId = 1816 } } } }
        }) }
        Mock Get-VirtualPortGroup { @() }
        Invoke-VlanResolution -Adapter $adapter | Should -Be '1816'
    }

    It 'still resolves the boundary VLANs 1 and 4094' {
        foreach ($boundaryVlan in @(1, 4094)) {
            $script:DistributedCache = @{}
            $script:StandardCache = @{}
            $adapter = [PSCustomObject]@{ NetworkName = "dvPG-$boundaryVlan"; MacAddress = '00:50:56:aa:bb:cc' }
            Mock Get-VDPortgroup { @([PSCustomObject]@{
                Name = "dvPG-$boundaryVlan"
                VlanConfiguration = "VLAN $boundaryVlan"
                ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{
                    DefaultPortConfig = [PSCustomObject]@{ Vlan = [PSCustomObject]@{ VlanId = $boundaryVlan } } } }
            }) }
            Mock Get-VirtualPortGroup { @() }
            Invoke-VlanResolution -Adapter $adapter | Should -Be ([string]$boundaryVlan)
        }
    }

    It 'still falls back to the VlanConfiguration string when no VlanId is exposed' {
        $adapter = [PSCustomObject]@{ NetworkName = 'dvPG-Legacy'; MacAddress = '00:50:56:aa:bb:cc' }
        Mock Get-VDPortgroup { @([PSCustomObject]@{
            Name = 'dvPG-Legacy'
            VlanConfiguration = 'VLAN 42'
            ExtensionData = [PSCustomObject]@{ Config = [PSCustomObject]@{
                DefaultPortConfig = [PSCustomObject]@{ Vlan = [PSCustomObject]@{} } } }
        }) }
        Mock Get-VirtualPortGroup { @() }
        Invoke-VlanResolution -Adapter $adapter | Should -Be '42'
    }
}

Describe 'step2 VM resolution' {

    BeforeAll {
        $script:Step2Source = Get-MigrationSource -RelativePath 'step2-ShutdownVM_StartBackupVeeam.ps1'
    }

    # Get-VM -Name returns one object per match and vCenter allows duplicate VM
    # names across folders/datacenters. Handing that array to Stop-VMGuest shut
    # down every homonym, and PowerState -eq on an array is truthy as soon as one
    # of them was already off.
    It 'resolves every VM before shutting anything down' {
        $script:Step2Source | Should -Match '\$resolvedVms'
        $script:Step2Source | Should -Match '\$ambiguousVmNames'
    }

    It 'refuses to act on an ambiguous VM name' {
        $script:Step2Source | Should -Match 'Refusing to shut down VMs that cannot be identified unambiguously'
    }

    It 'no longer re-resolves the VM by name inside the NIC disconnect helper' {
        $script:Step2Source | Should -Match 'Disconnect-VmNetworkAdapters -VmName \$vmName -VmObject \$vmObj'
        $script:Step2Source | Should -Not -Match '\$vmObj = VMware\.VimAutomation\.Core\\Get-VM -Name \$VmName'
    }
}

Describe 'step1 tag category comparison' {

    # $_.Tag.Category is a TagCategory object on some PowerCLI versions and a
    # bare string on others. Comparing the raw value to the category name only
    # works when PowerCLI supplies a type converter, and reading .Name blindly
    # throws under StrictMode against the string form -- hence the helper.
    # Detailed coverage lives in tests/step1-TagAssignment.Tests.ps1.
    It 'resolves the category name through the shape-agnostic helper' {
        $source = Get-MigrationSource -RelativePath 'step1-TagResources_CreateVeeamJob.ps1'
        $source | Should -Match 'Get-VmwareTagCategoryName -Category \$_\.Tag\.Category'
        $source | Should -Not -Match '\$_\.Tag\.Category -eq \$TagCategory'
    }
}

Describe 'VMware null guards under StrictMode' {

    It 'guards VMHost before walking the parent chain in run-migration' {
        $source = Get-MigrationSource -RelativePath 'run-migration.ps1'
        # The dereference must be reached only through the guard, never as a
        # bare statement: $null.Parent throws under StrictMode.
        $guarded = [regex]::Escape('$parent = $null') +
            '\s*\r?\n\s*if \(\$VMObject\.PSObject\.Properties\[''VMHost''\] -and \$VMObject\.VMHost\) \{' +
            '\s*\r?\n\s*' + [regex]::Escape('$parent = $VMObject.VMHost.Parent')
        $source | Should -Match $guarded
    }

    It 'guards VMHost before reading its name in the rollback' {
        $source = Get-MigrationSource -RelativePath 'Invoke-Rollback.ps1'
        $source | Should -Match 'if \(\$vm\.VMHost\) \{ \[string\]\$vm\.VMHost\.Name \}'
    }
}

Describe 'rollback powers on the VM it inspected' {

    BeforeAll {
        $script:RollbackSource = Get-MigrationSource -RelativePath 'Invoke-Rollback.ps1'
    }

    # Re-resolving by name could start a homonym in another folder, or a different
    # VM than the one whose power state had just been read.
    It 'carries the moref through the VMware state object' {
        $script:RollbackSource | Should -Match 'Id\s+= \[string\]\$vm\.Id'
    }

    It 'starts the VM by Id rather than by name' {
        $script:RollbackSource | Should -Match 'Get-VM -Id \$vmwareState\.Id -Server \$VcenterServer'
    }
}

Describe 'Resolve-AdapterVlanId single source of truth' {

    # The duplicated copy in tests/step3-MigrateVM.Tests.ps1 is how the VLAN 0
    # defect stayed green: the test asserted the buggy value of its own copy.
    It 'is defined once, in lib.ps1' {
        (Get-MigrationSource -RelativePath 'lib.ps1') | Should -Match 'function Resolve-AdapterVlanId'
        (Get-MigrationSource -RelativePath 'run-migration.ps1') | Should -Not -Match 'function Resolve-AdapterVlanId'
    }

    It 'is exercised from lib.ps1 by the step3 test suite' {
        $testSource = Get-Content -Path (Join-Path $script:RepoRoot 'tests/step3-MigrateVM.Tests.ps1') -Raw
        $testSource | Should -Not -Match 'function script:Resolve-AdapterVlanId'
        $testSource | Should -Match "powershell-migration/lib\.ps1"
    }
}
