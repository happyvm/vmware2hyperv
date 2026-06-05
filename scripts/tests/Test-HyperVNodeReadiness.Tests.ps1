#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester unit tests for the pure/helper functions of Test-HyperVNodeReadiness.ps1.

.DESCRIPTION
    The script under test is dot-sourced; its Main block is guarded by
    `if ($MyInvocation.InvocationName -eq '.') { return }`, so dot-sourcing loads
    every function without running any readiness check.

    These tests cover the platform-independent logic only (string/LDAP helpers,
    network-role mapping, node-identity resolution, config parsing and the TCP
    port probe). They also act as regression tests for bugs fixed during review:
      - ConvertTo-NetworkRoleMap silently dropped @{ Name=..; Role=.. } entries.
      - Test-TcpPort reported a refused (closed) port as open.
      - Read-CfgValue blocked on prompts even when a config file was loaded.

.EXAMPLE
    Invoke-Pester -Path scripts/tests/Test-HyperVNodeReadiness.Tests.ps1
#>

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-HyperVNodeReadiness.ps1'
    . $script:ScriptPath
}

Describe 'ConvertTo-LdapEscapedFilterValue' {
    It 'returns empty string for $null' {
        ConvertTo-LdapEscapedFilterValue -Value $null | Should -BeExactly ''
    }
    It 'leaves a plain value untouched' {
        ConvertTo-LdapEscapedFilterValue -Value 'node1' | Should -BeExactly 'node1'
    }
    It 'escapes the LDAP special characters \ * ( )' {
        ConvertTo-LdapEscapedFilterValue -Value 'a*b(c)d\e' | Should -BeExactly 'a\2ab\28c\29d\5ce'
    }
    It 'escapes the backslash before other characters (no double-escaping)' {
        # A leading backslash must become \5c, not \5c with the 5c re-escaped.
        ConvertTo-LdapEscapedFilterValue -Value '\' | Should -BeExactly '\5c'
    }
    It 'escapes a trailing $ used for sAMAccountName unchanged ($ is not special)' {
        ConvertTo-LdapEscapedFilterValue -Value 'NODE1$' | Should -BeExactly 'NODE1$'
    }
}

Describe 'Get-UniqueTextValues' {
    It 'trims and de-duplicates case-insensitively' {
        $r = @(Get-UniqueTextValues -Values @('Node1', ' node1 ', 'NODE1', 'node2'))
        $r | Should -HaveCount 2
        $r[0] | Should -BeExactly 'Node1'
        $r[1] | Should -BeExactly 'node2'
    }
    It 'skips null, empty and whitespace-only values' {
        $r = @(Get-UniqueTextValues -Values @($null, '', '   ', 'keep'))
        $r | Should -HaveCount 1
        $r[0] | Should -BeExactly 'keep'
    }
    It 'returns nothing for an all-empty input' {
        @(Get-UniqueTextValues -Values @($null, '')) | Should -HaveCount 0
    }
}

Describe 'ConvertTo-NetworkAdapterRole' {
    It 'normalizes <RoleText> to <Expected>' -ForEach @(
        @{ RoleText = 'Management';     Expected = 'Management' }
        @{ RoleText = 'Cluster';        Expected = 'Cluster' }
        @{ RoleText = 'Heartbeat';      Expected = 'Cluster' }
        @{ RoleText = 'LiveMigration';  Expected = 'LiveMigration' }
        @{ RoleText = 'iSCSI';          Expected = 'iSCSI' }
        @{ RoleText = 'S2DStorage';     Expected = 'S2DStorage' }
        @{ RoleText = 'Storage';        Expected = 'S2DStorage' }
        @{ RoleText = 'S2D';            Expected = 'S2DStorage' }
        @{ RoleText = 'VM';             Expected = 'VM' }
        @{ RoleText = 'VirtualMachine'; Expected = 'VM' }
        @{ RoleText = ' management ';   Expected = 'Management' }
    ) {
        ConvertTo-NetworkAdapterRole -Role $RoleText | Should -BeExactly $Expected
    }
    It 'returns $null for an unknown or empty role' {
        ConvertTo-NetworkAdapterRole -Role 'Nope'  | Should -BeNullOrEmpty
        ConvertTo-NetworkAdapterRole -Role ''       | Should -BeNullOrEmpty
        ConvertTo-NetworkAdapterRole -Role '   '    | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-NetworkRoleMap' {
    It 'maps the documented NetworkAdapters @{ Name; Role } array form (regression)' {
        $map = ConvertTo-NetworkRoleMap -Mappings @(
            @{ Name = 'Mgmt01';    Role = 'Management' }
            @{ Name = 'S2D01';     Role = 'S2DStorage' }
            @{ Name = 'Clu01';     Role = 'Heartbeat' }
        )
        $map.Keys | Should -HaveCount 3
        $map['Mgmt01'] | Should -BeExactly 'Management'
        $map['S2D01']  | Should -BeExactly 'S2DStorage'
        $map['Clu01']  | Should -BeExactly 'Cluster'
    }
    It 'maps the NetworkRoles @{ NicName = Role } single-hashtable form' {
        $map = ConvertTo-NetworkRoleMap -Mappings @( @{ Mgmt01 = 'Management'; VM01 = 'VM' } )
        $map.Keys | Should -HaveCount 2
        $map['Mgmt01'] | Should -BeExactly 'Management'
        $map['VM01']   | Should -BeExactly 'VM'
    }
    It 'accepts InterfaceAlias as the name key' {
        $map = ConvertTo-NetworkRoleMap -Mappings @( @{ InterfaceAlias = 'iSCSI01'; Role = 'iSCSI' } )
        $map['iSCSI01'] | Should -BeExactly 'iSCSI'
    }
    It 'reads name/role from a PSCustomObject' {
        $map = ConvertTo-NetworkRoleMap -Mappings @( [pscustomobject]@{ Name = 'LM01'; Role = 'LiveMigration' } )
        $map['LM01'] | Should -BeExactly 'LiveMigration'
    }
    It 'ignores entries with an unknown role and empty/null mappings' {
        $map = ConvertTo-NetworkRoleMap -Mappings @(
            @{ Name = 'X'; Role = 'Bogus' }
            $null
            @{ Name = 'Y'; Role = 'VM' }
        )
        $map.Keys | Should -HaveCount 1
        $map['Y'] | Should -BeExactly 'VM'
    }
    It 'returns an empty map for an empty input' {
        (ConvertTo-NetworkRoleMap -Mappings @()).Keys | Should -HaveCount 0
    }
}

Describe 'Get-NetworkAdapterRole' {
    BeforeAll {
        $script:RoleMap = ConvertTo-NetworkRoleMap -Mappings @(
            @{ Name = 'Mgmt01'; Role = 'Management' }
        )
    }
    It 'matches an adapter by Name' {
        $nic = [pscustomobject]@{ Name = 'Mgmt01'; InterfaceDescription = 'Intel NIC' }
        Get-NetworkAdapterRole -Adapter $nic -RoleMap $script:RoleMap | Should -BeExactly 'Management'
    }
    It 'returns $null when the adapter name is not mapped' {
        $nic = [pscustomobject]@{ Name = 'Other'; InterfaceDescription = 'x' }
        Get-NetworkAdapterRole -Adapter $nic -RoleMap $script:RoleMap | Should -BeNullOrEmpty
    }
    It 'returns $null for an empty role map' {
        $nic = [pscustomobject]@{ Name = 'Mgmt01' }
        Get-NetworkAdapterRole -Adapter $nic -RoleMap @{} | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-ClusterNodeIdentity' {
    It 'expands a short name using the domain' {
        $n = Resolve-ClusterNodeIdentity -NodeName 'node1' -DomainName 'corp.local'
        $n.ShortName     | Should -BeExactly 'node1'
        $n.Fqdn          | Should -BeExactly 'node1.corp.local'
        $n.ExpectedHosts | Should -Contain 'node1'
        $n.ExpectedHosts | Should -Contain 'node1.corp.local'
    }
    It 'derives the short name from an FQDN input' {
        $n = Resolve-ClusterNodeIdentity -NodeName 'node2.corp.local' -DomainName 'corp.local'
        $n.ShortName | Should -BeExactly 'node2'
        $n.Fqdn      | Should -BeExactly 'node2.corp.local'
    }
    It 'keeps the input name and resolves no FQDN for a bare short name without domain' {
        $n = Resolve-ClusterNodeIdentity -NodeName 'standalone' -DomainName ''
        $n.ShortName | Should -BeExactly 'standalone'
        $n.Fqdn      | Should -BeNullOrEmpty
    }
    It 'records an IPv4 literal as the input name without crashing' {
        $n = Resolve-ClusterNodeIdentity -NodeName '10.0.0.5' -DomainName 'corp.local'
        $n.InputName | Should -BeExactly '10.0.0.5'
        # No domain suffixing is applied to an IP literal.
        $n.Fqdn | Should -Not -BeExactly '10.0.0.5.corp.local'
    }
}

Describe 'Read-CfgValue (config-file mode never prompts)' {
    BeforeAll { $script:ConfigLoaded = $true }

    It 'returns a present non-empty scalar value' {
        Read-CfgValue @{ ClusterName = 'CL01' } 'ClusterName' 'prompt' | Should -BeExactly 'CL01'
    }
    It 'falls back to the default when the key is absent' {
        Read-CfgValue @{} 'Mode' 'prompt' 'Both' | Should -BeExactly 'Both'
    }
    It 'returns empty (skip) when the key is empty and there is no default' {
        Read-CfgValue @{ WitnessShare = '' } 'WitnessShare' 'prompt' | Should -BeExactly ''
    }
    It 'returns empty (skip) when the key is absent and there is no default' {
        Read-CfgValue @{} 'WitnessShare' 'prompt' | Should -BeExactly ''
    }
    It 'passes through an array value for -IsArray' {
        $r = @(Read-CfgValue @{ ClusterNodes = @('a','b') } 'ClusterNodes' 'prompt' -IsArray)
        $r | Should -HaveCount 2
        $r[0] | Should -BeExactly 'a'
    }
    It 'splits a delimited string for -IsArray' {
        $r = @(Read-CfgValue @{ DomainControllers = 'dc1, dc2; dc3' } 'DomainControllers' 'prompt' -IsArray)
        $r | Should -HaveCount 3
        $r[2] | Should -BeExactly 'dc3'
    }
    It 'returns an empty array for an absent -IsArray key' {
        @(Read-CfgValue @{} 'ClusterNodes' 'prompt' -IsArray) | Should -HaveCount 0
    }
}

Describe 'Test-TcpPort' {
    It 'returns $true for a port that is actively listening' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Test-TcpPort -Target '127.0.0.1' -Port $port -TimeoutMs 2000 | Should -BeTrue
        } finally {
            $listener.Stop()
        }
    }
    It 'returns $false for a reachable but closed port (regression: refused != open)' {
        # Bind then immediately release a port to obtain one nothing is listening on.
        $tmp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $tmp.Start()
        $closedPort = ([System.Net.IPEndPoint]$tmp.LocalEndpoint).Port
        $tmp.Stop()
        Test-TcpPort -Target '127.0.0.1' -Port $closedPort -TimeoutMs 1500 | Should -BeFalse
    }
}
