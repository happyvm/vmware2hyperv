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

Describe 'Get-VMUptime' {
    It 'returns one entry per mocked VM with correct uptime format' {
        $fakeBootTime = (Get-Date).AddDays(-3).AddHours(-2).AddMinutes(-15)

        $fakeGuest = [PSCustomObject]@{
            ToolsStatus  = 'toolsOk'
            BootTime     = $fakeBootTime
            GuestFullName = 'Windows Server 2019'
        }

        $fakeVm = [PSCustomObject]@{
            Name         = 'TESTVM01'
            PowerState   = 'PoweredOn'
            ExtensionData = [PSCustomObject]@{
                Guest   = $fakeGuest
                Runtime = [PSCustomObject]@{ BootTime = $fakeBootTime }
            }
        }

        Mock -CommandName 'Invoke-VMwareGetVM' -MockWith { @($fakeVm) }

        $result = Get-VMUptime
        $result | Should -HaveCount 1
        $result[0].VMName  | Should -Be 'TESTVM01'
        $result[0].Uptime  | Should -Match '^\d+ days, \d+ hours, \d+ minutes$'
    }

    It 'reports Unavailable when boot time cannot be determined' {
        $fakeGuest = [PSCustomObject]@{
            ToolsStatus   = 'toolsNotInstalled'
            BootTime      = $null
            GuestFullName = 'Linux'
        }

        $fakeVm = [PSCustomObject]@{
            Name         = 'LINUXVM01'
            PowerState   = 'PoweredOn'
            ExtensionData = [PSCustomObject]@{
                Guest   = $fakeGuest
                Runtime = [PSCustomObject]@{ BootTime = $null }
            }
        }

        Mock -CommandName 'Invoke-VMwareGetVM' -MockWith { @($fakeVm) }

        $result = Get-VMUptime
        $result[0].Uptime | Should -Be 'Unavailable'
    }
}
