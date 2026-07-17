<#
.SYNOPSIS
    Post-configuration functions for step3: OS mapping, high availability,
    LiveMigration, and backup tag.

.DESCRIPTION
    Extracted from step3-MigrateVM.ps1 (§4 du plan de refactoring).
    These functions are called from Invoke-SCVMMNetworkAndPostConfig after
    network configuration and Integration Services setup complete.

    Functions:
    - Set-SCVMMOperatingSystem   Set the SCVMM guest OS type from the VMware source OS.
    - Register-VmHighAvailability Register the VM as a clustered role and validate HA state.
    - Move-VmToSecondHost         Live-migrate the VM to the secondary Hyper-V host.
    - Set-VmBackupTag             Apply the Veeam backup tag to the SCVMM VM object.

.NOTES
    Depends on lib.ps1 (Write-MigrationLog, Invoke-SCVMMCommand, Import-RequiredModule,
    Install-RsatHyperV, Get-SCVMMVmRuntimeState, Start-SCVMMHostMigration,
    Get-SCVMMHostMigrationJobState, ConvertTo-NormalizedHostName,
    ConvertTo-NormalizedOperatingSystemName,
    Resolve-OperatingSystemMapping).
#>

Set-StrictMode -Version Latest

function Set-SCVMMOperatingSystem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $false)]
        [PSObject]$Result
    )

    $Name = $Context.VMName
    $ServerName = $Context.VMMServerName
    $SourceOperatingSystem = $Context.OperatingSystem
    $OperatingSystemMap = $Context.Config.SCVMM.OperatingSystemMap
    $LogFile = $Context.LogFile

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

function Register-VmHighAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $false)]
        [PSObject]$Result
    )

    $Name = $Context.VMName
    $ServerName = $Context.VMMServerName
    $ClusterName = $Context.HyperVCluster
    $LogFile = $Context.LogFile

    # Get-SCVMMVmRuntimeState returns $null when the VM is missing from SCVMM;
    # a bare property read on $null throws under StrictMode.
    $vmStateBeforeHa = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName
    if (-not $vmStateBeforeHa) {
        throw "VM '$Name' not found in SCVMM while checking high availability."
    }
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
                & $clusterVmRegistrationCommand -Cluster $ClusterName -VirtualMachine $Name
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

        $vmStateAfterHa = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName -Refresh
        if (-not ($vmStateAfterHa -and $vmStateAfterHa.IsHighlyAvailable)) {
            if ($clusterVmRegistrationCommand) {
                throw "VM '$Name' is still not highly available in SCVMM after Add-ClusterVirtualMachineRole and refresh."
            }

            throw "VM '$Name' is still not highly available in SCVMM after refresh, and Add-ClusterVirtualMachineRole is unavailable on this execution host. Install/import the FailoverClusters module (with the command available) or run this step from a Failover Clustering management host."
        }

        Write-MigrationLog "[$Name] SCVMM confirms high availability is enabled." -Level SUCCESS -LogFile $LogFile
    }
}

function Move-VmToSecondHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $false)]
        [PSObject]$Result
    )

    $Name = $Context.VMName
    $ServerName = $Context.VMMServerName
    $DestinationHost = $Context.HyperVHost2
    $LogFile = $Context.LogFile

    try {
        $vmStateBeforeMove = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName -Refresh
        if (-not $vmStateBeforeMove) {
            throw "VM '$Name' not found in SCVMM while preparing the host migration."
        }
        Write-MigrationLog "[$Name] Preparing host migration validation. Current host: '$($vmStateBeforeMove.HostName)'." -LogFile $LogFile

        $scvmmMigrationJob = $null

        try {
            $scvmmMigrationJob = Start-SCVMMHostMigration -Name $Name -ServerName $ServerName -DestinationHost $DestinationHost
            if ($scvmmMigrationJob -and -not [string]::IsNullOrWhiteSpace($scvmmMigrationJob.ID)) {
                Write-MigrationLog "[$Name] LiveMigration to $DestinationHost requested via SCVMM (job: '$($scvmmMigrationJob.Name)', id: '$($scvmmMigrationJob.ID)', status: '$($scvmmMigrationJob.Status)')." -Level SUCCESS -LogFile $LogFile
            } else {
                Write-MigrationLog "[$Name] LiveMigration to $DestinationHost requested via SCVMM." -Level SUCCESS -LogFile $LogFile
            }
        } catch {
            Write-MigrationLog "[$Name] SCVMM migration failed; retrying via Hyper-V Move-VM. Details: $_" -Level WARNING -LogFile $LogFile

            Install-RsatHyperV -LogFile $LogFile
            $hyperVMoveCommand = Get-Command -Name "Move-VM" -Module "Hyper-V" -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($hyperVMoveCommand) {
                & $hyperVMoveCommand -Name $Name -DestinationHost $DestinationHost -ErrorAction Stop
                Write-MigrationLog "[$Name] LiveMigration to $DestinationHost performed via Hyper-V module." -Level SUCCESS -LogFile $LogFile
            } else {
                throw "LiveMigration failed: SCVMM move failed and Hyper-V Move-VM cmdlet is unavailable on this runner."
            }
        }

        $destinationHostNormalized = ConvertTo-NormalizedHostName -Name $DestinationHost
        $migrationValidationTimeoutSeconds = [int](Get-MigrationConfigValue -Config $Context.Config -Path 'Timeouts.LiveMigration.ValidationSeconds' -Default 600)
        $migrationValidationPollIntervalSeconds = 15
        $migrationValidationElapsedSeconds = 0
        $migrationValidated = $false
        do {
            Start-Sleep -Seconds $migrationValidationPollIntervalSeconds
            $migrationValidationElapsedSeconds += $migrationValidationPollIntervalSeconds

            $vmStateAfterMove = Get-SCVMMVmRuntimeState -Name $Name -ServerName $ServerName -Refresh
            if (-not $vmStateAfterMove) {
                # Transient SCVMM refresh gap (VM object briefly unavailable during
                # the move): keep polling instead of throwing on a $null state.
                Write-MigrationLog "[$Name] VM state unavailable from SCVMM during migration validation (elapsed: ${migrationValidationElapsedSeconds}s); retrying." -Level WARNING -LogFile $LogFile
                continue
            }
            $currentHostNormalized = ConvertTo-NormalizedHostName -Name $vmStateAfterMove.HostName

            if ($scvmmMigrationJob -and -not [string]::IsNullOrWhiteSpace($scvmmMigrationJob.ID)) {
                $scvmmMigrationJobState = Get-SCVMMHostMigrationJobState -ServerName $ServerName -JobId $scvmmMigrationJob.ID
                if ($scvmmMigrationJobState) {
                    $jobStatus = [string]$scvmmMigrationJobState.Status
                    if ($jobStatus -match 'Failed|Canceled|Cancelled') {
                        $jobDetails = @($scvmmMigrationJobState.StatusString, $scvmmMigrationJobState.ErrorInfo) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                        throw "LiveMigration SCVMM job '$($scvmmMigrationJobState.Name)' ended with status '$jobStatus'. $($jobDetails -join ' ')"
                    }
                }
            }

            if ($currentHostNormalized -eq $destinationHostNormalized) {
                Write-MigrationLog "[$Name] LiveMigration validated: VM is now running on '$($vmStateAfterMove.HostName)'." -Level SUCCESS -LogFile $LogFile
                $migrationValidated = $true
                break
            }

            Write-MigrationLog "[$Name] Waiting for live migration completion (current host: '$($vmStateAfterMove.HostName)', expected: '$DestinationHost', elapsed: ${migrationValidationElapsedSeconds}s)." -Level WARNING -LogFile $LogFile
        } while ($migrationValidationElapsedSeconds -lt $migrationValidationTimeoutSeconds)

        if (-not $migrationValidated) {
            $lastKnownHost = if ($vmStateAfterMove) { [string]$vmStateAfterMove.HostName } else { '<unknown>' }
            throw "LiveMigration validation timed out after $migrationValidationTimeoutSeconds seconds. VM current host: '$lastKnownHost', expected destination: '$DestinationHost'."
        }
    } catch {
        if ([string]$_ -match "could not access an expected WMI class|Hyper-V Platform") {
            Write-MigrationLog "[$Name] LiveMigration unavailable on this runner (missing local Hyper-V platform). Migration already completed; run host-to-host move from a Hyper-V capable node or via SCVMM." -Level WARNING -LogFile $LogFile
        } else {
            # Propagate so the worker records the task as failed: swallowing the error
            # here used to mark VMs left on the wrong host as successful migrations.
            Write-MigrationLog "[$Name] LiveMigration error: $_" -Level ERROR -LogFile $LogFile
            throw
        }
    }
}

function Set-VmBackupTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $false)]
        [PSObject]$Result
    )

    $Name = $Context.VMName
    $ServerName = $Context.VMMServerName
    $TagName = $Context.BackupTag
    $LogFile = $Context.LogFile

    Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName, $BackupTagName)
        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while setting tag."
        }

        Set-SCVirtualMachine -VM $vm -Tag $BackupTagName | Out-Null
    } -ArgumentList @($Name, $ServerName, $TagName)

    Write-MigrationLog "[$Name] Backup tag '$TagName' applied." -LogFile $LogFile
}

# ---------------------------------------------------------------------------
# Set-VmIntegrationServices — configure Hyper-V Integration Services
# ---------------------------------------------------------------------------
function Set-VmIntegrationServices {
    <#
    .SYNOPSIS
        Configure Hyper-V Integration Services for the restored VM.

    .DESCRIPTION
        Enables key Integration Services (OS shutdown, data exchange, heartbeat,
        backup, guest services) and disables time synchronization (managed by
        the guest). Extracted from Set-VmNetworkConfiguration (BEA-283).

    .PARAMETER Context
        Hashtable with keys: VMName, VMMServerName, LogFile.

    .PARAMETER Result
        Task result object (not modified by this function; phase tracking is
        handled by the orchestrator via Invoke-Phase).

    .EXAMPLE
        Set-VmIntegrationServices -Context $context -Result $result
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $false)]
        [PSObject]$Result
    )

    $Name = $Context.VMName
    $ServerName = $Context.VMMServerName
    $LogFile = $Context.LogFile

    Write-MigrationLog "[$Name] Configuring Integration Services..." -LogFile $LogFile

    Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server |
            Where-Object { $_.VirtualizationPlatform -eq 'HyperV' } |
            Select-Object -First 1
        if (-not $vm) {
            throw "VM '$VmName' not found in SCVMM while configuring Integration Services."
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

        Set-SCVirtualMachine @setVmParameters | Out-Null

    } -ArgumentList @($Name, $ServerName)

    Write-MigrationLog "[$Name] Integration Services configured." -LogFile $LogFile
}
