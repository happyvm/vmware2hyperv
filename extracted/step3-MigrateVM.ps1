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

function Invoke-VeeamCommand {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @()
    )

    $compatSession = Get-PSSession -Name 'WinPSCompatSession' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($compatSession) {
        return Invoke-Command -Session $compatSession -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }

    return & $ScriptBlock @ArgumentList
}

# ── Instant Recovery: start ─────────────────────────────────────────────

Write-Log "[$VMName] Checking SCVMM in Veeam..." -LogFile $LogFile
$VBRSCVMM = Invoke-VeeamCommand -ScriptBlock {
    param($ScvmmServerName)
    Get-VBRServer | Where-Object { $_.Name -eq $ScvmmServerName -and $_.Type -eq "Scvmm" } |
        Select-Object -First 1 -Property Name, Type
} -ArgumentList @($SCVMMServer)

if (!$VBRSCVMM) {
    Write-Log "[$VMName] SCVMM $SCVMMServer is not registered in Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}

$Backup = Invoke-VeeamCommand -ScriptBlock {
    param($JobName)
    Get-VBRBackup | Where-Object { $_.Name -eq $JobName } |
        Select-Object -First 1 -Property Name, Id
} -ArgumentList @($BackupJobName)

if (!$Backup) {
    Write-Log "[$VMName] Backup job '$BackupJobName' not found in Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}

try {
    Invoke-VeeamCommand -ScriptBlock {
        param(
            [string]$JobName,
            [string]$Vm,
            [string]$DestinationHost,
            [string]$DestinationPath
        )

        $backup = Get-VBRBackup | Where-Object { $_.Name -eq $JobName } | Select-Object -First 1
        if (-not $backup) {
            throw "Backup job '$JobName' not found in Veeam."
        }

        $restorePoint = Get-VBRRestorePoint -Backup $backup |
            Where-Object { $_.Name -eq $Vm } |
            Sort-Object -Property CreationTime -Descending |
            Select-Object -First 1

        if (-not $restorePoint) {
            throw "No restore point found for VM '$Vm' in job '$JobName'."
        }

        Start-VBRHvInstantRecovery -RestorePoint $restorePoint -Server $DestinationHost -Path $DestinationPath -PowerUp $false -NICsEnabled $true -PreserveMACs $true -PreserveVmID $true | Out-Null
        return $true
    } -ArgumentList @($BackupJobName, $VMName, $HyperVHost, "$ClusterStorage\$VMName")
} catch {
    Write-Log "[$VMName] Instant Recovery preparation failed: $_" -Level ERROR -LogFile $LogFile
    throw
}

Write-Log "[$VMName] Starting Instant Recovery..." -LogFile $LogFile
try {
    Write-Log "[$VMName] Instant Recovery started." -Level SUCCESS -LogFile $LogFile

    $elapsed = 0
    do {
        $isWaitingForUserAction = Invoke-VeeamCommand -ScriptBlock {
            param($Vm)

            $instantRecoverySession = Get-VBRInstantRecovery |
                Where-Object { $_.VMName -eq $Vm } |
                Select-Object -First 1

            if (-not $instantRecoverySession) {
                return $false
            }

            if ($instantRecoverySession.State -eq "WaitingForUserAction") {
                return $true
            }

            $sessionNameCandidates = @(
                "$Vm-migrationhyp",
                "$Vm*"
            )

            foreach ($sessionName in $sessionNameCandidates) {
                $restoreSession = Get-VBRRestoreSession |
                    Where-Object { $_.Name -like $sessionName } |
                    Sort-Object -Property CreationTime -Descending |
                    Select-Object -First 1

                if (-not $restoreSession) {
                    continue
                }

                $updatedTitles = $restoreSession.Logger.GetLog().UpdatedRecords.Title
                if ($updatedTitles -match "Waiting for user action") {
                    return $true
                }
            }

            return $false
        } -ArgumentList @($VMName)

        if ($isWaitingForUserAction) {
            Write-Log "[$VMName] Instant Recovery in waiting mode (detected via state or restore session log)." -Level SUCCESS -LogFile $LogFile
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

$IRSession = Invoke-VeeamCommand -ScriptBlock {
    param($Vm)
    Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } |
        Select-Object -First 1 -Property VMName, State
} -ArgumentList @($VMName)

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
    Invoke-VeeamCommand -ScriptBlock {
        param($Vm)
        $irSession = Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } | Select-Object -First 1
        if (-not $irSession) {
            throw "No active Instant Recovery session for VM '$Vm'."
        }
        Start-VBRHvInstantRecoveryMigration -InstantRecovery $irSession | Out-Null
    } -ArgumentList @($VMName)

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
