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

Set-Alias -Name Get-VMWareVM -Value VMware.VimAutomation.Core\Get-VM

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
$VMNames = $VMList.VMName
Write-Log "VMs à traiter : $($VMNames -join ', ')" -LogFile $LogFile

# Récupération des VMs sur VMware avec leur VLAN
$VMs = @()
foreach ($VMName in $VMNames) {
    $VMObject = Get-VMWareVM -Name $VMName -ErrorAction SilentlyContinue
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
    Write-Log "VM: $VMName - VLAN: $VLANID" -LogFile $LogFile
    $VMs += [PSCustomObject]@{ Name = $VMName; VLAN = $VLANID }
}

Disconnect-VCenter -LogFile $LogFile

# Récupération des ressources réseau SCVMM
Write-Log "Récupération des VMNetworks et VMSubnets..." -LogFile $LogFile
$VMNetworks        = Get-SCVMNetwork -VMMServer $VMMServer
$VMSubnets         = Get-SCVMSubnet -VMMServer $VMMServer
$PortClassification = Get-SCPortClassification -VMMServer $VMMServer | Where-Object { $_.Name -eq "PC_VMNetwork" }

Write-Log "VMNetworks : $($VMNetworks.Count) | VMSubnets : $($VMSubnets.Count)" -LogFile $LogFile

foreach ($VM in $VMs) {
    $VMName = $VM.Name
    $VLANID = $VM.VLAN

    Write-Log "Traitement de $VMName (VLAN $VLANID)..." -LogFile $LogFile

    if ($VLANID -match "^\d+$") {
        $MatchingVMNetwork = $VMNetworks | Where-Object { $_.Name -like "*$VLANID*" -or $_.Description -like "*$VLANID*" }
        $MatchingVMSubnet  = $VMSubnets  | Where-Object { $_.Name -like "*$VLANID*" -or $_.Description -like "*$VLANID*" }

        if ($MatchingVMNetwork -and $MatchingVMSubnet) {
            $TargetVM = Get-SCVirtualMachine -Name $VMName -VMMServer $VMMServer | Where-Object { $_.VirtualizationPlatform -eq "HyperV" }
            if ($TargetVM) {
                # Configuration réseau
                $NetworkAdapter = Get-SCVirtualNetworkAdapter -VM $TargetVM
                Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $NetworkAdapter -VMNetwork $MatchingVMNetwork -VMSubnet $MatchingVMSubnet -VLanEnabled $true -VLanID $VLANID -VirtualNetwork "LS_SET_VMNetwork" -IPv4AddressType Dynamic -IPv6AddressType Dynamic -PortClassification $PortClassification | Out-Null
                Write-Log "Réseau configuré sur $VMName (VLAN $VLANID, VMNetwork $($MatchingVMNetwork.Name))." -Level SUCCESS -LogFile $LogFile

                # Integration Services
                Set-SCVirtualMachine -VM $TargetVM -EnableOperatingSystemShutdown $true -EnableTimeSynchronization $false -EnableDataExchange $true -EnableHeartbeat $true -EnableBackup $true -EnableGuestServicesInterface $true | Out-Null
                Write-Log "Integration Services configuré pour $VMName." -LogFile $LogFile

                # Cluster failover
                try {
                    Add-ClusterVirtualMachineRole -Cluster $HyperVCluster -VirtualMachine $TargetVM.Name
                    Write-Log "VM $VMName intégrée au cluster $HyperVCluster." -Level SUCCESS -LogFile $LogFile
                } catch {
                    Write-Log "Erreur cluster pour $VMName : $_" -Level ERROR -LogFile $LogFile
                }

                # LiveMigration
                try {
                    Move-VM -Name $TargetVM.Name -DestinationHost $HyperVHost2
                    Write-Log "LiveMigration de $VMName vers $HyperVHost2 effectuée." -Level SUCCESS -LogFile $LogFile
                } catch {
                    Write-Log "Erreur LiveMigration pour $VMName : $_" -Level ERROR -LogFile $LogFile
                }

                # Tag backup
                Set-SCVirtualMachine -VM $TargetVM -Tag $BackupTag
                Write-Log "Tag backup '$BackupTag' appliqué à $VMName." -LogFile $LogFile
            } else {
                Write-Log "VM $VMName non trouvée dans SCVMM." -Level WARNING -LogFile $LogFile
            }
        } else {
            Write-Log "Aucun VMNetwork/VMSubnet trouvé pour VLAN $VLANID sur $VMName." -Level WARNING -LogFile $LogFile
        }
    } else {
        Write-Log "VLAN ID invalide pour $VMName : $VLANID" -Level WARNING -LogFile $LogFile
    }
}

Write-Log "step5 terminé." -Level SUCCESS -LogFile $LogFile
