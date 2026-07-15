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

Pré-contrôles Live Migration (sur données hôtes rafraîchies, juste avant la remédiation) :
- bloquants (hôte exclu) : hôte injoignable/dégradé, agent VMM non prêt, hôte déjà en maintenance ;
- avertissements : hôte hors cluster (VM en saved state, pas d'évacuation), VM non hautement
  disponibles, média ISO/lecteur hôte attaché à une VM en cours d'exécution — le bloqueur
  classique de Live Migration, éjectable automatiquement avec -DismountIso.

Garde-fous supplémentaires pendant la remédiation :
- avant chaque lot (mode séquentiel compris), la mémoire RÉELLEMENT disponible du cluster
  (AvailableMemory/TotalMemory des nœuds actifs, hors hôtes du lot) est mesurée : sous le
  seuil -MinimumClusterAvailableResourcePercent, un avertissement explicite est émis ;
- en fin de cycle, tout hôte ciblé resté en mode maintenance (job en échec ou timeout) est
  signalé : un hôte oublié en maintenance ampute silencieusement la capacité du cluster.

Toutes les étapes sont journalisées avec horodatage sur la console et, si -LogFile est fourni,
dans un fichier — indispensable pour diagnostiquer une exécution planifiée.

Codes de sortie (sans -CentreonOutput) :
  0 = cycle terminé sans échec d'hôte
  1 = au moins un hôte en échec (scan, pré-contrôle ou remédiation), ou erreur fatale
Avec -CentreonOutput, les codes suivent la convention plugin : 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN.

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
Pourcentage minimal de ressources du cluster qui doit rester disponible dans un lot parallèle. Le poids
d'un hôte utilise sa mémoire si elle est exposée par SCVMM, sinon le nombre de CPU, sinon 1 par hôte.
Le total de référence est la capacité de TOUS les membres actifs du cluster connus de VMM (pas seulement
les hôtes ciblés). Si le seuil est impossible à respecter même avec un seul hôte (ex. cluster mono-nœud),
le script avance hôte par hôte en le signalant par un avertissement.

.PARAMETER DismountIso
Éjecte automatiquement les médias (ISO/lecteur hôte) attachés aux lecteurs DVD des VM en cours
d'exécution avant la remédiation de leur hôte — bloqueur classique de Live Migration. Sans ce
commutateur, les médias attachés sont seulement signalés en avertissement. Sans effet en -WhatIf.

.PARAMETER RemediationRetryCount
Nombre de tentatives supplémentaires pour les hôtes dont la remédiation a échoué (défaut : 0).
Les échecs de Live Migration sont souvent transitoires (pic de charge, verrou VM) : les hôtes
en échec sont relancés UN PAR UN à la fin du cycle, après un nouveau pré-contrôle Live
Migration sur données rafraîchies. Un hôte récupéré est retiré des échecs et inclus dans le
re-scan de conformité final. Sans objet quand la première tentative a arrêté le cycle
(mode séquentiel strict sans -ContinueOnHostFailure).

.PARAMETER CentreonOutput
Supprime la sortie de log console courante et émet une ligne finale compatible plugin Centreon/Nagios
avec perfdata. Les codes retour suivent alors la convention plugin : 0=OK, 1=WARNING (cycle terminé
avec avertissements), 2=CRITICAL (échec d'hôte ou erreur fatale), 3=UNKNOWN (baseline refusée).
Sans ce commutateur, les codes de sortie restent 0 (succès) / 1 (échec).

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
    [switch]$DismountIso,

    [Parameter()]
    [ValidateRange(0, 5)]
    [int]$RemediationRetryCount = 0,

    [Parameter()]
    [switch]$CentreonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFilePath    = $LogFile
$script:LogWriteWarned = $false
$script:FailedHosts    = [ordered]@{}
$script:CentreonOutputMode = [bool]$CentreonOutput
$script:WarningCount   = 0
$script:CycleStart     = Get-Date

function Write-PatchLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if ($Level -eq 'WARN') { $script:WarningCount++ }

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

function Test-DvdDriveHasMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Drive
    )

    foreach ($propertyName in @('ISO', 'HostDrive')) {
        $property = $Drive.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value -and "$($property.Value)" -ne '') {
            return $true
        }
    }

    $connectionProperty = $Drive.PSObject.Properties['Connection']
    if ($null -ne $connectionProperty -and $null -ne $connectionProperty.Value) {
        $connection = [string]$connectionProperty.Value
        if ($connection -ne '' -and $connection -ne 'None') { return $true }
    }

    return $false
}

function Test-VMHostLiveMigrationReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost,

        [switch]$DismountIso
    )

    # Pré-contrôles des causes classiques d'échec de la mise en maintenance
    # SCVMM (évacuation Live Migration) après le scan de baseline :
    # - Issues (bloquants) : hôte injoignable/dégradé, agent VMM non prêt,
    #   hôte déjà en maintenance — la remédiation échouerait, l'hôte est exclu ;
    # - Warnings (non bloquants) : hôte hors cluster (les VM passent en saved
    #   state, pas de Live Migration), VM non hautement disponibles, média
    #   ISO/lecteur hôte attaché à une VM en cours d'exécution (bloqueur
    #   classique de Live Migration, éjecté automatiquement avec -DismountIso).
    $hostName = Get-ObjectName -InputObject $VMHost
    $issues   = @()
    $warnings = @()
    $fixed    = @()

    $clusterName = Get-VMHostClusterName -VMHost $VMHost
    $isClustered = $clusterName -ne '__Standalone__'
    if (-not $isClustered) {
        # Avertissement, pas une exclusion : un hôte standalone reste patchable,
        # simplement sans évacuation Live Migration.
        $warnings += "hôte hors cluster SCVMM : pas d'évacuation Live Migration — les VM seront mises en saved state pendant la maintenance"
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

    if (Test-VMHostInMaintenance -VMHost $VMHost) {
        $issues += 'hôte déjà en maintenance'
    }

    # Inspection des VM en cours d'exécution (défensive : une inspection
    # impossible produit un avertissement, jamais un plantage).
    try {
        $vms = @(Get-SCVirtualMachine -VMHost $VMHost -ErrorAction Stop)

        $runningVms = @($vms | Where-Object {
                $vm = $_
                $state = $null
                foreach ($propertyName in @('VirtualMachineState', 'Status', 'StatusString')) {
                    $property = $vm.PSObject.Properties[$propertyName]
                    if ($null -ne $property -and $null -ne $property.Value) { $state = [string]$property.Value; break }
                }
                $state -match '^Running'
            })

        if ($isClustered) {
            $nonHaVms = @($runningVms | Where-Object {
                    $property = $_.PSObject.Properties['IsHighlyAvailable']
                    $null -ne $property -and $property.Value -eq $false
                })
            if ($nonHaVms.Count -gt 0) {
                $names = @($nonHaVms | ForEach-Object { Get-ObjectName -InputObject $_ } | Select-Object -First 5) -join ', '
                $warnings += "$($nonHaVms.Count) VM non hautement disponible(s) en cours d'exécution (saved state pendant la maintenance, pas de Live Migration) : $names$(if ($nonHaVms.Count -gt 5) { ', …' })"
            }
        }

        foreach ($vm in $runningVms) {
            $vmName = Get-ObjectName -InputObject $vm
            $drives = @()
            try {
                $drives = @(Get-SCVirtualDVDDrive -VM $vm -ErrorAction Stop)
            } catch {
                Write-Verbose "Lecture des lecteurs DVD impossible pour '$vmName' : $($_.Exception.Message)"
                continue
            }

            foreach ($drive in $drives) {
                if ($null -eq $drive) { continue }
                if (-not (Test-DvdDriveHasMedia -Drive $drive)) { continue }

                if ($DismountIso) {
                    try {
                        Set-SCVirtualDVDDrive -VirtualDVDDrive $drive -NoMedia -ErrorAction Stop | Out-Null
                        $fixed += "média éjecté du lecteur DVD de la VM '$vmName'"
                    } catch {
                        $warnings += "éjection du média impossible pour la VM '$vmName' : $($_.Exception.Message) — la Live Migration de cette VM peut échouer"
                    }
                } else {
                    $warnings += "VM '$vmName' : média attaché au lecteur DVD — bloqueur classique de Live Migration (relancez avec -DismountIso pour l'éjecter automatiquement)"
                }
            }
        }
    } catch {
        $warnings += "inspection des VM de $hostName impossible : $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        HostName    = $hostName
        ClusterName = $clusterName
        Ready       = ($issues.Count -eq 0)
        Issues      = @($issues)
        Warnings    = @($warnings)
        Fixed       = @($fixed)
    }
}

function Test-VMHostInMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost
    )

    foreach ($propertyName in @('MaintenanceHost', 'InMaintenanceMode', 'MaintenanceMode')) {
        $property = $VMHost.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $property.Value -eq $true) { return $true }
    }

    return $false
}

function Test-VMHostContributesCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$VMHost
    )

    # Un nœud injoignable ou déjà en maintenance n'apporte aucune capacité
    # d'accueil aux VM évacuées : il ne compte pas dans le total du cluster.
    $communicationProperty = $VMHost.PSObject.Properties['CommunicationState']
    if ($null -ne $communicationProperty -and $null -ne $communicationProperty.Value -and
        [string]$communicationProperty.Value -ne 'Responding') {
        return $false
    }

    return -not (Test-VMHostInMaintenance -VMHost $VMHost)
}

function ConvertTo-MemoryMegabytes {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    # VMM expose TotalMemory en octets mais AvailableMemory en mégaoctets.
    # Heuristique : une valeur > 1e8 est en octets (aucun hôte n'expose plus de
    # 100 To en Mo, et le moindre hôte dépasse 1e8 octets). Retourne -1 quand la
    # valeur est illisible, pour que l'appelant dégrade proprement ; 0 reste 0
    # (un hôte saturé n'a légitimement plus de mémoire disponible).
    if ($null -eq $Value) { return [double]-1 }

    $numeric = 0.0
    if (-not [double]::TryParse([string]$Value, [ref]$numeric)) { return [double]-1 }
    if ($numeric -lt 0) { return [double]-1 }

    if ($numeric -gt 1e8) {
        return [math]::Round($numeric / 1MB, 0)
    }
    return [math]::Round($numeric, 0)
}

function Get-ClusterLiveCapacityPercent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ClusterHosts,

        [string[]]$ExcludedHostNames = @()
    )

    # Pourcentage de mémoire RÉELLEMENT disponible sur les nœuds actifs du
    # cluster (hors hôtes exclus, typiquement ceux du lot en cours de
    # lancement). Contrairement à la planification statique par poids, cette
    # mesure reflète la charge courante. Retourne $null quand la mémoire n'est
    # pas lisible via VMM.
    $excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $ExcludedHostNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$excluded.Add($name) }
    }

    $totalMB = 0.0
    $availableMB = 0.0
    $countedHosts = 0

    foreach ($clusterHost in @($ClusterHosts)) {
        if ($null -eq $clusterHost) { continue }

        $isExcluded = $false
        foreach ($alias in (Get-VMHostAliasSet -VMHost $clusterHost)) {
            if ($excluded.Contains($alias)) { $isExcluded = $true; break }
        }
        if ($isExcluded) { continue }
        if (-not (Test-VMHostContributesCapacity -VMHost $clusterHost)) { continue }

        $hostTotalMB = ConvertTo-MemoryMegabytes -Value $(
            $property = $clusterHost.PSObject.Properties['TotalMemory']
            if ($null -ne $property) { $property.Value } else { $null }
        )
        $hostAvailableMB = ConvertTo-MemoryMegabytes -Value $(
            $property = $clusterHost.PSObject.Properties['AvailableMemory']
            if ($null -ne $property) { $property.Value } else { $null }
        )

        if ($hostTotalMB -le 0 -or $hostAvailableMB -lt 0) { return $null }

        $totalMB += $hostTotalMB
        $availableMB += $hostAvailableMB
        $countedHosts++
    }

    if ($countedHosts -eq 0 -or $totalMB -le 0) { return $null }

    return [math]::Round(($availableMB / $totalMB) * 100, 1)
}

function New-ClusterRemediationBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$CandidateHosts,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 64)]
        [int]$MaxParallelHostsPerCluster,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 100)]
        [int]$MinimumClusterAvailableResourcePercent,

        # Liste complète des hôtes VMM : le pourcentage « disponible » doit être
        # calculé sur la capacité de TOUS les membres actifs du cluster, pas
        # seulement sur les hôtes ciblés (cibler 2 hôtes d'un cluster de 8 doit
        # permettre un lot de 2 : la capacité retirée n'est que de 25 %).
        [AllowEmptyCollection()]
        [object[]]$AllClusterHosts = @()
    )

    $batches = @()
    $clusterGroups = $CandidateHosts | Group-Object { Get-VMHostClusterName -VMHost $_ }
    $remainingByCluster = @{}
    $totalWeightByCluster = @{}

    foreach ($group in $clusterGroups) {
        $remainingByCluster[$group.Name] = @($group.Group)

        $membership = @()
        if (@($AllClusterHosts).Count -gt 0) {
            $membership = @($AllClusterHosts | Where-Object {
                    (Get-VMHostClusterName -VMHost $_) -eq $group.Name -and
                    (Test-VMHostContributesCapacity -VMHost $_)
                })
        }
        if ($membership.Count -eq 0) { $membership = @($group.Group) }

        $totalWeight = ($membership | ForEach-Object { Get-VMHostResourceWeight -VMHost $_ } | Measure-Object -Sum).Sum
        if (-not $totalWeight -or $totalWeight -le 0) { $totalWeight = [double]$membership.Count }
        $totalWeightByCluster[$group.Name] = [double]$totalWeight
    }

    while (($remainingByCluster.Values | Where-Object { @($_).Count -gt 0 } | Measure-Object).Count -gt 0) {
        $batch = @()
        foreach ($clusterName in @($remainingByCluster.Keys)) {
            $remaining = @($remainingByCluster[$clusterName])
            if ($remaining.Count -eq 0) { continue }

            $totalWeight = [double]$totalWeightByCluster[$clusterName]

            $selected = @()
            $selectedWeight = 0.0
            foreach ($hostItem in $remaining) {
                if ($selected.Count -ge $MaxParallelHostsPerCluster) { break }
                $candidateWeight = Get-VMHostResourceWeight -VMHost $hostItem
                $availablePercent = (($totalWeight - ($selectedWeight + $candidateWeight)) / $totalWeight) * 100
                if ($availablePercent -ge $MinimumClusterAvailableResourcePercent) {
                    $selected += $hostItem
                    $selectedWeight += $candidateWeight
                }
            }

            if ($selected.Count -eq 0) {
                # Seuil impossible à respecter même avec un seul hôte (ex. cluster
                # mono-nœud) : on avance hôte par hôte mais on le SIGNALE au lieu
                # de violer silencieusement la contrainte.
                $selected = @($remaining | Select-Object -First 1)
                Write-PatchLog "[$clusterName] Seuil de $MinimumClusterAvailableResourcePercent% de ressources disponibles impossible à respecter même avec un seul hôte — remédiation hôte par hôte sous le seuil : $(Get-ObjectName -InputObject $selected[0])." -Level WARN
            }
            $batch += $selected
            $remainingByCluster[$clusterName] = @($remaining | Where-Object { $current = $_; -not @($selected | Where-Object { [object]::ReferenceEquals($_, $current) }) })
        }
        if ($batch.Count -eq 0) { break }
        $batches += , @($batch)
    }

    # Émet chaque lot comme un objet unique : l'appelant collecte avec @() et
    # obtient un tableau de lots. (L'ancien `return , $batches` combiné au @()
    # de l'appelant ajoutait un niveau d'imbrication : en mode parallèle chaque
    # « hôte » remédié était en réalité un tableau d'hôtes.)
    foreach ($completedBatch in $batches) {
        Write-Output -InputObject @($completedBatch) -NoEnumerate
    }
}

function Get-CentreonState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$FailureCount,
        [int]$WarningCount = 0
    )

    if ($FailureCount -gt 0) { return 'CRITICAL' }
    if ($WarningCount -gt 0) { return 'WARNING' }
    return 'OK'
}

function Get-CentreonExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'WARNING', 'CRITICAL', 'UNKNOWN')]
        [string]$State
    )

    # Convention plugin Nagios/Centreon : 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN.
    # (Un simple 0/1 ferait afficher WARNING à Centreon pour un texte CRITICAL.)
    switch ($State) {
        'OK'       { return 0 }
        'WARNING'  { return 1 }
        'CRITICAL' { return 2 }
        default    { return 3 }
    }
}

function Format-CentreonSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'WARNING', 'CRITICAL', 'UNKNOWN')]
        [string]$State,

        [Parameter(Mandatory = $true)][int]$TargetedCount,
        [Parameter(Mandatory = $true)][int]$RemediatedCount,
        [Parameter(Mandatory = $true)][int]$FailureCount,
        [int]$WarningCount = 0,
        [double]$DurationMinutes = 0
    )

    return "$State - Hyper-V/SCVMM patching: targeted=$TargetedCount remediated=$RemediatedCount failed=$FailureCount warnings=$WarningCount | targeted=$TargetedCount remediated=$RemediatedCount failed=$FailureCount warnings=$WarningCount duration_min=$DurationMinutes"
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

# Le corps principal est encapsulé pour qu'une erreur fatale produise quand même
# une ligne plugin Centreon (CRITICAL) et un code de sortie exploitables : sans
# cela, un throw laissait la supervision sans aucune sortie.
try {

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
        if ($CentreonOutput) {
            Write-Output "UNKNOWN - Hyper-V/SCVMM patching: baseline '$BaselineName' non disponible (création refusée)"
            exit (Get-CentreonExitCode -State 'UNKNOWN')
        }
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
    # Vue rafraîchie des hôtes VMM : la synchronisation WSUS et les scans de
    # conformité peuvent durer des heures — les pré-contrôles Live Migration et
    # le calcul de capacité doivent refléter l'état ACTUEL des hôtes, pas celui
    # du début de cycle.
    $refreshedVmmHosts = @()
    $refreshedHostsByAlias = @{}
    try {
        $refreshedVmmHosts = @(Get-SCVMHost -VMMServer $vmmConnection -ErrorAction Stop)
        foreach ($refreshedHost in $refreshedVmmHosts) {
            foreach ($alias in (Get-VMHostAliasSet -VMHost $refreshedHost)) {
                if (-not $refreshedHostsByAlias.ContainsKey($alias)) {
                    $refreshedHostsByAlias[$alias] = $refreshedHost
                }
            }
        }
    } catch {
        Write-PatchLog "Rafraîchissement des hôtes VMM impossible ($($_.Exception.Message)) — pré-contrôles sur les données du début de cycle." -Level WARN
    }

    $candidateHosts = @()
    foreach ($hostItem in $hosts) {
        $hostName = Get-ObjectName -InputObject $hostItem
        if ($script:FailedHosts.Contains($hostName)) {
            Write-PatchLog "Remédiation ignorée pour $hostName (échec en amont)." -Level WARN
            continue
        }

        $currentHost = if ($refreshedHostsByAlias.ContainsKey($hostName)) { $refreshedHostsByAlias[$hostName] } else { $hostItem }

        # L'éjection ISO est une action : jamais en -WhatIf.
        $readiness = Test-VMHostLiveMigrationReadiness -VMHost $currentHost -DismountIso:($DismountIso -and -not $WhatIfPreference)
        foreach ($fixedItem in $readiness.Fixed)      { Write-PatchLog "[$hostName] $fixedItem" }
        foreach ($warningItem in $readiness.Warnings) { Write-PatchLog "[$hostName] $warningItem" -Level WARN }
        if (-not $readiness.Ready) {
            Add-HostFailure -HostName $hostName -Reason "Pré-contrôle Live Migration en échec : $($readiness.Issues -join '; ')"
            continue
        }

        $candidateHosts += $currentHost
    }

    $remediationBatches = if ($ParallelRemediation) {
        @(New-ClusterRemediationBatch -CandidateHosts $candidateHosts -MaxParallelHostsPerCluster $MaxParallelHostsPerCluster -MinimumClusterAvailableResourcePercent $MinimumClusterAvailableResourcePercent -AllClusterHosts $refreshedVmmHosts)
    } else {
        @($candidateHosts | ForEach-Object { , @($_) })
    }

    # Hôtes candidats à une nouvelle tentative (-RemediationRetryCount) : seuls
    # les échecs de remédiation proprement dits sont rejouables — pas les
    # échecs de scan ni de pré-contrôle.
    $retryCandidates = [ordered]@{}

    $batchIndex = 0
    $batchCount = @($remediationBatches | Where-Object { @($_).Count -gt 0 }).Count
    foreach ($batch in $remediationBatches) {
        $batchHosts = @($batch)
        if ($batchHosts.Count -eq 0) { continue }
        $batchIndex++
        $batchNames = @($batchHosts | ForEach-Object { Get-ObjectName -InputObject $_ })
        Write-PatchLog "Lot $batchIndex/$batchCount : $($batchNames -join ', ')."

        # Contrôle de capacité sur données LIVE juste avant le lancement : la
        # planification statique date du début de la phase — un lot précédent a
        # pu laisser un hôte en maintenance, ou la charge des VM a évolué. La
        # mesure utilise AvailableMemory/TotalMemory des nœuds actifs restants.
        if (-not $WhatIfPreference) {
            try {
                $liveHosts = @(Get-SCVMHost -VMMServer $vmmConnection -ErrorAction Stop)
                $batchClusterNames = @($batchHosts | ForEach-Object { Get-VMHostClusterName -VMHost $_ } | Where-Object { $_ -ne '__Standalone__' } | Select-Object -Unique)
                foreach ($batchClusterName in $batchClusterNames) {
                    $clusterMembers = @($liveHosts | Where-Object { (Get-VMHostClusterName -VMHost $_) -eq $batchClusterName })
                    $livePercent = Get-ClusterLiveCapacityPercent -ClusterHosts $clusterMembers -ExcludedHostNames $batchNames
                    if ($null -eq $livePercent) {
                        Write-Verbose "[$batchClusterName] Mémoire cluster illisible via VMM — contrôle live ignoré pour ce lot."
                    } elseif ($livePercent -lt $MinimumClusterAvailableResourcePercent) {
                        Write-PatchLog "[$batchClusterName] Mémoire réellement disponible avant le lot : $livePercent% < seuil $MinimumClusterAvailableResourcePercent% — les Live Migrations risquent d'échouer ou de dégrader les VM." -Level WARN
                    } else {
                        Write-PatchLog "[$batchClusterName] Mémoire disponible avant le lot : $livePercent%."
                    }
                }
            } catch {
                Write-Verbose "Contrôle de capacité live impossible : $($_.Exception.Message)"
            }
        }

        $remediationJobs = @()
        foreach ($hostItem in $batchHosts) {
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
                    $retryCandidates[$hostName] = $hostItem
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
                $failedEntry = $remediationJobs | Where-Object { $_.Name -eq $remediationResult.Name } | Select-Object -First 1
                if ($null -ne $failedEntry) { $retryCandidates[$remediationResult.Name] = $failedEntry.VMHost }
            }
        }
    }

    # ── Nouvelles tentatives (-RemediationRetryCount) ─────────────────────────
    # Un par un (jamais en parallèle : un cluster qui vient d'échouer ne doit
    # pas être re-sollicité en rafale), avec pré-contrôle Live Migration
    # rejoué sur données rafraîchies. Les hôtes ont déjà été confirmés
    # (ShouldProcess) lors de la première tentative.
    if ($RemediationRetryCount -gt 0 -and $retryCandidates.Count -gt 0) {
        for ($retryAttempt = 1; ($retryAttempt -le $RemediationRetryCount) -and ($retryCandidates.Count -gt 0); $retryAttempt++) {
            Write-PatchLog "Nouvelle tentative de remédiation $retryAttempt/$RemediationRetryCount pour $($retryCandidates.Count) hôte(s) : $(@($retryCandidates.Keys) -join ', ')."
            $currentRound = $retryCandidates
            $retryCandidates = [ordered]@{}

            $retryRefreshedByAlias = @{}
            try {
                foreach ($refreshedHost in @(Get-SCVMHost -VMMServer $vmmConnection -ErrorAction Stop)) {
                    foreach ($alias in (Get-VMHostAliasSet -VMHost $refreshedHost)) {
                        if (-not $retryRefreshedByAlias.ContainsKey($alias)) { $retryRefreshedByAlias[$alias] = $refreshedHost }
                    }
                }
            } catch {
                Write-Verbose "Rafraîchissement des hôtes impossible pour la tentative $retryAttempt : $($_.Exception.Message)"
            }

            foreach ($retryEntry in $currentRound.GetEnumerator()) {
                $hostName = [string]$retryEntry.Key
                $hostItem = if ($retryRefreshedByAlias.ContainsKey($hostName)) { $retryRefreshedByAlias[$hostName] } else { $retryEntry.Value }

                $readiness = Test-VMHostLiveMigrationReadiness -VMHost $hostItem -DismountIso:($DismountIso -and -not $WhatIfPreference)
                foreach ($fixedItem in $readiness.Fixed)      { Write-PatchLog "[$hostName] $fixedItem" }
                foreach ($warningItem in $readiness.Warnings) { Write-PatchLog "[$hostName] $warningItem" -Level WARN }
                if (-not $readiness.Ready) {
                    Write-PatchLog "[$hostName] Nouvelle tentative abandonnée — pré-contrôle bloquant : $($readiness.Issues -join '; ')." -Level WARN
                    continue
                }

                Write-PatchLog "Remédiation (tentative $($retryAttempt + 1)) : $hostName."
                try {
                    $job = Start-SCUpdateRemediation `
                        -VMHost $hostItem `
                        -Baseline $baseline `
                        -RunAsynchronously `
                        -ErrorAction Stop
                    Wait-SCJobCompletion -Job $job -TimeoutMinutes $RemediationTimeoutMinutes -Activity "Remédiation $hostName (tentative $($retryAttempt + 1))" -IntervalSeconds $PollIntervalSeconds | Out-Null
                    $script:FailedHosts.Remove($hostName)
                    $remediatedHostItems += $hostItem
                    Write-PatchLog "Remédiation réussie pour $hostName à la tentative $($retryAttempt + 1)."
                } catch {
                    Write-PatchLog "[$hostName] Tentative $($retryAttempt + 1) en échec : $($_.Exception.Message)" -Level WARN
                    if ($retryAttempt -lt $RemediationRetryCount) { $retryCandidates[$hostName] = $hostItem }
                }
            }
        }
    }

    # Filet de sécurité : un hôte resté en mode maintenance après le cycle (job
    # en échec ou timeout) ampute silencieusement la capacité du cluster —
    # signalé explicitement pour action manuelle.
    if (-not $WhatIfPreference) {
        try {
            $targetedNameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($hostItem in $hosts) { [void]$targetedNameSet.Add((Get-ObjectName -InputObject $hostItem)) }

            foreach ($postCycleHost in @(Get-SCVMHost -VMMServer $vmmConnection -ErrorAction Stop)) {
                $isTargeted = $false
                foreach ($alias in (Get-VMHostAliasSet -VMHost $postCycleHost)) {
                    if ($targetedNameSet.Contains($alias)) { $isTargeted = $true; break }
                }
                if ($isTargeted -and (Test-VMHostInMaintenance -VMHost $postCycleHost)) {
                    Write-PatchLog "[$(Get-ObjectName -InputObject $postCycleHost)] Hôte encore en mode MAINTENANCE après le cycle — sortez-le manuellement (console VMM ou Stop-SCVMHostMaintenanceMode) pour restaurer la capacité du cluster." -Level WARN
                }
            }
        } catch {
            Write-Verbose "Contrôle post-cycle du mode maintenance impossible : $($_.Exception.Message)"
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
$durationMinutes = [math]::Round(((Get-Date) - $script:CycleStart).TotalMinutes, 1)
Write-PatchLog "Cycle patching Hyper-V/SCVMM terminé en $durationMinutes min : $($hosts.Count) hôte(s) ciblé(s), $($remediatedHostItems.Count) remédié(s), $failureCount en échec, $($script:WarningCount) avertissement(s)."

if ($failureCount -gt 0) {
    foreach ($failure in $script:FailedHosts.GetEnumerator()) {
        Write-PatchLog "  Échec $($failure.Key) : $($failure.Value)" -Level ERROR
    }
}

if ($CentreonOutput) {
    $centreonState = Get-CentreonState -FailureCount $failureCount -WarningCount $script:WarningCount
    Write-Output (Format-CentreonSummary -State $centreonState -TargetedCount $hosts.Count -RemediatedCount $remediatedHostItems.Count -FailureCount $failureCount -WarningCount $script:WarningCount -DurationMinutes $durationMinutes)
    exit (Get-CentreonExitCode -State $centreonState)
}

exit $(if ($failureCount -gt 0) { 1 } else { 0 })

} catch {
    $fatalMessage = $_.Exception.Message
    Write-PatchLog "Erreur fatale : $fatalMessage" -Level ERROR
    if ($CentreonOutput) {
        Write-Output "CRITICAL - Hyper-V/SCVMM patching: erreur fatale: $fatalMessage"
        exit (Get-CentreonExitCode -State 'CRITICAL')
    }
    exit 1
}
