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
    [string]$BackupTag,
    [int]$WaitingTimeoutSeconds = 1800,
    [int]$WaitingPollIntervalSeconds = 15,
    [switch]$ForceNetworkConfigOnly,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"

if (-not (Get-Command -Name ConvertTo-NormalizedOperatingSystemName -ErrorAction SilentlyContinue)) {
    function ConvertTo-NormalizedOperatingSystemName {
        param(
            [AllowNull()]
            [string]$Name
        )

        if ([string]::IsNullOrWhiteSpace($Name)) {
            return $null
        }

        $normalized = $Name.Trim().ToLowerInvariant()
        $normalized = $normalized -replace '[\/_-]+', ' '
        $normalized = $normalized -replace '\s+', ' '
        $normalized = $normalized -replace '^microsoft\s+', ''
        return $normalized.Trim()
    }
}

if (-not (Get-Command -Name Resolve-OperatingSystemMapping -ErrorAction SilentlyContinue)) {
    function Resolve-OperatingSystemMapping {
        param(
            [AllowNull()]
            [string]$OperatingSystem,

            $OperatingSystemMap
        )

        $normalized = ConvertTo-NormalizedOperatingSystemName -Name $OperatingSystem
        if ([string]::IsNullOrWhiteSpace($normalized) -or -not $OperatingSystemMap) {
            return $null
        }

        foreach ($entry in $OperatingSystemMap.GetEnumerator()) {
            $entryKey = ConvertTo-NormalizedOperatingSystemName -Name ([string]$entry.Key)
            if ($entryKey -eq $normalized) {
                return [string]$entry.Value
            }
        }

        return $null
    }
}

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


function Start-SCVMMHostMigration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$DestinationHost
    )

    if (-not $PSCmdlet.ShouldProcess($Name, "Start host migration to $DestinationHost via SCVMM")) {
        return
    }

    Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName, $TargetHostName)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while starting migration."
        }

        $targetHost = Get-SCVMHost -VMMServer $server |
            Where-Object { $_.ComputerName -eq $TargetHostName -or $_.Name -eq $TargetHostName } |
            Select-Object -First 1
        if (-not $targetHost) {
            throw "Destination host '$TargetHostName' not found in SCVMM."
        }

        Move-SCVirtualMachine -VM $vm -VMHost $targetHost -UseLAN -RunAsynchronously | Out-Null
    } -ArgumentList @($Name, $ServerName, $DestinationHost)
}

function Get-SCVMMVmRuntimeState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName
    )

    return Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName)
        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            return $null
        }

        $hostNameCandidates = @(
            [string]$vm.HostName,
            [string]$vm.VMHostName,
            [string]$vm.VMHost.ComputerName,
            [string]$vm.VMHost.Name,
            [string]$vm.HostComputerName,
            [string]$vm.Host
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        [pscustomobject]@{
            Name             = [string]$vm.Name
            IsHighlyAvailable = [bool]$vm.IsHighlyAvailable
            HostName         = $hostNameCandidates | Select-Object -First 1
            Status           = [string]$vm.Status
            StatusString     = [string]$vm.StatusString
        }
    } -ArgumentList @($Name, $ServerName)
}

function Normalize-HostName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return $Name.Trim().ToLowerInvariant().Split('.')[0]
}

function Refresh-SCVMMVirtualMachine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [string]$LogFile
    )

    Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName)
        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while refreshing."
        }

        $refreshCommand = Get-Command -Name 'Read-SCVirtualMachine' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($refreshCommand) {
            & $refreshCommand -VM $vm | Out-Null
        }
    } -ArgumentList @($Name, $ServerName)

    Write-MigrationLog "[$Name] SCVMM VM refresh completed." -LogFile $LogFile
}

function Invoke-SCVMMNetworkAndPostConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$Vlan,
        $AdapterVlanMappings,

        [string]$SourceOperatingSystem,
        [string]$SourceRemark,
        $Config,
        [string]$BackupTagName,
        [string]$ClusterName,
        [string]$DestinationHost,
        [string]$LogFile
    )

    Write-MigrationLog "[$Name] Network configuration (default VLAN $Vlan)..." -LogFile $LogFile

    if ($Vlan -notmatch "^\d+$") {
        Write-MigrationLog "[$Name] Invalid VLAN ID: '$Vlan' — network mapping skipped." -Level WARNING -LogFile $LogFile
        return
    }

    $requiredConfigPaths = @(
        @{ Path = "SCVMM.Network.PortClassificationName"; Value = $Config.SCVMM.Network.PortClassificationName },
        @{ Path = "SCVMM.Network.LogicalSwitchName";      Value = $Config.SCVMM.Network.LogicalSwitchName }
    )
    foreach ($requiredConfig in $requiredConfigPaths) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredConfig.Value)) {
            throw "Invalid configuration: key '$($requiredConfig.Path)' is missing or empty in config.psd1."
        }
    }

    $defaultNetworkMapping = Invoke-SCVMMCommand -ScriptBlock {
        param($ServerName, $CurrentVlan)
        $server = Get-SCVMMServer -ComputerName $ServerName

        $matchingVMNetwork = Get-SCVMNetwork -VMMServer $server |
            Where-Object { $_.Name -like "*$CurrentVlan*" -or $_.Description -like "*$CurrentVlan*" } |
            Select-Object -First 1

        $matchingVMSubnet = Get-SCVMSubnet -VMMServer $server |
            Where-Object { $_.Name -like "*$CurrentVlan*" -or $_.Description -like "*$CurrentVlan*" } |
            Select-Object -First 1

        [pscustomobject]@{
            VMNetworkName = $matchingVMNetwork.Name
            VMSubnetName = $matchingVMSubnet.Name
        }
    } -ArgumentList @($ServerName, $Vlan)

    if ([string]::IsNullOrWhiteSpace($defaultNetworkMapping.VMNetworkName) -or [string]::IsNullOrWhiteSpace($defaultNetworkMapping.VMSubnetName)) {
        Write-MigrationLog "[$Name] No VMNetwork/VMSubnet found for default VLAN $Vlan." -Level WARNING -LogFile $LogFile
        return
    }

    $TargetVM = Invoke-SCVMMCommand -ScriptBlock {
        param($Name, $ServerName)
        $server = Get-SCVMMServer -ComputerName $ServerName
        Get-SCVirtualMachine -Name $Name -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" }
    } -ArgumentList @($Name, $ServerName)
    if (!$TargetVM) {
        Write-MigrationLog "[$Name] VM not found in SCVMM." -Level WARNING -LogFile $LogFile
        return
    }

    $networkConfigRetryDelaySeconds = 30
    $networkConfigRetryCount = 2

    for ($networkConfigAttempt = 1; $networkConfigAttempt -le $networkConfigRetryCount; $networkConfigAttempt++) {
        try {
            Invoke-SCVMMCommand -ScriptBlock {
        param(
            $Name,
            $ServerName,
            $VMNetworkName,
            $VMSubnetName,
            $Vlan,
            $LogicalSwitch,
            $PortClassificationName,
            $Description,
            $AdapterVlanMappings
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

        $networkAdapter = $null
        $adapterRetryCount = 18
        $adapterRetryDelaySeconds = 10
        $refreshVirtualMachineCommand = Get-Command -Name 'Read-SCVirtualMachine' -ErrorAction SilentlyContinue | Select-Object -First 1

        function Normalize-MacAddress {
            param([AllowNull()][string]$Value)

            if ([string]::IsNullOrWhiteSpace($Value)) {
                return $null
            }

            return ($Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        }

        function Get-ScvmmNetworkAdapters {
            param(
                $CurrentVm,
                $CurrentServer,
                [string]$CurrentVmName
            )

            $adapters = @(Get-SCVirtualNetworkAdapter -VM $CurrentVm)
            if ($adapters) {
                return $adapters
            }

            $allAdapters = @(Get-SCVirtualNetworkAdapter -VMMServer $CurrentServer)
            if (-not $allAdapters) {
                return @()
            }

            $matchingAdapters = @($allAdapters |
                Where-Object {
                    ($_.VM -and $_.VM.ID -eq $CurrentVm.ID) -or
                    ($_.VMId -and $_.VMId -eq $CurrentVm.ID) -or
                    ($_.VMName -and $_.VMName -eq $CurrentVmName) -or
                    ($_.VM -and $_.VM.Name -eq $CurrentVmName)
                })

            return $matchingAdapters
        }

        $networkAdapters = @()
        for ($attempt = 1; $attempt -le $adapterRetryCount; $attempt++) {
            $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq "HyperV" } | Select-Object -First 1
            if (-not $vm) {
                throw "VM '$Name' no longer available in SCVMM while waiting for the virtual network adapter."
            }

            $networkAdapters = @(Get-ScvmmNetworkAdapters -CurrentVm $vm -CurrentServer $server -CurrentVmName $Name)
            if ($networkAdapters.Count -gt 0) {
                break
            }

            $vmStatusText = @(
                [string]$vm.Status,
                [string]$vm.StatusString,
                [string]$vm.MostRecentTaskUIState
            ) -join ' '
            if ($refreshVirtualMachineCommand -and $vmStatusText -match 'incomplete|creating|update|refresh') {
                & $refreshVirtualMachineCommand -VM $vm | Out-Null
            }

            Start-Sleep -Seconds $adapterRetryDelaySeconds
        }

        if ($networkAdapters.Count -eq 0) {
            throw "No SCVMM virtual network adapter found for VM '$Name' after waiting $($adapterRetryCount * $adapterRetryDelaySeconds) seconds. SCVMM may still show the VM in an incomplete configuration state; refresh the VM in SCVMM and retry."
        }

        $networkMappingsByVlan = @{}
        $networkMappingsBySourceNetworkName = @{}
        $networkMappingsByVlan[$Vlan] = [pscustomobject]@{
            VMNetwork = $vmNetwork
            VMSubnet = $vmSubnet
            Vlan = $Vlan
        }

        $adapterMappings = @()
        if ($AdapterVlanMappings) {
            $adapterMappings = @($AdapterVlanMappings | Where-Object { $_.VlanId -match '^\d+$' })
        }

        if ($adapterMappings.Count -gt 0) {
            foreach ($adapterMapping in $adapterMappings) {
                $mappingVlan = [string]$adapterMapping.VlanId
                $mappingNetworkName = [string]$adapterMapping.NetworkName

                if (-not $networkMappingsByVlan.ContainsKey($mappingVlan)) {
                    $matchingVMNetwork = Get-SCVMNetwork -VMMServer $server |
                        Where-Object { $_.Name -like "*$mappingVlan*" -or $_.Description -like "*$mappingVlan*" } |
                        Select-Object -First 1
                    $matchingVMSubnet = Get-SCVMSubnet -VMMServer $server |
                        Where-Object { $_.Name -like "*$mappingVlan*" -or $_.Description -like "*$mappingVlan*" } |
                        Select-Object -First 1

                    if ($matchingVMNetwork -and $matchingVMSubnet) {
                        $networkMappingsByVlan[$mappingVlan] = [pscustomobject]@{
                            VMNetwork = $matchingVMNetwork
                            VMSubnet = $matchingVMSubnet
                            Vlan = $mappingVlan
                        }
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($mappingNetworkName) -and -not $networkMappingsBySourceNetworkName.ContainsKey($mappingNetworkName)) {
                    $matchingByNetworkName = Get-SCVMNetwork -VMMServer $server |
                        Where-Object { $_.Name -eq $mappingNetworkName -or $_.Description -eq $mappingNetworkName } |
                        Select-Object -First 1

                    if (-not $matchingByNetworkName) {
                        $matchingByNetworkName = Get-SCVMNetwork -VMMServer $server |
                            Where-Object { $_.Name -like "*$mappingNetworkName*" -or $_.Description -like "*$mappingNetworkName*" } |
                            Select-Object -First 1
                    }

                    if ($matchingByNetworkName) {
                        $matchingSubnetByNetworkName = Get-SCVMSubnet -VMMServer $server |
                            Where-Object {
                                ($_.VMNetwork -and $_.VMNetwork.ID -eq $matchingByNetworkName.ID) -or
                                ($_.VMNetworkName -and $_.VMNetworkName -eq $matchingByNetworkName.Name)
                            } |
                            Select-Object -First 1

                        if ($matchingSubnetByNetworkName) {
                            $networkMappingsBySourceNetworkName[$mappingNetworkName] = [pscustomobject]@{
                                VMNetwork = $matchingByNetworkName
                                VMSubnet = $matchingSubnetByNetworkName
                                Vlan = if ($mappingVlan -match '^\d+$') { $mappingVlan } else { $Vlan }
                            }
                        }
                    }
                }
            }
        }

        $mappedAdapters = 0
        foreach ($networkAdapter in $networkAdapters) {
            $desiredMapping = $null
            $adapterMac = Normalize-MacAddress -Value ([string]$networkAdapter.MACAddressString)
            if (-not $adapterMac) {
                $adapterMac = Normalize-MacAddress -Value ([string]$networkAdapter.MACAddress)
            }

            if ($adapterMappings.Count -gt 0 -and $adapterMac) {
                $sourceAdapter = $adapterMappings |
                    Where-Object { (Normalize-MacAddress -Value ([string]$_.MacAddress)) -eq $adapterMac } |
                    Select-Object -First 1
                if ($sourceAdapter -and $networkMappingsByVlan.ContainsKey([string]$sourceAdapter.VlanId)) {
                    $desiredMapping = $networkMappingsByVlan[[string]$sourceAdapter.VlanId]
                } elseif (
                    $sourceAdapter -and
                    -not [string]::IsNullOrWhiteSpace([string]$sourceAdapter.NetworkName) -and
                    $networkMappingsBySourceNetworkName.ContainsKey([string]$sourceAdapter.NetworkName)
                ) {
                    $desiredMapping = $networkMappingsBySourceNetworkName[[string]$sourceAdapter.NetworkName]
                }
            }

            if (-not $desiredMapping) {
                Write-MigrationLog "[$Name] No VLAN mapping found for adapter MAC '$($networkAdapter.MACAddressString)' — disconnecting adapter." -Level WARNING -LogFile $LogFile
                Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $networkAdapter -NoConnection | Out-Null
                continue
            }

            Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $networkAdapter -VMNetwork $desiredMapping.VMNetwork -VMSubnet $desiredMapping.VMSubnet -VLanEnabled $true -VLanID $desiredMapping.Vlan -VirtualNetwork $LogicalSwitch -IPv4AddressType Dynamic -IPv6AddressType Dynamic -PortClassification $portClass | Out-Null
            $mappedAdapters++
        }

        if ($mappedAdapters -eq 0) {
            Write-MigrationLog "[$Name] No virtual network adapter could be mapped to a VLAN — all adapters have been disconnected." -Level WARNING -LogFile $LogFile
        }

        $setVmParameters = @{
            VM                             = $vm
            EnableOperatingSystemShutdown  = $true
            EnableTimeSynchronization      = $false
            EnableDataExchange             = $true
            EnableHeartbeat                = $true
            EnableBackup                   = $true
            EnableGuestServicesInterface   = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $setVmParameters["Description"] = $Description
        }

        Set-SCVirtualMachine @setVmParameters | Out-Null
            } -ArgumentList @(
        $Name,
        $ServerName,
        $defaultNetworkMapping.VMNetworkName,
        $defaultNetworkMapping.VMSubnetName,
        $Vlan,
        $Config.SCVMM.Network.LogicalSwitchName,
        $Config.SCVMM.Network.PortClassificationName,
        $SourceRemark,
        $AdapterVlanMappings
            )
            break
        } catch {
            if ($networkConfigAttempt -ge $networkConfigRetryCount) {
                throw
            }

            Write-MigrationLog "[$Name] SCVMM network/post-configuration attempt $networkConfigAttempt failed (`"$($_.Exception.Message)`"). Waiting $networkConfigRetryDelaySeconds seconds before retry (suspected transient SCVMM refresh/state delay)." -Level WARNING -LogFile $LogFile
            Start-Sleep -Seconds $networkConfigRetryDelaySeconds
        }
    }

    Write-MigrationLog "[$Name] Network configured (default VLAN $Vlan, multi-adapter mapping enabled)." -Level SUCCESS -LogFile $LogFile
    Write-MigrationLog "[$Name] Integration Services configured." -LogFile $LogFile
    if (-not [string]::IsNullOrWhiteSpace($SourceRemark)) {
        Write-MigrationLog "[$Name] SCVMM description updated from VMware remark." -LogFile $LogFile
    } else {
        Write-MigrationLog "[$Name] VMware remark empty; SCVMM description unchanged." -LogFile $LogFile
    }
    Set-SCVMMOperatingSystem -Name $Name -ServerName $ServerName -SourceOperatingSystem $SourceOperatingSystem -OperatingSystemMap $Config.SCVMM.OperatingSystemMap -LogFile $LogFile

    $vmStateBeforeHa = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName
    $vmHaState = [bool]$vmStateBeforeHa.IsHighlyAvailable

    $clusterVmRegistrationCommand = Get-Command -Name "Add-ClusterVirtualMachineRole" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $clusterVmRegistrationCommand) {
        try {
            Import-RequiredModule -Name "FailoverClusters" -LogFile $LogFile -UseWindowsPowerShellFallback
            $clusterVmRegistrationCommand = Get-Command -Name "Add-ClusterVirtualMachineRole" -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } catch {
            Write-MigrationLog "[$Name] FailoverClusters module import failed; high-availability registration will use SCVMM state only. Details: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
        }
    }

    if ($vmHaState) {
        Write-MigrationLog "[$Name] VM is already highly available in SCVMM." -Level SUCCESS -LogFile $LogFile
    } else {
        try {
            if ($clusterVmRegistrationCommand) {
                & $clusterVmRegistrationCommand -Cluster $ClusterName -VirtualMachine $TargetVM.Name
                Write-MigrationLog "[$Name] VM added to cluster $ClusterName; validating high availability state in SCVMM after refresh." -Level SUCCESS -LogFile $LogFile
            } else {
                Write-MigrationLog "[$Name] Add-ClusterVirtualMachineRole cmdlet unavailable on this execution host; skipping direct cluster cmdlet call and validating SCVMM high-availability state only." -Level WARNING -LogFile $LogFile
            }
        } catch {
            if ([string]$_ -match "already exists|already been configured|already highly available|is already part of") {
                Write-MigrationLog "[$Name] Cluster role already present; skipping duplicate high-availability registration." -Level WARNING -LogFile $LogFile
            } else {
                Write-MigrationLog "[$Name] Cluster error: $_" -Level ERROR -LogFile $LogFile
                throw
            }
        }

        Refresh-SCVMMVirtualMachine -Name $Name -ServerName $ServerName -LogFile $LogFile
        $vmStateAfterHa = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName
        if (-not $vmStateAfterHa.IsHighlyAvailable) {
            if ($clusterVmRegistrationCommand) {
                throw "VM '$Name' is still not highly available in SCVMM after Add-ClusterVirtualMachineRole and refresh."
            }

            throw "VM '$Name' is still not highly available in SCVMM after refresh, and Add-ClusterVirtualMachineRole is unavailable on this execution host. Install/import the FailoverClusters module (with the command available) or run this step from a Failover Clustering management host."
        }

        Write-MigrationLog "[$Name] SCVMM confirms high availability is enabled." -Level SUCCESS -LogFile $LogFile
    }

    try {
        Refresh-SCVMMVirtualMachine -Name $Name -ServerName $ServerName -LogFile $LogFile
        $vmStateBeforeMove = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName
        Write-MigrationLog "[$Name] Preparing host migration validation. Current host: '$($vmStateBeforeMove.HostName)'." -LogFile $LogFile

        Ensure-RsatHyperVInstalled -LogFile $LogFile
        $hyperVMoveCommand = Get-Command -Name "Move-VM" -Module "Hyper-V" -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($hyperVMoveCommand) {
            try {
                & $hyperVMoveCommand -Name $TargetVM.Name -DestinationHost $DestinationHost -ErrorAction Stop
                Write-MigrationLog "[$Name] LiveMigration to $DestinationHost performed via Hyper-V module." -Level SUCCESS -LogFile $LogFile
            } catch {
                if ([string]$_ -match "could not access an expected WMI class|Hyper-V Platform") {
                    Write-MigrationLog "[$Name] Hyper-V Move-VM failed due to local platform limits; retrying migration via SCVMM." -Level WARNING -LogFile $LogFile
                    Start-SCVMMHostMigration -Name $Name -ServerName $ServerName -DestinationHost $DestinationHost
                    Write-MigrationLog "[$Name] LiveMigration to $DestinationHost requested via SCVMM after Hyper-V failure." -Level SUCCESS -LogFile $LogFile
                } else {
                    throw
                }
            }
        } else {
            Write-MigrationLog "[$Name] Hyper-V Move-VM cmdlet unavailable on runner, trying SCVMM move." -Level WARNING -LogFile $LogFile
            Start-SCVMMHostMigration -Name $Name -ServerName $ServerName -DestinationHost $DestinationHost

            Write-MigrationLog "[$Name] LiveMigration to $DestinationHost requested via SCVMM." -Level SUCCESS -LogFile $LogFile
        }

        $destinationHostNormalized = Normalize-HostName -Name $DestinationHost
        $migrationValidationTimeoutSeconds = 600
        $migrationValidationPollIntervalSeconds = 15
        $migrationValidationElapsedSeconds = 0
        $migrationValidated = $false
        do {
            Start-Sleep -Seconds $migrationValidationPollIntervalSeconds
            $migrationValidationElapsedSeconds += $migrationValidationPollIntervalSeconds

            Refresh-SCVMMVirtualMachine -Name $Name -ServerName $ServerName -LogFile $LogFile
            $vmStateAfterMove = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName
            $currentHostNormalized = Normalize-HostName -Name $vmStateAfterMove.HostName

            if ($currentHostNormalized -eq $destinationHostNormalized) {
                Write-MigrationLog "[$Name] LiveMigration validated: VM is now running on '$($vmStateAfterMove.HostName)'." -Level SUCCESS -LogFile $LogFile
                $migrationValidated = $true
                break
            }

            Write-MigrationLog "[$Name] Waiting for live migration completion (current host: '$($vmStateAfterMove.HostName)', expected: '$DestinationHost', elapsed: ${migrationValidationElapsedSeconds}s)." -Level WARNING -LogFile $LogFile
        } while ($migrationValidationElapsedSeconds -lt $migrationValidationTimeoutSeconds)

        if (-not $migrationValidated) {
            throw "LiveMigration validation timed out after $migrationValidationTimeoutSeconds seconds. VM current host: '$($vmStateAfterMove.HostName)', expected destination: '$DestinationHost'."
        }
    } catch {
        if ([string]$_ -match "could not access an expected WMI class|Hyper-V Platform") {
            Write-MigrationLog "[$Name] LiveMigration unavailable on this runner (missing local Hyper-V platform). Migration already completed; run host-to-host move from a Hyper-V capable node or via SCVMM." -Level WARNING -LogFile $LogFile
        } else {
            Write-MigrationLog "[$Name] LiveMigration error: $_" -Level ERROR -LogFile $LogFile
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
    } -ArgumentList @($Name, $ServerName, $BackupTagName)

    Write-MigrationLog "[$Name] Backup tag '$BackupTagName' applied." -LogFile $LogFile
}

function Set-SCVMMOperatingSystem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [AllowNull()]
        [string]$SourceOperatingSystem,

        $OperatingSystemMap,

        [string]$LogFile
    )

    if ([string]::IsNullOrWhiteSpace($SourceOperatingSystem)) {
        Write-MigrationLog "[$Name] No source operating system provided; SCVMM OS update skipped." -Level WARNING -LogFile $LogFile
        return
    }

    $targetOperatingSystem = Resolve-OperatingSystemMapping -OperatingSystem $SourceOperatingSystem -OperatingSystemMap $OperatingSystemMap
    if ([string]::IsNullOrWhiteSpace($targetOperatingSystem)) {
        $normalizedOperatingSystem = ConvertTo-NormalizedOperatingSystemName -Name $SourceOperatingSystem
        Write-MigrationLog "[$Name] No SCVMM OS mapping found for '$normalizedOperatingSystem'." -Level WARNING -LogFile $LogFile
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Set SCVMM operating system to '$targetOperatingSystem'")) {
        return
    }

    $mappingResult = Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName, $TargetOperatingSystemName)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $scvmmOperatingSystems = Get-SCOperatingSystem -VMMServer $server
        $scvmmOperatingSystem = $scvmmOperatingSystems | Where-Object { $_.Name -eq $TargetOperatingSystemName } | Select-Object -First 1
        if (-not $scvmmOperatingSystem) {
            throw "Operating system '$TargetOperatingSystemName' not found in SCVMM."
        }

        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Where-Object { $_.VirtualizationPlatform -eq 'HyperV' } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while setting the operating system."
        }

        Set-SCVirtualMachine -VM $vm -OperatingSystem $scvmmOperatingSystem | Out-Null
        return $scvmmOperatingSystem.Name
    } -ArgumentList @($Name, $ServerName, $targetOperatingSystem)

    Write-MigrationLog "[$Name] SCVMM operating system set to '$mappingResult' from source '$SourceOperatingSystem'." -Level SUCCESS -LogFile $LogFile
}

# ── SCVMM connection ────────────────────────────────────────────────────────

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
        Write-MigrationLog "[$VMName] SCVMM module error hints at a VMM console/runtime mismatch on the runner. Validate that Virtual Machine Manager Console matching the SCVMM server version is installed and restart the shell." -Level ERROR -LogFile $LogFile
    }
    Write-MigrationLog "[$VMName] Failed to connect to SCVMM server '$SCVMMServer': $_" -Level ERROR -LogFile $LogFile
    throw
}

# ── Instant Recovery: start ─────────────────────────────────────────────

if (-not $ForceNetworkConfigOnly) {

Write-MigrationLog "[$VMName] Checking SCVMM in Veeam..." -LogFile $LogFile
$VBRSCVMM = Invoke-VeeamCommand -ScriptBlock {
    param($ScvmmServerName)
    Get-VBRServer | Where-Object { $_.Name -eq $ScvmmServerName -and $_.Type -eq "Scvmm" } |
        Select-Object -First 1 -Property Name, Type
} -ArgumentList @($SCVMMServer)

if (!$VBRSCVMM) {
    Write-MigrationLog "[$VMName] SCVMM $SCVMMServer is not registered in Veeam." -Level ERROR -LogFile $LogFile
    exit 1
}

$Backup = Invoke-VeeamCommand -ScriptBlock {
    param($JobName)
    Get-VBRBackup | Where-Object { $_.Name -eq $JobName } |
        Select-Object -First 1 -Property Name, Id
} -ArgumentList @($BackupJobName)

if (!$Backup) {
    Write-MigrationLog "[$VMName] Backup job '$BackupJobName' not found in Veeam." -Level ERROR -LogFile $LogFile
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
    Write-MigrationLog "[$VMName] Instant Recovery preparation failed: $_" -Level ERROR -LogFile $LogFile
    throw
}

Write-MigrationLog "[$VMName] Starting Instant Recovery..." -LogFile $LogFile
try {
    Write-MigrationLog "[$VMName] Instant Recovery started." -Level SUCCESS -LogFile $LogFile

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

        Write-MigrationLog "[$VMName] Current states: InstantRecovery='$($waitCheck.CurrentState)', RestoreSession='$($waitCheck.RestoreSessionState)' (elapsed: ${elapsed}s)." -LogFile $LogFile

        if ($waitCheck.WaitingDetected) {
            Write-MigrationLog "[$VMName] Instant Recovery in waiting mode (source=$($waitCheck.DetectionSource))." -Level SUCCESS -LogFile $LogFile
            break
        }


        Start-Sleep -Seconds $WaitingPollIntervalSeconds
        $elapsed += $WaitingPollIntervalSeconds
    } while ($elapsed -lt $WaitingTimeoutSeconds)

    if ($elapsed -ge $WaitingTimeoutSeconds) {
        throw "Timeout of $WaitingTimeoutSeconds seconds reached while waiting for WaitingForUserAction."
    }
} catch {
    Write-MigrationLog "[$VMName] Instant Recovery error: $_" -Level ERROR -LogFile $LogFile
    throw
}

# ── Instant Recovery: finalization ─────────────────────────────────────────

$IRSession = Invoke-VeeamCommand -ScriptBlock {
    param($Vm)
    Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } |
        Select-Object -First 1 -Property VMName, State
} -ArgumentList @($VMName)

if (!$IRSession) {
    Write-MigrationLog "[$VMName] No active Instant Recovery session." -Level ERROR -LogFile $LogFile
    exit 1
}

$vmInScvmm = Invoke-SCVMMCommand -ScriptBlock {
    param($Name, $ServerName)
    $server = Get-SCVMMServer -ComputerName $ServerName
    Get-SCVirtualMachine -Name $Name -VMMServer $server
} -ArgumentList @($VMName, $VMMServerName)
if (!$vmInScvmm) {
    Write-MigrationLog "[$VMName] VM missing from SCVMM, finalization impossible." -Level ERROR -LogFile $LogFile
    exit 1
}

Write-MigrationLog "[$VMName] Finalizing Instant Recovery..." -LogFile $LogFile
try {
    Invoke-VeeamCommand -ScriptBlock {
        param($Vm)
        $irSession = Get-VBRInstantRecovery | Where-Object { $_.VMName -eq $Vm } | Select-Object -First 1
        if (-not $irSession) {
            throw "No active Instant Recovery session for VM '$Vm'."
        }
        Start-VBRHvInstantRecoveryMigration -InstantRecovery $irSession | Out-Null
    } -ArgumentList @($VMName)

    Write-MigrationLog "[$VMName] Finalization completed." -Level SUCCESS -LogFile $LogFile

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
            Write-MigrationLog "[$VMName] Restore session not yet visible after finalization start (elapsed: ${finalizationElapsed}s)." -Level WARNING -LogFile $LogFile
        } else {
            Write-MigrationLog "[$VMName] Restore session '$($finalizationCheck.Name)' status: State='$($finalizationCheck.State)', Result='$($finalizationCheck.Result)' (elapsed: ${finalizationElapsed}s)." -LogFile $LogFile

            if ($finalizationCheck.Result -eq "Success") {
                Write-MigrationLog "[$VMName] VM restored permanently; network reconfiguration can start." -Level SUCCESS -LogFile $LogFile
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
    Write-MigrationLog "[$VMName] Finalization error: $_" -Level ERROR -LogFile $LogFile
    throw
}
}

# ── Network mapping ────────────────────────────────────────────────────────────

if ($ForceNetworkConfigOnly) {
    Write-MigrationLog "[$VMName] ForceNetworkConfigOnly enabled: skipping Instant Recovery/finalization and replaying only network/OS/post-configuration actions." -Level WARNING -LogFile $LogFile
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

Invoke-SCVMMNetworkAndPostConfig `
    -Name $VMName `
    -ServerName $VMMServerName `
    -Vlan $VlanId `
    -AdapterVlanMappings $adapterVlanMappings `
    -SourceOperatingSystem $OperatingSystem `
    -SourceRemark $Remark `
    -Config $Config `
    -BackupTagName $BackupTag `
    -ClusterName $HyperVCluster `
    -DestinationHost $HyperVHost2 `
    -LogFile $LogFile

Write-MigrationLog "[$VMName] Migration completed." -Level SUCCESS -LogFile $LogFile
