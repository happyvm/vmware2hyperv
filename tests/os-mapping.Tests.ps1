<#
.SYNOPSIS
    Tests for the OS mapping family fallback (lib.ps1) and for the real
    SCVMM.OperatingSystemMap shipped in config.psd1.
.DESCRIPTION
    The mapping table used to be keyed on exact minor releases, so any RHEL
    minor the operator had not enumerated resolved to nothing and the VM kept
    whatever guest OS SCVMM had guessed.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MigrationRoot = Join-Path $script:RepoRoot 'powershell-migration'
    . (Join-Path $script:MigrationRoot 'lib.ps1')
    $script:ShippedMap = (Import-PowerShellDataFile (Join-Path $script:MigrationRoot 'config.psd1')).SCVMM.OperatingSystemMap
}

Describe 'Get-OperatingSystemFamilyKey' {

    It 'reduces a Linux label with a minor version to family plus major' {
        Get-OperatingSystemFamilyKey -Name 'Red Hat Enterprise Linux 8.6' | Should -Be 'red hat enterprise linux 8'
    }

    It 'strips the bitness suffix vCenter appends to a guest id' {
        Get-OperatingSystemFamilyKey -Name 'Red Hat Enterprise Linux 8 (64-bit)' | Should -Be 'red hat enterprise linux 8'
    }

    It 'strips the release code name VMware Tools reports' {
        Get-OperatingSystemFamilyKey -Name 'Red Hat Enterprise Linux release 8.9 (Ootpa)' | Should -Be 'red hat enterprise linux 8'
    }

    It 'treats the ES / Server edition tokens as noise' {
        Get-OperatingSystemFamilyKey -Name 'Red Hat Enterprise Linux ES 7.9' | Should -Be 'red hat enterprise linux 7'
        Get-OperatingSystemFamilyKey -Name 'Red Hat Enterprise Linux Server 7.9' | Should -Be 'red hat enterprise linux 7'
    }

    It 'returns null for a Windows label, whose version is not trailing' {
        # Windows editions must keep resolving by exact match: Datacenter and
        # Standard share a family and a version but not an SCVMM name.
        Get-OperatingSystemFamilyKey -Name 'Windows Server 2019 Datacenter' | Should -BeNullOrEmpty
        Get-OperatingSystemFamilyKey -Name 'Windows Server 2012 R2 Standard' | Should -BeNullOrEmpty
    }

    It 'returns null for empty or unversioned labels' {
        Get-OperatingSystemFamilyKey -Name $null | Should -BeNullOrEmpty
        Get-OperatingSystemFamilyKey -Name '  ' | Should -BeNullOrEmpty
        Get-OperatingSystemFamilyKey -Name 'Some Appliance' | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-OperatingSystemMapping family fallback' {

    BeforeAll {
        $script:Map = @{
            'Red Hat Enterprise Linux 8'      = 'Red Hat Enterprise Linux 8 (64 bit)'
            'Red Hat Enterprise Linux ES 7.3' = 'Red Hat Enterprise Linux 7.3 (64 bit)'
            'Red Hat Enterprise Linux 7'      = 'Red Hat Enterprise Linux 7 (64 bit)'
            'Windows Server 2019 Datacenter'  = 'Windows Server 2019 Datacenter'
            'Windows Server 2019 Standard'    = 'Windows Server 2019 Standard'
        }
    }

    It 'resolves a minor release that is not listed' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Red Hat Enterprise Linux 8.6' -OperatingSystemMap $script:Map |
            Should -Be 'Red Hat Enterprise Linux 8 (64 bit)'
    }

    It 'keeps an exact minor-specific entry winning over the family default' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Red Hat Enterprise Linux ES 7.3' -OperatingSystemMap $script:Map |
            Should -Be 'Red Hat Enterprise Linux 7.3 (64 bit)'
    }

    It 'falls back to the family default for another 7.x minor' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Red Hat Enterprise Linux 7.6' -OperatingSystemMap $script:Map |
            Should -Be 'Red Hat Enterprise Linux 7 (64 bit)'
    }

    It 'never collapses two Windows editions onto one another' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Windows Server 2019 Standard' -OperatingSystemMap $script:Map |
            Should -Be 'Windows Server 2019 Standard'
        Resolve-OperatingSystemMapping -OperatingSystem 'Windows Server 2019 Enterprise' -OperatingSystemMap $script:Map |
            Should -BeNullOrEmpty
    }

    It 'still returns null for an unmapped distribution' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Ubuntu 22.04' -OperatingSystemMap $script:Map | Should -BeNullOrEmpty
    }
}

Describe 'Shipped SCVMM.OperatingSystemMap' {

    # These are the labels a vCenter guest id, VMware Tools, and a CMDB extract
    # actually produce for the same RHEL machine.
    It 'maps every RHEL minor of a supported family' {
        $expectations = @{
            'Red Hat Enterprise Linux 8 (64-bit)'          = 'Red Hat Enterprise Linux 8 (64 bit)'
            'Red Hat Enterprise Linux 7 (64-bit)'          = 'Red Hat Enterprise Linux 7 (64 bit)'
            'Red Hat Enterprise Linux 9 (64-bit)'          = 'Red Hat Enterprise Linux 9 (64 bit)'
            'Red Hat Enterprise Linux release 8.9 (Ootpa)' = 'Red Hat Enterprise Linux 8 (64 bit)'
            'Red Hat Enterprise Linux 8.6'                 = 'Red Hat Enterprise Linux 8 (64 bit)'
            'Red Hat Enterprise Linux 8.4'                 = 'Red Hat Enterprise Linux 8 (64 bit)'
            'Red Hat Enterprise Linux 7.6'                 = 'Red Hat Enterprise Linux 7 (64 bit)'
            'Red Hat Enterprise Linux 9.2'                 = 'Red Hat Enterprise Linux 9 (64 bit)'
            'Red Hat Enterprise Linux Server 7.9'          = 'Red Hat Enterprise Linux 7 (64 bit)'
            'Red Hat Enterprise Linux ES 6.4'              = 'Red Hat Enterprise Linux 6 (64 bit)'
            'CentOS Linux 7.9'                             = 'CentOS Linux 7 (64 bit)'
        }

        foreach ($sourceLabel in $expectations.Keys) {
            Resolve-OperatingSystemMapping -OperatingSystem $sourceLabel -OperatingSystemMap $script:ShippedMap |
                Should -Be $expectations[$sourceLabel] -Because "'$sourceLabel' must map"
        }
    }

    It 'keeps the minor-specific RHEL 7.3 override' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Red Hat Enterprise Linux ES 7.3' -OperatingSystemMap $script:ShippedMap |
            Should -Be 'Red Hat Enterprise Linux 7.3 (64 bit)'
    }

    It 'still maps every Windows entry it used to' {
        foreach ($windowsLabel in @(
            'Windows Server 2025 Datacenter', 'Windows Server 2022 Standard',
            'Windows Server 2019 Datacenter', 'Windows Server 2016 Standard',
            'Windows Server 2012 R2 Datacenter', 'Windows Server 2012 Standard',
            'Windows Server 2008 R2 Enterprise', 'Windows Server 2008 Standard',
            'Windows Server 2003 Standard Edition'
        )) {
            Resolve-OperatingSystemMapping -OperatingSystem $windowsLabel -OperatingSystemMap $script:ShippedMap |
                Should -Not -BeNullOrEmpty -Because "'$windowsLabel' must keep mapping"
        }
    }

    It 'declares a family default for every RHEL major it references' {
        foreach ($major in @(6, 7, 8, 9)) {
            Resolve-OperatingSystemMapping -OperatingSystem "Red Hat Enterprise Linux $major.99" -OperatingSystemMap $script:ShippedMap |
                Should -Not -BeNullOrEmpty -Because "RHEL $major needs a family default"
        }
    }
}

Describe 'OS mapping diagnostics' {

    BeforeAll {
        $script:PostConfigSource = Get-Content -Path (Join-Path $script:MigrationRoot 'step3/Step3.PostConfig.ps1') -Raw
    }

    It 'names the family key that was looked up when nothing matches' {
        $script:PostConfigSource | Should -Match 'Get-OperatingSystemFamilyKey -Name \$SourceOperatingSystem'
        $script:PostConfigSource | Should -Match 'Add an entry to SCVMM\.OperatingSystemMap in config\.psd1'
    }

    It 'lists the closest SCVMM names when the mapped value does not exist' {
        $script:PostConfigSource | Should -Match 'Closest SCVMM names'
    }
}
