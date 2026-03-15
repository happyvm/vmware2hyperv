#requires -Version 7.0

param (
    [Parameter(Mandatory = $true)]
    [string]$BackupJobName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$VlanId,

    [string]$SCVMMServer,
    [string]$HyperVHost,
    [string]$HyperVHost2,
    [string]$HyperVCluster,
    [string]$ClusterStorage,
    [string]$BackupTag,
    [string]$Tag,
    [int]$WaitingTimeoutSeconds = 1800,
    [int]$WaitingPollIntervalSeconds = 15,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $SCVMMServer)   { $SCVMMServer   = $Config.SCVMM.Server }
if (-not $HyperVHost)    { $HyperVHost    = $Config.HyperV.Host1 }
if (-not $HyperVHost2)   { $HyperVHost2   = $Config.HyperV.Host2 }
if (-not $HyperVCluster) { $HyperVCluster = $Config.HyperV.Cluster }
if (-not $ClusterStorage){ $ClusterStorage = $Config.HyperV.ClusterStorage }
if (-not $BackupTag)     { $BackupTag     = $Config.Tags.BackupTag }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step3-migrate-$VMName-$(Get-Date -Format 'yyyyMMdd').log" }

Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

# ── Instant Recovery: start ─────────────────────────────────────────────

Write-Log "[$VMName] Checking SCVMM in Veeam..." -LogFile $LogFile
$VBRSCVMM = Get-VBRServer | Where-Object { $_.Name -eq $SCVMMServer -and $_.Type -eq "Scvmm" }
if (!$VBRSCVMM) {
    Write-Log "[$VMName] SCVMM $SCVMMServer is not registered in Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}

$RestorePoint = Get-VBRRestorePoint | Where-Object { $_.GetBackup().Name -eq $BackupJobName -and $_.Name -eq $VMName }
if (!$RestorePoint) {
    Write-Log "[$VMName] No restore point found in job $BackupJobName." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-Log "[$VMName] Starting Instant Recovery..." -LogFile $LogFile
try {
    Start-VBRHvInstantRecovery -RestorePoint $RestorePoint -Server $HyperVHost -Path "$ClusterStorage\$VMName" -PowerUp $false -NICsEnabled $true -PreserveMACs $true -PreserveVmID $true
    Write-Log "[$VMName] Instant Recovery started." -Level SUCCESS -LogFile $LogFile

    $elapsed = 0
    do {
        $waitingVmNames = Get-VBRInstantRecovery |
            Where-Object { $_.State -eq "WaitingForUserAction" } |
            Select-Object -ExpandProperty VMName

        if ($waitingVmNames -contains $VMName) {
            Write-Log "[$VMName] State=WaitingForUserAction reached." -Level SUCCESS -LogFile $LogFile
            break
        }

        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $elapsed += $WaitingPollIntervalSeconds
    } while ($elapsed -lt $WaitingTimeoutSeconds)

    if ($elapsed -ge $WaitingTimeoutSeconds) {
        throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for WaitingForUserAction."
    }
} catch {
    Write-Log "[$VMName] Instant Recovery error: $_" -Level ERROR -LogFile $LogFile
    throw
}

# ── Instant Recovery: finalization ─────────────────────────────────────────

$VMMServer = Get-SCVMMServer -ComputerName $SCVMMServer

$IRSession = Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $VMName }
if (!$IRSession) {
    Write-Log "[$VMName] No active Instant Recovery session." -Level ERROR -LogFile $LogFile
    exit 1
}

$vmInScvmm = Get-SCVirtualMachine -Name $VMName -VMMServer $VMMServer
if (!$vmInScvmm) {
    Write-Log "[$VMName] VM missing from SCVMM, finalization impossible." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-Log "[$VMName] Finalizing Instant Recovery..." -LogFile $LogFile
try {
    Start-VBRHvInstantRecoveryMigration -InstantRecovery $IRSession
    Write-Log "[$VMName] Finalization completed." -Level SUCCESS -LogFile $LogFile
} catch {
    Write-Log "[$VMName] Finalization error: $_" -Level ERROR -LogFile $LogFile
    throw
}

# ── Network mapping ────────────────────────────────────────────────────────────

Write-Log "[$VMName] Network configuration (VLAN $VlanId)..." -LogFile $LogFile

if ($VlanId -notmatch "^\d+$") {
    Write-Log "[$VMName] Invalid VLAN ID: '$VlanId' — network mapping skipped." -Level WARNING -LogFile $LogFile
} else {
    $requiredConfigPaths = @(
        @{ Path = "SCVMM.Network.PortClassificationName"; Value = $Config.SCVMM.Network.PortClassificationName },
        @{ Path = "SCVMM.Network.LogicalSwitchName";      Value = $Config.SCVMM.Network.LogicalSwitchName }
    )
    foreach ($requiredConfig in $requiredConfigPaths) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredConfig.Value)) {
            throw "Invalid configuration: key '$($requiredConfig.Path)' is missing or empty in config.psd1."
        }
    }

    $VMNetworks         = Get-SCVMNetwork -VMMServer $VMMServer
    $VMSubnets          = Get-SCVMSubnet -VMMServer $VMMServer
    $PortClassification = Get-SCPortClassification -VMMServer $VMMServer | Where-Object { $_.Name -eq $Config.SCVMM.Network.PortClassificationName }

    $MatchingVMNetwork = $VMNetworks | Where-Object { $_.Name -like "*$VlanId*" -or $_.Description -like "*$VlanId*" }
    $MatchingVMSubnet  = $VMSubnets  | Where-Object { $_.Name -like "*$VlanId*" -or $_.Description -like "*$VlanId*" }

    if (!$MatchingVMNetwork -or !$MatchingVMSubnet) {
        Write-Log "[$VMName] No VMNetwork/VMSubnet found for VLAN $VlanId." -Level WARNING -LogFile $LogFile
    } else {
        $TargetVM = Get-SCVirtualMachine -Name $VMName -VMMServer $VMMServer | Where-Object { $_.VirtualizationPlatform -eq "HyperV" }
        if (!$TargetVM) {
            Write-Log "[$VMName] VM not found in SCVMM." -Level WARNING -LogFile $LogFile
        } else {
            $NetworkAdapter = Get-SCVirtualNetworkAdapter -VM $TargetVM
            Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $NetworkAdapter -VMNetwork $MatchingVMNetwork -VMSubnet $MatchingVMSubnet -VLanEnabled $true -VLanID $VlanId -VirtualNetwork $Config.SCVMM.Network.LogicalSwitchName -IPv4AddressType Dynamic -IPv6AddressType Dynamic -PortClassification $PortClassification | Out-Null
            Write-Log "[$VMName] Network configured (VLAN $VlanId, VMNetwork $($MatchingVMNetwork.Name))." -Level SUCCESS -LogFile $LogFile

            Set-SCVirtualMachine -VM $TargetVM -EnableOperatingSystemShutdown $true -EnableTimeSynchronization $false -EnableDataExchange $true -EnableHeartbeat $true -EnableBackup $true -EnableGuestServicesInterface $true | Out-Null
            Write-Log "[$VMName] Integration Services configured." -LogFile $LogFile

            try {
                Add-ClusterVirtualMachineRole -Cluster $HyperVCluster -VirtualMachine $TargetVM.Name
                Write-Log "[$VMName] VM added to cluster $HyperVCluster." -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-Log "[$VMName] Cluster error: $_" -Level ERROR -LogFile $LogFile
            }

            try {
                Move-VM -Name $TargetVM.Name -DestinationHost $HyperVHost2
                Write-Log "[$VMName] LiveMigration to $HyperVHost2 performed." -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-Log "[$VMName] LiveMigration error: $_" -Level ERROR -LogFile $LogFile
            }

            Set-SCVirtualMachine -VM $TargetVM -Tag $BackupTag | Out-Null
            Write-Log "[$VMName] Backup tag '$BackupTag' applied." -LogFile $LogFile
        }
    }
}

Write-Log "[$VMName] Migration completed." -Level SUCCESS -LogFile $LogFile
