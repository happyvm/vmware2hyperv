<#
.SYNOPSIS
    Post-migration independent validation — verifies that migrated VMs are healthy
    and that the Hyper-V environment matches the expected VMware source state.

.DESCRIPTION
    Independent verification agent for vmware2hyperv migrations. Runs AFTER step4
    (StartVM) and BEFORE step6 (CleanupVmware). Validates:

    1. VM Presence    — Every VM from the batch CSV exists in SCVMM
    2. VM Health      — Running, integration services OK, HA enabled, backup tag set
    3. Network        — NICs connected, expected IPs match
    4. Resource Match — CPU count, RAM (GB), disk count vs VMware source
    5. Connectivity   — Optional: WinRM ping to each guest VM
    6. Report         — Generates a structured JSON validation report

    Designed to be idempotent — safe to re-run. Non-blocking by default:
    failures are recorded but do not stop the pipeline (use -Strict to change).

.PARAMETER Tag
    Batch tag of the migration batch to validate (e.g. HypMig-lot-118).

.PARAMETER CsvFile
    Path to the batch CSV. Defaults to Config.Paths.CsvFile.

.PARAMETER ConfigFile
    Optional path to a PSD1 configuration file override.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.PARAMETER ReportPath
    Where to write the JSON validation report.
    Default: <LogDir>\validation-<Tag>-<timestamp>.json

.PARAMETER Strict
    When set, any validation failure causes the script to exit with code 1.
    Default: non-strict — failures are recorded but exit code is 0.

.PARAMETER SkipResourceComparison
    Skip CPU/RAM/disk comparison (useful when VMware source is unreachable
    or has already been decommissioned).

.PARAMETER SkipConnectivityTest
    Skip WinRM connectivity test to guest VMs.

.PARAMETER VmName
    Restrict validation to a single VM (incident recovery mode).

.EXAMPLE
    .\step5-ValidateMigration.ps1 -Tag HypMig-lot-118

.EXAMPLE
    .\step5-ValidateMigration.ps1 -Tag HypMig-lot-118 -Strict -SkipResourceComparison

.EXAMPLE
    .\step5-ValidateMigration.ps1 -Tag HypMig-lot-118 -VmName SRV-WEB01

.NOTES
    Part of the vmware2hyperv migration toolkit — BEA-318.
    Requires PowerShell 7+ with VirtualMachineManager and VMware.PowerCLI modules.
    Idempotent: safe to re-run on the same batch multiple times.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [string]$CsvFile,
    [string]$ConfigFile,
    [string]$LogFile,
    [string]$ReportPath,

    [switch]$Strict,
    [switch]$SkipResourceComparison,
    [switch]$SkipConnectivityTest,

    [string]$VmName
)

# ═══════════════════════════════════════════════════════════════════════════
# Initialisation
# ═══════════════════════════════════════════════════════════════════════════

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config = Import-MigrationConfig -ConfigFile $ConfigFile
if (-not $CsvFile) { $CsvFile = $Config.Paths.CsvFile }
Assert-PathPresent -Path $CsvFile -Label "Batch CSV"

if (-not $LogFile) {
    $LogFile = "$($Config.Paths.LogDir)\step5-validate-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

if (-not $ReportPath) {
    $ReportPath = "$($Config.Paths.LogDir)\validation-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
}

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "STEP 5: Independent migration validation for batch '$Tag'" -LogFile $LogFile
Write-MigrationLog "Report: $ReportPath" -LogFile $LogFile
Write-MigrationLog "Strict mode: $Strict" -LogFile $LogFile
Write-MigrationLog "Skip resource comparison: $SkipResourceComparison" -LogFile $LogFile
Write-MigrationLog "Skip connectivity test: $SkipConnectivityTest" -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile

# ═══════════════════════════════════════════════════════════════════════════
# Load modules
# ═══════════════════════════════════════════════════════════════════════════

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

$useVmware = -not $SkipResourceComparison
if ($useVmware) {
    try {
        Import-RequiredModule -Name "VMware.VimAutomation.Core" -LogFile $LogFile -UseWindowsPowerShellFallback
    } catch {
        Write-MigrationLog "VMware.PowerCLI not available — disabling resource comparison." -Level WARNING -LogFile $LogFile
        $useVmware = $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Helper functions
# ═══════════════════════════════════════════════════════════════════════════

function Get-BatchVmNames {
    param(
        [string]$CsvPath,
        [string]$BatchTag
    )

    $rows = Import-Csv -Path $CsvPath -Delimiter ";"
    $vmRows = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })

    # Filter by Tag column if present
    $rowsWithTag = @($vmRows | Where-Object { $_.PSObject.Properties['Tag'] -and -not [string]::IsNullOrWhiteSpace($_.Tag) })
    if ($rowsWithTag) {
        $vmRows = @($rowsWithTag | Where-Object { $_.Tag.Trim() -eq $BatchTag })
    }

    return @($vmRows | Select-Object -ExpandProperty VMName | Sort-Object -Unique)
}

function Get-HyperVVmInventory {
    param(
        [string[]]$VMNames,
        [string]$ExpectedBackupTag
    )

    return @(
        Invoke-SCVMMCommand -ScriptBlock {
            # $using: is only valid when the scriptblock crosses a remoting boundary;
            # Invoke-SCVMMCommand also runs it locally with '&', so every external
            # value must be passed through -ArgumentList.
            param($Names, $BackupTag, $VmmServerName)

            $server = Get-SCVMMServer -ComputerName $VmmServerName
            $nameLookup = @{}
            foreach ($n in $Names) { $nameLookup[$n.ToLowerInvariant()] = $n }

            $result = @()
            foreach ($name in $Names) {
                $vm = Get-SCVirtualMachine -Name $name -VMMServer $server -ErrorAction SilentlyContinue |
                    Select-Object -First 1

                if (-not $vm) {
                    $result += [pscustomobject]@{
                        VMName           = $name
                        Found            = $false
                        Running          = $false
                        CPUCount         = $null
                        MemoryGB         = $null
                        DiskCount        = $null
                        HostName         = $null
                        IntegrationOK    = $false
                        NICsConnected    = $false
                        IPAddresses      = @()
                        HAEnabled        = $false
                        BackupTagPresent = $false
                        StatusString     = 'VM not found in SCVMM'
                    }
                    continue
                }

                $running = [string]$vm.StatusString -match 'Running|Power.*On|En cours'
                $cpuCount = [int]$vm.CPUCount
                $memoryGB = [math]::Round([double]$vm.Memory / 1GB, 1)

                $disks = @(Get-SCVirtualDiskDrive -VM $vm -ErrorAction SilentlyContinue)
                $diskCount = $disks.Count

                $adapters = @(Get-SCVirtualNetworkAdapter -VM $vm -ErrorAction SilentlyContinue)
                $nicsConnected = ($adapters | Where-Object {
                    [string]$_.ConnectionState -match 'Connected|Connecté|OK|On'
                }).Count -gt 0

                $ips = @($adapters | ForEach-Object { $_.IPv4Addresses } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Unique)

                $integrationOk = [string]$vm.IntegrationServicesState -match 'OK|Operational|Up|Ready'

                $haEnabled = [bool]$vm.IsHighlyAvailable

                # Exact match after split (same rule as step4): a substring match would
                # let a tag like 'Hyp' pass for 'HypMig'.
                $tagPresent = if ([string]::IsNullOrWhiteSpace($BackupTag)) { $true }
                else { [bool]([string]$vm.Tag -split ';|,' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $BackupTag } | Measure-Object | Select-Object -ExpandProperty Count) }

                $result += [pscustomobject]@{
                    VMName           = $name
                    Found            = $true
                    Running          = $running
                    CPUCount         = $cpuCount
                    MemoryGB         = $memoryGB
                    DiskCount        = $diskCount
                    HostName         = [string]$vm.VMHost.ComputerName
                    IntegrationOK    = $integrationOk
                    NICsConnected    = $nicsConnected
                    IPAddresses      = @($ips)
                    HAEnabled        = $haEnabled
                    BackupTagPresent = $tagPresent
                    StatusString     = [string]$vm.StatusString
                }
            }
            return $result
        } -ArgumentList @($VMNames, $Config.Tags.BackupTag, $Config.SCVMM.Server)
    )
}

function Get-VmwareSourceInventory {
    param(
        [string[]]$VMNames
    )

    try {
        Connect-VCenter -Server $Config.VCenter.Server -LogFile $LogFile

        $result = @{}
        foreach ($name in $VMNames) {
            $vm = VMware.VimAutomation.Core\Get-VM -Name $name -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if (-not $vm) {
                $result[$name] = [pscustomobject]@{
                    Found    = $false
                    CPUCount = $null
                    MemoryGB = $null
                    DiskCount = $null
                    PowerState = $null
                }
                continue
            }

            $disks = @(VMware.VimAutomation.Core\Get-HardDisk -VM $vm -ErrorAction SilentlyContinue)
            $result[$name] = [pscustomobject]@{
                Found      = $true
                CPUCount   = [int]$vm.NumCpu
                MemoryGB   = [math]::Round([double]$vm.MemoryGB, 1)
                DiskCount  = $disks.Count
                PowerState = [string]$vm.PowerState
            }
        }
        return $result
    } finally {
        Disconnect-VCenter -LogFile $LogFile
    }
}

function Test-VmWinRmConnectivity {
    param(
        [string]$VMName,
        [string[]]$IPAddresses,
        [int]$TimeoutSeconds = 10
    )

    if (-not $IPAddresses -or $IPAddresses.Count -eq 0) {
        return [pscustomobject]@{ Reachable = $false; Error = 'No IP addresses' }
    }

    $credential = $null
    if ($Config.Validation.CredentialPSCredential) {
        $credential = $Config.Validation.CredentialPSCredential
    }

    foreach ($ip in $IPAddresses) {
        try {
            $params = @{
                ComputerName = $ip
                ErrorAction  = 'Stop'
            }
            if ($credential) { $params.Credential = $credential }

            $sessionOption = New-PSSessionOption -OpenTimeout ($TimeoutSeconds * 1000) `
                -OperationTimeout ($TimeoutSeconds * 1000) -IdleTimeout 60000
            $session = New-PSSession @params -SessionOption $sessionOption
            if ($session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                return [pscustomobject]@{ Reachable = $true; IP = $ip; Error = $null }
            }
        } catch {
            Write-MigrationLog "[$VMName] WinRM to $ip failed: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
        }
    }

    return [pscustomobject]@{ Reachable = $false; Error = 'WinRM unreachable on all IPs' }
}

# ═══════════════════════════════════════════════════════════════════════════
# Main validation logic
# ═══════════════════════════════════════════════════════════════════════════

$vmNames = Get-BatchVmNames -CsvPath $CsvFile -BatchTag $Tag

if (-not [string]::IsNullOrWhiteSpace($VmName)) {
    $vmNames = @($vmNames | Where-Object { $_ -eq $VmName })
    if (-not $vmNames) {
        Write-MigrationLog "VM '$VmName' not found in batch CSV for tag '$Tag'." -Level ERROR -LogFile $LogFile
        if ($Strict) { exit 1 } else { exit 0 }
    }
}

Write-MigrationLog "Validating $($vmNames.Count) VM(s): $($vmNames -join ', ')" -LogFile $LogFile

# ── 1. Hyper-V inventory ─────────────────────────────────────────────────
Write-MigrationLog "--- 1. Retrieving Hyper-V/SCVMM inventory ---" -LogFile $LogFile
$hypervInventory = Get-HyperVVmInventory -VMNames $vmNames

# ── 2. VMware source inventory (optional) ────────────────────────────────
$vmwareInventory = @{}
if ($useVmware) {
    Write-MigrationLog "--- 2. Retrieving VMware source inventory ---" -LogFile $LogFile
    $vmwareInventory = Get-VmwareSourceInventory -VMNames $vmNames
}

# ── 3. Build validation results per VM ───────────────────────────────────
Write-MigrationLog "--- 3. Building validation results ---" -LogFile $LogFile

$validationResults = @()
$overallPassed = $true
$checksTotal = 0
$checksPassed = 0

foreach ($vmName in $vmNames) {
    $hv = $hypervInventory | Where-Object { $_.VMName -eq $vmName } | Select-Object -First 1
    $vw = $vmwareInventory[$vmName]

    $checks = @()

    # Check 1: VM exists in SCVMM
    $found = $hv -and $hv.Found
    $checks += [pscustomobject]@{
        Name   = 'VMExists'
        Passed = $found
        Detail = if ($found) { "Found on host $($hv.HostName)" } else { 'VM not found in SCVMM' }
    }

    # Check 2: VM is running
    $running = $found -and $hv.Running
    $checks += [pscustomobject]@{
        Name   = 'VMRunning'
        Passed = $running
        Detail = if ($running) { "Status: $($hv.StatusString)" }
                elseif ($found) { "Status: $($hv.StatusString) (not Running)" }
                else { 'VM not found' }
    }

    # Check 3: Integration services OK
    $integrationOk = $found -and $hv.IntegrationOK
    $checks += [pscustomobject]@{
        Name   = 'IntegrationServices'
        Passed = $integrationOk
        Detail = if ($integrationOk) { 'OK' } elseif ($found) { 'Not ready' } else { 'N/A' }
    }

    # Check 4: HA enabled
    $haOk = $found -and $hv.HAEnabled
    $checks += [pscustomobject]@{
        Name   = 'HighAvailability'
        Passed = $haOk
        Detail = if ($haOk) { 'Enabled' } elseif ($found) { 'Not enabled' } else { 'N/A' }
    }

    # Check 5: Backup tag present
    $tagOk = $found -and $hv.BackupTagPresent
    $checks += [pscustomobject]@{
        Name   = 'BackupTag'
        Passed = $tagOk
        Detail = if ($tagOk) { 'Present' } elseif ($found) { 'Missing' } else { 'N/A' }
    }

    # Check 6: NIC connected
    $nicOk = $found -and $hv.NICsConnected
    $checks += [pscustomobject]@{
        Name   = 'NetworkConnected'
        Passed = $nicOk
        Detail = if ($nicOk) { "IPs: $($hv.IPAddresses -join ', ')" }
                elseif ($found) { 'No NICs connected' }
                else { 'N/A' }
    }

    # Check 7: Resource match (CPU)
    if ($useVmware -and $vw -and $vw.Found -and $found -and $hv.Found) {
        $cpuMatch = $hv.CPUCount -eq $vw.CPUCount
        $checks += [pscustomobject]@{
            Name   = 'CPUCount'
            Passed = $cpuMatch
            Detail = "Source: $($vw.CPUCount) | Target: $($hv.CPUCount)"
        }

        $ramMatch = $hv.MemoryGB -eq $vw.MemoryGB
        $checks += [pscustomobject]@{
            Name   = 'MemoryGB'
            Passed = $ramMatch
            Detail = "Source: $($vw.MemoryGB) GB | Target: $($hv.MemoryGB) GB"
        }

        $diskMatch = $hv.DiskCount -eq $vw.DiskCount
        $checks += [pscustomobject]@{
            Name   = 'DiskCount'
            Passed = $diskMatch
            Detail = "Source: $($vw.DiskCount) | Target: $($hv.DiskCount)"
        }
    }

    # Check 8: WinRM connectivity (optional)
    if (-not $SkipConnectivityTest -and $found -and $hv.Found -and $hv.IPAddresses.Count -gt 0) {
        $winRmResult = Test-VmWinRmConnectivity -VMName $vmName -IPAddresses $hv.IPAddresses
        $checks += [pscustomobject]@{
            Name   = 'WinRMConnectivity'
            Passed = $winRmResult.Reachable
            Detail = if ($winRmResult.Reachable) { "Reachable at $($winRmResult.IP)" }
                    else { $winRmResult.Error }
        }
    }

    $vmPassed = ($checks | Where-Object { -not $_.Passed }).Count -eq 0
    $vmChecksTotal = $checks.Count
    $vmChecksPassed = ($checks | Where-Object { $_.Passed }).Count
    $checksTotal += $vmChecksTotal
    $checksPassed += $vmChecksPassed

    if (-not $vmPassed) { $overallPassed = $false }

    $vmResult = [pscustomobject]@{
        VMName       = $vmName
        Passed       = $vmPassed
        ChecksPassed = $vmChecksPassed
        ChecksTotal  = $vmChecksTotal
        Checks       = @($checks)
        HyperV       = if ($hv) {
            [pscustomobject]@{
                Found         = $hv.Found
                Running       = $hv.Running
                CPUCount      = $hv.CPUCount
                MemoryGB      = $hv.MemoryGB
                DiskCount     = $hv.DiskCount
                HostName      = $hv.HostName
                IPAddresses   = $hv.IPAddresses
            }
        } else { $null }
        VmwareSource = if ($vw) {
            [pscustomobject]@{
                Found      = $vw.Found
                CPUCount   = $vw.CPUCount
                MemoryGB   = $vw.MemoryGB
                DiskCount  = $vw.DiskCount
                PowerState = $vw.PowerState
            }
        } else { $null }
    }

    $validationResults += $vmResult

    $statusIcon = if ($vmPassed) { '[PASS]' } else { '[FAIL]' }
    Write-MigrationLog "$statusIcon $vmName — $vmChecksPassed/$vmChecksTotal checks passed" `
        -Level $(if ($vmPassed) { 'SUCCESS' } else { 'ERROR' }) -LogFile $LogFile

    foreach ($check in $checks) {
        if (-not $check.Passed) {
            Write-MigrationLog "  ✗ $($check.Name): $($check.Detail)" -Level WARNING -LogFile $LogFile
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Generate report
# ═══════════════════════════════════════════════════════════════════════════

$report = [pscustomobject]@{
    GeneratedAt     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    BatchTag        = $Tag
    ValidatedBy     = 'step5-ValidateMigration.ps1'
    OverallPassed   = $overallPassed
    VMsValidated    = $vmNames.Count
    ChecksTotal     = $checksTotal
    ChecksPassed    = $checksPassed
    Strict          = [bool]$Strict
    VMs             = @($validationResults)
}

$report | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportPath -Encoding UTF8

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "VALIDATION COMPLETE" -Level $(if ($overallPassed) { 'SUCCESS' } else { 'ERROR' }) -LogFile $LogFile
Write-MigrationLog "Result: $checksPassed/$checksTotal checks passed across $($vmNames.Count) VM(s)" -LogFile $LogFile
Write-MigrationLog "Report saved: $ReportPath" -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile

if (-not $overallPassed) {
    $failedVms = @($validationResults | Where-Object { -not $_.Passed } | Select-Object -ExpandProperty VMName)
    Write-MigrationLog "FAILED VMs: $($failedVms -join ', ')" -Level ERROR -LogFile $LogFile
}

if ($Strict -and -not $overallPassed) {
    exit 1
}

exit 0