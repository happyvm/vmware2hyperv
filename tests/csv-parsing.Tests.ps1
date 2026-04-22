Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path -Path $repoRoot -ChildPath 'powershell-migration/lib.ps1')
}

Describe 'Get-FirstPropertyValue — CSV column name variants' {
    It 'reads VMName column' {
        $row = [PSCustomObject]@{ VMName = 'SRV01'; Tag = 'lot-1' }
        Get-FirstPropertyValue -InputObject $row -PropertyNames @('VMName', 'VmName', 'Name', 'NomVM') | Should -Be 'SRV01'
    }

    It 'falls back to NomVM when VMName is absent' {
        $row = [PSCustomObject]@{ NomVM = 'SRV02'; Tag = 'lot-1' }
        Get-FirstPropertyValue -InputObject $row -PropertyNames @('VMName', 'VmName', 'Name', 'NomVM') | Should -Be 'SRV02'
    }

    It 'reads ExpectedIP column' {
        $row = [PSCustomObject]@{ VMName = 'SRV01'; ExpectedIP = '10.0.0.1' }
        Get-FirstPropertyValue -InputObject $row -PropertyNames @('ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'IP', 'IPAddress', 'IpAddress') | Should -Be '10.0.0.1'
    }

    It 'falls back to IPAttendue when ExpectedIP is absent' {
        $row = [PSCustomObject]@{ VMName = 'SRV01'; IPAttendue = '10.0.0.2' }
        Get-FirstPropertyValue -InputObject $row -PropertyNames @('ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'IP', 'IPAddress', 'IpAddress') | Should -Be '10.0.0.2'
    }

    It 'returns null when no IP column is present' {
        $row = [PSCustomObject]@{ VMName = 'SRV01' }
        Get-FirstPropertyValue -InputObject $row -PropertyNames @('ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'IP', 'IPAddress', 'IpAddress') | Should -BeNullOrEmpty
    }

    It 'reads OperatingSystem column' {
        $row = [PSCustomObject]@{ VMName = 'SRV01'; OperatingSystem = 'Windows Server 2019' }
        Get-FirstPropertyValue -InputObject $row -PropertyNames @('OperatingSystem', 'Operating system') | Should -Be 'Windows Server 2019'
    }

    It 'handles VM names with special characters' {
        $row = [PSCustomObject]@{ VMName = 'SRV-01_PROD'; Tag = 'lot-1' }
        Get-FirstPropertyValue -InputObject $row -PropertyNames @('VMName', 'NomVM') | Should -Be 'SRV-01_PROD'
    }
}

Describe 'CSV delimiter handling' {
    It 'parses a semicolon-delimited batch CSV correctly' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmpFile -Value "VMName;Tag;OperatingSystem`nSRV01;lot-1;Windows Server 2019`nSRV02;lot-1;Windows Server 2022"
            $rows = Import-Csv -Path $tmpFile -Delimiter ';'
            $rows | Should -HaveCount 2
            $rows[0].VMName | Should -Be 'SRV01'
            $rows[1].Tag    | Should -Be 'lot-1'
        } finally {
            Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
        }
    }

    It 'parses a semicolon-delimited IP extract CSV with alternate column names' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmpFile -Value "NomVM;IPAttendue`nSRV01;192.168.1.10`nSRV02;192.168.1.11"
            $rows = Import-Csv -Path $tmpFile -Delimiter ';'
            $rows | Should -HaveCount 2

            $vmName = Get-FirstPropertyValue -InputObject $rows[0] -PropertyNames @('VMName', 'VmName', 'Name', 'NomVM')
            $ip     = Get-FirstPropertyValue -InputObject $rows[0] -PropertyNames @('ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'IP', 'IPAddress', 'IpAddress')

            $vmName | Should -Be 'SRV01'
            $ip     | Should -Be '192.168.1.10'
        } finally {
            Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
        }
    }

    It 'handles empty or whitespace-only rows gracefully' {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmpFile -Value "VMName;Tag`nSRV01;lot-1`n ;lot-1`n`nSRV02;lot-1"
            $rows = Import-Csv -Path $tmpFile -Delimiter ';'
            $validRows = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })
            $validRows | Should -HaveCount 2
        } finally {
            Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
        }
    }
}
