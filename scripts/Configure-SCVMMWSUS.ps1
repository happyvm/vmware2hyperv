#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules VirtualMachineManager

<#
.SYNOPSIS
Configure les produits, classifications et langues d'un serveur WSUS intégré à SCVMM.

.DESCRIPTION
La modification est effectuée via les cmdlets SCVMM, pas directement via la console/API WSUS.
Par défaut, la sélection existante est remplacée par une sélection minimale destinée à :
- Windows Server 2022 / Hyper-V : Microsoft Server operating system-21H2
- Windows Server 2025 / Hyper-V : Microsoft Server operating system-24H2
- SCVMM 2022 et/ou 2025, selon -SCVMMVersion
- Microsoft Defender Antivirus, sauf avec -ExcludeDefender

Utiliser -AddOnly pour conserver les autres produits/classifications/langues déjà configurés.
Utiliser d'abord -WhatIf pour vérifier la cible et la sélection.

.PARAMETER VMMServer
    Nom FQDN ou NetBIOS du serveur SCVMM qui référence le serveur WSUS.

.PARAMETER WSUSServer
    Nom du serveur WSUS à configurer lorsqu'un seul serveur ne peut pas être déduit automatiquement.

.PARAMETER SCVMMVersion
    Version de SCVMM dont les produits doivent être inclus : None, 2022, 2025 ou Both.

.PARAMETER Languages
    Codes de langue WSUS à conserver pour la synchronisation.

.PARAMETER ExcludeDefender
    N'ajoute pas Microsoft Defender Antivirus ni la classification Definition Updates.

.PARAMETER AddOnly
    Ajoute la sélection recommandée aux paramètres existants au lieu de les remplacer exactement.

.PARAMETER NoSynchronization
    Applique la configuration sans lancer de synchronisation WSUS depuis SCVMM.

.PARAMETER ForceFullCatalogImport
    Lance la synchronisation avec import complet du catalogue après application de la configuration.

.EXAMPLE
    .\Configure-SCVMMWSUS.ps1 `
        -VMMServer 'scvmm01.contoso.local' `
        -WSUSServer 'wsus01.contoso.local' `
        -SCVMMVersion Both `
        -WhatIf

.EXAMPLE
    .\Configure-SCVMMWSUS.ps1 `
        -VMMServer 'scvmm01.contoso.local' `
        -SCVMMVersion 2025 `
        -AddOnly `
        -ForceFullCatalogImport
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMMServer,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$WSUSServer,

    [Parameter(Mandatory = $true)]
    [ValidateSet('None', '2022', '2025', 'Both')]
    [string]$SCVMMVersion,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Languages = @('en', 'fr'),

    [Parameter()]
    [switch]$ExcludeDefender,

    [Parameter()]
    [switch]$AddOnly,

    [Parameter()]
    [switch]$NoSynchronization,

    [Parameter()]
    [switch]$ForceFullCatalogImport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-UniqueStringList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )

    $values = foreach ($item in $InputObject) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [string]) {
            $text = $item.Trim()
        }
        elseif ($null -ne $item.PSObject.Properties['Name']) {
            $text = ([string]$item.Name).Trim()
        }
        elseif ($null -ne $item.PSObject.Properties['Title']) {
            $text = ([string]$item.Title).Trim()
        }
        else {
            $text = ([string]$item).Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $text
        }
    }

    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($values | Sort-Object -Unique)) {
        [void]$list.Add([string]$value)
    }

    return $list
}

function Get-SCSettingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$CandidatePropertyNames
    )

    foreach ($propertyName in $CandidatePropertyNames) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if ($null -ne $property) {
            return [pscustomobject]@{
                Found        = $true
                PropertyName = $propertyName
                Values       = @(ConvertTo-UniqueStringList -InputObject @($property.Value))
            }
        }
    }

    return [pscustomobject]@{
        Found        = $false
        PropertyName = $null
        Values       = @()
    }
}

Import-Module VirtualMachineManager -ErrorAction Stop

Write-Verbose "Connexion au serveur VMM '$VMMServer'."
$vmmConnection = Get-SCVMMServer -ComputerName $VMMServer -SetAsDefault -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($WSUSServer)) {
    $updateServers = @(Get-SCUpdateServer -VMMServer $vmmConnection -ErrorAction Stop)
}
else {
    $updateServers = @(
        Get-SCUpdateServer `
            -VMMServer $vmmConnection `
            -ComputerName $WSUSServer `
            -ErrorAction Stop
    )
}

if ($updateServers.Count -eq 0) {
    throw "Aucun serveur WSUS intégré à SCVMM n'a été trouvé."
}

if ($updateServers.Count -gt 1) {
    $names = ($updateServers | ForEach-Object { $_.ComputerName }) -join ', '
    throw "Plusieurs serveurs WSUS sont intégrés à SCVMM ($names). Relancez avec -WSUSServer <FQDN>."
}

$updateServer = $updateServers[0]

$wantedProducts = @(
    'Microsoft Server operating system-21H2'
    'Microsoft Server operating system-24H2'
)

switch ($SCVMMVersion) {
    '2022' {
        $wantedProducts += 'System Center 2022 - Virtual Machine Manager'
    }
    '2025' {
        $wantedProducts += 'System Center 2025 - Virtual Machine Manager'
    }
    'Both' {
        $wantedProducts += @(
            'System Center 2022 - Virtual Machine Manager'
            'System Center 2025 - Virtual Machine Manager'
        )
    }
    'None' {
        # Aucun produit VMM ajouté : utile si WSUS ne sert qu'aux hôtes Hyper-V.
    }
}

$wantedClassifications = @(
    'Security Updates'
    'Critical Updates'
    'Update Rollups'
    'Updates'
)

if (-not $ExcludeDefender) {
    $wantedProducts += 'Microsoft Defender Antivirus'
    $wantedClassifications += 'Definition Updates'
}

$products = ConvertTo-UniqueStringList -InputObject $wantedProducts
$classifications = ConvertTo-UniqueStringList -InputObject $wantedClassifications
$languageList = ConvertTo-UniqueStringList -InputObject $Languages

if ($AddOnly) {
    $currentProducts = Get-SCSettingValue `
        -InputObject $updateServer `
        -CandidatePropertyNames @('UpdateCategories', 'Categories', 'Products')

    $currentClassifications = Get-SCSettingValue `
        -InputObject $updateServer `
        -CandidatePropertyNames @('UpdateClassifications', 'Classifications')

    $currentLanguages = Get-SCSettingValue `
        -InputObject $updateServer `
        -CandidatePropertyNames @('UpdateLanguages', 'Languages')

    foreach ($setting in @(
        @{ Name = 'produits';        Result = $currentProducts }
        @{ Name = 'classifications'; Result = $currentClassifications }
        @{ Name = 'langues';         Result = $currentLanguages }
    )) {
        if (-not $setting.Result.Found) {
            throw "Le mode -AddOnly ne peut pas lire les $($setting.Name) actuels dans l’objet SCVMM. Exécutez 'Get-SCUpdateServer | Format-List *' pour identifier les propriétés, ou relancez sans -AddOnly après validation avec -WhatIf."
        }
    }

    $products = ConvertTo-UniqueStringList -InputObject @($currentProducts.Values + $products)
    $classifications = ConvertTo-UniqueStringList -InputObject @($currentClassifications.Values + $classifications)
    $languageList = ConvertTo-UniqueStringList -InputObject @($currentLanguages.Values + $languageList)
}

Write-Host ''
Write-Host "Serveur VMM  : $VMMServer"
Write-Host "Serveur WSUS : $($updateServer.ComputerName)"
$configurationMode = if ($AddOnly) { 'Ajout/conservation' } else { 'Remplacement exact' }
Write-Host "Mode         : $configurationMode"
Write-Host ''
Write-Host 'Produits sélectionnés :'
$products | ForEach-Object { Write-Host "  - $_" }
Write-Host 'Classifications sélectionnées :'
$classifications | ForEach-Object { Write-Host "  - $_" }
Write-Host 'Langues sélectionnées :'
$languageList | ForEach-Object { Write-Host "  - $_" }
Write-Host ''

$target = "WSUS '$($updateServer.ComputerName)' intégré à VMM '$VMMServer'"
$action = 'Configurer produits, classifications et langues de synchronisation'

if ($PSCmdlet.ShouldProcess($target, $action)) {
    Set-SCUpdateServer `
        -UpdateServer $updateServer `
        -VMMServer $vmmConnection `
        -UpdateCategories $products `
        -UpdateClassifications $classifications `
        -UpdateLanguages $languageList `
        -ErrorAction Stop | Out-Null

    Write-Host 'Configuration SCVMM/WSUS appliquée.'

    if (-not $NoSynchronization) {
        $syncParameters = @{
            UpdateServer = $updateServer
            VMMServer    = $vmmConnection
            ErrorAction  = 'Stop'
        }

        if ($ForceFullCatalogImport) {
            $syncParameters.ForceFullUpdateCatalogImport = $true
        }

        Start-SCUpdateServerSynchronization @syncParameters | Out-Null
        $catalogImportMode = if ($ForceFullCatalogImport) { ' avec import complet du catalogue' } else { '' }
        Write-Host "Synchronisation lancée$catalogImportMode."
    }
    else {
        Write-Host 'Synchronisation non lancée (-NoSynchronization).'
    }
}
