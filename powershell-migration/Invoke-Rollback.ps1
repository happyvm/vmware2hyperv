<#
.SYNOPSIS
    Rollback strategy and execution for VMware → Hyper-V migrations.

.DESCRIPTION
    Implements the rollback strategy for vmware2hyperv (BEA-318).
    The strategy is layered — multiple safety nets, from fastest to most expensive:

    LAYER 1 — Power-On Rollback (fastest, ~seconds)
      Since the migration pipeline SHUTS DOWN VMware VMs (step2) but never
      deletes them (deletion is a separate step6), the original VMware VMs
      remain powered off. The primary rollback simply powers them back on
      and stops the Hyper-V copies.

    LAYER 2 — Veeam Instant Restore (~minutes)
      If a VMware VM was accidentally deleted or corrupted, the Veeam backup
      taken in step2 can be used to instant-restore the VM on VMware.

    LAYER 3 — Full Veeam Restore (~hours, last resort)
      For critical scenarios, a full Veeam restore from the backup repository.

    ROLLBACK MANIFEST:
      Every rollback operation produces a JSON manifest tracking:
      - Original VMware VM state (power, host, datastore)
      - Hyper-V VM state before rollback
      - Actions taken
      - Final state

.PARAMETER Tag
    Batch tag of the migration batch to roll back (e.g. HypMig-lot-118).

.PARAMETER VmName
    Restrict rollback to a single VM. If omitted, all VMs in the batch are rolled back.

.PARAMETER ConfigFile
    Optional path to a PSD1 configuration file override.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.PARAMETER ManifestDir
    Directory for rollback manifest files.
    Default: <LogDir>\rollback-manifests\

.PARAMETER DryRun
    Simulate the rollback without making any changes. Shows what WOULD happen.

.PARAMETER Force
    Skip confirmation prompts. Required for non-interactive/automated use.

.PARAMETER RollbackLayer
    Which rollback layer to use:
    - PowerOn (default): Power on VMware VMs, stop Hyper-V VMs
    - VeeamInstant: Use Veeam instant restore to recreate VMware VMs
    - Full: Full Veeam restore (slowest, most thorough)
    - Auto: Try layers in order (PowerOn → VeeamInstant → fail if neither works)

.EXAMPLE
    # Dry-run: see what would happen for a full batch rollback
    .\Invoke-Rollback.ps1 -Tag HypMig-lot-118 -DryRun

.EXAMPLE
    # Rollback a single VM
    .\Invoke-Rollback.ps1 -Tag HypMig-lot-118 -VmName SRV-WEB01 -Force

.EXAMPLE
    # Rollback using Veeam instant restore
    .\Invoke-Rollback.ps1 -Tag HypMig-lot-118 -RollbackLayer VeeamInstant -Force

.NOTES
    Part of the vmware2hyperv migration toolkit — BEA-318.
    Requires PowerShell 7+ with VMware.PowerCLI and VirtualMachineManager modules.
    Optional: Veeam.Backup.PowerShell for Layer 2/3 rollback.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [string]$VmName,
    [string]$ConfigFile,
    [string]$LogFile,
    [string]$ManifestDir,

    [switch]$DryRun,
    [switch]$Force,

    [ValidateSet('PowerOn', 'VeeamInstant', 'Full', 'Auto')]
    [string]$RollbackLayer = 'PowerOn'
)

# ═══════════════════════════════════════════════════════════════════════════
# Initialisation
# ═══════════════════════════════════════════════════════════════════════════

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config = Import-MigrationConfig -ConfigFile $ConfigFile

if (-not $LogFile) {
    $LogFile = "$($Config.Paths.LogDir)\rollback-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

if (-not $ManifestDir) {
    $ManifestDir = "$($Config.Paths.LogDir)\rollback-manifests"
}

if (-not (Test-Path $ManifestDir)) {
    New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null
}

$manifestPath = "$ManifestDir\rollback-$Tag-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "ROLLBACK initiated for batch '$Tag'" -LogFile $LogFile
Write-MigrationLog "Layer: $RollbackLayer" -LogFile $LogFile
Write-MigrationLog "DryRun: $DryRun" -LogFile $LogFile
Write-MigrationLog "VM filter: $(if ($VmName) { $VmName } else { 'ALL' })" -LogFile $LogFile
Write-MigrationLog "Manifest: $manifestPath" -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile

# ═══════════════════════════════════════════════════════════════════════════
# Confirmation (interactive safety)
# ═══════════════════════════════════════════════════════════════════════════

if (-not $DryRun -and -not $Force) {
    $scope = if ($VmName) { "VM '$VmName'" } else { "ALL VMs in batch '$Tag'" }
    Write-Host ""
    Write-Host "⚠️  ROLLBACK: $scope" -ForegroundColor Yellow
    Write-Host "   Layer: $RollbackLayer" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Type 'ROLLBACK' to confirm"
    if ($confirm -ne 'ROLLBACK') {
        Write-MigrationLog "Rollback cancelled by operator." -Level WARNING -LogFile $LogFile
        exit 0
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Load modules
# ═══════════════════════════════════════════════════════════════════════════

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

try {
    Import-RequiredModule -Name "VMware.VimAutomation.Core" -LogFile $LogFile -UseWindowsPowerShellFallback
    $vmwareAvailable = $true
} catch {
    Write-MigrationLog "VMware.PowerCLI not available — Layer 1 (PowerOn) rollback will not work." -Level WARNING -LogFile $LogFile
    $vmwareAvailable = $false
}

$veeamAvailable = $false
if ($RollbackLayer -in @('VeeamInstant', 'Full', 'Auto')) {
    try {
        Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
        $veeamAvailable = $true
    } catch {
        Write-MigrationLog "Veeam.Backup.PowerShell not available — Layer 2/3 rollback will not work." -Level WARNING -LogFile $LogFile
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Helper functions
# ═══════════════════════════════════════════════════════════════════════════

function Get-VmwareVmState {
    param(
        [string]$VMName,
        [string]$VcenterServer
    )

    $vm = VMware.VimAutomation.Core\Get-VM -Name $VMName -Server $VcenterServer -ErrorAction SilentlyContinue |
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

function Get-HyperVVmInfo {
    param(
        [string]$VMName
    )

    return Invoke-SCVMMCommand -ScriptBlock {
        param($Name)
        $vm = Get-SCVirtualMachine -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $vm) {
            return [pscustomobject]@{ Found = $false; Running = $false }
        }
        return [pscustomobject]@{
            Found   = $true
            Running = [string]$vm.StatusString -match 'Running|Power.*On|En cours'
            Host    = [string]$vm.VMHost.ComputerName
            ID      = [string]$vm.ID
        }
    } -ArgumentList @($VMName)
}

# ═══════════════════════════════════════════════════════════════════════════
# Layer 1: Power-On Rollback
# ═══════════════════════════════════════════════════════════════════════════

function Invoke-PowerOnRollback {
    param(
        [string]$VMName,
        [string]$VcenterServer
    )

    Write-MigrationLog "[$VMName] Layer 1 — Power-On Rollback" -LogFile $LogFile

    # 1. Check VMware VM state
    $vmwareState = Get-VmwareVmState -VMName $VMName -VcenterServer $VcenterServer

    if (-not $vmwareState.Found) {
        Write-MigrationLog "[$VMName] VMware VM not found — cannot perform Power-On rollback." -Level ERROR -LogFile $LogFile
        return [pscustomobject]@{
            VMName      = $VMName
            Layer       = 'PowerOn'
            Success     = $false
            Error       = 'VMware VM not found'
            VmwareState = $vmwareState
        }
    }

    Write-MigrationLog "[$VMName] VMware VM state: $($vmwareState.PowerState) on $($vmwareState.VMHost)" -LogFile $LogFile

    # 2. Check Hyper-V VM state
    $hypervInfo = Get-HyperVVmInfo -VMName $VMName

    # 3. Stop Hyper-V VM
    if ($hypervInfo.Found -and $hypervInfo.Running) {
        Write-MigrationLog "[$VMName] Stopping Hyper-V VM on $($hypervInfo.Host)..." -LogFile $LogFile

        if (-not $DryRun) {
            try {
                Invoke-SCVMMCommand -ScriptBlock {
                    param($Name)
                    $vm = Get-SCVirtualMachine -Name $Name -ErrorAction Stop | Select-Object -First 1
                    if (-not $vm) { throw "VM not found" }
                    Stop-SCVirtualMachine -VM $vm -Shutdown -ErrorAction Stop | Out-Null
                } -ArgumentList @($VMName)

                Write-MigrationLog "[$VMName] Hyper-V VM stopped." -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-MigrationLog "[$VMName] Failed to stop Hyper-V VM: $_" -Level ERROR -LogFile $LogFile

                # Try force stop
                try {
                    Invoke-SCVMMCommand -ScriptBlock {
                        param($Name)
                        $vm = Get-SCVirtualMachine -Name $Name -ErrorAction Stop | Select-Object -First 1
                        if ($vm) { Stop-SCVirtualMachine -VM $vm -Force -ErrorAction Stop | Out-Null }
                    } -ArgumentList @($VMName)
                    Write-MigrationLog "[$VMName] Hyper-V VM force-stopped." -Level SUCCESS -LogFile $LogFile
                } catch {
                    Write-MigrationLog "[$VMName] Force stop also failed: $_" -Level ERROR -LogFile $LogFile
                }
            }
        } else {
            Write-MigrationLog "[DRY-RUN] Would stop Hyper-V VM on $($hypervInfo.Host)" -LogFile $LogFile
        }
    } elseif ($hypervInfo.Found) {
        Write-MigrationLog "[$VMName] Hyper-V VM is already stopped." -LogFile $LogFile
    } else {
        Write-MigrationLog "[$VMName] Hyper-V VM not found in SCVMM — nothing to stop." -LogFile $LogFile
    }

    # 4. Start VMware VM
    if ($vmwareState.PowerState -eq 'PoweredOff') {
        Write-MigrationLog "[$VMName] Starting VMware VM on $($vmwareState.VMHost)..." -LogFile $LogFile

        if (-not $DryRun) {
            try {
                $vm = VMware.VimAutomation.Core\Get-VM -Name $VMName |
                    Where-Object { $_.PowerState -eq 'PoweredOff' } |
                    Select-Object -First 1
                if ($vm) {
                    Start-VM -VM $vm -ErrorAction Stop | Out-Null
                    Write-MigrationLog "[$VMName] VMware VM started." -Level SUCCESS -LogFile $LogFile
                } else {
                    Write-MigrationLog "[$VMName] No powered-off VMware VM found." -Level ERROR -LogFile $LogFile
                }
            } catch {
                Write-MigrationLog "[$VMName] Failed to start VMware VM: $_" -Level ERROR -LogFile $LogFile
                return [pscustomobject]@{
                    VMName      = $VMName
                    Layer       = 'PowerOn'
                    Success     = $false
                    Error       = "Failed to start VMware VM: $_"
                    VmwareState = $vmwareState
                    HyperVInfo  = $hypervInfo
                }
            }
        } else {
            Write-MigrationLog "[DRY-RUN] Would start VMware VM on $($vmwareState.VMHost)" -LogFile $LogFile
        }
    } elseif ($vmwareState.PowerState -eq 'PoweredOn') {
        Write-MigrationLog "[$VMName] VMware VM is already powered on." -LogFile $LogFile
    }

    return [pscustomobject]@{
        VMName      = $VMName
        Layer       = 'PowerOn'
        Success     = $true
        Error       = $null
        VmwareState = $vmwareState
        HyperVInfo  = $hypervInfo
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Layer 2: Veeam Instant Restore Rollback
# ═══════════════════════════════════════════════════════════════════════════

function Invoke-VeeamInstantRollback {
    param(
        [string]$VMName,
        [string]$BackupJobName
    )

    Write-MigrationLog "[$VMName] Layer 2 — Veeam Instant Restore Rollback" -LogFile $LogFile

    if (-not $veeamAvailable) {
        return [pscustomobject]@{
            VMName  = $VMName
            Layer   = 'VeeamInstant'
            Success = $false
            Error   = 'Veeam module not available'
        }
    }

    # Find the latest restore point
    if (-not $DryRun) {
        try {
            $restorePoint = Get-VBRRestorePoint -Name $VMName -ErrorAction Stop |
                Sort-Object -Property CreationTime -Descending |
                Select-Object -First 1

            if (-not $restorePoint) {
                return [pscustomobject]@{
                    VMName  = $VMName
                    Layer   = 'VeeamInstant'
                    Success = $false
                    Error   = 'No Veeam restore point found'
                }
            }

            Write-MigrationLog "[$VMName] Found restore point from $($restorePoint.CreationTime)" -LogFile $LogFile

            # Start instant recovery to VMware
            $server = Get-VBRServer -Type ESXi -ErrorAction Stop | Select-Object -First 1
            Start-VBRInstantRecovery -RestorePoint $restorePoint -Server $server -ErrorAction Stop

            Write-MigrationLog "[$VMName] Veeam instant recovery started." -Level SUCCESS -LogFile $LogFile
        } catch {
            Write-MigrationLog "[$VMName] Veeam instant restore failed: $_" -Level ERROR -LogFile $LogFile
            return [pscustomobject]@{
                VMName  = $VMName
                Layer   = 'VeeamInstant'
                Success = $false
                Error   = "$_"
            }
        }
    } else {
        Write-MigrationLog "[DRY-RUN] Would instant-restore $VMName via Veeam" -LogFile $LogFile
    }

    return [pscustomobject]@{
        VMName  = $VMName
        Layer   = 'VeeamInstant'
        Success = $true
        Error   = $null
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Main rollback orchestrator
# ═══════════════════════════════════════════════════════════════════════════

# Determine which VMs to roll back
$csvRows = Import-Csv -Path $Config.Paths.CsvFile -Delimiter ";"
$vmRows = @($csvRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMName) })

# Filter by Tag column if present
$rowsWithTag = @($vmRows | Where-Object { $_.PSObject.Properties['Tag'] -and -not [string]::IsNullOrWhiteSpace($_.Tag) })
if ($rowsWithTag) {
    $vmRows = @($rowsWithTag | Where-Object { $_.Tag.Trim() -eq $Tag })
}

$vmNames = @($vmRows | Select-Object -ExpandProperty VMName | Sort-Object -Unique)

if (-not [string]::IsNullOrWhiteSpace($VmName)) {
    $vmNames = @($vmNames | Where-Object { $_ -eq $VmName })
    if (-not $vmNames) {
        Write-MigrationLog "VM '$VmName' not found in batch CSV for tag '$Tag'." -Level ERROR -LogFile $LogFile
        exit 1
    }
}

if (-not $vmNames) {
    Write-MigrationLog "No VMs found for rollback." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-MigrationLog "Rolling back $($vmNames.Count) VM(s): $($vmNames -join ', ')" -LogFile $LogFile

if ($RollbackLayer -eq 'Auto') {
    if ($vmwareAvailable) {
        $effectiveLayer = 'PowerOn'
    } elseif ($veeamAvailable) {
        $effectiveLayer = 'VeeamInstant'
    } else {
        Write-MigrationLog "Auto rollback: no layer available (neither VMware nor Veeam module loaded)." -Level ERROR -LogFile $LogFile
        exit 1
    }
    Write-MigrationLog "Auto-selected rollback layer: $effectiveLayer" -LogFile $LogFile
} else {
    $effectiveLayer = $RollbackLayer
}

# Connect to VMware
if ($effectiveLayer -eq 'PowerOn' -and $vmwareAvailable) {
    Connect-VCenter -Server $Config.VCenter.Server -LogFile $LogFile
}

$results = @()
$successCount = 0
$failCount = 0

try {
    foreach ($vmName in $vmNames) {
        # Capture pre-rollback state
        $preState = [pscustomobject]@{
            TimestampUTC = (Get-Date).ToUniversalTime().ToString('o')
            Vmware = if ($vmwareAvailable) {
                Get-VmwareVmState -VMName $vmName -VcenterServer $Config.VCenter.Server
            } else { $null }
            HyperV = Get-HyperVVmInfo -VMName $vmName
        }

        # Execute rollback
        $result = switch ($effectiveLayer) {
            'PowerOn' {
                if (-not $vmwareAvailable) {
                    [pscustomobject]@{ VMName = $vmName; Layer = 'PowerOn'; Success = $false; Error = 'VMware module not available' }
                } else {
                    Invoke-PowerOnRollback -VMName $vmName -VcenterServer $Config.VCenter.Server
                }
            }
            'VeeamInstant' {
                Invoke-VeeamInstantRollback -VMName $vmName -BackupJobName "Backup-$Tag"
            }
            'Full' {
                Write-MigrationLog "[$VMName] Layer 3 — Full Veeam Restore (not yet implemented)" -Level WARNING -LogFile $LogFile
                [pscustomobject]@{ VMName = $vmName; Layer = 'Full'; Success = $false; Error = 'Full restore not implemented in this version' }
            }
        }

        # Capture post-rollback state
        $postState = [pscustomobject]@{
            TimestampUTC = (Get-Date).ToUniversalTime().ToString('o')
            Vmware = if ($vmwareAvailable) {
                Get-VmwareVmState -VMName $vmName -VcenterServer $Config.VCenter.Server
            } else { $null }
            HyperV = Get-HyperVVmInfo -VMName $vmName
        }

        $entry = [pscustomobject]@{
            VMName     = $vmName
            Layer      = $effectiveLayer
            DryRun     = [bool]$DryRun
            Success    = $result.Success
            Error      = $result.Error
            PreState   = $preState
            PostState  = $postState
        }
        $results += $entry

        if ($result.Success) { $successCount++ } else { $failCount++ }

        $icon = if ($result.Success) { '[OK]' } else { '[FAIL]' }
        Write-MigrationLog "$icon $vmName — Layer: $effectiveLayer" `
            -Level $(if ($result.Success) { 'SUCCESS' } else { 'ERROR' }) -LogFile $LogFile
    }
} finally {
    if ($effectiveLayer -eq 'PowerOn' -and $vmwareAvailable) {
        Disconnect-VCenter -LogFile $LogFile
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Generate manifest
# ═══════════════════════════════════════════════════════════════════════════

$manifest = [pscustomobject]@{
    GeneratedAt   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    BatchTag      = $Tag
    RollbackLayer = $effectiveLayer
    DryRun        = [bool]$DryRun
    TotalVMs      = $vmNames.Count
    SuccessCount  = $successCount
    FailCount     = $failCount
    VMs           = @($results)
}

$manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestPath -Encoding UTF8

Write-MigrationLog "======================================================" -LogFile $LogFile
Write-MigrationLog "ROLLBACK COMPLETE: $successCount succeeded, $failCount failed" `
    -Level $(if ($failCount -eq 0) { 'SUCCESS' } else { 'ERROR' }) -LogFile $LogFile
Write-MigrationLog "Manifest saved: $manifestPath" -LogFile $LogFile
Write-MigrationLog "======================================================" -LogFile $LogFile

if ($failCount -gt 0) { exit 1 }
exit 0