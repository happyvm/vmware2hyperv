<#
.SYNOPSIS
    Start Hyper-V VMs and validate post-migration compliance.

.DESCRIPTION
    Starts the migrated VMs on Hyper-V hosts, then loops until every VM is fully
    compliant (or the loop is interrupted / -IntegrationMaxIterations is reached):
    - VM running, NIC connected, guest IPv4 matches the expected IP (extract-ip.csv)
    - Integration services healthy (heartbeat, time sync, data exchange, guest agent)
    - High Availability enabled and the post-migration backup tag present in SCVMM
    - WinRM-based VMware Tools removal on Windows Server 2012+ (best effort)

    This folds what used to be a separate post-migration-checks pass into the same
    SCVMM inventory loop as the VM start/Integration Services polling, avoiding a
    second full pass over every VM. By default the loop has no iteration cap: it
    keeps polling until every VM is compliant. Interrupt with Ctrl+C to stop waiting
    without losing the VMs already started, or pass -IntegrationMaxIterations to cap it.

.PARAMETER ConfigFile
    Optional path to the configuration file. Defaults to config.psd1.

.PARAMETER CsvFile
    Path to the batch CSV file. Defaults to Config.Paths.CsvFile.

.PARAMETER ExtractIpCsvFile
    Path to the CSV of expected guest IPs. Defaults to Config.Paths.ExtractIpCsv, or
    <CsvFile folder>\extract-ip.csv. Optional: if the file is missing, the expected-IP
    check is skipped (treated as compliant) instead of failing the whole script.

.PARAMETER Tag
    Optional batch tag to filter VMs from the CSV.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.PARAMETER IntegrationPollIntervalSeconds
    Interval between compliance polls. Default: 30.

.PARAMETER IntegrationMaxIterations
    Maximum polling iterations. Default: 0 (unlimited — loop until every VM is
    compliant or the script is interrupted).

.PARAMETER WinRmRetryDelaySeconds
    Delay between WinRM retries in seconds. Default: 15.

.PARAMETER WinRmMaxAttempts
    Maximum WinRM connection attempts. Default: 20.

.EXAMPLE
    .\step4-StartVM.ps1 -Tag HypMig-lot-118

.EXAMPLE
    .\step4-StartVM.ps1 -Tag HypMig-lot-118 -IntegrationMaxIterations 20

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VirtualMachineManager module.
#>

param (
    [string]$ConfigFile,
    [string]$CsvFile,
    [string]$ExtractIpCsvFile,
    [string]$Tag,
    [string]$LogFile,
    [int]$IntegrationPollIntervalSeconds = 30,
    [int]$IntegrationMaxIterations = 0,
    [int]$WinRmRetryDelaySeconds = 15,
    [int]$WinRmMaxAttempts = 20
)

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config = Import-MigrationConfig -ConfigFile $ConfigFile
if (-not $CsvFile) { $CsvFile = $Config.Paths.CsvFile }
Assert-PathPresent -Path $CsvFile -Label "Batch CSV"

if (-not $ExtractIpCsvFile) {
    if ($Config.Paths.ExtractIpCsv) {
        $ExtractIpCsvFile = [string]$Config.Paths.ExtractIpCsv
    } else {
        $batchFolder = Split-Path -Path $CsvFile -Parent
        $ExtractIpCsvFile = Join-Path -Path $batchFolder -ChildPath "extract-ip.csv"
    }
}

if (-not $LogFile) {
    $batchLabel = if ([string]::IsNullOrWhiteSpace($Tag)) { 'all' } else { $Tag }
    $LogFile = "$($Config.Paths.LogDir)\step4-startvm-$batchLabel-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

function Get-ExpectedIpMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rows = Import-Csv -Path $Path -Delimiter ";"
    $map = @{}

    foreach ($row in $rows) {
        $vmName = Get-FirstPropertyValue -InputObject $row -PropertyNames @(
            'VMName', 'VmName', 'Name', 'NomVM'
        )
        $ip = Get-FirstPropertyValue -InputObject $row -PropertyNames @(
            'ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'TargetIp', 'IP', 'IPAddress', 'IpAddress'
        )

        if ([string]::IsNullOrWhiteSpace($vmName) -or [string]::IsNullOrWhiteSpace($ip)) {
            continue
        }

        $map[$vmName.ToLowerInvariant()] = $ip
    }

    return $map
}

if (Test-Path -Path $ExtractIpCsvFile) {
    $expectedIpMap = Get-ExpectedIpMap -Path $ExtractIpCsvFile
} else {
    Write-MigrationLog "Extract IP CSV not found ($ExtractIpCsvFile) — skipping expected-IP validation." -Level WARNING -LogFile $LogFile
    $expectedIpMap = @{}
}

function Get-SCVMMVmInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$VMNames,

        [hashtable]$ExpectedIpMap = @{},

        [string]$ExpectedBackupTag
    )

    $names = @(
        $VMNames |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
    )

    if (-not $names) {
        return @()
    }

    return @(
        Invoke-SCVMMCommand -ScriptBlock {
            param($VmmServerName, $Names, $IpMap, $BackupTag)

            function Get-IntegrationStatusSummary {
                param($Vm)

                $primarySignals = @(
                    [string]$Vm.IntegrationServicesState,
                    [string]$Vm.GuestAgentStatus,
                    [string]$Vm.VMAddition
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                $secondarySignals = @(
                    [string]$Vm.HeartbeatStatus,
                    [string]$Vm.HeartbeatEnabled
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                $summary = $null
                if ($primarySignals) {
                    $summary = ($primarySignals | Select-Object -Unique) -join ' | '
                } elseif ($secondarySignals) {
                    $summary = ($secondarySignals | Select-Object -Unique) -join ' | '
                }

                if ([string]::IsNullOrWhiteSpace($summary)) {
                    $summary = 'Not detected'
                }

                $ready = $false
                if ($summary -match 'OK|Operational|Up|Ready|Responding|Actif|Fonctionnel|Installed|Enabled|Version') {
                    $ready = $true
                }
                if ($summary -match 'Not.?Detected|Disabled|Stopped|Error|Unknown|Unavailable|N.?A|Inconnu|Arrêté|Missing|Non détecté') {
                    $ready = $false
                }

                return [pscustomobject]@{
                    Ready   = [bool]$ready
                    Summary = [string]$summary
                }
            }

            $server = Get-SCVMMServer -ComputerName $VmmServerName

            foreach ($name in $Names) {
                $vm = Get-SCVirtualMachine -Name $name -VMMServer $server | Select-Object -First 1

                if (-not $vm) {
                    [pscustomobject]@{
                        VMName                  = $name
                        Exists                  = $false
                        Running                 = $false
                        HypervConfiguredOs      = $null
                        Status                  = $null
                        StatusString            = $null
                        VMHostComputerName      = $null
                        IntegrationReady        = $false
                        IntegrationDetails      = 'VM introuvable'
                        NetworkConnected        = $false
                        CurrentIPs              = @()
                        IPMatches               = $false
                        HighAvailabilityEnabled = $false
                        CurrentTag              = $null
                        BackupTagPresent        = $false
                    }
                    continue
                }

                try {
                    $refreshedVm = Read-SCVirtualMachine -VM $vm -Force -ErrorAction Stop
                    if ($refreshedVm) {
                        $vm = $refreshedVm
                    } else {
                        $vm = Get-SCVirtualMachine -Name $name -VMMServer $server | Select-Object -First 1
                    }
                } catch {
                    $vm = Get-SCVirtualMachine -Name $name -VMMServer $server | Select-Object -First 1
                }

                $statusRaw = @(
                    [string]$vm.Status,
                    [string]$vm.StatusString,
                    [string]$vm.VirtualMachineState
                ) -join ' '

                $running = $statusRaw -match 'Running|Power.*On|En cours d.?exécution|Démarré'
                $integrationStatus = Get-IntegrationStatusSummary -Vm $vm

                $adapters = @(Get-SCVirtualNetworkAdapter -VM $vm -ErrorAction SilentlyContinue)
                $connectedAdapters = @($adapters | Where-Object {
                    $state = [string]$_.ConnectionState
                    $state -match 'Connected|Connecté|OK|On' -or
                    (-not [string]::IsNullOrWhiteSpace([string]$_.VMNetwork)) -or
                    (-not [string]::IsNullOrWhiteSpace([string]$_.VMSubnet))
                })
                $networkConnected = $connectedAdapters.Count -gt 0

                $allIps = @(
                    foreach ($adapter in $adapters) {
                        foreach ($address in @($adapter.IPv4Addresses)) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$address)) {
                                [string]$address
                            }
                        }
                    }
                ) | Select-Object -Unique

                $expectedIp = $null
                if ($IpMap -and $IpMap.ContainsKey($name.ToLowerInvariant())) {
                    $expectedIp = [string]$IpMap[$name.ToLowerInvariant()]
                }
                $ipMatches = if ([string]::IsNullOrWhiteSpace($expectedIp)) { $true } else { $allIps -contains $expectedIp }

                $highAvailabilityEnabled = [bool]$vm.IsHighlyAvailable

                $currentTag = [string]$vm.Tag
                $backupTagPresent = if ([string]::IsNullOrWhiteSpace($BackupTag)) {
                    $true
                } else {
                    [bool]($currentTag -split ';|,' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $BackupTag } | Measure-Object | Select-Object -ExpandProperty Count)
                }

                [pscustomobject]@{
                    VMName                  = $name
                    Exists                  = $true
                    Running                 = [bool]$running
                    HypervConfiguredOs      = [string]$vm.OperatingSystem
                    Status                  = [string]$vm.Status
                    StatusString            = [string]$vm.StatusString
                    VMHostComputerName      = [string]$vm.VMHost.ComputerName
                    IntegrationReady        = [bool]$integrationStatus.Ready
                    IntegrationDetails      = [string]$integrationStatus.Summary
                    NetworkConnected        = [bool]$networkConnected
                    CurrentIPs              = @($allIps)
                    IPMatches               = [bool]$ipMatches
                    HighAvailabilityEnabled = [bool]$highAvailabilityEnabled
                    CurrentTag              = $currentTag
                    BackupTagPresent        = [bool]$backupTagPresent
                }
            }
        } -ArgumentList @($ServerName, $names, $ExpectedIpMap, $ExpectedBackupTag)
    )
}

function Start-SCVMMVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    Invoke-SCVMMCommand -ScriptBlock {
        param($VmmServerName, $Name)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$Name' introuvable dans SCVMM."
        }

        Start-SCVirtualMachine -VM $vm -ErrorAction Stop | Out-Null
    } -ArgumentList @($ServerName, $VMName)
}

function Resolve-OsActionPlan {
    param(
        [string]$OperatingSystem
    )

    $generation = Get-OsGeneration -OperatingSystem $OperatingSystem

    if (-not $generation) {
        return [pscustomobject]@{
            OsGeneration = $null
            ActionPlan   = 'ManualUnknown'
        }
    }

    if ($generation -eq 2003 -or $generation -eq 2008) {
        return [pscustomobject]@{
            OsGeneration = $generation
            ActionPlan   = 'ManualLegacy'
        }
    }

    if ($generation -ge 2012 -and $generation -le 2025) {
        return [pscustomobject]@{
            OsGeneration = $generation
            ActionPlan   = 'WinRM'
        }
    }

    return [pscustomobject]@{
        OsGeneration = $generation
        ActionPlan   = 'ManualOther'
    }
}

# ---------------------------------------------------------------------------
# Test-VmCompliant : a VM is fully done once it's running, connected, has its
# expected IP, integration services are healthy, HA is on, and the
# post-migration backup tag is present — folds what used to be the separate
# post-migration-checks pass into this same loop.
# ---------------------------------------------------------------------------
function Test-VmCompliant {
    param(
        [bool]$Exists,
        [bool]$Running,
        [bool]$NetworkConnected,
        [bool]$IntegrationReady,
        [bool]$HighAvailabilityEnabled,
        [bool]$BackupTagPresent,
        [bool]$IPMatches
    )

    return [bool]($Exists -and $Running -and $NetworkConnected -and $IntegrationReady -and $HighAvailabilityEnabled -and $BackupTagPresent -and $IPMatches)
}

function Get-ComplianceIssues {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if (-not $VmItem.VmFound) {
        return @('VM introuvable')
    }

    $issues = @()
    if (-not $VmItem.Started) { $issues += 'non démarrée' }
    if (-not $VmItem.NetworkConnected) { $issues += 'NIC non connectée' }
    if (-not $VmItem.IPMatches) { $issues += 'IP inattendue' }
    if (-not $VmItem.IntegrationReady) { $issues += 'Integration Services non OK' }
    if (-not $VmItem.HighAvailabilityEnabled) { $issues += 'HA non activée' }
    if (-not $VmItem.BackupTagPresent) { $issues += 'tag backup absent' }

    return $issues
}

function Get-ActionDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if (-not $VmItem.VmFound) {
        return 'VM introuvable dans SCVMM'
    }

    if (-not [string]::IsNullOrWhiteSpace($VmItem.StartError) -and -not $VmItem.Started) {
        return "Démarrage SCVMM KO : à vérifier à la main"
    }

    switch ($VmItem.ActionPlan) {
        'ManualUnknown' { return 'OS inconnu : à la main' }
        'ManualLegacy'  { return "OS $($VmItem.OsGeneration) : à la main" }
        'ManualOther'   { return "OS $($VmItem.OsGeneration) : à la main" }
        'WinRM' {
            switch ($VmItem.ActionState) {
                'Queued'        { return "OS $($VmItem.OsGeneration) : WinRM en attente" }
                'Running'       { return "OS $($VmItem.OsGeneration) : WinRM en cours" }
                'Success-HTTPS' { return "OS $($VmItem.OsGeneration) : WinRM HTTPS OK" }
                'Success-HTTP'  { return "OS $($VmItem.OsGeneration) : WinRM HTTP OK" }
                'Failed'        { return "OS $($VmItem.OsGeneration) : WinRM KO, à faire à la main" }
                'Skipped'       { return "OS $($VmItem.OsGeneration) : WinRM non lancé, à faire à la main" }
                default         { return "OS $($VmItem.OsGeneration) : WinRM en attente" }
            }
        }
        default { return 'À déterminer' }
    }
}

function Get-PowerStateDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if (-not $VmItem.VmFound) {
        return 'VM introuvable'
    }

    if ($VmItem.Started) {
        return 'Allumée'
    }

    return 'Éteinte'
}

function Start-WinRmRemediationJob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$LocalScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$RemoteScriptPath,

        [PSCredential]$Credential,

        [string]$TargetLogFile,

        [int]$MaxAttempts = 20,

        [int]$RetryDelaySeconds = 15
    )

    # Chaque job écrit dans son propre fichier de log : plusieurs ThreadJobs partageant
    # le même fichier provoquent des collisions Add-Content (« file in use ») et des
    # lignes perdues. Le log par VM est dérivé du log principal (suffixe -<VM>).
    $jobLogFile = $TargetLogFile
    if (-not [string]::IsNullOrWhiteSpace($TargetLogFile)) {
        $safeVmName = ($VMName -replace '[\\/:*?"<>|\s]', '_')
        $jobLogFile = ($TargetLogFile -replace '\.log$', '') + "-$safeVmName.log"
    }

    # Start-ThreadJob is used instead of Start-Job to avoid PSUseUsingScopeModifierInNewRunspaces warnings.
    # ThreadJob is available in PS 7+ and provides better performance for parallel workloads.
    return Start-ThreadJob -Name "startvm-$VMName" -ArgumentList @(
        $VMName,
        $LocalScriptPath,
        $RemoteScriptPath,
        $Credential,
        $jobLogFile,
        $MaxAttempts,
        $RetryDelaySeconds
    ) -ScriptBlock {
        param(
            [string]$ComputerName,
            [string]$JobLocalScriptPath,
            [string]$JobRemoteScriptPath,
            [PSCredential]$JobCredential,
            [string]$JobLogFile,
            [int]$JobMaxAttempts,
            [int]$JobRetryDelaySeconds
        )

        function Write-JobLog {
            param(
                [string]$Message,
                [string]$Level = 'INFO',
                [string]$LogFile
            )

            if ([string]::IsNullOrWhiteSpace($LogFile)) {
                return
            }

            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Add-Content -Path $LogFile -Value "[$timestamp] [$Level] [$ComputerName] $Message"
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
                Write-JobLog -Message "WinRM HTTPS indisponible: $($_.Exception.Message)" -Level 'WARNING' -LogFile $JobLogFile
            }

            try {
                Test-WSMan -ComputerName $ComputerName -ErrorAction Stop | Out-Null
                return [pscustomobject]@{
                    Protocol = 'HTTP'
                    Session  = New-PSSession @sessionParams
                }
            } catch {
                Write-JobLog -Message "WinRM HTTP indisponible: $($_.Exception.Message)" -Level 'WARNING' -LogFile $JobLogFile
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
                Write-JobLog -Message "Script distant introuvable: $LocalScriptPath" -Level 'WARNING' -LogFile $JobLogFile
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

                # Le script distant est un .bat : powershell.exe -File n'accepte que des .ps1.
                # Codes retour du batch : 0 = succès, 1 = erreur, 2 = cleanup VMware partiel.
                $remoteExitCode = Invoke-Command -Session $session -ScriptBlock {
                    param($ScriptPath)
                    & cmd.exe /c "`"$ScriptPath`"" | Out-Null
                    $LASTEXITCODE
                } -ArgumentList @($RemoteScriptPath) -ErrorAction Stop

                if ($remoteExitCode -eq 1) {
                    Write-JobLog -Message "Script Integration Services terminé en erreur (exit code 1) via WinRM $protocol." -Level 'WARNING' -LogFile $JobLogFile
                    return "ExecutionFailed-$protocol"
                }

                if ($remoteExitCode -eq 2) {
                    Write-JobLog -Message "Script Integration Services terminé avec cleanup VMware partiel (exit code 2) via WinRM $protocol." -Level 'WARNING' -LogFile $JobLogFile
                }

                Write-JobLog -Message "Script Integration Services exécuté via WinRM $protocol (exit code $remoteExitCode)." -Level 'SUCCESS' -LogFile $JobLogFile
                return "Success-$protocol"
            } catch {
                Write-JobLog -Message "Échec via WinRM $protocol : $($_.Exception.Message)" -Level 'WARNING' -LogFile $JobLogFile
                return "ExecutionFailed-$protocol"
            } finally {
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
            }
        }

        $lastStatus = 'WinRMUnavailable'

        for ($attempt = 1; $attempt -le $JobMaxAttempts; $attempt++) {
            Write-JobLog -Message "Tentative WinRM $attempt/$JobMaxAttempts." -LogFile $JobLogFile
            $lastStatus = Invoke-RemoteVmwareToolsRemoval -ComputerName $ComputerName -LocalScriptPath $JobLocalScriptPath -RemoteScriptPath $JobRemoteScriptPath -Credential $JobCredential

            if ($lastStatus -like 'Success-*') {
                return [pscustomobject]@{
                    VMName       = $ComputerName
                    FinalStatus  = $lastStatus
                    Attempts     = $attempt
                }
            }

            if ($lastStatus -eq 'ScriptAbsent') {
                break
            }

            if ($attempt -lt $JobMaxAttempts) {
                Start-Sleep -Seconds $JobRetryDelaySeconds
            }
        }

        return [pscustomobject]@{
            VMName      = $ComputerName
            FinalStatus = $lastStatus
            Attempts    = $JobMaxAttempts
        }
    }
}

function Update-WinRmActionState {
    param(
        [Parameter(Mandatory = $true)]
        $VmItem
    )

    if ($VmItem.ActionPlan -ne 'WinRM' -or -not $VmItem.ActionJobId) {
        return
    }

    $job = Get-Job -Id $VmItem.ActionJobId -ErrorAction SilentlyContinue
    if (-not $job) {
        if ($VmItem.ActionState -in @('Queued', 'Running')) {
            $VmItem.ActionState = 'Failed'
        }
        $VmItem.ActionJobId = $null
        return
    }

    switch ($job.State) {
        'NotStarted' {
            $VmItem.ActionState = 'Queued'
        }
        'Running' {
            $VmItem.ActionState = 'Running'
        }
        'Completed' {
            $result = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue | Select-Object -Last 1
            $finalStatus = if ($result -and $result.PSObject.Properties['FinalStatus']) {
                [string]$result.FinalStatus
            } else {
                'Unknown'
            }

            switch -Wildcard ($finalStatus) {
                'Success-HTTPS' { $VmItem.ActionState = 'Success-HTTPS' }
                'Success-HTTP'  { $VmItem.ActionState = 'Success-HTTP' }
                default         { $VmItem.ActionState = 'Failed' }
            }

            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $VmItem.ActionJobId = $null
        }
        'Failed' {
            $VmItem.ActionState = 'Failed'
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $VmItem.ActionJobId = $null
        }
        'Stopped' {
            $VmItem.ActionState = 'Failed'
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $VmItem.ActionJobId = $null
        }
        default {
            $VmItem.ActionState = 'Queued'
        }
    }
}

function Show-PendingDashboard {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Inventory,

        [int]$Iteration,

        [int]$MaxIterations
    )

    $pendingRows = @(
        $Inventory |
            Where-Object { -not $_.DisplayCompleted } |
            Sort-Object VMName |
            ForEach-Object {
                [pscustomobject]@{
                    'Nom de la VM'      = $_.VMName
                    'Power state'       = Get-PowerStateDisplayText -VmItem $_
                    'OS'                = if ([string]::IsNullOrWhiteSpace($_.DisplayOperatingSystem)) { 'Inconnu' } else { $_.DisplayOperatingSystem }
                    'Non-conformités'   = (Get-ComplianceIssues -VmItem $_) -join ', '
                    'Actions à mener'   = Get-ActionDisplayText -VmItem $_
                }
            }
    )

    if ($Host.Name -notin @('ServerRemoteHost')) {
        try { Clear-Host } catch { Write-Verbose "Clear-Host is not supported by the current host: $($_.Exception.Message)" }
    }

    $iterationLabel = if ($MaxIterations -le 0) { "$Iteration (illimité, Ctrl+C pour arrêter)" } else { "$Iteration/$MaxIterations" }
    Write-Information "Suivi lotissement - rafraîchissement $iterationLabel - éléments restants : $($pendingRows.Count)" -InformationAction Continue
    Write-Information "" -InformationAction Continue

    if ($pendingRows) {
        $pendingRows |
            Format-Table -AutoSize |
            Out-String -Width 4096 |
            ForEach-Object { Write-Information $_ -InformationAction Continue }
    } else {
        Write-Information "Toutes les VM sont conformes (démarrées, réseau, IP, Integration Services, HA, tag backup)." -InformationAction Continue
    }
}

$rows = Import-Csv -Path $CsvFile -Delimiter ';'
$targetRows = @(
    $rows | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.VMName) -and (
            [string]::IsNullOrWhiteSpace($Tag) -or $_.Tag -eq $Tag
        )
    }
)

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

$localWinRmScriptPath = [string]$Config.RemoteActions.WinRm.RemoveVmwareToolsScriptLocalPath
$remoteWinRmScriptPath = [string]$Config.RemoteActions.WinRm.RemoveVmwareToolsScriptRemotePath
$expectedBackupTag = [string]$Config.Tags.BackupTag

$initialSnapshots = Get-SCVMMVmInventory -ServerName $Config.SCVMM.Server -VMNames ($targetRows.VMName) -ExpectedIpMap $expectedIpMap -ExpectedBackupTag $expectedBackupTag
$initialSnapshotByName = @{}
foreach ($snapshot in $initialSnapshots) {
    $initialSnapshotByName[[string]$snapshot.VMName] = $snapshot
}

$vmInventory = foreach ($row in $targetRows) {
    $vmName = [string]$row.VMName
    $sourceOs = Get-FirstPropertyValue -InputObject $row -PropertyNames @('OperatingSystem', 'Operating system')
    $snapshot = $initialSnapshotByName[$vmName]

    $displayOperatingSystem = if ($snapshot -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.HypervConfiguredOs)) {
        [string]$snapshot.HypervConfiguredOs
    } else {
        $sourceOs
    }

    $actionPlan = Resolve-OsActionPlan -OperatingSystem $displayOperatingSystem

    if (-not $snapshot) {
        $snapshot = [pscustomobject]@{
            VMName                  = $vmName
            Exists                  = $false
            Running                 = $false
            HypervConfiguredOs      = $null
            IntegrationReady        = $false
            IntegrationDetails      = 'VM introuvable'
            NetworkConnected        = $false
            CurrentIPs              = @()
            IPMatches               = $false
            HighAvailabilityEnabled = $false
            CurrentTag              = $null
            BackupTagPresent        = $false
        }
    }

    [pscustomobject]@{
        VMName                  = $vmName
        SourceOperatingSystem   = $sourceOs
        DisplayOperatingSystem  = $displayOperatingSystem
        OsGeneration            = $actionPlan.OsGeneration
        ActionPlan              = $actionPlan.ActionPlan
        ActionState             = if ($snapshot.Exists) { 'Queued' } else { 'Skipped' }
        ActionJobId             = $null
        VmFound                 = [bool]$snapshot.Exists
        Started                 = [bool]$snapshot.Running
        StartError              = $null
        IntegrationReady        = [bool]$snapshot.IntegrationReady
        IntegrationDetails      = if ($snapshot.Exists) { [string]$snapshot.IntegrationDetails } else { 'VM introuvable' }
        NetworkConnected        = [bool]$snapshot.NetworkConnected
        CurrentIPs              = @($snapshot.CurrentIPs)
        IPMatches               = [bool]$snapshot.IPMatches
        HighAvailabilityEnabled = [bool]$snapshot.HighAvailabilityEnabled
        CurrentTag              = $snapshot.CurrentTag
        BackupTagPresent        = [bool]$snapshot.BackupTagPresent
        DisplayCompleted        = Test-VmCompliant -Exists $snapshot.Exists -Running $snapshot.Running -NetworkConnected $snapshot.NetworkConnected -IntegrationReady $snapshot.IntegrationReady -HighAvailabilityEnabled $snapshot.HighAvailabilityEnabled -BackupTagPresent $snapshot.BackupTagPresent -IPMatches $snapshot.IPMatches
    }
}

Write-MigrationLog "Lotissement chargé: $($vmInventory.Count) VM(s)." -LogFile $LogFile

foreach ($vmItem in @($vmInventory | Where-Object { $_.VmFound -and -not $_.Started })) {
    try {
        Start-SCVMMVm -ServerName $Config.SCVMM.Server -VMName $vmItem.VMName
        $vmItem.Started = $true
        Write-MigrationLog "[$($vmItem.VMName)] Démarrage demandé dans SCVMM." -Level SUCCESS -LogFile $LogFile
    } catch {
        $vmItem.StartError = $_.Exception.Message
        $vmItem.Started = $false
        Write-MigrationLog "[$($vmItem.VMName)] Échec au démarrage SCVMM: $($_.Exception.Message)" -Level WARNING -LogFile $LogFile
    }
}

$winRmScriptAvailable = -not [string]::IsNullOrWhiteSpace($localWinRmScriptPath) -and (Test-Path -Path $localWinRmScriptPath)
if (-not $winRmScriptAvailable) {
    Write-MigrationLog "Script WinRM introuvable ou non configuré: $localWinRmScriptPath" -Level WARNING -LogFile $LogFile
}

foreach ($vmItem in @($vmInventory | Where-Object { $_.VmFound -and -not $_.DisplayCompleted })) {
    switch ($vmItem.ActionPlan) {
        'ManualUnknown' {
            $vmItem.ActionState = 'Skipped'
        }
        'ManualLegacy' {
            $vmItem.ActionState = 'Skipped'
        }
        'ManualOther' {
            $vmItem.ActionState = 'Skipped'
        }
        'WinRM' {
            if (-not $winRmScriptAvailable) {
                $vmItem.ActionState = 'Failed'
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($vmItem.StartError) -and -not $vmItem.Started) {
                $vmItem.ActionState = 'Skipped'
                continue
            }

            $job = Start-WinRmRemediationJob -VMName $vmItem.VMName -LocalScriptPath $localWinRmScriptPath -RemoteScriptPath $remoteWinRmScriptPath -Credential $winRmCredential -TargetLogFile $LogFile -MaxAttempts $WinRmMaxAttempts -RetryDelaySeconds $WinRmRetryDelaySeconds
            $vmItem.ActionJobId = $job.Id
            $vmItem.ActionState = 'Queued'
            Write-MigrationLog "[$($vmItem.VMName)] Job WinRM lancé." -LogFile $LogFile
        }
    }
}

$iteration = 0
$refreshNeeded = $true

# IntegrationMaxIterations = 0 means unlimited: keep polling until every VM is
# compliant, or the operator interrupts with Ctrl+C.
while ($refreshNeeded -and ($IntegrationMaxIterations -le 0 -or $iteration -lt $IntegrationMaxIterations)) {
    $iteration++

    foreach ($vmItem in @($vmInventory | Where-Object { $_.ActionPlan -eq 'WinRM' })) {
        Update-WinRmActionState -VmItem $vmItem
    }

    $namesToRefresh = @(
        $vmInventory |
            Where-Object { $_.VmFound -and -not $_.DisplayCompleted } |
            Select-Object -ExpandProperty VMName
    )

    if ($namesToRefresh) {
        $refreshedSnapshots = Get-SCVMMVmInventory -ServerName $Config.SCVMM.Server -VMNames $namesToRefresh -ExpectedIpMap $expectedIpMap -ExpectedBackupTag $expectedBackupTag
        $snapshotByName = @{}
        foreach ($snapshot in $refreshedSnapshots) {
            $snapshotByName[[string]$snapshot.VMName] = $snapshot
        }

        foreach ($vmItem in @($vmInventory | Where-Object { $_.VmFound -and -not $_.DisplayCompleted })) {
            $snapshot = $snapshotByName[$vmItem.VMName]
            if (-not $snapshot) {
                continue
            }

            $vmItem.Started = [bool]$snapshot.Running
            if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.HypervConfiguredOs)) {
                $vmItem.DisplayOperatingSystem = [string]$snapshot.HypervConfiguredOs

                if ($vmItem.ActionPlan -like 'Manual*' -or -not $vmItem.OsGeneration) {
                    $previousActionPlan = $vmItem.ActionPlan
                    $resolvedActionPlan = Resolve-OsActionPlan -OperatingSystem $vmItem.DisplayOperatingSystem
                    $vmItem.OsGeneration = $resolvedActionPlan.OsGeneration
                    $vmItem.ActionPlan = $resolvedActionPlan.ActionPlan

                    if ($previousActionPlan -ne 'WinRM' -and $vmItem.ActionPlan -eq 'WinRM' -and -not $vmItem.DisplayCompleted) {
                        $vmItem.ActionState = 'Queued'
                    }
                }
            }

            $vmItem.IntegrationReady = [bool]$snapshot.IntegrationReady
            $vmItem.IntegrationDetails = [string]$snapshot.IntegrationDetails
            $vmItem.NetworkConnected = [bool]$snapshot.NetworkConnected
            $vmItem.CurrentIPs = @($snapshot.CurrentIPs)
            $vmItem.IPMatches = [bool]$snapshot.IPMatches
            $vmItem.HighAvailabilityEnabled = [bool]$snapshot.HighAvailabilityEnabled
            $vmItem.CurrentTag = $snapshot.CurrentTag
            $vmItem.BackupTagPresent = [bool]$snapshot.BackupTagPresent

            if (Test-VmCompliant -Exists $vmItem.VmFound -Running $vmItem.Started -NetworkConnected $vmItem.NetworkConnected -IntegrationReady $vmItem.IntegrationReady -HighAvailabilityEnabled $vmItem.HighAvailabilityEnabled -BackupTagPresent $vmItem.BackupTagPresent -IPMatches $vmItem.IPMatches) {
                $vmItem.DisplayCompleted = $true
                Write-MigrationLog "[$($vmItem.VMName)] Conforme (démarrée, réseau, IP, Integration Services, HA, tag backup)." -Level SUCCESS -LogFile $LogFile
            }

            if (
                $vmItem.ActionPlan -eq 'WinRM' -and
                -not $vmItem.DisplayCompleted -and
                -not $vmItem.ActionJobId -and
                $vmItem.ActionState -eq 'Queued' -and
                $winRmScriptAvailable
            ) {
                $job = Start-WinRmRemediationJob -VMName $vmItem.VMName -LocalScriptPath $localWinRmScriptPath -RemoteScriptPath $remoteWinRmScriptPath -Credential $winRmCredential -TargetLogFile $LogFile -MaxAttempts $WinRmMaxAttempts -RetryDelaySeconds $WinRmRetryDelaySeconds
                $vmItem.ActionJobId = $job.Id
                $vmItem.ActionState = 'Queued'
                Write-MigrationLog "[$($vmItem.VMName)] Job WinRM relancé." -LogFile $LogFile
            }
        }
    }

    Show-PendingDashboard -Inventory $vmInventory -Iteration $iteration -MaxIterations $IntegrationMaxIterations

    $remainingItems = @($vmInventory | Where-Object { -not $_.DisplayCompleted })
    $refreshNeeded = $remainingItems.Count -gt 0

    if ($refreshNeeded -and ($IntegrationMaxIterations -le 0 -or $iteration -lt $IntegrationMaxIterations)) {
        Start-Sleep -Seconds $IntegrationPollIntervalSeconds
    }
}

foreach ($vmItem in @($vmInventory | Where-Object { $_.ActionPlan -eq 'WinRM' })) {
    Update-WinRmActionState -VmItem $vmItem
}

$remainingAfterLoop = @($vmInventory | Where-Object { -not $_.DisplayCompleted })
if ($remainingAfterLoop) {
    Write-MigrationLog "$($remainingAfterLoop.Count) VM(s) non conformes après $iteration itération(s) (IntegrationMaxIterations atteint)." -Level WARNING -LogFile $LogFile
    foreach ($vmItem in $remainingAfterLoop) {
        $issues = (Get-ComplianceIssues -VmItem $vmItem) -join '; '
        Write-MigrationLog "[$($vmItem.VMName)] $issues" -Level WARNING -LogFile $LogFile
    }
} else {
    Write-MigrationLog "Toutes les VM sont conformes après $iteration itération(s)." -Level SUCCESS -LogFile $LogFile
}

$results = foreach ($vmItem in $vmInventory) {
    [pscustomobject]@{
        VMName                    = $vmItem.VMName
        PowerState                = Get-PowerStateDisplayText -VmItem $vmItem
        OperatingSystem           = $vmItem.DisplayOperatingSystem
        OsGeneration              = $vmItem.OsGeneration
        VmFound                   = $vmItem.VmFound
        Started                   = $vmItem.Started
        NetworkConnected          = $vmItem.NetworkConnected
        CurrentIPs                = ($vmItem.CurrentIPs -join ',')
        IPMatches                 = $vmItem.IPMatches
        IntegrationReady          = $vmItem.IntegrationReady
        IntegrationServicesStatus = $vmItem.IntegrationDetails
        HighAvailabilityEnabled   = $vmItem.HighAvailabilityEnabled
        BackupTagPresent          = $vmItem.BackupTagPresent
        Compliant                 = $vmItem.DisplayCompleted
        ActionPlan                = $vmItem.ActionPlan
        ActionState               = $vmItem.ActionState
        ActionToTake              = Get-ActionDisplayText -VmItem $vmItem
        StartError                = $vmItem.StartError
    }
}

Write-Information "" -InformationAction Continue
$results |
    Select-Object VMName, PowerState, OperatingSystem, Compliant, IntegrationServicesStatus, ActionToTake |
    Format-Table -AutoSize |
    Out-String -Width 4096 |
    ForEach-Object { Write-Information $_ -InformationAction Continue }

$summaryPath = Join-Path -Path $Config.Paths.LogDir -ChildPath "step4-startvm-summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $summaryPath -Delimiter ';' -NoTypeInformation
Write-MigrationLog "Résumé exporté: $summaryPath" -Level SUCCESS -LogFile $LogFile
Write-MigrationLog "step4-startvm terminé." -Level SUCCESS -LogFile $LogFile

if ($remainingAfterLoop -and $IntegrationMaxIterations -gt 0) {
    exit 2
}
