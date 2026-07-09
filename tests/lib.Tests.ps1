Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path -Path $repoRoot -ChildPath 'powershell-migration/lib.ps1')
}

Describe 'ConvertTo-NormalizedOperatingSystemName' {
    It 'returns null for null/empty values' {
        ConvertTo-NormalizedOperatingSystemName -Name $null | Should -BeNullOrEmpty
        ConvertTo-NormalizedOperatingSystemName -Name '' | Should -BeNullOrEmpty
        ConvertTo-NormalizedOperatingSystemName -Name '   ' | Should -BeNullOrEmpty
    }

    It 'normalizes case, separators, and leading Microsoft prefix' {
        $value = ConvertTo-NormalizedOperatingSystemName -Name ' Microsoft   Windows_Server-2022/Datacenter '
        $value | Should -Be 'windows server 2022 datacenter'
    }
}

Describe 'Resolve-OperatingSystemMapping' {
    It 'matches a source value against map keys after normalization' {
        $map = @{
            'Windows Server 2022 Datacenter' = 'Windows Server 2022 Datacenter'
            'Red Hat Enterprise Linux 8.10'  = 'Red Hat Enterprise Linux 8 (64 bit)'
        }

        $resolved = Resolve-OperatingSystemMapping -OperatingSystem 'microsoft windows_server_2022 datacenter' -OperatingSystemMap $map
        $resolved | Should -Be 'Windows Server 2022 Datacenter'
    }

    It 'returns null when no key matches or map/value is missing' {
        $map = @{ 'CentOS Linux 7' = 'CentOS Linux 7 (64 bit)' }

        Resolve-OperatingSystemMapping -OperatingSystem 'Ubuntu 22.04' -OperatingSystemMap $map | Should -BeNullOrEmpty
        Resolve-OperatingSystemMapping -OperatingSystem $null -OperatingSystemMap $map | Should -BeNullOrEmpty
        Resolve-OperatingSystemMapping -OperatingSystem 'CentOS Linux 7' -OperatingSystemMap $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-FirstPropertyValue' {
    It 'returns the value of the first matching property' {
        $obj = [PSCustomObject]@{ OperatingSystem = 'Windows Server 2022'; OS = 'Win' }
        Get-FirstPropertyValue -InputObject $obj -PropertyNames @('OperatingSystem', 'OS') | Should -Be 'Windows Server 2022'
    }

    It 'falls back to the second property when the first is absent or empty' {
        $obj = [PSCustomObject]@{ OperatingSystem = ''; OS = 'Linux' }
        Get-FirstPropertyValue -InputObject $obj -PropertyNames @('OperatingSystem', 'OS') | Should -Be 'Linux'
    }

    It 'returns null when no matching property has a value' {
        $obj = [PSCustomObject]@{ Name = 'VM1' }
        Get-FirstPropertyValue -InputObject $obj -PropertyNames @('OperatingSystem', 'OS') | Should -BeNullOrEmpty
    }

    It 'returns null when all candidate properties are whitespace' {
        $obj = [PSCustomObject]@{ OperatingSystem = '   '; OS = '  ' }
        Get-FirstPropertyValue -InputObject $obj -PropertyNames @('OperatingSystem', 'OS') | Should -BeNullOrEmpty
    }
}

Describe 'Get-OsGeneration' {
    It 'returns the correct year for each supported OS generation' {
        Get-OsGeneration -OperatingSystem 'Windows Server 2003 R2'      | Should -Be 2003
        Get-OsGeneration -OperatingSystem 'Windows Server 2008 R2 SP1'  | Should -Be 2008
        Get-OsGeneration -OperatingSystem 'Windows Server 2012 R2'      | Should -Be 2012
        Get-OsGeneration -OperatingSystem 'Windows Server 2016'         | Should -Be 2016
        Get-OsGeneration -OperatingSystem 'Windows Server 2019'         | Should -Be 2019
        Get-OsGeneration -OperatingSystem 'Windows Server 2022'         | Should -Be 2022
        Get-OsGeneration -OperatingSystem 'Windows Server 2025'         | Should -Be 2025
    }

    It 'returns null for unrecognized or missing OS strings' {
        Get-OsGeneration -OperatingSystem 'Red Hat Enterprise Linux 8' | Should -BeNullOrEmpty
        Get-OsGeneration -OperatingSystem ''                           | Should -BeNullOrEmpty
        Get-OsGeneration -OperatingSystem $null                        | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-MigrationTarget' {
    BeforeAll {
        $testConfig = @{
            HyperV = @{
                Host1          = 'default-hv01.domain'
                Host2          = 'default-hv02.domain'
                Cluster        = 'DefaultHyperVCluster'
                ClusterStorage = 'C:\ClusterStorage\DefaultVolume'
            }
            MigrationMappings = @{
                ClusterMappings = @(
                    @{
                        VMwareCluster  = 'VmwareClusterA'
                        HyperVCluster  = 'HyperVClusterA'
                        Host1          = 'hv-a01.domain'
                        Host2          = 'hv-a02.domain'
                        ClusterStorage = 'C:\ClusterStorage\VolumeA'
                    }
                )
            }
        }
    }

    It 'returns the mapped Hyper-V target for a VMware cluster' {
        $target = Resolve-MigrationTarget -Config $testConfig -VmwareClusterName 'vmwareclustera'

        $target.MappingMatched | Should -BeTrue
        $target.HyperVHost | Should -Be 'hv-a01.domain'
        $target.HyperVHost2 | Should -Be 'hv-a02.domain'
        $target.HyperVCluster | Should -Be 'HyperVClusterA'
        $target.ClusterStorage | Should -Be 'C:\ClusterStorage\VolumeA'
    }

    It 'falls back to the default HyperV block when no mapping matches' {
        $target = Resolve-MigrationTarget -Config $testConfig -VmwareClusterName 'UnknownCluster'

        $target.MappingMatched | Should -BeFalse
        $target.HyperVHost | Should -Be 'default-hv01.domain'
        $target.HyperVHost2 | Should -Be 'default-hv02.domain'
        $target.HyperVCluster | Should -Be 'DefaultHyperVCluster'
        $target.ClusterStorage | Should -Be 'C:\ClusterStorage\DefaultVolume'
    }
}

Describe 'Connect-VCenter credential fallback' {
    BeforeEach {
        $script:VCenterCredentialFallback = $null
        $script:ConnectVIServerCalls = @()
        $script:GetCredentialCalls = 0

        Mock -CommandName Import-RequiredModule -MockWith { }
        Mock -CommandName Get-VCenterPowerCLIConfiguration -MockWith { [PSCustomObject]@{ DefaultVIServerMode = 'Multiple' } }
        Mock -CommandName Invoke-VCenterVIServerConnection -MockWith {
            param($Server, $Credential)

            $script:ConnectVIServerCalls += [PSCustomObject]@{
                Server        = $Server
                HasCredential = $null -ne $Credential
            }

            if (-not $Credential) {
                throw 'SSPI pass-through refused'
            }

            [PSCustomObject]@{ Name = $Server }
        }
        Mock -CommandName Request-VCenterFallbackCredential -MockWith {
            $script:GetCredentialCalls++
            [pscredential]::new('domain\migration', (ConvertTo-SecureString 'secret' -AsPlainText -Force))
        }
    }

    It 'prompts only once and reuses the fallback credential for subsequent vCenter connections' {
        Connect-VCenter -Server 'vcenter-a.domain.local'
        Connect-VCenter -Server 'vcenter-b.domain.local'

        $script:GetCredentialCalls | Should -Be 1
        @($script:ConnectVIServerCalls | Where-Object HasCredential) | Should -HaveCount 2
        @($script:ConnectVIServerCalls | Where-Object { -not $_.HasCredential }) | Should -HaveCount 2
    }
}

Describe 'Get-ModuleImportStrategies' {
    It 'uses standard import before fallbacks for regular modules' {
        $strategies = @(Get-ModuleImportStrategies -UseWindowsPowerShellFallback)
        $strategies[0] | Should -Be 'Standard'
    }

    It 'keeps SkipEditionCheck as a PowerShell Core fallback' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Get-ModuleImportStrategies | Should -Contain 'SkipEditionCheck'
    }

    It 'prefers Windows PowerShell compatibility before SkipEditionCheck on Windows PowerShell Core' -Skip:(-not ($PSVersionTable.PSEdition -eq 'Core' -and $IsWindows)) {
        $strategies = @(Get-ModuleImportStrategies -UseWindowsPowerShellFallback)
        [array]::IndexOf($strategies, 'WindowsPowerShell') | Should -BeLessThan ([array]::IndexOf($strategies, 'SkipEditionCheck'))
    }

    It 'tries the Windows PowerShell compatibility session first for known Windows-only management modules' -Skip:(-not ($PSVersionTable.PSEdition -eq 'Core' -and $IsWindows)) {
        foreach ($moduleName in @('VirtualMachineManager', 'Veeam.Backup.PowerShell', 'FailoverClusters')) {
            $strategies = @(Get-ModuleImportStrategies -UseWindowsPowerShellFallback -ModuleName $moduleName)
            $strategies[0] | Should -Be 'WindowsPowerShell' -Because "$moduleName imports in-process without error but fails at runtime (IndigoLayer)"
        }
    }

    It 'keeps the standard-first order for modules outside the Windows-only list' -Skip:(-not ($PSVersionTable.PSEdition -eq 'Core' -and $IsWindows)) {
        $strategies = @(Get-ModuleImportStrategies -UseWindowsPowerShellFallback -ModuleName 'VMware.PowerCLI')
        $strategies[0] | Should -Be 'Standard'
    }

    It 'never uses the compatibility session when the fallback is not requested' {
        $strategies = @(Get-ModuleImportStrategies -ModuleName 'VirtualMachineManager')
        $strategies | Should -Not -Contain 'WindowsPowerShell'
    }
}
