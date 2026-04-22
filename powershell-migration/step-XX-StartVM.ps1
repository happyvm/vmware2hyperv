param (
    [string]$ConfigFile,
    [string]$CsvFile,
    [string]$Tag,
    [string]$LogFile,
    [int]$IntegrationPollIntervalSeconds = 30,
    [int]$IntegrationMaxIterations = 10
)

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config = Import-PowerShellDataFile $ConfigFile
if (-not $CsvFile) { $CsvFile = $Config.Paths.CsvFile }
Assert-PathPresent -Path $CsvFile -Label "Batch CSV"

if (-not $LogFile) {
    $batchLabel = if ([string]::IsNullOrWhiteSpace($Tag)) { 'all' } else { $Tag }
    $LogFile = "$($Config.Paths.LogDir)\step-XX-startvm-$batchLabel-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

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

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return $null
}

function Get-OsGeneration {
    param(
        [string]$OperatingSystem
    )

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
        return $null
    }

    if ($OperatingSystem -match '2003') { return 2003 }
    if ($OperatingSystem -match '2008') { return 2008 }
    if ($OperatingSystem -match '2012') { return 2012 }
    if ($OperatingSystem -match '2016') { return 2016 }
    if ($OperatingSystem -match '2019') { return 2019 }
    if ($OperatingSystem -match '2022') { return 2022 }
    if ($OperatingSystem -match '2025') { return 2025 }

    return $null
}

function Get-WinRmSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [PSCredential]$Credential
    )

    $sessionParams = @{
        ComputerName = $ComputerName
        ErrorAction  = 'Stop'
    }

    if ($Credential) {
        $sessionParams.Credential = $Credential
    }

    try {
        Test-WSMan -ComputerName $ComputerName -UseSSL -ErrorAction Stop | Out-Null
        $httpsSessionParams = $sessionParams.Clone()
        $httpsSessionParams.UseSSL = $true
        return [pscustomobject]@{
            Protocol = 'HTTPS'
            Session  = New-PSSession @httpsSessionParams
        }
    } catch {
        Write-MigrationLog "[$ComputerName] WinRM HTTPS indisponible: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
    }

    try {
        Test-WSMan -ComputerName $ComputerName -ErrorAction Stop | Out-Null
        return [pscustomobject]@{
            Protocol = 'HTTP'
            Session  = New-PSSession @sessionParams
        }
    } catch {
        Write-MigrationLog "[$ComputerName] WinRM HTTP indisponible: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
    }

    return $null
}

function Invoke-RemoteVmwareToolsRemoval {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$LocalScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$RemoteScriptPath,

        [PSCredential]$Credential
    )

    if (-not (Test-Path -Path $LocalScriptPath)) {
        Write-MigrationLog "[$ComputerName] Script de suppression VMware Tools introuvable: $LocalScriptPath" -Level WARNING -LogFile $LogFile
        return 'ScriptAbsent'
    }

    $winRmConnection = Get-WinRmSession -ComputerName $ComputerName -Credential $Credential
    if (-not $winRmConnection) {
        return 'WinRMUnavailable'
    }

    $session = $winRmConnection.Session
    $protocol = $winRmConnection.Protocol

    try {
        $remoteFolder = Split-Path -Path $RemoteScriptPath -Parent
        Invoke-Command -Session $session -ScriptBlock {
            param($Path)
            if (-not (Test-Path -Path $Path)) {
                New-Item -Path $Path -ItemType Directory -Force | Out-Null
            }
        } -ArgumentList @($remoteFolder) -ErrorAction Stop

        Copy-Item -Path $LocalScriptPath -Destination $RemoteScriptPath -ToSession $session -Force -ErrorAction Stop

        Invoke-Command -Session $session -ScriptBlock {
            param($ScriptPath)
            powershell.exe -ExecutionPolicy Bypass -File $ScriptPath
        } -ArgumentList @($RemoteScriptPath) -ErrorAction Stop | Out-Null

        Write-MigrationLog "[$ComputerName] Script de suppression VMware Tools exécuté via WinRM $protocol." -Level SUCCESS -LogFile $LogFile
        return "Success-$protocol"
    } catch {
        Write-MigrationLog "[$ComputerName] Échec suppression VMware Tools via WinRM $protocol : $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
        return "ExecutionFailed-$protocol"
    } finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Mount-IntegrationIso {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$IsoPath
    )

    if ([string]::IsNullOrWhiteSpace($IsoPath)) {
        return 'NoIsoConfigured'
    }

    return Invoke-SCVMMCommand -ScriptBlock {
        param($VmmServerName, $Name, $Path)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            return 'VmNotFound'
        }

        $dvdDrive = Get-SCVirtualDVDDrive -VM $vm -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dvdDrive) {
            return 'NoDvdDrive'
        }

        Set-SCVirtualDVDDrive -VirtualDVDDrive $dvdDrive -ISO $Path -ErrorAction Stop | Out-Null
        return 'Mounted'
    } -ArgumentList @($ServerName, $VMName, $IsoPath)
}

function Get-IntegrationServicesState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    return Invoke-SCVMMCommand -ScriptBlock {
        param($VmmServerName, $Name)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            return [pscustomobject]@{
                Exists = $false
                Ready  = $false
                Raw    = "VM introuvable"
            }
        }

        $integrationSignals = @(
            [string]$vm.HeartbeatStatus,
            [string]$vm.HeartbeatEnabled,
            [string]$vm.GuestAgentStatus,
            [string]$vm.IntegrationServicesState,
            [string]$vm.VMAddition,
            [string]$vm.VirtualMachineState
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $integrationText = ($integrationSignals -join ' | ')
        $integrationReady = $false
        if (-not [string]::IsNullOrWhiteSpace($integrationText)) {
            if ($integrationText -match 'OK|Running|Operational|Up|Ready|Responding|Actif|Fonctionnel') {
                $integrationReady = $true
            }
            if ($integrationText -match 'Not|Disabled|Stopped|Error|Unknown|Unavailable|N.?A|Inconnu|Arrêté') {
                $integrationReady = $false
            }
        }

        return [pscustomobject]@{
            Exists = $true
            Ready  = [bool]$integrationReady
            Raw    = if ([string]::IsNullOrWhiteSpace($integrationText)) { "Signal absent" } else { $integrationText }
        }
    } -ArgumentList @($ServerName, $VMName)
}

$rows = Import-Csv -Path $CsvFile -Delimiter ';'
$targetRows = @($rows | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.VMName) -and (
        [string]::IsNullOrWhiteSpace($Tag) -or $_.Tag -eq $Tag
    )
})

if (-not $targetRows) {
    $target = if ([string]::IsNullOrWhiteSpace($Tag)) { 'all rows' } else { "tag '$Tag'" }
    Write-MigrationLog "Aucune VM trouvée dans le CSV pour $target." -Level ERROR -LogFile $LogFile
    exit 1
}

$pollIntervalFromConfig = $Config.StartVm.IntegrationPollIntervalSeconds
if ($pollIntervalFromConfig -and [int]$pollIntervalFromConfig -gt 0) {
    $IntegrationPollIntervalSeconds = [int]$pollIntervalFromConfig
}

$maxIterationsFromConfig = $Config.StartVm.IntegrationMaxIterations
if ($maxIterationsFromConfig -and [int]$maxIterationsFromConfig -gt 0) {
    $IntegrationMaxIterations = [int]$maxIterationsFromConfig
}

$winRmCredential = $null
if ($Config.RemoteActions.WinRm.Credential) {
    $winRmCredential = $Config.RemoteActions.WinRm.Credential
}

$results = foreach ($row in $targetRows) {
    $vmName = [string]$row.VMName
    $sourceOs = Get-FirstPropertyValue -InputObject $row -PropertyNames @('OperatingSystem', 'Operating system')
    $osGeneration = Get-OsGeneration -OperatingSystem $sourceOs

    Write-MigrationLog "[$vmName] Traitement VM (OS source: '$sourceOs')." -LogFile $LogFile

    $vmData = Invoke-SCVMMCommand -ScriptBlock {
        param($VmmServerName, $Name)
        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1

        if (-not $vm) {
            return [pscustomobject]@{
                Exists = $false
            }
        }

        $statusRaw = @([string]$vm.Status, [string]$vm.StatusString, [string]$vm.VirtualMachineState) -join ' '
        $running = $statusRaw -match 'Running|Power.*On|En cours d.?exécution|Démarré'

        return [pscustomobject]@{
            Exists                = $true
            Running               = [bool]$running
            HypervConfiguredOs    = [string]$vm.OperatingSystem
            Status                = [string]$vm.Status
            StatusString          = [string]$vm.StatusString
            VMHostComputerName    = [string]$vm.VMHost.ComputerName
        }
    } -ArgumentList @($Config.SCVMM.Server, $vmName)

    if (-not $vmData.Exists) {
        Write-MigrationLog "[$vmName] VM introuvable dans SCVMM." -Level WARNING -LogFile $LogFile
        [pscustomobject]@{
            VMName                  = $vmName
            SourceOperatingSystem   = $sourceOs
            HyperVConfiguredOS      = $null
            Started                 = $false
            WinRM                   = 'N/A'
            IsoMount                = 'N/A'
            NextAction              = 'VM non trouvée dans SCVMM'
        }
        continue
    }

    $started = $vmData.Running
    if (-not $started) {
        try {
            Invoke-SCVMMCommand -ScriptBlock {
                param($VmmServerName, $Name)
                $server = Get-SCVMMServer -ComputerName $VmmServerName
                $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1
                if ($vm) {
                    Start-SCVirtualMachine -VM $vm -ErrorAction Stop | Out-Null
                }
            } -ArgumentList @($Config.SCVMM.Server, $vmName)
            Start-Sleep -Seconds 5
            $started = $true
            Write-MigrationLog "[$vmName] Démarrage demandé dans SCVMM." -Level SUCCESS -LogFile $LogFile
        } catch {
            $started = $false
            Write-MigrationLog "[$vmName] Échec au démarrage: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
        }
    } else {
        Write-MigrationLog "[$vmName] VM déjà démarrée." -LogFile $LogFile
    }

    $isoMountStatus = 'N/A'
    $winRmStatus = 'N/A'
    $nextAction = 'Aucune'
    $integrationReady = $false
    $integrationDetails = 'Non vérifié'

    if ($osGeneration -and $osGeneration -lt 2012) {
        $isoPath = $null
        if ($osGeneration -eq 2003) {
            $isoPath = [string]$Config.IntegrationServices.IsoByOsFamily.'2003'
        } elseif ($osGeneration -eq 2008) {
            $isoPath = [string]$Config.IntegrationServices.IsoByOsFamily.'2008'
        }

        $isoMountStatus = Mount-IntegrationIso -ServerName $Config.SCVMM.Server -VMName $vmName -IsoPath $isoPath
        $nextAction = 'OS < 2012 : faire à la main Integration Services + remove hidden devices + remove VMware Tools'
    }
    elseif ($osGeneration -and $osGeneration -ge 2012) {
        $scriptLocalPath = [string]$Config.RemoteActions.WinRm.RemoveVmwareToolsScriptLocalPath
        $scriptRemotePath = [string]$Config.RemoteActions.WinRm.RemoveVmwareToolsScriptRemotePath
        $winRmStatus = Invoke-RemoteVmwareToolsRemoval -ComputerName $vmName -LocalScriptPath $scriptLocalPath -RemoteScriptPath $scriptRemotePath -Credential $winRmCredential

        if ($winRmStatus -like 'Success-*') {
            $nextAction = 'VMware Tools removal lancé à distance'
        } else {
            $nextAction = 'WinRM indisponible/KO : actions manuelles (Integration Services si nécessaire, remove hidden devices, remove VMware Tools)'
        }
    }
    else {
        $nextAction = 'OS non identifié : vérifier manuellement Integration Services / VMware Tools'
    }

    for ($iteration = 1; $iteration -le $IntegrationMaxIterations; $iteration++) {
        $integrationState = Get-IntegrationServicesState -ServerName $Config.SCVMM.Server -VMName $vmName
        if (-not $integrationState.Exists) {
            $integrationReady = $false
            $integrationDetails = "VM introuvable au contrôle intégration"
            break
        }

        $integrationReady = [bool]$integrationState.Ready
        $integrationDetails = [string]$integrationState.Raw

        Write-MigrationLog "[$vmName] Contrôle Integration Services itération $iteration/$IntegrationMaxIterations : ready=$integrationReady ; details='$integrationDetails'" -LogFile $LogFile
        if ($integrationReady) {
            break
        }

        if ($iteration -lt $IntegrationMaxIterations) {
            Start-Sleep -Seconds $IntegrationPollIntervalSeconds
        }
    }

    if (-not $integrationReady) {
        $nextAction = "$nextAction | Integration Services non OK après boucle de vérification"
    }

    [pscustomobject]@{
        VMName                = $vmName
        SourceOperatingSystem = $sourceOs
        HyperVConfiguredOS    = $vmData.HypervConfiguredOs
        Started               = [bool]$started
        IntegrationReady      = [bool]$integrationReady
        IntegrationDetails    = $integrationDetails
        WinRM                 = $winRmStatus
        IsoMount              = $isoMountStatus
        NextAction            = $nextAction
    }
}

Write-Information "" -InformationAction Continue
$results | Format-Table -AutoSize VMName, Started, IntegrationReady, SourceOperatingSystem, HyperVConfiguredOS, WinRM, IsoMount, NextAction |
    Out-String -Width 4096 |
    ForEach-Object { Write-Information $_ -InformationAction Continue }

$summaryPath = Join-Path -Path $Config.Paths.LogDir -ChildPath "step-XX-startvm-summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $summaryPath -Delimiter ';' -NoTypeInformation
Write-MigrationLog "Résumé exporté: $summaryPath" -Level SUCCESS -LogFile $LogFile
Write-MigrationLog "step-XX-startvm terminé." -Level SUCCESS -LogFile $LogFile
