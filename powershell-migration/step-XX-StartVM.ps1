param (
    [string]$ConfigFile,
    [string]$CsvFile,
    [string]$Tag,
    [string]$LogFile,
    [int]$IntegrationPollIntervalSeconds = 30,
    [int]$IntegrationMaxIterations = 10,
    [int]$WinRmRetryDelaySeconds = 15,
    [int]$WinRmMaxAttempts = 20
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

function Get-SCVMMVmInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$VMNames
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
            param($VmmServerName, $Names)

            function Get-IntegrationStatusSummary {
                param($Vm)

                $primarySignals = @(
                    [string]$Vm.IntegrationServicesState,
                    [string]$Vm.GuestAgentStatus,
                    [string]$Vm.VMAddition
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

                $secondarySignals = @(
                    [string]$Vm.HeartbeatStatus
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
            $refreshedHostNames = New-Object 'System.Collections.Generic.HashSet[string]'

            foreach ($name in $Names) {
                $vm = Get-SCVirtualMachine -Name $name -VMMServer $server | Select-Object -First 1

                if (-not $vm) {
                    [pscustomobject]@{
                        VMName               = $name
                        Exists               = $false
                        Running              = $false
                        HypervConfiguredOs   = $null
                        Status               = $null
                        StatusString         = $null
                        VMHostComputerName   = $null
                        IntegrationReady     = $false
                        IntegrationDetails   = 'VM introuvable'
                    }
                    continue
                }

                $hostName = [string]$vm.VMHost.ComputerName
                if (-not [string]::IsNullOrWhiteSpace($hostName) -and -not $refreshedHostNames.Contains($hostName)) {
                    try {
                        Read-SCVMHost -VMHost $vm.VMHost -ErrorAction Stop | Out-Null
                        $null = $refreshedHostNames.Add($hostName)
                    } catch {
                    }
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

                [pscustomobject]@{
                    VMName               = $name
                    Exists               = $true
                    Running              = [bool]$running
                    HypervConfiguredOs   = [string]$vm.OperatingSystem
                    Status               = [string]$vm.Status
                    StatusString         = [string]$vm.StatusString
                    VMHostComputerName   = [string]$vm.VMHost.ComputerName
                    IntegrationReady     = [bool]$integrationStatus.Ready
                    IntegrationDetails   = [string]$integrationStatus.Summary
                }
            }
        } -ArgumentList @($ServerName, $names)
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

    return Start-Job -Name "startvm-$VMName" -ArgumentList @(
        $VMName,
        $LocalScriptPath,
        $RemoteScriptPath,
        $Credential,
        $TargetLogFile,
        $MaxAttempts,
        $RetryDelaySeconds
    ) -ScriptBlock {
        param(
            $ComputerName,
            $JobLocalScriptPath,
            $JobRemoteScriptPath,
            $JobCredential,
            $JobLogFile,
            $JobMaxAttempts,
            $JobRetryDelaySeconds
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

                Invoke-Command -Session $session -ScriptBlock {
                    param($ScriptPath)
                    powershell.exe -ExecutionPolicy Bypass -File $ScriptPath
                } -ArgumentList @($RemoteScriptPath) -ErrorAction Stop | Out-Null

                Write-JobLog -Message "Script Integration Services exécuté via WinRM $protocol." -Level 'SUCCESS' -LogFile $JobLogFile
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
                    'Nom de la VM'                 = $_.VMName
                    'Power state'                  = Get-PowerStateDisplayText -VmItem $_
                    'OS'                           = if ([string]::IsNullOrWhiteSpace($_.DisplayOperatingSystem)) { 'Inconnu' } else { $_.DisplayOperatingSystem }
                    'Integration services status'  = $_.IntegrationDetails
                    'Actions à mener'              = Get-ActionDisplayText -VmItem $_
                }
            }
    )

    if ($Host.Name -notin @('ServerRemoteHost')) {
        try { Clear-Host } catch {}
    }

    Write-Information "Suivi lotissement - rafraîchissement $Iteration/$MaxIterations - éléments restants : $($pendingRows.Count)" -InformationAction Continue
    Write-Information "" -InformationAction Continue

    if ($pendingRows) {
        $pendingRows |
            Format-Table -AutoSize |
            Out-String -Width 4096 |
            ForEach-Object { Write-Information $_ -InformationAction Continue }
    } else {
        Write-Information "Toutes les VM ont désormais leurs Integration Services actifs." -InformationAction Continue
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

$initialSnapshots = Get-SCVMMVmInventory -ServerName $Config.SCVMM.Server -VMNames ($targetRows.VMName)
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
            VMName             = $vmName
            Exists             = $false
            Running            = $false
            HypervConfiguredOs = $null
            IntegrationReady   = $false
            IntegrationDetails = 'VM introuvable'
        }
    }

    [pscustomobject]@{
        VMName                = $vmName
        SourceOperatingSystem = $sourceOs
        DisplayOperatingSystem= $displayOperatingSystem
        OsGeneration          = $actionPlan.OsGeneration
        ActionPlan            = $actionPlan.ActionPlan
        ActionState           = if ($snapshot.Exists) { 'Queued' } else { 'Skipped' }
        ActionJobId           = $null
        VmFound               = [bool]$snapshot.Exists
        Started               = [bool]$snapshot.Running
        StartError            = $null
        IntegrationReady      = [bool]$snapshot.IntegrationReady
        IntegrationDetails    = if ($snapshot.Exists) { [string]$snapshot.IntegrationDetails } else { 'VM introuvable' }
        DisplayCompleted      = [bool]$snapshot.IntegrationReady
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

while ($refreshNeeded -and $iteration -lt $IntegrationMaxIterations) {
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
        $refreshedSnapshots = Get-SCVMMVmInventory -ServerName $Config.SCVMM.Server -VMNames $namesToRefresh
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

            $previouslyReady = [bool]$vmItem.IntegrationReady
            $vmItem.IntegrationReady = [bool]$snapshot.IntegrationReady
            $vmItem.IntegrationDetails = [string]$snapshot.IntegrationDetails

            if (-not $previouslyReady -and $vmItem.IntegrationReady) {
                $vmItem.DisplayCompleted = $true
                Write-MigrationLog "[$($vmItem.VMName)] Integration Services actifs, retrait de la liste dynamique." -Level SUCCESS -LogFile $LogFile
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

    if ($refreshNeeded -and $iteration -lt $IntegrationMaxIterations) {
        Start-Sleep -Seconds $IntegrationPollIntervalSeconds
    }
}

foreach ($vmItem in @($vmInventory | Where-Object { $_.ActionPlan -eq 'WinRM' })) {
    Update-WinRmActionState -VmItem $vmItem
}

$remainingAfterLoop = @($vmInventory | Where-Object { -not $_.DisplayCompleted })
if ($remainingAfterLoop) {
    Write-MigrationLog "Des VM restent visibles après la boucle de rafraîchissement: $($remainingAfterLoop.Count)." -Level WARNING -LogFile $LogFile
}

$results = foreach ($vmItem in $vmInventory) {
    [pscustomobject]@{
        VMName                    = $vmItem.VMName
        PowerState                = Get-PowerStateDisplayText -VmItem $vmItem
        OperatingSystem           = $vmItem.DisplayOperatingSystem
        OsGeneration              = $vmItem.OsGeneration
        VmFound                   = $vmItem.VmFound
        Started                   = $vmItem.Started
        IntegrationReady          = $vmItem.IntegrationReady
        IntegrationServicesStatus = $vmItem.IntegrationDetails
        ActionPlan                = $vmItem.ActionPlan
        ActionState               = $vmItem.ActionState
        ActionToTake              = Get-ActionDisplayText -VmItem $vmItem
        StartError                = $vmItem.StartError
    }
}

Write-Information "" -InformationAction Continue
$results |
    Select-Object VMName, PowerState, OperatingSystem, IntegrationServicesStatus, ActionToTake |
    Format-Table -AutoSize |
    Out-String -Width 4096 |
    ForEach-Object { Write-Information $_ -InformationAction Continue }

$summaryPath = Join-Path -Path $Config.Paths.LogDir -ChildPath "step-XX-startvm-summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $summaryPath -Delimiter ';' -NoTypeInformation
Write-MigrationLog "Résumé exporté: $summaryPath" -Level SUCCESS -LogFile $LogFile
Write-MigrationLog "step-XX-startvm terminé." -Level SUCCESS -LogFile $LogFile
