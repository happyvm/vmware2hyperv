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

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback
if (-not $ForceNetworkConfigOnly) {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
} else {
    Write-MigrationLog "[$VMName] ForceNetworkConfigOnly enabled: skipping Veeam module import." -LogFile $LogFile
}

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

    $TargetVM = Invoke-SCVMMCommand -ScriptBlock {
        param($Name, $ServerName)
        $server = Get-SCVMMServer -ComputerName $ServerName
        Get-SCVirtualMachine -Name $Name -VMMServer $server |
            Where-Object { $_.VirtualizationPlatform -eq "HyperV" } |
            Select-Object -First 1
    } -ArgumentList @($Name, $ServerName)
    if (!$TargetVM) {
        Write-MigrationLog "[$Name] VM not found in SCVMM." -Level WARNING -LogFile $LogFile
        return
    }

    $networkConfigRetryDelaySeconds = 30
    $networkConfigRetryCount = 2

    $networkResult = $null
    for ($networkConfigAttempt = 1; $networkConfigAttempt -le $networkConfigRetryCount; $networkConfigAttempt++) {
        try {
            $networkResult = Invoke-SCVMMCommand -ScriptBlock {
        param(
            $Name,
            $ServerName,
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

        $allVMNetworks = @(Get-SCVMNetwork -VMMServer $server | Sort-Object Name)
        $allVMSubnets = @(Get-SCVMSubnet -VMMServer $server | Sort-Object Name)

        $portClass = Get-SCPortClassification -VMMServer $server | Where-Object { $_.Name -eq $PortClassificationName } | Select-Object -First 1
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

        function Test-IsZeroMacAddress {
            param([AllowNull()][string]$Value)

            $normalized = Normalize-MacAddress -Value $Value
            return ($normalized -and $normalized -eq '000000000000')
        }

        function Convert-ToScvmmStaticMacAddress {
            param([AllowNull()][string]$Value)

            $normalized = Normalize-MacAddress -Value $Value
            if (-not $normalized -or $normalized.Length -ne 12) {
                return $null
            }

            return (($normalized -split '(.{2})' | Where-Object { $_ }) -join '-')
        }

        function Get-ScvmmNetworkAdapters {
            param(
                $CurrentVm,
                $CurrentServer,
                [string]$CurrentVmName
            )

            $adapters = @(try { Get-SCVirtualNetworkAdapter -VM $CurrentVm -ErrorAction Stop } catch { @() })
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

        $matchingDefaultNetworks = @($allVMNetworks | Where-Object { $_.Name -like "*$Vlan*" -or $_.Description -like "*$Vlan*" })
        $matchingDefaultSubnets = @($allVMSubnets | Where-Object { $_.Name -like "*$Vlan*" -or $_.Description -like "*$Vlan*" })
        if ($matchingDefaultNetworks.Count -eq 0 -or $matchingDefaultSubnets.Count -eq 0) {
            throw "No VMNetwork/VMSubnet found for default VLAN $Vlan."
        }

        $networkMappingsByVlan = @{}
        $networkMappingsBySourceNetworkName = @{}
        $networkMappingsByVlan[$Vlan] = [pscustomobject]@{
            VMNetwork               = $matchingDefaultNetworks | Select-Object -First 1
            VMSubnet                = $matchingDefaultSubnets | Select-Object -First 1
            Vlan                    = $Vlan
            Ambiguous               = ($matchingDefaultNetworks.Count -gt 1 -or $matchingDefaultSubnets.Count -gt 1)
            CandidateVMNetworkNames = @($matchingDefaultNetworks | ForEach-Object { [string]$_.Name })
            CandidateVMSubnetNames  = @($matchingDefaultSubnets  | ForEach-Object { [string]$_.Name })
            ResolutionMode          = 'default-vlan'
        }

        $adapterMappings = @()
        if ($AdapterVlanMappings) {
            $adapterMappings = @($AdapterVlanMappings | Where-Object { $_.VlanId -match '^\d+$' })
        }

        foreach ($adapterMapping in $adapterMappings) {
            $mappingVlan = [string]$adapterMapping.VlanId
            $mappingNetworkName = [string]$adapterMapping.NetworkName

            if (-not $networkMappingsByVlan.ContainsKey($mappingVlan)) {
                $matchingNetworks = @($allVMNetworks | Where-Object { $_.Name -like "*$mappingVlan*" -or $_.Description -like "*$mappingVlan*" })
                $matchingSubnets  = @($allVMSubnets  | Where-Object { $_.Name -like "*$mappingVlan*" -or $_.Description -like "*$mappingVlan*" })
                if ($matchingNetworks.Count -gt 0 -and $matchingSubnets.Count -gt 0) {
                    $networkMappingsByVlan[$mappingVlan] = [pscustomobject]@{
                        VMNetwork               = $matchingNetworks | Select-Object -First 1
                        VMSubnet                = $matchingSubnets  | Select-Object -First 1
                        Vlan                    = $mappingVlan
                        Ambiguous               = ($matchingNetworks.Count -gt 1 -or $matchingSubnets.Count -gt 1)
                        CandidateVMNetworkNames = @($matchingNetworks | ForEach-Object { [string]$_.Name })
                        CandidateVMSubnetNames  = @($matchingSubnets  | ForEach-Object { [string]$_.Name })
                        ResolutionMode          = 'vlan'
                    }
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($mappingNetworkName) -and -not $networkMappingsBySourceNetworkName.ContainsKey($mappingNetworkName)) {
                $matchingByName = @($allVMNetworks | Where-Object { $_.Name -eq $mappingNetworkName -or $_.Description -eq $mappingNetworkName })
                if (-not $matchingByName) {
                    $matchingByName = @($allVMNetworks | Where-Object { $_.Name -like "*$mappingNetworkName*" -or $_.Description -like "*$mappingNetworkName*" })
                }
                if ($matchingByName.Count -gt 0) {
                    $selectedByName = $matchingByName | Select-Object -First 1
                    $matchingSubnetByName = @($allVMSubnets | Where-Object {
                        ($_.VMNetwork -and $_.VMNetwork.ID -eq $selectedByName.ID) -or
                        ($_.VMNetworkName -and $_.VMNetworkName -eq $selectedByName.Name)
                    })
                    if ($matchingSubnetByName.Count -gt 0) {
                        $networkMappingsBySourceNetworkName[$mappingNetworkName] = [pscustomobject]@{
                            VMNetwork               = $selectedByName
                            VMSubnet                = $matchingSubnetByName | Select-Object -First 1
                            Vlan                    = if ($mappingVlan -match '^\d+$') { $mappingVlan } else { $Vlan }
                            Ambiguous               = ($matchingByName.Count -gt 1 -or $matchingSubnetByName.Count -gt 1)
                            CandidateVMNetworkNames = @($matchingByName     | ForEach-Object { [string]$_.Name })
                            CandidateVMSubnetNames  = @($matchingSubnetByName | ForEach-Object { [string]$_.Name })
                            ResolutionMode          = 'source-network-name'
                        }
                    }
                }
            }
        }

        $mappedAdapters = 0
        $fallbackMappedAdapters = 0
        $indexedFallbackMappedAdapters = 0
        $macMatchedAdapters = 0
        $adapterResolutionWarnings = New-Object 'System.Collections.Generic.List[string]'

        if ($networkMappingsByVlan[$Vlan].Ambiguous) {
            $defaultCandidates = $networkMappingsByVlan[$Vlan].CandidateVMNetworkNames -join ', '
            $defaultSelected   = [string]$networkMappingsByVlan[$Vlan].VMNetwork.Name
            [void]$adapterResolutionWarnings.Add("[$Name] Default VLAN $Vlan mapping is ambiguous. Selected='$defaultSelected'; Candidates='$defaultCandidates'. First deterministic candidate selected.")
        }

        $macMatchesByTargetIndex = @{}
        $indexFallbackByTargetIndex = @{}
        $usedSourceIndexes = New-Object 'System.Collections.Generic.HashSet[int]'

        # 1) First pass: exact match by preserved MAC address
        for ($adapterIndex = 0; $adapterIndex -lt $networkAdapters.Count; $adapterIndex++) {
            $networkAdapter = $networkAdapters[$adapterIndex]

            $adapterMac = Normalize-MacAddress -Value ([string]$networkAdapter.MACAddressString)
            if (-not $adapterMac) {
                $adapterMac = Normalize-MacAddress -Value ([string]$networkAdapter.MACAddress)
            }

            if (-not $adapterMac -or (Test-IsZeroMacAddress -Value $adapterMac)) {
                continue
            }

            for ($sourceIndex = 0; $sourceIndex -lt $adapterMappings.Count; $sourceIndex++) {
                if ($usedSourceIndexes.Contains($sourceIndex)) {
                    continue
                }

                $sourceAdapter = $adapterMappings[$sourceIndex]
                $sourceMac = Normalize-MacAddress -Value ([string]$sourceAdapter.MacAddress)

                if ($sourceMac -and $sourceMac -eq $adapterMac) {
                    $macMatchesByTargetIndex[$adapterIndex] = $sourceAdapter
                    [void]$usedSourceIndexes.Add($sourceIndex)
                    break
                }
            }
        }

        # 2) Second pass: fallback by remaining adapter order only for still-unmatched NICs
        $remainingTargetIndexes = @()
        for ($adapterIndex = 0; $adapterIndex -lt $networkAdapters.Count; $adapterIndex++) {
            if (-not $macMatchesByTargetIndex.ContainsKey($adapterIndex)) {
                $remainingTargetIndexes += $adapterIndex
            }
        }

        $remainingSourceIndexes = @()
        for ($sourceIndex = 0; $sourceIndex -lt $adapterMappings.Count; $sourceIndex++) {
            if (-not $usedSourceIndexes.Contains($sourceIndex)) {
                $remainingSourceIndexes += $sourceIndex
            }
        }

        $fallbackPairs = [Math]::Min($remainingTargetIndexes.Count, $remainingSourceIndexes.Count)
        for ($i = 0; $i -lt $fallbackPairs; $i++) {
            $targetIndex = $remainingTargetIndexes[$i]
            $sourceIndex = $remainingSourceIndexes[$i]
            $indexFallbackByTargetIndex[$targetIndex] = $adapterMappings[$sourceIndex]
            [void]$usedSourceIndexes.Add($sourceIndex)
        }

        for ($adapterIndex = 0; $adapterIndex -lt $networkAdapters.Count; $adapterIndex++) {
            $networkAdapter = $networkAdapters[$adapterIndex]
            $desiredMapping = $null
            $selectedSourceAdapter = $null

            if ($macMatchesByTargetIndex.ContainsKey($adapterIndex)) {
                $selectedSourceAdapter = $macMatchesByTargetIndex[$adapterIndex]

                if ($networkMappingsByVlan.ContainsKey([string]$selectedSourceAdapter.VlanId)) {
                    $desiredMapping = $networkMappingsByVlan[[string]$selectedSourceAdapter.VlanId]
                } elseif (
                    -not [string]::IsNullOrWhiteSpace([string]$selectedSourceAdapter.NetworkName) -and
                    $networkMappingsBySourceNetworkName.ContainsKey([string]$selectedSourceAdapter.NetworkName)
                ) {
                    $desiredMapping = $networkMappingsBySourceNetworkName[[string]$selectedSourceAdapter.NetworkName]
                }

                if ($desiredMapping) {
                    $macMatchedAdapters++
                }
            }

            if (-not $desiredMapping -and $indexFallbackByTargetIndex.ContainsKey($adapterIndex)) {
                $selectedSourceAdapter = $indexFallbackByTargetIndex[$adapterIndex]

                if ($networkMappingsByVlan.ContainsKey([string]$selectedSourceAdapter.VlanId)) {
                    $desiredMapping = $networkMappingsByVlan[[string]$selectedSourceAdapter.VlanId]
                } elseif (
                    -not [string]::IsNullOrWhiteSpace([string]$selectedSourceAdapter.NetworkName) -and
                    $networkMappingsBySourceNetworkName.ContainsKey([string]$selectedSourceAdapter.NetworkName)
                ) {
                    $desiredMapping = $networkMappingsBySourceNetworkName[[string]$selectedSourceAdapter.NetworkName]
                }

                if ($desiredMapping) {
                    $indexedFallbackMappedAdapters++
                }
            }

            $usedDefaultVlanFallback = $false
            if (-not $desiredMapping) {
                $desiredMapping = $networkMappingsByVlan[$Vlan]
                $usedDefaultVlanFallback = $true
                $fallbackMappedAdapters++
            }

            if ($usedDefaultVlanFallback) {
                $sourceMacText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.MacAddress } else { '<unknown>' }
                $sourceNetworkText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.NetworkName } else { '<unknown>' }
                $sourceVlanText = if ($selectedSourceAdapter -and [string]$selectedSourceAdapter.VlanId -match '^\d+$') { [string]$selectedSourceAdapter.VlanId } else { '<unknown>' }
                $selectedVmNetworkText = [string]$desiredMapping.VMNetwork.Name
                $reasonText = if ($sourceVlanText -ne '<unknown>') {
                    "No candidate found for source VLAN '$sourceVlanText'; mapped to default VLAN $Vlan."
                } else {
                    "No source adapter information; mapped to default VLAN $Vlan."
                }
                [void]$adapterResolutionWarnings.Add(
                    "[$Name] Adapter #$($adapterIndex + 1) fallback mapping used.`n" +
                    "SourceMac='$sourceMacText'`n" +
                    "SourceNetwork='$sourceNetworkText'`n" +
                    "SourceVlan='$sourceVlanText'`n" +
                    "Candidates='<none>'`n" +
                    "Selected='$selectedVmNetworkText' (default VLAN $Vlan)`n" +
                    "Reason='$reasonText'"
                )
            } elseif ($desiredMapping.Ambiguous) {
                $sourceMacText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.MacAddress } else { '<unknown>' }
                $sourceNetworkText = if ($selectedSourceAdapter) { [string]$selectedSourceAdapter.NetworkName } else { '<unknown>' }
                $sourceVlanText = if ($selectedSourceAdapter -and $selectedSourceAdapter.VlanId) { [string]$selectedSourceAdapter.VlanId } else { [string]$desiredMapping.Vlan }
                $candidateNetworksText = if ($desiredMapping.CandidateVMNetworkNames) { $desiredMapping.CandidateVMNetworkNames -join ', ' } else { '<none>' }
                $selectedVmNetworkText = [string]$desiredMapping.VMNetwork.Name
                $resolutionReason = switch ([string]$desiredMapping.ResolutionMode) {
                    'source-network-name' { 'Ambiguous source-network-name match; first deterministic candidate selected.' }
                    'vlan' { 'Ambiguous VLAN match; first deterministic candidate selected.' }
                    default { 'Ambiguous default VLAN mapping; first deterministic candidate selected.' }
                }
                [void]$adapterResolutionWarnings.Add(
                    "[$Name] Adapter #$($adapterIndex + 1) fallback mapping used.`n" +
                    "SourceMac='$sourceMacText'`n" +
                    "SourceNetwork='$sourceNetworkText'`n" +
                    "SourceVlan='$sourceVlanText'`n" +
                    "Candidates='$candidateNetworksText'`n" +
                    "Selected='$selectedVmNetworkText'`n" +
                    "Reason='$resolutionReason'"
                )
            }

            $setAdapterParameters = @{
                VirtualNetworkAdapter = $networkAdapter
                VMNetwork             = $desiredMapping.VMNetwork
                VMSubnet              = $desiredMapping.VMSubnet
                VLanEnabled           = $true
                VLanID                = $desiredMapping.Vlan
                VirtualNetwork        = $LogicalSwitch
                IPv4AddressType       = 'Dynamic'
                IPv6AddressType       = 'Dynamic'
                PortClassification    = $portClass
            }

            $targetAdapterMac = Normalize-MacAddress -Value ([string]$networkAdapter.MACAddressString)
            if (-not $targetAdapterMac) {
                $targetAdapterMac = Normalize-MacAddress -Value ([string]$networkAdapter.MACAddress)
            }

            if ((Test-IsZeroMacAddress -Value $targetAdapterMac) -and $selectedSourceAdapter) {
                $sourceStaticMac = Convert-ToScvmmStaticMacAddress -Value ([string]$selectedSourceAdapter.MacAddress)
                if ($sourceStaticMac) {
                    $setAdapterParameters['MACAddressType'] = 'Static'
                    $setAdapterParameters['MACAddress'] = $sourceStaticMac
                    [void]$adapterResolutionWarnings.Add("[$Name] Adapter #$($adapterIndex + 1): SCVMM returned 00:00:00:00:00:00, forcing static MAC from VMware ($sourceStaticMac).")
                }
            }

            Set-SCVirtualNetworkAdapter @setAdapterParameters | Out-Null
            $mappedAdapters++
        }

        if ($mappedAdapters -eq 0) {
            throw "No virtual network adapter could be mapped to a VLAN."
        }

        [pscustomobject]@{
            AdapterCount              = $networkAdapters.Count
            MappedAdapterCount        = $mappedAdapters
            MacMatchedAdapterCount    = $macMatchedAdapters
            FallbackAdapterCount      = $fallbackMappedAdapters
            IndexedFallbackCount      = $indexedFallbackMappedAdapters
            AdapterWarnings           = @($adapterResolutionWarnings)
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

    if ($networkResult -and $networkResult.MacMatchedAdapterCount -gt 0) {
        Write-MigrationLog "[$Name] $($networkResult.MacMatchedAdapterCount)/$($networkResult.AdapterCount) adapter(s) matched by preserved MAC address." -LogFile $LogFile
    }

    if ($networkResult -and $networkResult.IndexedFallbackCount -gt 0) {
        Write-MigrationLog "[$Name] $($networkResult.IndexedFallbackCount) adapter(s) were matched by adapter order fallback." -Level WARNING -LogFile $LogFile
    }

    if ($networkResult -and $networkResult.FallbackAdapterCount -gt 0) {
        Write-MigrationLog "[$Name] $($networkResult.FallbackAdapterCount)/$($networkResult.AdapterCount) adapter(s) had no exact match and were kept on default VLAN $Vlan." -Level WARNING -LogFile $LogFile
    }

    if ($networkResult -and $networkResult.AdapterWarnings) {
        foreach ($adapterWarning in @($networkResult.AdapterWarnings)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$adapterWarning)) {
                Write-MigrationLog $adapterWarning -Level WARNING -LogFile $LogFile
            }
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

        try {
            Start-SCVMMHostMigration -Name $Name -ServerName $ServerName -DestinationHost $DestinationHost
            Write-MigrationLog "[$Name] LiveMigration to $DestinationHost requested via SCVMM." -Level SUCCESS -LogFile $LogFile
        } catch {
            Write-MigrationLog "[$Name] SCVMM migration failed; retrying via Hyper-V Move-VM. Details: $_" -Level WARNING -LogFile $LogFile

            Ensure-RsatHyperVInstalled -LogFile $LogFile
            $hyperVMoveCommand = Get-Command -Name "Move-VM" -Module "Hyper-V" -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($hyperVMoveCommand) {
                & $hyperVMoveCommand -Name $TargetVM.Name -DestinationHost $DestinationHost -ErrorAction Stop
                Write-MigrationLog "[$Name] LiveMigration to $DestinationHost performed via Hyper-V module." -Level SUCCESS -LogFile $LogFile
            } else {
                throw "LiveMigration failed: SCVMM move failed and Hyper-V Move-VM cmdlet is unavailable on this runner."
            }
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
    $msg = "[$VMName] SCVMM $SCVMMServer is not registered in Veeam."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
}

$Backup = Invoke-VeeamCommand -ScriptBlock {
    param($JobName)
    Get-VBRBackup | Where-Object { $_.Name -eq $JobName } |
        Select-Object -First 1 -Property Name, Id
} -ArgumentList @($BackupJobName)

if (!$Backup) {
    $msg = "[$VMName] Backup job '$BackupJobName' not found in Veeam."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
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
    $msg = "[$VMName] No active Instant Recovery session."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
}

$vmInScvmm = Invoke-SCVMMCommand -ScriptBlock {
    param($Name, $ServerName)
    $server = Get-SCVMMServer -ComputerName $ServerName
    Get-SCVirtualMachine -Name $Name -VMMServer $server
} -ArgumentList @($VMName, $VMMServerName)
if (!$vmInScvmm) {
    $msg = "[$VMName] VM missing from SCVMM, finalization impossible."
    Write-MigrationLog $msg -Level ERROR -LogFile $LogFile
    throw $msg
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
