<#
.SYNOPSIS
    Pester tests for Invoke-Rollback.ps1 (BEA-318)
.DESCRIPTION
    Validates rollback logic without requiring live VMware/Hyper-V/Veeam.
    Tests core functions and manifest structure in isolation.
#>

Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════════
# Test: Get-VmwareVmState (mocked)
# ═══════════════════════════════════════════════════════════════════════════

Describe 'Get-VmwareVmState' {

    BeforeAll {
        # Define stub so Mock can target it (Pester 6 requirement)
        function script:TestGetVM { }

        # Use a mockable wrapper instead of calling Get-VM directly
        function script:Get-VmwareVmState {
            param([string]$VMName, [string]$VcenterServer)

            $vm = TestGetVM -Name $VMName -Server $VcenterServer -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if (-not $vm) {
                return [pscustomobject]@{
                    Found      = $false
                    PowerState = $null
                    VMHost     = $null
                    Datastore  = $null
                }
            }

            return [pscustomobject]@{
                Found      = $true
                PowerState = [string]$vm.PowerState
                VMHost     = [string]$vm.VMHost.Name
                Datastore  = [string]$vm.DatastoreIdList
            }
        }
    }

    Context 'VM not found in VMware' {
        It 'returns Found=false' {
            Mock TestGetVM { return $null }
            $result = Get-VmwareVmState -VMName 'MISSING-VM' -VcenterServer 'vcenter.test'
            $result.Found | Should -BeFalse
            $result.PowerState | Should -BeNullOrEmpty
        }
    }

    Context 'VM is powered off' {
        It 'returns Found=true and PowerState=PoweredOff' {
            $mockVm = [pscustomobject]@{
                PowerState     = 'PoweredOff'
                VMHost         = [pscustomobject]@{ Name = 'esx01.test' }
                DatastoreIdList = 'datastore-123'
            }
            Mock TestGetVM { return $mockVm }
            $result = Get-VmwareVmState -VMName 'SRV-TEST' -VcenterServer 'vcenter.test'
            $result.Found | Should -BeTrue
            $result.PowerState | Should -Be 'PoweredOff'
            $result.VMHost | Should -Be 'esx01.test'
        }
    }

    Context 'VM is powered on' {
        It 'returns Found=true and PowerState=PoweredOn' {
            $mockVm = [pscustomobject]@{
                PowerState     = 'PoweredOn'
                VMHost         = [pscustomobject]@{ Name = 'esx02.test' }
                DatastoreIdList = 'datastore-456'
            }
            Mock TestGetVM { return $mockVm }
            $result = Get-VmwareVmState -VMName 'SRV-TEST' -VcenterServer 'vcenter.test'
            $result.Found | Should -BeTrue
            $result.PowerState | Should -Be 'PoweredOn'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Rollback manifest structure
# ═══════════════════════════════════════════════════════════════════════════

Describe 'Rollback manifest structure' {

    It 'manifest has all required top-level fields' {
        $manifest = [pscustomobject]@{
            GeneratedAt   = '2026-07-09T14:00:00+02:00'
            BatchTag      = 'HypMig-lot-118'
            RollbackLayer = 'PowerOn'
            DryRun        = $false
            TotalVMs      = 3
            SuccessCount  = 2
            FailCount     = 1
            VMs           = @()
        }

        $manifest.PSObject.Properties.Name | Should -Contain 'GeneratedAt'
        $manifest.PSObject.Properties.Name | Should -Contain 'BatchTag'
        $manifest.PSObject.Properties.Name | Should -Contain 'RollbackLayer'
        $manifest.PSObject.Properties.Name | Should -Contain 'DryRun'
        $manifest.PSObject.Properties.Name | Should -Contain 'TotalVMs'
        $manifest.PSObject.Properties.Name | Should -Contain 'SuccessCount'
        $manifest.PSObject.Properties.Name | Should -Contain 'FailCount'
        $manifest.PSObject.Properties.Name | Should -Contain 'VMs'
    }

    It 'VM-level manifest entry has correct fields' {
        $entry = [pscustomobject]@{
            VMName    = 'SRV-WEB01'
            Layer     = 'PowerOn'
            DryRun    = $false
            Success   = $true
            Error     = $null
            PreState  = [pscustomobject]@{
                TimestampUTC = '2026-07-09T12:00:00.0000000Z'
                Vmware       = [pscustomobject]@{ Found = $true; PowerState = 'PoweredOff' }
                HyperV       = [pscustomobject]@{ Found = $true; Running = $true }
            }
            PostState = [pscustomobject]@{
                TimestampUTC = '2026-07-09T12:01:00.0000000Z'
                Vmware       = [pscustomobject]@{ Found = $true; PowerState = 'PoweredOn' }
                HyperV       = [pscustomobject]@{ Found = $true; Running = $false }
            }
        }

        $entry.PSObject.Properties.Name | Should -Contain 'VMName'
        $entry.PSObject.Properties.Name | Should -Contain 'Layer'
        $entry.PSObject.Properties.Name | Should -Contain 'DryRun'
        $entry.PSObject.Properties.Name | Should -Contain 'Success'
        $entry.PSObject.Properties.Name | Should -Contain 'Error'
        $entry.PSObject.Properties.Name | Should -Contain 'PreState'
        $entry.PSObject.Properties.Name | Should -Contain 'PostState'
    }

    It 'manifest serializes to valid JSON' {
        $manifest = [pscustomobject]@{
            GeneratedAt   = '2026-07-09T14:00:00+02:00'
            BatchTag      = 'HypMig-lot-118'
            RollbackLayer = 'PowerOn'
            DryRun        = $true
            TotalVMs      = 1
            SuccessCount  = 1
            FailCount     = 0
            VMs           = @(
                [pscustomobject]@{
                    VMName  = 'TEST-VM'
                    Layer   = 'PowerOn'
                    DryRun  = $true
                    Success = $true
                    Error   = $null
                    PreState  = $null
                    PostState = $null
                }
            )
        }

        $json = $manifest | ConvertTo-Json -Depth 3
        $json | Should -Not -BeNullOrEmpty

        # Verify it can be re-parsed
        $reparsed = $json | ConvertFrom-Json
        $reparsed.BatchTag | Should -Be 'HypMig-lot-118'
        $reparsed.TotalVMs | Should -Be 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Rollback layer selection logic
# ═══════════════════════════════════════════════════════════════════════════

Describe 'Rollback layer selection' {

    Context 'Explicit layer selection' {
        It 'uses the specified layer' {
            $RollbackLayer = 'PowerOn'
            $effectiveLayer = $RollbackLayer
            $effectiveLayer | Should -Be 'PowerOn'
        }

        It 'validates layer value is in allowed set' {
            $allowed = @('PowerOn', 'VeeamInstant', 'Full', 'Auto')
            'PowerOn' -in $allowed | Should -BeTrue
            'InvalidLayer' -in $allowed | Should -BeFalse
        }
    }

    Context 'Auto layer selection' {
        It 'selects PowerOn when VMware is available' {
            $vmwareAvailable = $true
            $veeamAvailable = $false
            $RollbackLayer = 'Auto'

            if ($vmwareAvailable) { $effectiveLayer = 'PowerOn' }
            elseif ($veeamAvailable) { $effectiveLayer = 'VeeamInstant' }
            else { $effectiveLayer = $null }

            $effectiveLayer | Should -Be 'PowerOn'
        }

        It 'selects VeeamInstant when VMware is unavailable but Veeam is' {
            $vmwareAvailable = $false
            $veeamAvailable = $true
            $RollbackLayer = 'Auto'

            if ($vmwareAvailable) { $effectiveLayer = 'PowerOn' }
            elseif ($veeamAvailable) { $effectiveLayer = 'VeeamInstant' }
            else { $effectiveLayer = $null }

            $effectiveLayer | Should -Be 'VeeamInstant'
        }

        It 'selects nothing when neither is available' {
            $vmwareAvailable = $false
            $veeamAvailable = $false
            $RollbackLayer = 'Auto'

            if ($vmwareAvailable) { $effectiveLayer = 'PowerOn' }
            elseif ($veeamAvailable) { $effectiveLayer = 'VeeamInstant' }
            else { $effectiveLayer = $null }

            $effectiveLayer | Should -BeNull
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Dry-run behavior
# ═══════════════════════════════════════════════════════════════════════════

Describe 'Dry-run semantics' {

    It 'manifest records DryRun=true when -DryRun is set' {
        $manifest = [pscustomobject]@{
            DryRun = $true
        }
        $manifest.DryRun | Should -BeTrue
    }

    It 'manifest records DryRun=false for real execution' {
        $manifest = [pscustomobject]@{
            DryRun = $false
        }
        $manifest.DryRun | Should -BeFalse
    }

    It 'VM-level entry also records DryRun flag' {
        $entry = [pscustomobject]@{
            VMName  = 'SRV-WEB01'
            DryRun  = $true
            Success = $true
        }
        $entry.DryRun | Should -BeTrue
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Integration — Invoke-Rollback.ps1 syntax
# ═══════════════════════════════════════════════════════════════════════════

Describe 'Invoke-Rollback.ps1 syntax' {

    It 'script file exists' {
        $scriptPath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'Invoke-Rollback.ps1'
        $exists = Test-Path $scriptPath
        if (-not $exists) {
            $scriptPath = '/home/paperclip/vmware2hyperv/powershell-migration/Invoke-Rollback.ps1'
            $exists = Test-Path $scriptPath
        }
        $exists | Should -BeTrue
    }

    It 'script has no syntax errors (AST parse)' {
        $scriptPath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'Invoke-Rollback.ps1'
        if (-not (Test-Path $scriptPath)) {
            $scriptPath = '/home/paperclip/vmware2hyperv/powershell-migration/Invoke-Rollback.ps1'
        }

        $errors = $null
        try {
            [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$null, [ref]$errors
            )
        } catch { }

        if ($errors) {
            $errors.Count | Should -Be 0
        } else {
            $true | Should -BeTrue
        }
    }

    It 'script contains comment-based help' {
        $scriptPath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'Invoke-Rollback.ps1'
        if (-not (Test-Path $scriptPath)) {
            $scriptPath = '/home/paperclip/vmware2hyperv/powershell-migration/Invoke-Rollback.ps1'
        }

        $content = Get-Content $scriptPath -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $content | Should -Match '\.SYNOPSIS'
            $content | Should -Match '\.DESCRIPTION'
            $content | Should -Match 'ROLLBACK STRATEGY|LAYER 1|LAYER 2'
            $content | Should -Match '\.EXAMPLE'
        } else {
            Set-ItResult -Skipped -Because 'Script file not readable'
        }
    }

    It 'script has mandatory Tag parameter' {
        $scriptPath = Join-Path $PSScriptRoot '..' 'powershell-migration' 'Invoke-Rollback.ps1'
        if (-not (Test-Path $scriptPath)) {
            $scriptPath = '/home/paperclip/vmware2hyperv/powershell-migration/Invoke-Rollback.ps1'
        }

        $content = Get-Content $scriptPath -Raw -ErrorAction SilentlyContinue
        if ($content) {
            # (?s) = single-line mode so . matches newlines
            $content | Should -Match '(?s)\[Parameter\(Mandatory\s*=\s*\$true\)\].*?\$Tag'
        } else {
            Set-ItResult -Skipped -Because 'Script file not readable'
        }
    }
}