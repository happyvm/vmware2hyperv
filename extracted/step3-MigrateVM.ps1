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

# ── Instant Recovery : démarrage ─────────────────────────────────────────────

Write-Log "[$VMName] Vérification SCVMM dans Veeam..." -LogFile $LogFile
$VBRSCVMM = Get-VBRServer | Where-Object { $_.Name -eq $SCVMMServer -and $_.Type -eq "Scvmm" }
if (!$VBRSCVMM) {
    Write-Log "[$VMName] SCVMM $SCVMMServer n'est pas enregistré dans Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}

$RestorePoint = Get-VBRRestorePoint | Where-Object { $_.GetBackup().Name -eq $BackupJobName -and $_.Name -eq $VMName }
if (!$RestorePoint) {
    Write-Log "[$VMName] Aucun point de restauration trouvé dans le job $BackupJobName." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-Log "[$VMName] Démarrage Instant Recovery..." -LogFile $LogFile
try {
    Start-VBRHvInstantRecovery -RestorePoint $RestorePoint -Server $HyperVHost -Path "$ClusterStorage\$VMName" -PowerUp $false -NICsEnabled $true -PreserveMACs $true -PreserveVmID $true
    Write-Log "[$VMName] Instant Recovery lancé." -Level SUCCESS -LogFile $LogFile

    $elapsed = 0
    do {
        $waitingVmNames = Get-VBRInstantRecovery |
            Where-Object { $_.State -eq "WaitingForUserAction" } |
            Select-Object -ExpandProperty VMName

        if ($waitingVmNames -contains $VMName) {
            Write-Log "[$VMName] State=WaitingForUserAction atteint." -Level SUCCESS -LogFile $LogFile
            break
        }

        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $elapsed += $WaitingPollIntervalSeconds
    } while ($elapsed -lt $WaitingTimeoutSeconds)

    if ($elapsed -ge $WaitingTimeoutSeconds) {
        throw "Timeout de $WaitingTimeoutSeconds secondes atteint en attente de WaitingForUserAction."
    }
} catch {
    Write-Log "[$VMName] Erreur Instant Recovery : $_" -Level ERROR -LogFile $LogFile
    throw
}

# ── Instant Recovery : finalisation ─────────────────────────────────────────

$VMMServer = Get-SCVMMServer -ComputerName $SCVMMServer

$IRSession = Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $VMName }
if (!$IRSession) {
    Write-Log "[$VMName] Aucune session Instant Recovery active." -Level ERROR -LogFile $LogFile
    exit 1
}

$vmInScvmm = Get-SCVirtualMachine -Name $VMName -VMMServer $VMMServer
if (!$vmInScvmm) {
    Write-Log "[$VMName] VM absente de SCVMM, finalisation impossible." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-Log "[$VMName] Finalisation Instant Recovery..." -LogFile $LogFile
try {
    Start-VBRHvInstantRecoveryMigration -InstantRecovery $IRSession
    Write-Log "[$VMName] Finalisation complète." -Level SUCCESS -LogFile $LogFile
} catch {
    Write-Log "[$VMName] Erreur finalisation : $_" -Level ERROR -LogFile $LogFile
    throw
}

# ── Mapping réseau ────────────────────────────────────────────────────────────

Write-Log "[$VMName] Configuration réseau (VLAN $VlanId)..." -LogFile $LogFile

if ($VlanId -notmatch "^\d+$") {
    Write-Log "[$VMName] VLAN ID invalide : '$VlanId' — mapping réseau ignoré." -Level WARNING -LogFile $LogFile
} else {
    $requiredConfigPaths = @(
        @{ Path = "SCVMM.Network.PortClassificationName"; Value = $Config.SCVMM.Network.PortClassificationName },
        @{ Path = "SCVMM.Network.LogicalSwitchName";      Value = $Config.SCVMM.Network.LogicalSwitchName }
    )
    foreach ($requiredConfig in $requiredConfigPaths) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredConfig.Value)) {
            throw "Configuration invalide : la clé '$($requiredConfig.Path)' est absente ou vide dans config.psd1."
        }
    }

    $VMNetworks         = Get-SCVMNetwork -VMMServer $VMMServer
    $VMSubnets          = Get-SCVMSubnet -VMMServer $VMMServer
    $PortClassification = Get-SCPortClassification -VMMServer $VMMServer | Where-Object { $_.Name -eq $Config.SCVMM.Network.PortClassificationName }

    $MatchingVMNetwork = $VMNetworks | Where-Object { $_.Name -like "*$VlanId*" -or $_.Description -like "*$VlanId*" }
    $MatchingVMSubnet  = $VMSubnets  | Where-Object { $_.Name -like "*$VlanId*" -or $_.Description -like "*$VlanId*" }

    if (!$MatchingVMNetwork -or !$MatchingVMSubnet) {
        Write-Log "[$VMName] Aucun VMNetwork/VMSubnet trouvé pour VLAN $VlanId." -Level WARNING -LogFile $LogFile
    } else {
        $TargetVM = Get-SCVirtualMachine -Name $VMName -VMMServer $VMMServer | Where-Object { $_.VirtualizationPlatform -eq "HyperV" }
        if (!$TargetVM) {
            Write-Log "[$VMName] VM non trouvée dans SCVMM." -Level WARNING -LogFile $LogFile
        } else {
            $NetworkAdapter = Get-SCVirtualNetworkAdapter -VM $TargetVM
            Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $NetworkAdapter -VMNetwork $MatchingVMNetwork -VMSubnet $MatchingVMSubnet -VLanEnabled $true -VLanID $VlanId -VirtualNetwork $Config.SCVMM.Network.LogicalSwitchName -IPv4AddressType Dynamic -IPv6AddressType Dynamic -PortClassification $PortClassification | Out-Null
            Write-Log "[$VMName] Réseau configuré (VLAN $VlanId, VMNetwork $($MatchingVMNetwork.Name))." -Level SUCCESS -LogFile $LogFile

            Set-SCVirtualMachine -VM $TargetVM -EnableOperatingSystemShutdown $true -EnableTimeSynchronization $false -EnableDataExchange $true -EnableHeartbeat $true -EnableBackup $true -EnableGuestServicesInterface $true | Out-Null
            Write-Log "[$VMName] Integration Services configurés." -LogFile $LogFile

            try {
                Add-ClusterVirtualMachineRole -Cluster $HyperVCluster -VirtualMachine $TargetVM.Name
                Write-Log "[$VMName] VM intégrée au cluster $HyperVCluster." -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-Log "[$VMName] Erreur cluster : $_" -Level ERROR -LogFile $LogFile
            }

            try {
                Move-VM -Name $TargetVM.Name -DestinationHost $HyperVHost2
                Write-Log "[$VMName] LiveMigration vers $HyperVHost2 effectuée." -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-Log "[$VMName] Erreur LiveMigration : $_" -Level ERROR -LogFile $LogFile
            }

            Set-SCVirtualMachine -VM $TargetVM -Tag $BackupTag | Out-Null
            Write-Log "[$VMName] Tag backup '$BackupTag' appliqué." -LogFile $LogFile
        }
    }
}

Write-Log "[$VMName] Migration complète." -Level SUCCESS -LogFile $LogFile
