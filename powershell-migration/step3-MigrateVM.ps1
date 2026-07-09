<#
.SYNOPSIS
    Execute Instant Recovery, network configuration, and post-migration setup for a single VM.

.DESCRIPTION
    The core step3 migration script invoked per-VM (directly or via worker-step3.ps1).
    Starts the Veeam Instant Recovery mount, finalizes it (commit), configures the
    Hyper-V VM networking (VLAN, IP), applies OS-level post-migration changes, and
    cleans up the Veeam mount session.

.PARAMETER BackupJobName
    Name of the Veeam backup job. Mandatory.

.PARAMETER VMName
    Target VM name. Mandatory.

.PARAMETER VlanId
    VLAN ID for the restored VM. Mandatory.

.PARAMETER AdapterVlanMapJson
    JSON object mapping adapter names to VLAN IDs for multi-NIC VMs.

.PARAMETER OperatingSystem
    Guest OS identifier (e.g. Windows, Linux) for OS-specific configuration.

.PARAMETER Remark
    Additional notes from the CSV for operational context.

.PARAMETER SCVMMServer
    SCVMM server name. Defaults to Config.SCVMM.Server.

.PARAMETER HyperVHost
    Primary Hyper-V host. Auto-resolved from migration target if not provided.

.PARAMETER HyperVHost2
    Secondary Hyper-V host for host affinity configuration.

.PARAMETER HyperVCluster
    Hyper-V cluster name. Auto-resolved from migration target if not provided.

.PARAMETER ClusterStorage
    Cluster shared volume path. Auto-resolved from migration target if not provided.

.PARAMETER VmwareCluster
    Source VMware cluster name for migration target resolution.

.PARAMETER BackupTag
    Veeam backup tag for restore point selection. Defaults to Config.Tags.BackupTag.

.PARAMETER WaitingTimeoutSeconds
    Maximum wait time for mount operations. Default: 1800.

.PARAMETER WaitingPollIntervalSeconds
    Poll interval for mount operations. Default: 15.

.PARAMETER ForceNetworkConfigOnly
    Skip Instant Recovery and run only network/OS post-configuration.

.PARAMETER SkipInstantRecoveryStart
    Skip starting the Instant Recovery mount.

.PARAMETER SkipInstantRecoveryFinalization
    Skip finalizing (committing) the Instant Recovery mount.

.PARAMETER SkipNetworkAndPostConfig
    Skip network configuration and OS post-migration steps.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step3-MigrateVM.ps1 -BackupJobName Backup-HypMig-lot-118 -VMName SRV-WEB01 -VlanId 100 -HyperVHost hv01 -ClusterStorage C:\ClusterStorage\Volume1

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with Veeam.Backup.PowerShell and VirtualMachineManager modules.
    Refactored in BEA-261/268: internal functions moved to step3/ modules;
    this script is now a pure orchestrator (~150 lines).
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$BackupJobName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$VlanId,
    [string]$AdapterVlanMapJson,

    [string]$OperatingSystem,
    [string]$Remark,
    [string]$SCVMMServer,
    [string]$HyperVHost,
    [string]$HyperVHost2,
    [string]$HyperVCluster,
    [string]$ClusterStorage,
    [string]$VmwareCluster,
    [string]$BackupTag,
    [int]$WaitingTimeoutSeconds = 1800,
    [int]$WaitingPollIntervalSeconds = 15,
    [switch]$ForceNetworkConfigOnly,
    [switch]$SkipInstantRecoveryStart,
    [switch]$SkipInstantRecoveryFinalization,
    [switch]$SkipNetworkAndPostConfig,
    [string]$LogFile
)

# ── Bootstrap ────────────────────────────────────────────────────────────────
. "$PSScriptRoot\lib.ps1"
Get-ChildItem "$PSScriptRoot\step3\Step3.*.ps1" |
    Where-Object Name -ne 'Step3.ScvmmSession.Functions.ps1' |
    ForEach-Object { . $_.FullName }

Initialize-ScvmmSessionFunction -FunctionFiles @(
    "$PSScriptRoot\step3\Step3.ScvmmSession.Functions.ps1"
)

$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $SCVMMServer)   { $SCVMMServer   = $Config.SCVMM.Server }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step3-migrate-$VMName-$(Get-Date -Format 'yyyyMMdd').log" }

$resolvedMigrationTarget = Resolve-MigrationTarget -Config $Config -VmwareClusterName $VmwareCluster -LogFile $LogFile
if (-not $HyperVHost)    { $HyperVHost    = $resolvedMigrationTarget.HyperVHost }
if (-not $HyperVHost2)   { $HyperVHost2   = $resolvedMigrationTarget.HyperVHost2 }
if (-not $HyperVCluster) { $HyperVCluster = $resolvedMigrationTarget.HyperVCluster }
if (-not $ClusterStorage){ $ClusterStorage = $resolvedMigrationTarget.ClusterStorage }
if (-not $BackupTag)     { $BackupTag     = $Config.Tags.BackupTag }

if ($ForceNetworkConfigOnly) {
    $SkipInstantRecoveryStart = $true
    $SkipInstantRecoveryFinalization = $true
}

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback
if (-not $SkipInstantRecoveryStart -or -not $SkipInstantRecoveryFinalization) {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
} else {
    Write-MigrationLog "[$VMName] Instant Recovery start/finalization disabled: skipping Veeam module import." -LogFile $LogFile
}

# ── SCVMM connection ──────────────────────────────────────────────────────────
$VMMServerName = Connect-Step3Scvmm -SCVMMServer $SCVMMServer -VMName $VMName -LogFile $LogFile

# ── Veeam Instant Recovery ────────────────────────────────────────────────────
try {
    Invoke-VeeamRecoveryPhase -BackupJobName $BackupJobName `
        -VMName $VMName `
        -HyperVHost $HyperVHost `
        -ClusterStorage $ClusterStorage `
        -SCVMMServer $SCVMMServer `
        -VMMServerName $VMMServerName `
        -SkipInstantRecoveryStart:$SkipInstantRecoveryStart `
        -SkipInstantRecoveryFinalization:$SkipInstantRecoveryFinalization `
        -WaitingTimeoutSeconds $WaitingTimeoutSeconds `
        -WaitingPollIntervalSeconds $WaitingPollIntervalSeconds `
        -LogFile $LogFile
} catch {
    Write-MigrationLog "[$VMName] Veeam recovery phase failed: $_" -Level ERROR -LogFile $LogFile
    throw
}

# ── Network mapping & post-configuration ──────────────────────────────────────
if ($ForceNetworkConfigOnly) {
    Write-MigrationLog "[$VMName] ForceNetworkConfigOnly enabled: skipping Instant Recovery/finalization and replaying only network/OS/post-configuration actions." -Level WARNING -LogFile $LogFile
}

if ($SkipNetworkAndPostConfig) {
    Write-MigrationLog "[$VMName] SkipNetworkAndPostConfig enabled: Instant Recovery phase completed; network/post-configuration skipped." -Level WARNING -LogFile $LogFile
    Write-MigrationLog "[$VMName] Migration completed (Instant Recovery only mode)." -Level SUCCESS -LogFile $LogFile
    return
}

$adapterVlanMappings = @()
if (-not [string]::IsNullOrWhiteSpace($AdapterVlanMapJson)) {
    try {
        $parsedMappings = ConvertFrom-Json -InputObject $AdapterVlanMapJson -ErrorAction Stop
        if ($parsedMappings) {
            $adapterVlanMappings = @($parsedMappings)
        }
    } catch {
        Write-MigrationLog "[$VMName] Unable to parse adapter VLAN mapping payload. Falling back to default VLAN '$VlanId'. Details: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
    }
}

Set-VmNetworkConfiguration `
    -Name $VMName `
    -ServerName $VMMServerName `
    -Vlan $VlanId `
    -AdapterVlanMappings $adapterVlanMappings `
    -SourceRemark $Remark `
    -Config $Config `
    -LogFile $LogFile

Set-SCVMMOperatingSystem -Name $VMName -ServerName $VMMServerName -SourceOperatingSystem $OperatingSystem -OperatingSystemMap $Config.SCVMM.OperatingSystemMap -LogFile $LogFile

Register-VmHighAvailability -Name $VMName -ServerName $VMMServerName -ClusterName $HyperVCluster -LogFile $LogFile

Move-VmToSecondHost -Name $VMName -ServerName $VMMServerName -DestinationHost $HyperVHost2 -LogFile $LogFile

Set-VmBackupTag -Name $VMName -ServerName $VMMServerName -TagName $BackupTag -LogFile $LogFile

Write-MigrationLog "[$VMName] Migration completed." -Level SUCCESS -LogFile $LogFile