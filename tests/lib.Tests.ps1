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
