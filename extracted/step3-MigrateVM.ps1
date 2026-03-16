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

function Invoke-SCVMMCommand {
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
        $waitCheck = Invoke-VeeamCommand -ScriptBlock {
            param($Vm)

            $instantRecoverySession = Get-VBRInstantRecovery |
                Where-Object { $_.VMName -eq $Vm } |
                Select-Object -First 1

            $currentState = if ($instantRecoverySession) { [string]$instantRecoverySession.State } else { "<none>" }
            $restoreSessionState = "<none>"
            $waitingDetected = $false
            $detectionSource = $null

            if ($instantRecoverySession -and $instantRecoverySession.State -eq "WaitingForUserAction") {
                $waitingDetected = $true
                $detectionSource = "instant-recovery-state"
            }

            if (-not $waitingDetected) {
                $restoreSession = Get-VBRRestoreSession |
                    Where-Object { $_.Name -eq $Vm -or $_.Name -eq "$Vm-migrationhyp" -or $_.Name -like "$Vm*" } |
                    Sort-Object -Property CreationTime -Descending |
                    Select-Object -First 1

                if ($restoreSession) {
                    $restoreSessionState = [string]$restoreSession.State
                    $sessionLog = $restoreSession.Logger.GetLog()
                    $logRecords = @()
                    if ($sessionLog.UpdatedRecords) { $logRecords += $sessionLog.UpdatedRecords }
                    if ($sessionLog.Records)        { $logRecords += $sessionLog.Records }

                    $logText = ($logRecords | ForEach-Object {
                        @($_.Title, $_.Description, $_.Message, $_.Text)
                    } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"

                    if ($logText -match "Waiting for user action") {
                        $waitingDetected = $true
                        $detectionSource = "restore-session-log"
                    }
                }
            }

            [PSCustomObject]@{
                WaitingDetected     = $waitingDetected
                CurrentState        = $currentState
                RestoreSessionState = $restoreSessionState
                DetectionSource     = $detectionSource
            }
        } -ArgumentList @($VMName)

        Write-Log "[$VMName] Current states: InstantRecovery='$($waitCheck.CurrentState)', RestoreSession='$($waitCheck.RestoreSessionState)' (elapsed: ${elapsed}s)." -LogFile $LogFile

        if ($waitCheck.WaitingDetected) {
            Write-Log "[$VMName] Instant Recovery in waiting mode (source=$($waitCheck.DetectionSource))." -Level SUCCESS -LogFile $LogFile
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

try {
    $VMMServerName = Invoke-SCVMMCommand -ScriptBlock {
        param($ServerName)
        $server = Get-SCVMMServer -ComputerName $ServerName
        if (-not $server) {
            throw "SCVMM server '$ServerName' not found."
        }

        return $server.Name
    } -ArgumentList @($SCVMMServer)
} catch {
    if ([string]$_ -match "IndigoLayer") {
        Write-Log "[$VMName] SCVMM module error hints at a VMM console/runtime mismatch on the runner. Validate that Virtual Machine Manager Console matching the SCVMM server version is installed and restart the shell." -Level ERROR -LogFile $LogFile
    }
    Write-Log "[$VMName] Failed to connect to SCVMM server '$SCVMMServer': $_" -Level ERROR -LogFile $LogFile
    throw
}

$IRSession = Invoke-VeeamCommand -ScriptBlock {
    param($Vm)
    Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } |
        Select-Object -First 1 -Property VMName, State
} -ArgumentList @($VMName)

if (!$IRSession) {
    Write-Log "[$VMName] No active Instant Recovery session." -Level ERROR -LogFile $LogFile
    exit 1
}

$vmInScvmm = Invoke-SCVMMCommand -ScriptBlock {
    param($Name, $ServerName)
    $server = Get-SCVMMServer -ComputerName $ServerName
    Get-SCVirtualMachine -Name $Name -VMMServer $server
} -ArgumentList @($VMName, $VMMServerName)
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

    $finalizationElapsed = 0
    do {
        $finalizationCheck = Invoke-VeeamCommand -ScriptBlock {
            param($Vm)

            $restoreSession = Get-VBRRestoreSession |
                Where-Object { $_.Name -eq $Vm -or $_.Name -eq "$Vm-migrationhyp" -or $_.Name -like "$Vm*" } |
                Sort-Object -Property CreationTime -Descending |
                Select-Object -First 1

            if (-not $restoreSession) {
                return [PSCustomObject]@{
                    Found  = $false
                    Name   = $null
                    State  = $null
                    Result = $null
                }
            }

            [PSCustomObject]@{
                Found  = $true
                Name   = [string]$restoreSession.Name
                State  = [string]$restoreSession.State
                Result = [string]$restoreSession.Result
            }
        } -ArgumentList @($VMName)

        if (-not $finalizationCheck.Found) {
            Write-Log "[$VMName] Restore session not yet visible after finalization start (elapsed: ${finalizationElapsed}s)." -Level WARNING -LogFile $LogFile
        } else {
            Write-Log "[$VMName] Restore session '$($finalizationCheck.Name)' status: State='$($finalizationCheck.State)', Result='$($finalizationCheck.Result)' (elapsed: ${finalizationElapsed}s)." -LogFile $LogFile

            if ($finalizationCheck.Result -eq "Success") {
                Write-Log "[$VMName] VM restored permanently; network reconfiguration can start." -Level SUCCESS -LogFile $LogFile
                break
            }

            if ($finalizationCheck.Result -eq "Failed" -or $finalizationCheck.Result -eq "Warning") {
                throw "Restore session '$($finalizationCheck.Name)' ended with result '$($finalizationCheck.Result)'."
            }
        }

        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $finalizationElapsed += $WaitingPollIntervalSeconds
    } while ($finalizationElapsed -lt $WaitingTimeoutSeconds)

    if ($finalizationElapsed -ge $WaitingTimeoutSeconds) {
        throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for restore session success before network reconfiguration."
    }
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

    $NetworkMapping = Invoke-SCVMMCommand -ScriptBlock {
        param($ServerName, $Vlan)
        $server = Get-SCVMMServer -ComputerName $ServerName

        $matchingVMNetwork = Get-SCVMNetwork -VMMServer $server |
            Where-Object { $_.Name -like "*$Vlan*" -or $_.Description -like "*$Vlan*" } |
            Select-Object -First 1

        $matchingVMSubnet = Get-SCVMSubnet -VMMServer $server |
            Where-Object { $_.Name -like "*$Vlan*" -or $_.Description -like "*$Vlan*" } |
            Select-Object -First 1

        [pscustomobject]@{
            VMNetworkName = $matchingVMNetwork.Name
            VMSubnetName  = $matchingVMSubnet.Name
        }
    } -ArgumentList @($VMMServerName, $VlanId)

    if ([string]::IsNullOrWhiteSpace($NetworkMapping.VMNetworkName) -or [string]::IsNullOrWhiteSpace($NetworkMapping.VMSubnetName)) {
        Write-Log "[$VMName] No VMNetwork/VMSubnet found for VLAN $VlanId." -Level WARNING -LogFile $LogFile
    } else {
        $TargetVM = Invoke-SCVMMCommand -ScriptBlock {
            param($Name, $ServerName)
            $server = Get-SCVMMServer -ComputerName $ServerName
            Get-SCVirtualMachine -Name $Name -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" }
        } -ArgumentList @($VMName, $VMMServerName)
        if (!$TargetVM) {
            Write-Log "[$VMName] VM not found in SCVMM." -Level WARNING -LogFile $LogFile
        } else {
            Invoke-SCVMMCommand -ScriptBlock {
                param(
                    $Name,
                    $ServerName,
                    $VMNetworkName,
                    $VMSubnetName,
                    $Vlan,
                    $LogicalSwitch,
                    $PortClassificationName
                )
                $server = Get-SCVMMServer -ComputerName $ServerName
                $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
                if (-not $vm) {
                    throw "VM '$Name' not found in SCVMM while applying network configuration."
                }

                $vmNetwork = Get-SCVMNetwork -VMMServer $server | Where-Object { $_.Name -eq $VMNetworkName } | Select-Object -First 1
                $vmSubnet = Get-SCVMSubnet -VMMServer $server | Where-Object { $_.Name -eq $VMSubnetName } | Select-Object -First 1
                $portClass = Get-SCPortClassification -VMMServer $server | Where-Object { $_.Name -eq $PortClassificationName } | Select-Object -First 1

                if (-not $vmNetwork -or -not $vmSubnet) {
                    throw "Unable to resolve VMNetwork/VMSubnet in SCVMM for VLAN '$Vlan'."
                }

                if (-not $portClass) {
                    throw "Port classification '$PortClassificationName' not found in SCVMM."
                }

                $networkAdapter = Get-SCVirtualNetworkAdapter -VM $vm
                Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $networkAdapter -VMNetwork $vmNetwork -VMSubnet $vmSubnet -VLanEnabled $true -VLanID $Vlan -VirtualNetwork $LogicalSwitch -IPv4AddressType Dynamic -IPv6AddressType Dynamic -PortClassification $portClass | Out-Null
                Set-SCVirtualMachine -VM $vm -EnableOperatingSystemShutdown $true -EnableTimeSynchronization $false -EnableDataExchange $true -EnableHeartbeat $true -EnableBackup $true -EnableGuestServicesInterface $true | Out-Null
            } -ArgumentList @(
                $VMName,
                $VMMServerName,
                $NetworkMapping.VMNetworkName,
                $NetworkMapping.VMSubnetName,
                $VlanId,
                $Config.SCVMM.Network.LogicalSwitchName,
                $Config.SCVMM.Network.PortClassificationName
            )

            Write-Log "[$VMName] Network configured (VLAN $VlanId, VMNetwork $($NetworkMapping.VMNetworkName))." -Level SUCCESS -LogFile $LogFile
            Write-Log "[$VMName] Integration Services configured." -LogFile $LogFile

            try {
                Add-ClusterVirtualMachineRole -Cluster $HyperVCluster -VirtualMachine $TargetVM.Name
                Write-Log "[$VMName] VM added to cluster $HyperVCluster." -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-Log "[$VMName] Cluster error: $_" -Level ERROR -LogFile $LogFile
            }

            try {
                $hyperVMoveCommand = Get-Command -Name "Move-VM" -Module "Hyper-V" -ErrorAction SilentlyContinue |
                    Select-Object -First 1

                if ($hyperVMoveCommand) {
                    & $hyperVMoveCommand -Name $TargetVM.Name -DestinationHost $HyperVHost2 -ErrorAction Stop
                    Write-Log "[$VMName] LiveMigration to $HyperVHost2 performed via Hyper-V module." -Level SUCCESS -LogFile $LogFile
                } else {
                    Write-Log "[$VMName] Hyper-V Move-VM cmdlet unavailable on runner, trying SCVMM move." -Level WARNING -LogFile $LogFile
                    Invoke-SCVMMCommand -ScriptBlock {
                        param($Name, $ServerName, $DestinationHost)

                        $server = Get-SCVMMServer -ComputerName $ServerName
                        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1
                        if (-not $vm) {
                            throw "VM '$Name' not found in SCVMM while starting migration."
                        }

                        $targetHost = Get-SCVMHost -VMMServer $server | Where-Object { $_.ComputerName -eq $DestinationHost -or $_.Name -eq $DestinationHost } | Select-Object -First 1
                        if (-not $targetHost) {
                            throw "Destination host '$DestinationHost' not found in SCVMM."
                        }

                        Move-SCVirtualMachine -VM $vm -VMHost $targetHost -UseLAN -RunAsynchronously | Out-Null
                    } -ArgumentList @($VMName, $VMMServerName, $HyperVHost2)

                    Write-Log "[$VMName] LiveMigration to $HyperVHost2 requested via SCVMM." -Level SUCCESS -LogFile $LogFile
                }
            } catch {
                if ([string]$_ -match "could not access an expected WMI class|Hyper-V Platform") {
                    Write-Log "[$VMName] LiveMigration unavailable on this runner (missing local Hyper-V platform). Migration already completed; run host-to-host move from a Hyper-V capable node or via SCVMM." -Level WARNING -LogFile $LogFile
                } else {
                    Write-Log "[$VMName] LiveMigration error: $_" -Level ERROR -LogFile $LogFile
                }
            }

            Invoke-SCVMMCommand -ScriptBlock {
                param($Name, $ServerName, $TagName)
                $server = Get-SCVMMServer -ComputerName $ServerName
                $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1
                if (-not $vm) {
                    throw "VM '$Name' not found in SCVMM while setting tag."
                }

                Set-SCVirtualMachine -VM $vm -Tag $TagName | Out-Null
            } -ArgumentList @($VMName, $VMMServerName, $BackupTag)

            Write-Log "[$VMName] Backup tag '$BackupTag' applied." -LogFile $LogFile
        }
    }
}

Write-Log "[$VMName] Migration completed." -Level SUCCESS -LogFile $LogFile
