#requires -Version 7.0
<#!
.SYNOPSIS
    Prépare une migration VMware -> Hyper-V en exploitant des fonctionnalités PowerShell 7.

.DESCRIPTION
    Ce script parcourt des répertoires de VMs VMware, détecte les fichiers d'intérêt
    (.vmx, .vmdk, .vhd, .vhdx) et produit un plan d'action JSON.

    Points PowerShell 7 utilisés :
    - Pipeline chain operators (&& / ||)
    - Null-coalescing (??)
    - Ternary operator (? :)
    - ForEach-Object -Parallel
    - Classement/formatage UTF-8 par défaut

.PARAMETER SourcePath
    Dossier racine contenant les exports VMware.

.PARAMETER DestinationPath
    Dossier de sortie pour les métadonnées Hyper-V.

.PARAMETER ThrottleLimit
    Nombre max de tâches parallèles.

.PARAMETER WhatIf
    Simule les opérations sans écrire de fichiers.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Container })]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$DestinationPath,

    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VmArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [int]$Throttle = 4
    )

    $files = Get-ChildItem -Path $Root -Recurse -File -ErrorAction Stop |
        Where-Object Extension -in '.vmx', '.vmdk', '.vhd', '.vhdx'

    $files | ForEach-Object -Parallel {
        $item = $_
        [pscustomobject]@{
            Name           = $item.BaseName
            Extension      = $item.Extension
            FullName       = $item.FullName
            SizeGB         = [math]::Round($item.Length / 1GB, 3)
            SuggestedDisk  = $item.Extension -in '.vhd', '.vhdx' ? 'reuse' : 'convert'
            LastWriteUtc   = $item.LastWriteTimeUtc
        }
    } -ThrottleLimit $Throttle
}

$resolvedDestination = (Resolve-Path -Path $DestinationPath -ErrorAction SilentlyContinue)?.Path ?? $DestinationPath
Test-Path -Path $resolvedDestination -PathType Container || ($null = New-Item -Path $resolvedDestination -ItemType Directory -Force)

$plan = Get-VmArtifact -Root $SourcePath -Throttle $ThrottleLimit |
    Sort-Object Name, Extension

$metadata = [pscustomobject]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    sourcePath     = (Resolve-Path $SourcePath).Path
    destination    = $resolvedDestination
    vmCount        = ($plan | Select-Object -ExpandProperty Name -Unique).Count
    artifacts      = $plan
}

$outputFile = Join-Path -Path $resolvedDestination -ChildPath 'migration-plan.json'

if ($PSCmdlet.ShouldProcess($outputFile, 'Écriture du plan de migration')) {
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -Path $outputFile -Encoding utf8
}

$summary = [pscustomobject]@{
    outputFile = $outputFile
    totalItems = $plan.Count
    vmCount    = $metadata.vmCount
}

$summary | Format-List
