#requires -Version 7.0

param (
    [string]$VCenterServer,
    [string]$CsvFile,
    [string]$SCVMMServer,
    [string]$HyperVHost,
    [string]$HyperVHost2,
    [string]$HyperVCluster,
    [string]$ClusterStorage,
    [string]$BackupTag,
    [string]$Tag,      # Optionnel - pour contextualiser le log
    [string]$VMName,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $CsvFile)       { $CsvFile       = $Config.Paths.CsvFile }
if (-not $SCVMMServer)   { $SCVMMServer   = $Config.SCVMM.Server }
if (-not $HyperVHost)    { $HyperVHost    = $Config.HyperV.Host1 }
if (-not $HyperVHost2)   { $HyperVHost2   = $Config.HyperV.Host2 }
if (-not $HyperVCluster) { $HyperVCluster = $Config.HyperV.Cluster }
if (-not $ClusterStorage){ $ClusterStorage = $Config.HyperV.ClusterStorage }
if (-not $BackupTag)     { $BackupTag     = $Config.Tags.BackupTag }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step5-map-network$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }

$requiredConfigPaths = @(
    @{ Path = "SCVMM.Network.PortClassificationName"; Value = $Config.SCVMM.Network.PortClassificationName },
    @{ Path = "SCVMM.Network.LogicalSwitchName";      Value = $Config.SCVMM.Network.LogicalSwitchName }
)

foreach ($requiredConfig in $requiredConfigPaths) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredConfig.Value)) {
        $errorMessage = "Configuration invalide : la clé '$($requiredConfig.Path)' est absente ou vide dans config.psd1."
        Write-Log $errorMessage -Level ERROR -LogFile $LogFile
        throw $errorMessage
    }
}

Write-Log "Démarrage step5 - mapping réseau VMware → Hyper-V" -LogFile $LogFile
Assert-FileExists -Path $CsvFile -Label "CSV lotissement" -LogFile $LogFile

Write-Log "Connexion à vCenter..." -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

Write-Log "Connexion à SCVMM..." -LogFile $LogFile
Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback
$VMMServer = Get-SCVMMServer -ComputerName $SCVMMServer
Write-Log "Connexion à SCVMM réussie." -Level SUCCESS -LogFile $LogFile

Write-Log "Chargement du fichier CSV..." -LogFile $LogFile
$VMList  = Import-Csv -Path $CsvFile -Delimiter ";"
if ($VMName) {
    $VMList = $VMList | Where-Object { $_.VMName -eq $VMName }
    if (-not $VMList) {
        Write-Log "VM $VMName absente du CSV, aucune opération de mapping à réaliser." -Level WARNING -LogFile $LogFile
        exit 0
    }
}
$VMNames = $VMList.VMName
Write-Log "VMs à traiter : $($VMNames -join ', ')" -LogFile $LogFile

# Récupération des VMs sur VMware avec leur VLAN
$VMs = @()
foreach ($vmNameFromCsv in $VMNames) {
    $VMObject = VMware.VimAutomation.Core\Get-VM -Name $vmNameFromCsv -ErrorAction SilentlyContinue
    if ($VMObject) {
        $NetworkAdapter = Get-NetworkAdapter -VM $VMObject -ErrorAction SilentlyContinue
        if ($NetworkAdapter) {
            $PortGroup  = $NetworkAdapter.NetworkName
            if ($PortGroup) {
                $DVPortGroup = Get-VDPortgroup -Name $PortGroup -ErrorAction SilentlyContinue
                if ($DVPortGroup) {
                    $VLANID = if ($DVPortGroup.VlanConfiguration -match "\d+") { $matches[0] } else { "Valeur non reconnue" }
                } else {
                    $VLANID = "PortGroup non trouvé"
                }
            } else {
                $VLANID = "Non attaché à un réseau"
            }
        } else {
            $VLANID = "Pas d'adaptateur réseau"
        }
    } else {
        $VLANID = "VM introuvable"
    }
    Write-Log "VM: $vmNameFromCsv - VLAN: $VLANID" -LogFile $LogFile
    $VMs += [PSCustomObject]@{ Name = $vmNameFromCsv; VLAN = $VLANID }
}

Disconnect-VCenter -LogFile $LogFile

# Récupération des ressources réseau SCVMM
Write-Log "Récupération des VMNetworks et VMSubnets..." -LogFile $LogFile
$VMNetworks        = Get-SCVMNetwork -VMMServer $VMMServer
$VMSubnets         = Get-SCVMSubnet -VMMServer $VMMServer
$PortClassification = Get-SCPortClassification -VMMServer $VMMServer | Where-Object { $_.Name -eq $Config.SCVMM.Network.PortClassificationName }

Write-Log "VMNetworks : $($VMNetworks.Count) | VMSubnets : $($VMSubnets.Count)" -LogFile $LogFile

foreach ($vmRecord in $VMs) {
    $targetVmName = $vmRecord.Name
    $vlanId = $vmRecord.VLAN

    Write-Log "Traitement de $targetVmName (VLAN $vlanId)..." -LogFile $LogFile

    if ($vlanId -match "^\d+$") {
        $MatchingVMNetwork = $VMNetworks | Where-Object { $_.Name -like "*$vlanId*" -or $_.Description -like "*$vlanId*" }
        $MatchingVMSubnet  = $VMSubnets  | Where-Object { $_.Name -like "*$vlanId*" -or $_.Description -like "*$vlanId*" }

        if ($MatchingVMNetwork -and $MatchingVMSubnet) {
            $TargetVM = Get-SCVirtualMachine -Name $targetVmName -VMMServer $VMMServer | Where-Object { $_.VirtualizationPlatform -eq "HyperV" }
            if ($TargetVM) {
                # Configuration réseau
                $NetworkAdapter = Get-SCVirtualNetworkAdapter -VM $TargetVM
                Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $NetworkAdapter -VMNetwork $MatchingVMNetwork -VMSubnet $MatchingVMSubnet -VLanEnabled $true -VLanID $vlanId -VirtualNetwork $Config.SCVMM.Network.LogicalSwitchName -IPv4AddressType Dynamic -IPv6AddressType Dynamic -PortClassification $PortClassification | Out-Null
                Write-Log "Réseau configuré sur $targetVmName (VLAN $vlanId, VMNetwork $($MatchingVMNetwork.Name))." -Level SUCCESS -LogFile $LogFile

                # Integration Services
                Set-SCVirtualMachine -VM $TargetVM -EnableOperatingSystemShutdown $true -EnableTimeSynchronization $false -EnableDataExchange $true -EnableHeartbeat $true -EnableBackup $true -EnableGuestServicesInterface $true | Out-Null
                Write-Log "Integration Services configuré pour $targetVmName." -LogFile $LogFile

                # Cluster failover
                try {
                    Add-ClusterVirtualMachineRole -Cluster $HyperVCluster -VirtualMachine $TargetVM.Name
                    Write-Log "VM $targetVmName intégrée au cluster $HyperVCluster." -Level SUCCESS -LogFile $LogFile
                } catch {
                    Write-Log "Erreur cluster pour $targetVmName : $_" -Level ERROR -LogFile $LogFile
                }

                # LiveMigration
                try {
                    Move-VM -Name $TargetVM.Name -DestinationHost $HyperVHost2
                    Write-Log "LiveMigration de $targetVmName vers $HyperVHost2 effectuée." -Level SUCCESS -LogFile $LogFile
                } catch {
                    Write-Log "Erreur LiveMigration pour $targetVmName : $_" -Level ERROR -LogFile $LogFile
                }

                # Tag backup
                Set-SCVirtualMachine -VM $TargetVM -Tag $BackupTag
                Write-Log "Tag backup '$BackupTag' appliqué à $targetVmName." -LogFile $LogFile
            } else {
                Write-Log "VM $targetVmName non trouvée dans SCVMM." -Level WARNING -LogFile $LogFile
            }
        } else {
            Write-Log "Aucun VMNetwork/VMSubnet trouvé pour VLAN $vlanId sur $targetVmName." -Level WARNING -LogFile $LogFile
        }
    } else {
        Write-Log "VLAN ID invalide pour $targetVmName : $vlanId" -Level WARNING -LogFile $LogFile
    }
}

Write-Log "step5 terminé." -Level SUCCESS -LogFile $LogFile
