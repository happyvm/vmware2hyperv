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
- scan de conformité puis remédiation hôte par hôte.

La remédiation SCVMM met un hôte en maintenance, évacue les VM par Live Migration lorsque le cluster
le permet, applique les correctifs, redémarre si nécessaire, puis retire le mode maintenance.

.PARAMETER VMMServer
Nom FQDN ou NetBIOS du serveur SCVMM.

.PARAMETER BaselineName
Nom de la baseline SCVMM à créer ou mettre à jour.

.PARAMETER HostGroupName
Nom du groupe d'hôtes SCVMM contenant les hôtes Hyper-V à patcher.

.PARAMETER VMHostNames
Liste optionnelle des hôtes Hyper-V à traiter. Si omise, tous les hôtes du groupe sont ciblés.

.PARAMETER UpdateClassifications
Classifications SCVMM/WSUS à inclure dans la baseline.

.PARAMETER IncludeUpdateTitleRegex
Expression régulière optionnelle appliquée au titre des mises à jour candidates.

.PARAMETER ExcludeUpdateTitleRegex
Expression régulière optionnelle d'exclusion appliquée au titre des mises à jour candidates.

.PARAMETER SynchronizationTimeoutMinutes
Temps maximum d'attente de la synchronisation WSUS.

.PARAMETER ComplianceTimeoutMinutes
Temps maximum d'attente du scan de conformité par hôte.

.PARAMETER RemediationTimeoutMinutes
Temps maximum d'attente de la remédiation par hôte.

.PARAMETER SkipSynchronization
Ne lance pas la synchronisation WSUS/SCVMM.

.PARAMETER SkipRemediation
Met à jour et affecte la baseline, puis scanne la conformité sans corriger les hôtes.

.PARAMETER ParallelRemediation
Autorise la remédiation de plusieurs hôtes en parallèle. Par défaut, le script traite un hôte à la fois
pour préserver la capacité cluster pendant les Live Migrations.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Invoke-SCVMMHostPatchBaseline.ps1 `
    -VMMServer scvmm01.contoso.local `
    -BaselineName 'Hyper-V Monthly Security Baseline' `
    -HostGroupName 'All Hosts\\Production\\Hyper-V'

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
    [switch]$SkipSynchronization,

    [Parameter()]
    [switch]$SkipRemediation,

    [Parameter()]
    [switch]$ParallelRemediation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-SCJobCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Job,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2880)]
        [int]$TimeoutMinutes,

        [Parameter(Mandatory = $true)]
        [string]$Activity
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

        Start-Sleep -Seconds 30
        $currentJob = Get-SCJob -ID $currentJob.ID -ErrorAction Stop
        Write-Verbose "[$Activity] Statut SCVMM: $($currentJob.Status)."
    }

    if ($null -ne $currentJob -and [string]$currentJob.Status -notin $successStatuses) {
        throw "Echec SCVMM pendant : $Activity. Statut: $($currentJob.Status). Erreur: $($currentJob.ErrorInfo)."
    }

    if ($null -ne $currentJob -and [string]$currentJob.Status -eq 'SucceedWithInfo') {
        Write-Warning "[$Activity] Job SCVMM terminé avec informations. Détail: $($currentJob.ErrorInfo)."
    }

    return $currentJob
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

Import-Module VirtualMachineManager -ErrorAction Stop

Write-Host "Connexion à SCVMM '$VMMServer'."
$vmmConnection = Get-SCVMMServer -ComputerName $VMMServer -SetAsDefault -ErrorAction Stop

if (-not $SkipSynchronization) {
    $updateServers = @(Get-SCUpdateServer -VMMServer $vmmConnection -ErrorAction Stop)
    if ($updateServers.Count -eq 0) {
        throw "Aucun serveur WSUS intégré à SCVMM n'a été trouvé."
    }

    foreach ($updateServer in $updateServers) {
        $target = "WSUS '$($updateServer.ComputerName)' intégré à VMM '$VMMServer'"
        if ($PSCmdlet.ShouldProcess($target, 'Synchroniser le catalogue de correctifs')) {
            Write-Host "Synchronisation WSUS/SCVMM : $($updateServer.ComputerName)."
            $syncJob = Start-SCUpdateServerSynchronization `
                -UpdateServer $updateServer `
                -VMMServer $vmmConnection `
                -RunAsynchronously `
                -ErrorAction Stop
            Wait-SCJobCompletion -Job $syncJob -TimeoutMinutes $SynchronizationTimeoutMinutes -Activity "Synchronisation $($updateServer.ComputerName)" | Out-Null
        }
    }
}
else {
    Write-Host 'Synchronisation WSUS/SCVMM ignorée (-SkipSynchronization).'
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
    $wantedHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $VMHostNames) {
        [void]$wantedHosts.Add($name)
    }

    $hosts = @($hosts | Where-Object {
            $hostAliases = foreach ($propertyName in @('Name', 'ComputerName', 'FullyQualifiedDomainName')) {
                $property = $_.PSObject.Properties[$propertyName]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    [string]$property.Value
                }
            }

            @($hostAliases | Where-Object { $wantedHosts.Contains($_) }).Count -gt 0
        })
}

if ($hosts.Count -eq 0) {
    throw "Aucun hôte Hyper-V SCVMM trouvé dans '$HostGroupName' avec les filtres fournis."
}

Write-Host 'Hôtes ciblés :'
$hosts | ForEach-Object { Write-Host "  - $(Get-ObjectName -InputObject $_)" }

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

$baseline = Get-SCBaseline -VMMServer $vmmConnection -Name $BaselineName -ErrorAction SilentlyContinue
$baselineTarget = "Baseline SCVMM '$BaselineName'"

if ($null -eq $baseline) {
    if ($PSCmdlet.ShouldProcess($baselineTarget, 'Créer la baseline')) {
        $baseline = New-SCBaseline -VMMServer $vmmConnection -Name $BaselineName -Update $updates -ErrorAction Stop
    }
}
else {
    if ($PSCmdlet.ShouldProcess($baselineTarget, "Mettre à jour avec $($updates.Count) correctif(s)")) {
        Set-SCBaseline -Baseline $baseline -Update $updates -ErrorAction Stop | Out-Null
        $baseline = Get-SCBaseline -VMMServer $vmmConnection -Name $BaselineName -ErrorAction Stop
    }
}

# En mode -Confirm, l'opérateur peut refuser la création de la baseline puis
# accepter les étapes suivantes : sans cette garde, Set-SCBaseline recevrait
# -Baseline $null et échouerait avec une erreur de binding brute. En -WhatIf,
# la simulation des étapes suivantes reste affichée (leurs blocs ShouldProcess
# ne s'exécutent jamais).
if ($null -eq $baseline) {
    Write-Host "Baseline '$BaselineName' non disponible (création refusée ou simulée)."
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

foreach ($hostItem in $hosts) {
    $hostName = Get-ObjectName -InputObject $hostItem
    if ($PSCmdlet.ShouldProcess("Hôte Hyper-V '$hostName'", 'Scanner la conformité aux correctifs')) {
        Write-Host "Scan de conformité : $hostName."
        $scanJob = Start-SCComplianceScan -VMHost $hostItem -RunAsynchronously -ErrorAction Stop
        Wait-SCJobCompletion -Job $scanJob -TimeoutMinutes $ComplianceTimeoutMinutes -Activity "Scan conformité $hostName" | Out-Null
    }
}

if ($SkipRemediation) {
    Write-Host 'Remédiation ignorée (-SkipRemediation).'
    return
}

$remediationJobs = @()
foreach ($hostItem in $hosts) {
    $hostName = Get-ObjectName -InputObject $hostItem
    if ($PSCmdlet.ShouldProcess("Hôte Hyper-V '$hostName'", 'Appliquer les correctifs via maintenance SCVMM et Live Migration')) {
        Write-Host "Remédiation : $hostName."
        $job = Start-SCUpdateRemediation `
            -VMHost $hostItem `
            -Baseline $baseline `
            -RunAsynchronously `
            -ErrorAction Stop

        if ($ParallelRemediation) {
            $remediationJobs += [pscustomobject]@{ HostName = $hostName; Job = $job }
        }
        else {
            Wait-SCJobCompletion -Job $job -TimeoutMinutes $RemediationTimeoutMinutes -Activity "Remédiation $hostName" | Out-Null
        }
    }
}

foreach ($entry in $remediationJobs) {
    Wait-SCJobCompletion -Job $entry.Job -TimeoutMinutes $RemediationTimeoutMinutes -Activity "Remédiation $($entry.HostName)" | Out-Null
}

Write-Host 'Cycle patching Hyper-V/SCVMM terminé.'
