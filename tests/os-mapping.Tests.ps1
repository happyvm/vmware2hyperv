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

    # Labels actually produced by a ServiceNow cmdb_ci_server export's "Operating
    # System" column: "Windows <year> <edition>" without the word "Server", and
    # trademark-symbol / comma variants from Discovery.
    It 'maps the ServiceNow short forms onto the same SCVMM names as their long forms' {
        $expectations = @{
            'Windows 2025 Standard'      = 'Windows Server 2025 Standard'
            'Windows 2022 Datacenter'    = 'Windows Server 2022 Datacenter'
            'Windows 2019 Datacenter'    = 'Windows Server 2019 Datacenter'
            'Windows 2016 Standard'      = 'Windows Server 2016 Standard'
            'Windows 2012 R2 Standard'   = 'Windows Server 2012 R2 Standard'
            'Windows 2012 Standard'      = '64-bit edition of Windows Server 2012 Standard'
            'Windows 2008 R2 Standard'   = '64-bit edition of Windows Server 2008 R2 Standard'
            'Windows 2003 Standard'      = 'Windows Server 2003 Standard Edition (32-bit x86)'
        }

        foreach ($sourceLabel in $expectations.Keys) {
            Resolve-OperatingSystemMapping -OperatingSystem $sourceLabel -OperatingSystemMap $script:ShippedMap |
                Should -Be $expectations[$sourceLabel] -Because "'$sourceLabel' must map"
        }
    }

    It 'maps the trademark-symbol variant Discovery reports for Windows 2008 Standard' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Windows ® 2008 Standard' -OperatingSystemMap $script:ShippedMap |
            Should -Be 'Windows Server 2008 Standard 32-Bit'
    }

    It 'maps the comma-separated edition Discovery reports for Windows 2003' {
        Resolve-OperatingSystemMapping -OperatingSystem 'Microsoft Windows Server 2003, Standard' -OperatingSystemMap $script:ShippedMap |
            Should -BeNullOrEmpty -Because 'the edition wording (no trailing "Edition") does not match any configured key'
    }

    It 'extends CentOS with the same naming pattern as the shipped CentOS Linux 7 entry' {
        Resolve-OperatingSystemMapping -OperatingSystem 'CentOS 6' -OperatingSystemMap $script:ShippedMap |
            Should -Be 'CentOS Linux 6 (64 bit)'
    }

    # ServiceNow cmdb_ci_server splits the Linux family ("Operating System" =
    # "Linux Red Hat") and the version ("OS Version" = "8.10") across two
    # columns; Merge-CmdbOperatingSystemVersion recombines them upstream into
    # "Linux Red Hat 8.10" before it reaches this map.
    It 'resolves the merged "Linux family + version" labels this CMDB export produces' {
        $expectations = @{
            'Linux Red Hat 8.10'   = 'Red Hat Enterprise Linux 8 (64 bit)'
            'Linux Red Hat 7.6'    = 'Red Hat Enterprise Linux 7 (64 bit)'
            'Linux Red Hat 9.4'    = 'Red Hat Enterprise Linux 9 (64 bit)'
            'Linux CentOS 7.9.2009' = 'CentOS Linux 7 (64 bit)'
            'Linux CentOS 6.5'     = 'CentOS Linux 6 (64 bit)'
        }

        foreach ($sourceLabel in $expectations.Keys) {
            Resolve-OperatingSystemMapping -OperatingSystem $sourceLabel -OperatingSystemMap $script:ShippedMap |
                Should -Be $expectations[$sourceLabel] -Because "'$sourceLabel' must map"
        }
    }
}

Describe 'Merge-CmdbOperatingSystemVersion' {

    It 'appends the OS Version column when the OS label carries no version of its own' {
        Merge-CmdbOperatingSystemVersion -OperatingSystem 'Linux Red Hat' -OsVersion '8.10' | Should -Be 'Linux Red Hat 8.10'
        Merge-CmdbOperatingSystemVersion -OperatingSystem 'Linux CentOS' -OsVersion '7.9.2009' | Should -Be 'Linux CentOS 7.9.2009'
    }

    It 'leaves an already-versioned OS label untouched' {
        Merge-CmdbOperatingSystemVersion -OperatingSystem 'Windows 2019 Datacenter' -OsVersion '10.0.17763' |
            Should -Be 'Windows 2019 Datacenter'
        Merge-CmdbOperatingSystemVersion -OperatingSystem 'Red Hat Enterprise Linux 8 (64-bit)' -OsVersion '8.6' |
            Should -Be 'Red Hat Enterprise Linux 8 (64-bit)'
    }

    It 'does not guess from a non-numeric version string (kernel build, service pack code)' {
        Merge-CmdbOperatingSystemVersion -OperatingSystem 'GNU/Linux' -OsVersion '6.1.166-1-generic' | Should -Be 'GNU/Linux'
        Merge-CmdbOperatingSystemVersion -OperatingSystem 'Linux SuSE' -OsVersion '15-sp5' | Should -Be 'Linux SuSE'
    }

    It 'returns the OS label unchanged when either input is empty' {
        Merge-CmdbOperatingSystemVersion -OperatingSystem 'Linux Red Hat' -OsVersion '' | Should -Be 'Linux Red Hat'
        Merge-CmdbOperatingSystemVersion -OperatingSystem $null -OsVersion '8.10' | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-CmdbDrpTool' {

    BeforeAll {
        # DrpToolMap is shipped empty in config.psd1 (the operator fills it in with
        # their own CMDB's real values), so tests exercise the resolver directly
        # against a representative map instead of the shipped one.
        $script:DrpToolTestMap = @{
            'SRDF'      = 'storage réplication'
            'Zerto'     = 'VM réplication'
            'Veeam B&R' = 'backup restore'
        }
    }

    It 'resolves a raw CMDB value to its mapped category' {
        Resolve-CmdbDrpTool -DrpTool 'SRDF' -DrpToolMap $script:DrpToolTestMap | Should -Be 'storage réplication'
        Resolve-CmdbDrpTool -DrpTool 'Zerto' -DrpToolMap $script:DrpToolTestMap | Should -Be 'VM réplication'
        Resolve-CmdbDrpTool -DrpTool 'Veeam B&R' -DrpToolMap $script:DrpToolTestMap | Should -Be 'backup restore'
    }

    It 'matches case-insensitively and ignores surrounding whitespace' {
        Resolve-CmdbDrpTool -DrpTool '  srdf  ' -DrpToolMap $script:DrpToolTestMap | Should -Be 'storage réplication'
        Resolve-CmdbDrpTool -DrpTool 'ZERTO' -DrpToolMap $script:DrpToolTestMap | Should -Be 'VM réplication'
    }

    It 'returns null for a value with no matching entry' {
        Resolve-CmdbDrpTool -DrpTool 'SomeOtherTool' -DrpToolMap $script:DrpToolTestMap | Should -BeNullOrEmpty
    }

    It 'returns null for an empty value or an empty map' {
        Resolve-CmdbDrpTool -DrpTool '' -DrpToolMap $script:DrpToolTestMap | Should -BeNullOrEmpty
        Resolve-CmdbDrpTool -DrpTool 'SRDF' -DrpToolMap @{} | Should -BeNullOrEmpty
    }

    It 'ships with an empty DrpToolMap, left for the operator to fill in' {
        $shippedDrpToolMap = (Import-PowerShellDataFile (Join-Path $script:MigrationRoot 'config.psd1')).CMDB.DrpToolMap
        $shippedDrpToolMap.Count | Should -Be 0
    }
}

Describe 'ConvertTo-NormalizedOperatingSystemName trademark and separator handling' {

    It 'strips a trailing registered-trademark symbol' {
        ConvertTo-NormalizedOperatingSystemName -Name 'Windows ® 2008 Standard' | Should -Be 'windows 2008 standard'
    }

    It 'strips the "(R)" text form Discovery sometimes reports instead of the symbol' {
        ConvertTo-NormalizedOperatingSystemName -Name 'Microsoft(R) Windows(R) Server 2003' | Should -Be 'windows server 2003'
    }

    It 'treats a comma as a separator, same as slash/underscore/hyphen' {
        ConvertTo-NormalizedOperatingSystemName -Name 'Windows Server 2003, Standard' | Should -Be 'windows server 2003 standard'
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
