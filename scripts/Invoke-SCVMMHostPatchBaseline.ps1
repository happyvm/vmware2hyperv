#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules VirtualMachineManager

<#
.SYNOPSIS
Synchronise WSUS/SCVMM, met à jour une baseline de correctifs et remédie les hôtes Hyper-V.

.DESCRIPTION
Script conçu pour une exécution non interactive via le Planificateur de tâches Windows.
Il orchestre le cycle patching SCVMM d'un cluster Hyper-V :
- lancement et attente de la synchronisation WSUS intégrée à SCVMM ;
- alimentation d'une baseline SCVMM avec les correctifs approuvés correspondant aux classifications choisies ;
- affectation de la baseline aux hôtes Hyper-V ciblés ;
- scans de conformité lancés en parallèle sur tous les hôtes ;
- remédiation hôte par hôte (ou en parallèle avec -ParallelRemediation) ;
- re-scan de conformité et relevé de l'état final par hôte.

La remédiation SCVMM met un hôte en maintenance, évacue les VM par Live Migration lorsque le cluster
le permet, applique les correctifs, redémarre si nécessaire, puis retire le mode maintenance.

Un hôte dont le scan de conformité échoue est exclu de la remédiation et compté en échec.
Toutes les étapes sont journalisées avec horodatage sur la console et, si -LogFile est fourni,
dans un fichier — indispensable pour diagnostiquer une exécution planifiée.

Codes de sortie :
  0 = cycle terminé sans échec d'hôte
  1 = au moins un hôte en échec (scan ou remédiation), ou erreur fatale

.PARAMETER VMMServer
Nom FQDN ou NetBIOS du serveur SCVMM.

.PARAMETER BaselineName
Nom de la baseline SCVMM à créer ou mettre à jour.

.PARAMETER HostGroupName
Nom du groupe d'hôtes SCVMM contenant les hôtes Hyper-V à patcher (sous-groupes inclus).

.PARAMETER VMHostNames
Liste optionnelle des hôtes Hyper-V à traiter. Si omise, tous les hôtes du groupe sont ciblés.
Le script s'arrête si un nom fourni ne correspond à aucun hôte du groupe (protection contre
les fautes de frappe qui excluraient silencieusement un hôte du cycle de patching).

.PARAMETER UpdateClassifications
Classifications SCVMM/WSUS à inclure dans la baseline.

.PARAMETER IncludeUpdateTitleRegex
Expression régulière optionnelle appliquée au titre des mises à jour candidates.

.PARAMETER ExcludeUpdateTitleRegex
Expression régulière optionnelle d'exclusion appliquée au titre des mises à jour candidates.

.PARAMETER SynchronizationTimeoutMinutes
Temps maximum d'attente de la synchronisation WSUS.

.PARAMETER ComplianceTimeoutMinutes
Temps maximum d'attente des scans de conformité (échéance partagée par le lot de scans).

.PARAMETER RemediationTimeoutMinutes
Temps maximum d'attente de la remédiation. Par hôte en mode séquentiel ; échéance globale
partagée en mode -ParallelRemediation (les jobs s'exécutent simultanément).

.PARAMETER PollIntervalSeconds
Intervalle de sondage des jobs SCVMM, en secondes (défaut : 30).

.PARAMETER LogFile
Chemin d'un fichier journal horodaté. Recommandé pour les exécutions planifiées.
Un chemin inaccessible dégrade en sortie console uniquement (un seul avertissement).

.PARAMETER SkipSynchronization
Ne lance pas la synchronisation WSUS/SCVMM.

.PARAMETER SkipRemediation
Met à jour et affecte la baseline, puis scanne la conformité sans corriger les hôtes.

.PARAMETER SkipFinalComplianceScan
Ne relance pas de scan de conformité après la remédiation et ne relève pas l'état final.

.PARAMETER ContinueOnHostFailure
En mode séquentiel, poursuit avec les hôtes suivants lorsque la remédiation d'un hôte échoue,
au lieu d'arrêter le cycle (comportement par défaut). Les échecs restent comptés et le script
se termine avec le code 1. En mode -ParallelRemediation, les jobs étant déjà lancés, les
échecs individuels n'interrompent jamais les autres hôtes.

.PARAMETER ParallelRemediation
Autorise la remédiation de plusieurs hôtes en parallèle. Les hôtes de clusters différents peuvent être
traités en même temps ; dans un même cluster, les lots respectent -MaxParallelHostsPerCluster et
-MinimumClusterAvailableResourcePercent. Par défaut, le script traite un hôte à la fois pour préserver
la capacité cluster pendant les Live Migrations.

.PARAMETER MaxParallelHostsPerCluster
Nombre maximal d’hôtes remédiés simultanément dans un même cluster lorsque -ParallelRemediation est actif.

.PARAMETER MinimumClusterAvailableResourcePercent
Pourcentage minimal de ressources du cluster qui doit rester disponible dans un lot parallèle. Le script
utilise la mémoire hôte si elle est exposée par SCVMM, sinon le nombre de CPU, sinon un poids de 1 par hôte.

.PARAMETER CentreonOutput
Supprime la sortie de log console courante et émet une ligne finale compatible plugin Centreon/Nagios
avec perfdata et code retour 0/1.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-SCVMMHostPatchBaseline.ps1 `
    -VMMServer scvmm01.contoso.local `
    -BaselineName 'Hyper-V Monthly Security Baseline' `
    -HostGroupName 'All Hosts\\Production\\Hyper-V' `
    -LogFile 'C:\Logs\HyperV-Patching.log' `
    -ContinueOnHostFailure

.EXAMPLE
.\Invoke-SCVMMHostPatchBaseline.ps1 `
    -VMMServer scvmm01.contoso.local `
    -BaselineName 'Hyper-V Monthly Security Baseline' `
    -HostGroupName 'All Hosts\\Production\\Hyper-V' `
    -VMHostNames hv01.contoso.local,hv02.contoso.local `
    -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMMServer,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BaselineName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$HostGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMHostNames,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$UpdateClassifications = @('Security Updates', 'Critical Updates', 'Update Rollups', 'Updates'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$IncludeUpdateTitleRegex,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ExcludeUpdateTitleRegex = 'Preview|Language Pack|Feature update',

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$SynchronizationTimeoutMinutes = 180,

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$ComplianceTimeoutMinutes = 120,

    [Parameter()]
    [ValidateRange(1, 2880)]
    [int]$RemediationTimeoutMinutes = 360,

    [Parameter()]
    [ValidateRange(5, 600)]
    [int]$PollIntervalSeconds = 30,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogFile,

    [Parameter()]
    [switch]$SkipSynchronization,

    [Parameter()]
    [switch]$SkipRemediation,

    [Parameter()]
    [switch]$SkipFinalComplianceScan,

    [Parameter()]
    [switch]$ContinueOnHostFailure,

    [Parameter()]
    [switch]$ParallelRemediation,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$MaxParallelHostsPerCluster = 2,

    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$MinimumClusterAvailableResourcePercent = 50,

    [Parameter()]
    [switch]$CentreonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFilePath    = $LogFile
$script:LogWriteWarned = $false
$script:FailedHosts    = [ordered]@{}
$script:CentreonOutputMode = [bool]$CentreonOutput

function Write-PatchLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    if (-not $script:CentreonOutputMode) {
        Write-Host $line -ForegroundColor $color
    }

    if ($script:LogFilePath) {
        # Journalisation résiliente : un chemin inaccessible dégrade en sortie
        # console uniquement (un seul avertissement), sans interrompre le cycle.
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            if (-not $script:LogWriteWarned) {
                $script:LogWriteWarned = $true
                Write-Warning "Journal '$($script:LogFilePath)' inaccessible ($($_.Exception.Message)) — sortie console uniquement."
            }
        }
    }
}

function Add-HostFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    if (-not $script:FailedHosts.Contains($HostName)) {
        $script:FailedHosts[$HostName] = $Reason
    }
    Write-PatchLog "[$HostName] $Reason" -Level ERROR
}

function Wait-SCJobCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Job,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2880)]
        [int]$TimeoutMinutes,

        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [ValidateRange(5, 600)]
        [int]$IntervalSeconds = 30
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $currentJob = $Job

    # 'SucceedWithInfo' est un succès (avec avertissements), pas un échec : un
    # cycle planifié ne doit pas s'interrompre pour une remédiation réussie
    # accompagnée d'informations.
    $successStatuses = @('Completed', 'SucceedWithInfo')

    while ($null -ne $currentJob -and $currentJob.Status -in @('Running', 'NotStarted')) {
        if ((Get-Date) -gt $deadline) {
            throw "Timeout après $TimeoutMinutes minute(s) pendant : $Activity. Job SCVMM: $($currentJob.ID)."
        }

        Start-Sleep -Seconds $IntervalSeconds
        $currentJob = Get-SCJob -ID $currentJob.ID -ErrorAction Stop
        Write-Verbose "[$Activity] Statut SCVMM: $($currentJob.Status)."
    }

    if ($null -ne $currentJob -and [string]$currentJob.Status -notin $successStatuses) {
        throw "Echec SCVMM pendant : $Activity. Statut: $($currentJob.Status). Erreur: $($currentJob.ErrorInfo)."
    }

    if ($null -ne $currentJob -and [string]$currentJob.Status -eq 'SucceedWithInfo') {
        Write-PatchLog "[$Activity] Job SCVMM terminé avec informations. Détail: $($currentJob.ErrorInfo)." -Level WARN
    }

    return $currentJob
}

function Wait-SCJobBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2880)]
        [int]$TimeoutMinutes,

        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [ValidateRange(5, 600)]
        [int]$IntervalSeconds = 30
    )

    # Les jobs d'un lot s'exécutent simultanément côté SCVMM : ils partagent une
    # seule échéance au lieu d'additionner un timeout complet par job (N hôtes
    # en parallèle n'attendent plus jusqu'à N x timeout).
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $successStatuses = @('Completed', 'SucceedWithInfo')

    $pending = [ordered]@{}
    foreach ($entry in $Entries) {
        $pending[[string]$entry.Name] = $entry.Job
    }
    $results = @()

    while ($pending.Count -gt 0) {
        foreach ($name in @($pending.Keys)) {
            $job = Get-SCJob -ID $pending[$name].ID -ErrorAction Stop
            if ($job.Status -in @('Running', 'NotStarted')) {
                $pending[$name] = $job
                continue
            }

            $succeeded = [string]$job.Status -in $successStatuses
            if ($succeeded -and [string]$job.Status -eq 'SucceedWithInfo') {
                Write-PatchLog "[$Activity $name] Job SCVMM terminé avec informations. Détail: $($job.ErrorInfo)." -Level WARN
            }
            $results += [pscustomobject]@{
                Name      = $name
                Succeeded = $succeeded
                Status    = [string]$job.Status
                Detail    = if ($succeeded) { '' } else { "Statut: $($job.Status). Erreur: $($job.ErrorInfo)." }
            }
            $pending.Remove($name)
        }

        if ($pending.Count -eq 0) { break }

        if ((Get-Date) -gt $deadline) {
            foreach ($name in @($pending.Keys)) {
                $results += [pscustomobject]@{
                    Name      = $name
                    Succeeded = $false
                    Status    = 'Timeout'
                    Detail    = "Timeout après $TimeoutMinutes minute(s). Job SCVMM: $($pending[$name].ID)."
                }
                $pending.Remove($name)
            }
            break
        }

        Write-Verbose "[$Activity] $($pending.Count) job(s) SCVMM en cours."
        Start-Sleep -Seconds $IntervalSeconds
    }

    return $results
}

function Get-ObjectName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    foreach ($propertyName in @('Name', 'ComputerName', 'FullyQualifiedDomainName')) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return [string]$InputObject
}

function Get-VMHostAliasSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost
    )

    $aliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($propertyName in @('Name', 'ComputerName', 'FullyQualifiedDomainName')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            [void]$aliases.Add([string]$property.Value)
        }
    }

    return , $aliases
}


function Get-VMHostClusterName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost
    )

    foreach ($propertyName in @('HostCluster', 'VMHostCluster', 'Cluster', 'ClusterName')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $null -eq $property.Value) { continue }

        if ($property.Value -is [string]) { return [string]$property.Value }
        $nameProperty = $property.Value.PSObject.Properties['Name']
        if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            return [string]$nameProperty.Value
        }
    }

    return '__Standalone__'
}

function Get-VMHostResourceWeight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost
    )

    foreach ($propertyName in @('TotalMemory', 'Memory', 'PhysicalMemory', 'MemoryCapacity')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = 0.0
            if ([double]::TryParse([string]$property.Value, [ref]$value) -and $value -gt 0) { return $value }
        }
    }

    foreach ($propertyName in @('CPUCount', 'LogicalProcessorCount', 'ProcessorCount')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = 0.0
            if ([double]::TryParse([string]$property.Value, [ref]$value) -and $value -gt 0) { return $value }
        }
    }

    return 1.0
}

function Test-VMHostLiveMigrationReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost
    )

    $hostName = Get-ObjectName -InputObject $VMHost
    $issues = @()

    $clusterName = Get-VMHostClusterName -VMHost $VMHost
    if ($clusterName -eq '__Standalone__') {
        $issues += 'hôte hors cluster SCVMM : remédiation avec Live Migration non garantie'
    }

    foreach ($propertyName in @('OverallState', 'Status', 'HostState', 'ComputerState')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value -and [string]$property.Value -match 'NeedsAttention|NotResponding|Unresponsive|Error|Failed') {
            $issues += "état hôte défavorable ($propertyName=$($property.Value))"
        }
    }

    foreach ($propertyName in @('AgentStatus', 'VMMServiceStatus')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value -and [string]$property.Value -notmatch 'UpToDate|Responding|OK|Healthy|Running') {
            $issues += "agent SCVMM non prêt ($propertyName=$($property.Value))"
        }
    }

    foreach ($propertyName in @('MaintenanceHost', 'InMaintenanceMode', 'MaintenanceMode')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $property.Value -eq $true) {
            $issues += 'hôte déjà en maintenance'
        }
    }

    return [pscustomobject]@{
        HostName    = $hostName
        ClusterName = $clusterName
        Ready       = ($issues.Count -eq 0)
        Issues      = $issues
    }
}

function New-ClusterRemediationBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$CandidateHosts,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 64)]
        [int]$MaxParallelHostsPerCluster,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 100)]
        [int]$MinimumClusterAvailableResourcePercent
    )

    $batches = @()
    $clusterGroups = $CandidateHosts | Group-Object { Get-VMHostClusterName -VMHost $_ }
    $remainingByCluster = @{}
    foreach ($group in $clusterGroups) { $remainingByCluster[$group.Name] = @($group.Group) }

    while (($remainingByCluster.Values | Where-Object { @($_).Count -gt 0 } | Measure-Object).Count -gt 0) {
        $batch = @()
        foreach ($clusterName in @($remainingByCluster.Keys)) {
            $remaining = @($remainingByCluster[$clusterName])
            if ($remaining.Count -eq 0) { continue }

            $totalWeight = ($CandidateHosts | Where-Object { (Get-VMHostClusterName -VMHost $_) -eq $clusterName } | ForEach-Object { Get-VMHostResourceWeight -VMHost $_ } | Measure-Object -Sum).Sum
            if (-not $totalWeight -or $totalWeight -le 0) { $totalWeight = [double]$remaining.Count }

            $selected = @()
            foreach ($hostItem in $remaining) {
                if ($selected.Count -ge $MaxParallelHostsPerCluster) { break }
                $selectedWeight = ($selected + @($hostItem) | ForEach-Object { Get-VMHostResourceWeight -VMHost $_ } | Measure-Object -Sum).Sum
                $availablePercent = (($totalWeight - $selectedWeight) / $totalWeight) * 100
                if ($availablePercent -ge $MinimumClusterAvailableResourcePercent) { $selected += $hostItem }
            }

            if ($selected.Count -eq 0) { $selected = @($remaining | Select-Object -First 1) }
            $batch += $selected
            $remainingByCluster[$clusterName] = @($remaining | Where-Object { $current = $_; -not @($selected | Where-Object { [object]::ReferenceEquals($_, $current) }) })
        }
        if ($batch.Count -eq 0) { break }
        $batches += , @($batch)
    }

    return , $batches
}

function Write-CentreonSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$TargetedCount,
        [Parameter(Mandatory = $true)][int]$RemediatedCount,
        [Parameter(Mandatory = $true)][int]$FailureCount
    )

    $state = if ($FailureCount -gt 0) { 'CRITICAL' } else { 'OK' }
    $message = "$state - Hyper-V/SCVMM patching: targeted=$TargetedCount remediated=$RemediatedCount failed=$FailureCount | targeted=$TargetedCount remediated=$RemediatedCount failed=$FailureCount"
    Write-Output $message
}

function Get-VMHostComplianceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost,

        [Parameter(Mandatory = $true)]
        [object]$VmmConnection
    )

    # Relevé défensif : la forme des objets de conformité varie selon la version
    # de VMM. Toute défaillance retourne 'Unknown (...)' sans interrompre le cycle.
    try {
        $aliases = Get-VMHostAliasSet -VMHost $VMHost

        $managedComputer = Get-SCVMMManagedComputer -VMMServer $VmmConnection -ErrorAction Stop | Where-Object {
            $nameProperty = $_.PSObject.Properties['Name']
            $null -ne $nameProperty -and $null -ne $nameProperty.Value -and $aliases.Contains([string]$nameProperty.Value)
        } | Select-Object -First 1

        if ($null -eq $managedComputer) {
            return 'Unknown (ordinateur managé introuvable dans SCVMM)'
        }

        $status = Get-SCComplianceStatus -VMMManagedComputer $managedComputer -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $status) {
            return 'Unknown (aucun statut de conformité retourné)'
        }

        $stateProperty = $status.PSObject.Properties['OverallComplianceState']
        if ($null -ne $stateProperty -and $null -ne $stateProperty.Value -and "$($stateProperty.Value)" -ne '') {
            return [string]$stateProperty.Value
        }
        return 'Unknown'
    } catch {
        return "Unknown ($($_.Exception.Message))"
    }
}

Import-Module VirtualMachineManager -ErrorAction Stop

Write-PatchLog "Cycle patching démarré — VMM: $VMMServer, baseline: '$BaselineName', groupe: '$HostGroupName'."
$vmmConnection = Get-SCVMMServer -ComputerName $VMMServer -SetAsDefault -ErrorAction Stop

if (-not $SkipSynchronization) {
    $updateServers = @(Get-SCUpdateServer -VMMServer $vmmConnection -ErrorAction Stop)
    if ($updateServers.Count -eq 0) {
        throw "Aucun serveur WSUS intégré à SCVMM n'a été trouvé."
    }

    foreach ($updateServer in $updateServers) {
        $target = "WSUS '$($updateServer.ComputerName)' intégré à VMM '$VMMServer'"
        if ($PSCmdlet.ShouldProcess($target, 'Synchroniser le catalogue de correctifs')) {
            Write-PatchLog "Synchronisation WSUS/SCVMM : $($updateServer.ComputerName)."
            $syncJob = Start-SCUpdateServerSynchronization `
                -UpdateServer $updateServer `
                -VMMServer $vmmConnection `
                -RunAsynchronously `
                -ErrorAction Stop
            Wait-SCJobCompletion -Job $syncJob -TimeoutMinutes $SynchronizationTimeoutMinutes -Activity "Synchronisation $($updateServer.ComputerName)" -IntervalSeconds $PollIntervalSeconds | Out-Null
        }
    }
}
else {
    Write-PatchLog 'Synchronisation WSUS/SCVMM ignorée (-SkipSynchronization).'
}

$hostGroups = @(Get-SCVMHostGroup -VMMServer $vmmConnection -Name $HostGroupName -ErrorAction Stop)
if ($hostGroups.Count -gt 1) {
    $paths = ($hostGroups | ForEach-Object {
            $pathProperty = $_.PSObject.Properties['Path']
            if ($null -ne $pathProperty -and $pathProperty.Value) { [string]$pathProperty.Value } else { [string]$_.Name }
        }) -join ', '
    throw "Plusieurs groupes d'hôtes portent le nom '$HostGroupName' ($paths). Utilisez un nom de groupe unique."
}
$hostGroup = $hostGroups[0]

# AllChildHosts inclut les hôtes des sous-groupes ; le filtre par VMHostGroup.ID
# (repli si la propriété est absente) ne retient que les hôtes directs du groupe.
$allChildHostsProperty = $hostGroup.PSObject.Properties['AllChildHosts']
if ($null -ne $allChildHostsProperty -and $null -ne $allChildHostsProperty.Value) {
    $hosts = @($allChildHostsProperty.Value)
}
else {
    $hosts = @(Get-SCVMHost -VMMServer $vmmConnection | Where-Object {
            $groupProperty = $_.PSObject.Properties['VMHostGroup']
            $null -ne $groupProperty -and $null -ne $groupProperty.Value -and $groupProperty.Value.ID -eq $hostGroup.ID
        })
}

if ($VMHostNames) {
    # Sélection nominative avec contrôle strict : un nom sans correspondance
    # (faute de frappe) arrête le cycle plutôt que d'exclure silencieusement
    # un hôte du patching.
    $selectedHosts = @()
    $matchedNames  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($hostItem in $hosts) {
        $aliasSet = Get-VMHostAliasSet -VMHost $hostItem
        $wantedMatches = @($VMHostNames | Where-Object { $aliasSet.Contains($_) })
        if ($wantedMatches.Count -gt 0) {
            $selectedHosts += $hostItem
            foreach ($match in $wantedMatches) { [void]$matchedNames.Add($match) }
        }
    }

    $unmatchedNames = @($VMHostNames | Where-Object { -not $matchedNames.Contains($_) } | Select-Object -Unique)
    if ($unmatchedNames.Count -gt 0) {
        throw "Hôte(s) demandé(s) introuvable(s) dans '$HostGroupName' : $($unmatchedNames -join ', '). Vérifiez -VMHostNames."
    }

    $hosts = $selectedHosts
}

if ($hosts.Count -eq 0) {
    throw "Aucun hôte Hyper-V SCVMM trouvé dans '$HostGroupName' avec les filtres fournis."
}

Write-PatchLog "Hôtes ciblés ($($hosts.Count)) :"
$hosts | ForEach-Object { Write-PatchLog "  - $(Get-ObjectName -InputObject $_)" }

# Le catalogue peut contenir des dizaines de milliers de mises à jour : filtrer
# en une seule passe (classification via HashSet, titres via regex, exclusion
# des correctifs supersédés/déclinés lorsque ces propriétés existent) plutôt
# qu'en trois passes avec un appel de fonction par objet.
$allowedClassifications = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($classification in $UpdateClassifications) {
    [void]$allowedClassifications.Add($classification)
}

$updates = @(Get-SCUpdate -VMMServer $vmmConnection -ErrorAction Stop | Where-Object {
        $update = $_

        $classificationMatch = $false
        foreach ($propertyName in @('Classification', 'UpdateClassification', 'ClassificationName')) {
            $property = $update.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $allowedClassifications.Contains([string]$property.Value)) {
                $classificationMatch = $true
                break
            }
        }
        if (-not $classificationMatch) { return $false }

        $title = $null
        foreach ($propertyName in @('Title', 'Name')) {
            $property = $update.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $title = [string]$property.Value
                break
            }
        }
        if (-not $title) { $title = [string]$update }

        if ($IncludeUpdateTitleRegex -and $title -notmatch $IncludeUpdateTitleRegex) { return $false }
        if ($ExcludeUpdateTitleRegex -and $title -match $ExcludeUpdateTitleRegex) { return $false }

        foreach ($flagName in @('IsSuperseded', 'IsDeclined')) {
            $property = $update.PSObject.Properties[$flagName]
            if ($null -ne $property -and $property.Value -eq $true) { return $false }
        }

        return $true
    })

if ($updates.Count -eq 0) {
    throw 'Aucune mise à jour candidate trouvée pour alimenter la baseline.'
}

Write-PatchLog "$($updates.Count) correctif(s) candidat(s) pour la baseline."

$baseline = Get-SCBaseline -VMMServer $vmmConnection -Name $BaselineName -ErrorAction SilentlyContinue
$baselineTarget = "Baseline SCVMM '$BaselineName'"

if ($null -eq $baseline) {
    if ($PSCmdlet.ShouldProcess($baselineTarget, 'Créer la baseline')) {
        $baseline = New-SCBaseline -VMMServer $vmmConnection -Name $BaselineName -Update $updates -ErrorAction Stop
        Write-PatchLog "Baseline '$BaselineName' créée avec $($updates.Count) correctif(s)."
    }
}
else {
    if ($PSCmdlet.ShouldProcess($baselineTarget, "Mettre à jour avec $($updates.Count) correctif(s)")) {
        Set-SCBaseline -Baseline $baseline -Update $updates -ErrorAction Stop | Out-Null
        $baseline = Get-SCBaseline -VMMServer $vmmConnection -Name $BaselineName -ErrorAction Stop
        Write-PatchLog "Baseline '$BaselineName' mise à jour avec $($updates.Count) correctif(s)."
    }
}

# En mode -Confirm, l'opérateur peut refuser la création de la baseline puis
# accepter les étapes suivantes : sans cette garde, Set-SCBaseline recevrait
# -Baseline $null et échouerait avec une erreur de binding brute. En -WhatIf,
# la simulation des étapes suivantes reste affichée (leurs blocs ShouldProcess
# ne s'exécutent jamais).
if ($null -eq $baseline) {
    Write-PatchLog "Baseline '$BaselineName' non disponible (création refusée ou simulée)." -Level WARN
    if (-not $WhatIfPreference) {
        return
    }
}

foreach ($hostItem in $hosts) {
    $hostName = Get-ObjectName -InputObject $hostItem
    if ($PSCmdlet.ShouldProcess("Hôte Hyper-V '$hostName'", "Affecter la baseline '$BaselineName'")) {
        Set-SCBaseline -Baseline $baseline -VMHost $hostItem -ErrorAction Stop | Out-Null
    }
}

# Scans de conformité : les jobs sont lancés en parallèle (un scan ne perturbe
# pas les charges de travail) puis attendus comme un seul lot. Un hôte dont le
# scan échoue est exclu de la remédiation et compté en échec.
$scanEntries = @()
foreach ($hostItem in $hosts) {
    $hostName = Get-ObjectName -InputObject $hostItem
    if ($PSCmdlet.ShouldProcess("Hôte Hyper-V '$hostName'", 'Scanner la conformité aux correctifs')) {
        Write-PatchLog "Scan de conformité lancé : $hostName."
        try {
            $scanJob = Start-SCComplianceScan -VMHost $hostItem -RunAsynchronously -ErrorAction Stop
            $scanEntries += [pscustomobject]@{ Name = $hostName; Job = $scanJob }
        } catch {
            Add-HostFailure -HostName $hostName -Reason "Échec du lancement du scan de conformité : $($_.Exception.Message)"
        }
    }
}

if ($scanEntries.Count -gt 0) {
    foreach ($scanResult in Wait-SCJobBatch -Entries $scanEntries -TimeoutMinutes $ComplianceTimeoutMinutes -Activity 'Scan conformité' -IntervalSeconds $PollIntervalSeconds) {
        if ($scanResult.Succeeded) {
            Write-PatchLog "Scan de conformité terminé : $($scanResult.Name)."
        } else {
            Add-HostFailure -HostName $scanResult.Name -Reason "Scan de conformité en échec — hôte exclu de la remédiation. $($scanResult.Detail)"
        }
    }
}

$remediatedHostItems = @()

if ($SkipRemediation) {
    Write-PatchLog 'Remédiation ignorée (-SkipRemediation).'
}
else {
    $candidateHosts = @()
    foreach ($hostItem in $hosts) {
        $hostName = Get-ObjectName -InputObject $hostItem
        if ($script:FailedHosts.Contains($hostName)) {
            Write-PatchLog "Remédiation ignorée pour $hostName (échec en amont)." -Level WARN
            continue
        }

        $readiness = Test-VMHostLiveMigrationReadiness -VMHost $hostItem
        if (-not $readiness.Ready) {
            Add-HostFailure -HostName $hostName -Reason "Pré-contrôle Live Migration en échec : $($readiness.Issues -join '; ')"
            continue
        }

        $candidateHosts += $hostItem
    }

    $remediationBatches = if ($ParallelRemediation) {
        @(New-ClusterRemediationBatch -CandidateHosts $candidateHosts -MaxParallelHostsPerCluster $MaxParallelHostsPerCluster -MinimumClusterAvailableResourcePercent $MinimumClusterAvailableResourcePercent)
    } else {
        @($candidateHosts | ForEach-Object { , @($_) })
    }

    foreach ($batch in $remediationBatches) {
        $remediationJobs = @()
        foreach ($hostItem in @($batch)) {
            $hostName = Get-ObjectName -InputObject $hostItem
            if ($PSCmdlet.ShouldProcess("Hôte Hyper-V '$hostName'", 'Appliquer les correctifs via maintenance SCVMM et Live Migration')) {
                Write-PatchLog "Remédiation : $hostName."
                try {
                    $job = Start-SCUpdateRemediation `
                        -VMHost $hostItem `
                        -Baseline $baseline `
                        -RunAsynchronously `
                        -ErrorAction Stop
                    $remediationJobs += [pscustomobject]@{ Name = $hostName; Job = $job; VMHost = $hostItem }
                } catch {
                    Add-HostFailure -HostName $hostName -Reason "Échec du lancement de la remédiation : $($_.Exception.Message)"
                    if (-not $ContinueOnHostFailure -and -not $ParallelRemediation) { throw }
                }
            }
        }

        foreach ($remediationResult in Wait-SCJobBatch -Entries $remediationJobs -TimeoutMinutes $RemediationTimeoutMinutes -Activity 'Remédiation' -IntervalSeconds $PollIntervalSeconds) {
            if ($remediationResult.Succeeded) {
                Write-PatchLog "Remédiation terminée : $($remediationResult.Name)."
                $remediatedHostItems += @($remediationJobs | Where-Object { $_.Name -eq $remediationResult.Name } | ForEach-Object { $_.VMHost })
            } else {
                Add-HostFailure -HostName $remediationResult.Name -Reason "Remédiation en échec : $($remediationResult.Detail)"
                if (-not $ContinueOnHostFailure -and -not $ParallelRemediation) { throw "Remédiation en échec : $($remediationResult.Name)" }
            }
        }
    }

    # Re-scan de conformité : vérifie que la remédiation a réellement ramené les
    # hôtes à l'état conforme (un correctif peut rester en attente de redémarrage
    # ou avoir échoué silencieusement côté agent).
    if (-not $SkipFinalComplianceScan -and $remediatedHostItems.Count -gt 0) {
        Write-PatchLog 'Scan de conformité post-remédiation.'
        $finalScanEntries = @()
        foreach ($hostItem in $remediatedHostItems) {
            $hostName = Get-ObjectName -InputObject $hostItem
            try {
                $scanJob = Start-SCComplianceScan -VMHost $hostItem -RunAsynchronously -ErrorAction Stop
                $finalScanEntries += [pscustomobject]@{ Name = $hostName; Job = $scanJob }
            } catch {
                Write-PatchLog "Vérification finale impossible pour $hostName : $($_.Exception.Message)" -Level WARN
            }
        }

        if ($finalScanEntries.Count -gt 0) {
            foreach ($scanResult in Wait-SCJobBatch -Entries $finalScanEntries -TimeoutMinutes $ComplianceTimeoutMinutes -Activity 'Scan final' -IntervalSeconds $PollIntervalSeconds) {
                if (-not $scanResult.Succeeded) {
                    Write-PatchLog "Scan final en échec pour $($scanResult.Name) — état de conformité non vérifié. $($scanResult.Detail)" -Level WARN
                }
            }
        }

        foreach ($hostItem in $remediatedHostItems) {
            $hostName = Get-ObjectName -InputObject $hostItem
            $complianceState = Get-VMHostComplianceState -VMHost $hostItem -VmmConnection $vmmConnection
            $level = if ($complianceState -eq 'Compliant') { 'INFO' } else { 'WARN' }
            Write-PatchLog "Conformité finale ${hostName} : $complianceState" -Level $level
        }
    }
    elseif ($SkipFinalComplianceScan) {
        Write-PatchLog 'Scan de conformité post-remédiation ignoré (-SkipFinalComplianceScan).'
    }
}

# ── Bilan et code de sortie ───────────────────────────────────────────────────
$failureCount = $script:FailedHosts.Count
Write-PatchLog "Cycle patching Hyper-V/SCVMM terminé : $($hosts.Count) hôte(s) ciblé(s), $($remediatedHostItems.Count) remédié(s), $failureCount en échec."

if ($CentreonOutput) {
    Write-CentreonSummary -TargetedCount $hosts.Count -RemediatedCount $remediatedHostItems.Count -FailureCount $failureCount
}

if ($failureCount -gt 0) {
    foreach ($failure in $script:FailedHosts.GetEnumerator()) {
        Write-PatchLog "  Échec $($failure.Key) : $($failure.Value)" -Level ERROR
    }
    exit 1
}

exit 0
