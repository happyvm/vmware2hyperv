<#
.SYNOPSIS
    SCVMM connection and helper functions for step3 migration.

.DESCRIPTION
    Function-only file (no inline execution). Contains the SCVMM connection
    logic with IndigoLayer recovery and reusable SCVMM operation helpers.
    These helpers are used by Step3.PostConfig.ps1 functions (HA registration,
    LiveMigration).

    Functions:
    - Connect-Step3Scvmm           SCVMM connection with IndigoLayer retry
    - Start-SCVMMHostMigration     Initiate VM host migration via SCVMM
    - Get-SCVMMHostMigrationJobState Query a SCVMM migration job status
    - Get-SCVMMVmRuntimeState      Query VM runtime state (host, HA, status)
    - ConvertTo-NormalizedHostName  Normalize hostname for comparison

.NOTES
    Part of the vmware2hyperv migration toolkit — step3 refactoring §3.
    Must be loaded BEFORE Step3.PostConfig.ps1 — the alphabetical sort order
    (ConnectScvmm < PostConfig) guarantees this.
    Depends on lib.ps1 (Invoke-SCVMMCommand, Write-MigrationLog,
    Install-RsatHyperV, Repair-WindowsOnlyModuleImport).
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Connect-Step3Scvmm — SCVMM connection with IndigoLayer recovery
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Connect to the SCVMM server, with automatic fallback to the Windows
    PowerShell compatibility session when the module fails in PS7.

.DESCRIPTION
    Attempts to connect to the SCVMM server. If the initial attempt fails with
    an "IndigoLayer" or "type initializer" error (indicating the SCVMM module's
    WCF runtime cannot work in PowerShell 7), the function repairs the module
    import through the WinPS compat session and retries once.

.PARAMETER SCVMMServer
    SCVMM server hostname or FQDN. Mandatory.

.PARAMETER VMName
    VM name for logging context. Mandatory.

.PARAMETER LogFile
    Path to the migration log file. Mandatory.

.EXAMPLE
    $vmmServerName = Connect-Step3Scvmm -SCVMMServer "scvmm01.contoso.com" -VMName "SRV-WEB01" -LogFile $LogFile
#>
function Connect-Step3Scvmm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SCVMMServer,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$LogFile
    )

    $connectToScvmmServer = {
        Invoke-SCVMMCommand -ScriptBlock {
            param($ServerName)
            $server = Get-SCVMMServer -ComputerName $ServerName
            if (-not $server) {
                throw "SCVMM server '$ServerName' not found."
            }
            return $server.Name
        } -ArgumentList @($SCVMMServer)
    }

    try {
        $VMMServerName = & $connectToScvmmServer
    } catch {
        if ([string]$_ -match "IndigoLayer|type initializer" -and (Repair-WindowsOnlyModuleImport -Name "VirtualMachineManager" -LogFile $LogFile)) {
            try {
                $VMMServerName = & $connectToScvmmServer
                Write-MigrationLog "[$VMName] SCVMM connection recovered through the Windows PowerShell compatibility session." -Level SUCCESS -LogFile $LogFile
            } catch {
                Write-MigrationLog "[$VMName] SCVMM connection still failing after Windows PowerShell compatibility re-import. Validate that the Virtual Machine Manager Console matching the SCVMM server version is installed on the runner. Details: $_" -Level ERROR -LogFile $LogFile
                throw
            }
        } else {
            if ([string]$_ -match "IndigoLayer|type initializer") {
                Write-MigrationLog "[$VMName] SCVMM module error hints at a VMM console/runtime mismatch on the runner. Validate that Virtual Machine Manager Console matching the SCVMM server version is installed and restart the shell." -Level ERROR -LogFile $LogFile
            }
            Write-MigrationLog "[$VMName] Failed to connect to SCVMM server '$SCVMMServer': $_" -Level ERROR -LogFile $LogFile
            throw
        }
    }

    return $VMMServerName
}

# ---------------------------------------------------------------------------
# Start-SCVMMHostMigration — initiate VM host migration via SCVMM
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Start a SCVMM host migration for a VM.

.DESCRIPTION
    Moves the VM to a target Hyper-V host via SCVMM. Runs the operation
    asynchronously (Move-SCVirtualMachine -RunAsynchronously).

.PARAMETER Name
    VM name. Mandatory.

.PARAMETER ServerName
    SCVMM server name. Mandatory.

.PARAMETER DestinationHost
    Target Hyper-V host name. Mandatory.

.EXAMPLE
    Start-SCVMMHostMigration -Name "SRV-WEB01" -ServerName $VMMServerName -DestinationHost "hv02"
#>
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

        # Move-SCVirtualMachine returns the VirtualMachine object, NOT the SCVMM
        # job — reading .ID off that return value yields the VM GUID, which never
        # matches a Get-SCJob ID and silently disabled job-state monitoring.
        # Capture the real job via -JobVariable (VMM common parameter) with a
        # fallback to the VM's MostRecentTask.
        $scvmmMoveJob = $null
        $moveCommand = Get-Command -Name Move-SCVirtualMachine -ErrorAction SilentlyContinue | Select-Object -First 1
        $supportsJobVariable = $moveCommand -and $moveCommand.Parameters.ContainsKey('JobVariable')

        if ($supportsJobVariable) {
            $movedVm = Move-SCVirtualMachine -VM $vm -VMHost $targetHost -UseLAN -RunAsynchronously -JobVariable scvmmMoveJob
        } else {
            $movedVm = Move-SCVirtualMachine -VM $vm -VMHost $targetHost -UseLAN -RunAsynchronously
        }

        if (-not $scvmmMoveJob -and $movedVm -and $movedVm.PSObject.Properties['MostRecentTask'] -and $movedVm.MostRecentTask) {
            $scvmmMoveJob = $movedVm.MostRecentTask
        }

        if (-not $scvmmMoveJob) {
            return $null
        }

        [pscustomobject]@{
            ID           = if ($scvmmMoveJob.PSObject.Properties['ID']) { [string]$scvmmMoveJob.ID } else { $null }
            Name         = if ($scvmmMoveJob.PSObject.Properties['Name']) { [string]$scvmmMoveJob.Name } else { $null }
            Status       = if ($scvmmMoveJob.PSObject.Properties['Status']) { [string]$scvmmMoveJob.Status } else { $null }
            StatusString = if ($scvmmMoveJob.PSObject.Properties['StatusString']) { [string]$scvmmMoveJob.StatusString } else { $null }
            ErrorInfo    = if ($scvmmMoveJob.PSObject.Properties['ErrorInfo']) { [string]$scvmmMoveJob.ErrorInfo } else { $null }
        }
    } -ArgumentList @($Name, $ServerName, $DestinationHost)
}

# ---------------------------------------------------------------------------
# Get-SCVMMHostMigrationJobState — query SCVMM migration job status
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Query a SCVMM migration job returned by Start-SCVMMHostMigration.

.DESCRIPTION
    Move-SCVirtualMachine -RunAsynchronously returns before the migration is
    complete. This helper lets the caller distinguish an operation that is
    still running from a failed/cancelled SCVMM job instead of only waiting for
    the VM host to change until timeout.
#>
function Get-SCVMMHostMigrationJobState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    return Invoke-SCVMMCommand -ScriptBlock {
        param($VmmServerName, $ScvmmJobId)

        $server = Get-SCVMMServer -ComputerName $VmmServerName

        # Targeted lookup first: enumerating every SCVMM job with a bare
        # Get-SCJob is expensive on a busy VMM server.
        $job = $null
        try {
            $job = Get-SCJob -ID $ScvmmJobId -VMMServer $server -ErrorAction Stop | Select-Object -First 1
        } catch {
            Write-Verbose "Get-SCJob -ID lookup failed, falling back to enumeration: $($_.Exception.Message)"
        }
        if (-not $job) {
            $job = Get-SCJob -VMMServer $server | Where-Object { [string]$_.ID -eq $ScvmmJobId } | Select-Object -First 1
        }
        if (-not $job) {
            return $null
        }

        [pscustomobject]@{
            ID           = if ($job.PSObject.Properties['ID']) { [string]$job.ID } else { $null }
            Name         = if ($job.PSObject.Properties['Name']) { [string]$job.Name } else { $null }
            Status       = if ($job.PSObject.Properties['Status']) { [string]$job.Status } else { $null }
            StatusString = if ($job.PSObject.Properties['StatusString']) { [string]$job.StatusString } else { $null }
            ErrorInfo    = if ($job.PSObject.Properties['ErrorInfo']) { [string]$job.ErrorInfo } else { $null }
        }
    } -ArgumentList @($ServerName, $JobId)
}

# ---------------------------------------------------------------------------
# Get-SCVMMVmRuntimeState — query VM runtime state from SCVMM
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Query the runtime state of a VM from SCVMM.

.DESCRIPTION
    Returns a [PSCustomObject] with the VM's Name, IsHighlyAvailable flag,
    HostName, Status, and StatusString. Can optionally refresh the VM state
    within the same SCVMM round-trip to avoid a separate connection.

.PARAMETER Name
    VM name. Mandatory.

.PARAMETER ServerName
    SCVMM server name. Mandatory.

.PARAMETER Refresh
    When specified, reads the VM state via Read-SCVirtualMachine before
    querying properties, within a single SCVMM round-trip.

.EXAMPLE
    $vmState = Get-SCVMMVmRuntimeState -Name "SRV-WEB01" -ServerName $VMMServerName -Refresh
#>
function Get-SCVMMVmRuntimeState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [switch]$Refresh
    )

    return Invoke-SCVMMCommand -ScriptBlock {
        param($VmName, $VmmServerName, $DoRefresh)
        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $VmName -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            return $null
        }

        if ($DoRefresh) {
            $refreshCommand = Get-Command -Name 'Read-SCVirtualMachine' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($refreshCommand) {
                $refreshedVm = & $refreshCommand -VM $vm | Select-Object -First 1
                if ($refreshedVm) {
                    $vm = $refreshedVm
                }
            }
        }

        function Get-ObjectPropertyValue {
            param($InputObject, [string]$PropertyName, [string]$Context = 'object')
            if (-not $InputObject) {
                Write-Verbose "SCVMM debug: $Context is null while reading '$PropertyName'."
                return $null
            }

            $property = $InputObject.PSObject.Properties[$PropertyName]
            if ($property) { return $property.Value }

            $availableProperties = @($InputObject.PSObject.Properties.Name | Sort-Object) -join ', '
            Write-Verbose "SCVMM debug: property '$PropertyName' is missing on $Context ($($InputObject.GetType().FullName)). Available properties: $availableProperties"
            return $null
        }

        $vmHost = Get-ObjectPropertyValue -InputObject $vm -PropertyName 'VMHost' -Context 'VM runtime state'
        $hostNameCandidates = @(
            (Get-ObjectPropertyValue -InputObject $vm -PropertyName 'HostName' -Context 'VM runtime state'),
            (Get-ObjectPropertyValue -InputObject $vm -PropertyName 'VMHostName' -Context 'VM runtime state'),
            (Get-ObjectPropertyValue -InputObject $vmHost -PropertyName 'ComputerName' -Context 'VM host runtime state'),
            (Get-ObjectPropertyValue -InputObject $vmHost -PropertyName 'Name' -Context 'VM host runtime state'),
            (Get-ObjectPropertyValue -InputObject $vm -PropertyName 'HostComputerName' -Context 'VM runtime state'),
            (Get-ObjectPropertyValue -InputObject $vm -PropertyName 'Host' -Context 'VM runtime state')
        ) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        [pscustomobject]@{
            Name              = [string](Get-ObjectPropertyValue -InputObject $vm -PropertyName 'Name' -Context 'VM runtime state')
            IsHighlyAvailable = [bool](Get-ObjectPropertyValue -InputObject $vm -PropertyName 'IsHighlyAvailable' -Context 'VM runtime state')
            HostName          = $hostNameCandidates | Select-Object -First 1
            Status            = [string](Get-ObjectPropertyValue -InputObject $vm -PropertyName 'Status' -Context 'VM runtime state')
            StatusString      = [string](Get-ObjectPropertyValue -InputObject $vm -PropertyName 'StatusString' -Context 'VM runtime state')
        }
    } -ArgumentList @($Name, $ServerName, [bool]$Refresh)
}

# ---------------------------------------------------------------------------
# ConvertTo-NormalizedHostName — normalize hostname for comparison
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    Normalize a hostname to a canonical lowercase short form.

.DESCRIPTION
    Trims whitespace, lowercases, and strips the domain suffix (everything
    after the first dot). Returns $null for null/empty input.

.PARAMETER Name
    Hostname to normalize. Can be $null.

.EXAMPLE
    ConvertTo-NormalizedHostName -Name "HV01.contoso.com"   # returns "hv01"
    ConvertTo-NormalizedHostName -Name "HV02"               # returns "hv02"
#>
function ConvertTo-NormalizedHostName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return $Name.Trim().ToLowerInvariant().Split('.')[0]
}