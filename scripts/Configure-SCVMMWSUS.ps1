#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules VirtualMachineManager

<#
.SYNOPSIS
Configure the products, classifications, and languages of a WSUS server integrated with SCVMM.

.DESCRIPTION
The change is applied through SCVMM cmdlets, not directly through the WSUS console/API.
By default, the existing selection is replaced with a minimal baseline intended for:
- Windows Server 2022 / Hyper-V: Microsoft Server operating system-21H2
- Windows Server 2025 / Hyper-V: Microsoft Server operating system-24H2
- SCVMM 2022 and/or 2025, depending on -SCVMMVersion
- Microsoft Defender Antivirus, unless -ExcludeDefender is used

Use -AddOnly to keep other already configured products/classifications/languages.
Use -WhatIf first to review the target and selection.

.PARAMETER VMMServer
    FQDN or NetBIOS name of the SCVMM server that references the WSUS server.

.PARAMETER WSUSServer
    Name of the WSUS server to configure when a single server cannot be inferred automatically.

.PARAMETER SCVMMVersion
    SCVMM version whose products must be included: None, 2022, 2025, or Both.

.PARAMETER Languages
    WSUS language codes to keep for synchronization.

.PARAMETER ExcludeDefender
    Do not add Microsoft Defender Antivirus or the Definition Updates classification.

.PARAMETER AddOnly
    Add the recommended selection to existing settings instead of replacing them exactly.

.PARAMETER NoSynchronization
    Apply the configuration without starting WSUS synchronization from SCVMM.

.PARAMETER ForceFullCatalogImport
    Start synchronization with a full catalog import after applying the configuration.

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

Write-Verbose "Connecting to VMM server '$VMMServer'."
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
    throw "No WSUS server integrated with SCVMM was found."
}

if ($updateServers.Count -gt 1) {
    $names = ($updateServers | ForEach-Object { $_.ComputerName }) -join ', '
    throw "Multiple WSUS servers are integrated with SCVMM ($names). Run again with -WSUSServer <FQDN>."
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
        # No VMM product added: useful when WSUS is only used for Hyper-V hosts.
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
        @{ Name = 'products';        Result = $currentProducts }
        @{ Name = 'classifications'; Result = $currentClassifications }
        @{ Name = 'languages';         Result = $currentLanguages }
    )) {
        if (-not $setting.Result.Found) {
            throw "-AddOnly mode cannot read the current $($setting.Name) from the SCVMM object. Run 'Get-SCUpdateServer | Format-List *' to identify the properties, or run again without -AddOnly after validation with -WhatIf."
        }
    }

    $products = ConvertTo-UniqueStringList -InputObject @($currentProducts.Values + $products)
    $classifications = ConvertTo-UniqueStringList -InputObject @($currentClassifications.Values + $classifications)
    $languageList = ConvertTo-UniqueStringList -InputObject @($currentLanguages.Values + $languageList)
}

Write-Host ''
Write-Host "VMM server  : $VMMServer"
Write-Host "WSUS server : $($updateServer.ComputerName)"
$configurationMode = if ($AddOnly) { 'Add/preserve' } else { 'Exact replacement' }
Write-Host "Mode         : $configurationMode"
Write-Host ''
Write-Host 'Selected products:'
$products | ForEach-Object { Write-Host "  - $_" }
Write-Host 'Selected classifications:'
$classifications | ForEach-Object { Write-Host "  - $_" }
Write-Host 'Selected languages:'
$languageList | ForEach-Object { Write-Host "  - $_" }
Write-Host ''

$target = "WSUS '$($updateServer.ComputerName)' integrated with VMM '$VMMServer'"
$action = 'Configure synchronization products, classifications, and languages'

if ($PSCmdlet.ShouldProcess($target, $action)) {
    Set-SCUpdateServer `
        -UpdateServer $updateServer `
        -VMMServer $vmmConnection `
        -UpdateCategories $products `
        -UpdateClassifications $classifications `
        -UpdateLanguages $languageList `
        -ErrorAction Stop | Out-Null

    Write-Host 'SCVMM/WSUS configuration applied.'

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
        $catalogImportMode = if ($ForceFullCatalogImport) { ' with full catalog import' } else { '' }
        Write-Host "Synchronization started$catalogImportMode."
    }
    else {
        Write-Host 'Synchronization not started (-NoSynchronization).'
    }
}
