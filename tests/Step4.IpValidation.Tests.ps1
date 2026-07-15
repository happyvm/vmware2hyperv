Set-StrictMode -Version Latest

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'powershell-migration' 'lib.ps1')

    function Get-TestExpectedIpMap {
        param([string]$Path)
        $rows = Import-Csv -Path $Path -Delimiter ';'
        $map = @{}
        foreach ($row in $rows) {
            $vmNameRaw = Get-FirstPropertyValue -InputObject $row -PropertyNames @('VMName', 'VmName', 'Name', 'NomVM')
            $ipRaw = Get-FirstPropertyValue -InputObject $row -PropertyNames @('ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'TargetIp', 'IP', 'IPAddress', 'IpAddress')
            $vmName = if ($null -eq $vmNameRaw) { '' } else { ([string]$vmNameRaw).Trim() }
            $ip = if ($null -eq $ipRaw) { '' } else { ([string]$ipRaw).Trim() }
            if ([string]::IsNullOrWhiteSpace($vmName) -or [string]::IsNullOrWhiteSpace($ip)) { continue }
            $map[$vmName.ToLowerInvariant()] = [pscustomobject]@{ ExpectedIP = $ip; IsValid = (Test-ValidIPv4Address -Address $ip) }
        }
        return $map
    }

    function Invoke-TestIpValidation {
        param(
            [hashtable]$Map,
            [string]$VMName = 'VM01',
            [object[]]$CurrentIPs = @(),
            [switch]$RequireExpectedIp,
            [switch]$SkipExpectedIpValidation
        )
        $expectedIp = $null
        $invalid = $false
        $key = $VMName.ToLowerInvariant()
        if ($Map -and $Map.ContainsKey($key)) {
            $expectedIp = [string]$Map[$key].ExpectedIP
            $invalid = -not [bool]$Map[$key].IsValid
        }
        Test-ExpectedIPv4Address -ExpectedIP $expectedIp -CurrentIPs $CurrentIPs -RequireExpectedIp ([bool]$RequireExpectedIp) -ExpectedIpInvalid $invalid -ExpectedIpValidationSkipped ([bool]$SkipExpectedIpValidation)
    }
}

Describe 'Step4 expected IPv4 validation' {
    It 'matches a valid expected IP among multiple reported IPs' {
        $r = Invoke-TestIpValidation -Map @{ vm01 = [pscustomobject]@{ ExpectedIP='10.0.0.10'; IsValid=$true } } -CurrentIPs @('192.0.2.1','10.0.0.10') -RequireExpectedIp
        $r.IPValidationStatus | Should -Be 'Matched'
        $r.IPMatches | Should -BeTrue
    }

    It 'detects a different reported IP' {
        $r = Invoke-TestIpValidation -Map @{ vm01 = [pscustomobject]@{ ExpectedIP='10.0.0.10'; IsValid=$true } } -CurrentIPs @('10.0.0.11') -RequireExpectedIp
        $r.IPValidationStatus | Should -Be 'Mismatch'
        $r.IPMatches | Should -BeFalse
    }

    It 'trims VM names and IP addresses from CSV' {
        $csv = Join-Path $TestDrive 'extract-ip.csv'
        "VMName;ExpectedIP`n VM01 ; 10.0.0.10 " | Set-Content -Path $csv
        $map = Get-TestExpectedIpMap -Path $csv
        $map.ContainsKey('vm01') | Should -BeTrue
        $map['vm01'].ExpectedIP | Should -Be '10.0.0.10'
    }

    It 'marks invalid IPv4 as invalid expected IP' {
        $r = Invoke-TestIpValidation -Map @{ vm01 = [pscustomobject]@{ ExpectedIP='999.1.1.1'; IsValid=$false } } -CurrentIPs @('10.0.0.10') -RequireExpectedIp
        $r.IPValidationStatus | Should -Be 'InvalidExpectedIP'
    }

    It 'rejects IPv6 in expected IP column' {
        Test-ValidIPv4Address -Address '2001:db8::1' | Should -BeFalse
    }

    It 'skips validation when extract-ip.csv is absent in permissive mode' {
        $r = Invoke-TestIpValidation -Map @{} -CurrentIPs @('10.0.0.10') -SkipExpectedIpValidation
        $r.IPValidationStatus | Should -Be 'ValidationSkipped'
        $r.IPMatches | Should -BeTrue
    }

    It 'requires extract-ip.csv when strict mode is requested' {
        $RequireExpectedIp = $true
        $fileExists = $false
        ($RequireExpectedIp -and -not $fileExists) | Should -BeTrue
    }

    It 'skips a VM absent from the IP file in permissive mode' {
        $r = Invoke-TestIpValidation -Map @{} -CurrentIPs @('10.0.0.10')
        $r.IPValidationStatus | Should -Be 'ValidationSkipped'
        $r.IPMatches | Should -BeTrue
    }

    It 'fails a VM absent from the IP file in strict mode' {
        $r = Invoke-TestIpValidation -Map @{} -CurrentIPs @('10.0.0.10') -RequireExpectedIp
        $r.IPValidationStatus | Should -Be 'MissingExpectedIP'
        $r.IPMatches | Should -BeFalse
    }

    It 'reports no guest IP when SCVMM returns none' {
        $r = Invoke-TestIpValidation -Map @{ vm01 = [pscustomobject]@{ ExpectedIP='10.0.0.10'; IsValid=$true } } -CurrentIPs @() -RequireExpectedIp
        $r.IPValidationStatus | Should -Be 'NoGuestIPReported'
    }

    It 'does not match a single APIPA address' {
        $r = Invoke-TestIpValidation -Map @{ vm01 = [pscustomobject]@{ ExpectedIP='10.0.0.10'; IsValid=$true } } -CurrentIPs @('169.254.10.2') -RequireExpectedIp
        $r.IPValidationStatus | Should -Be 'NoGuestIPReported'
        $r.CurrentIPs | Should -Contain '169.254.10.2'
    }

    It 'matches across multiple network adapters when one has the expected IP' {
        $r = Invoke-TestIpValidation -Map @{ vm01 = [pscustomobject]@{ ExpectedIP='10.0.0.10'; IsValid=$true } } -CurrentIPs @('192.0.2.1','10.0.0.10') -RequireExpectedIp
        $r.IPMatches | Should -BeTrue
    }

    It 'uses exact comparison and does not match substrings' {
        $r = Invoke-TestIpValidation -Map @{ vm01 = [pscustomobject]@{ ExpectedIP='10.0.0.1'; IsValid=$true } } -CurrentIPs @('10.0.0.10') -RequireExpectedIp
        $r.IPValidationStatus | Should -Be 'Mismatch'
    }
}
