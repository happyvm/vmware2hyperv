<#
.SYNOPSIS
    Interactive setup wizard for config.local.psd1.

.DESCRIPTION
    Prompts for the environment-specific values every migration script needs
    (vCenter, SCVMM, SMTP, paths, recipient lists...) and saves them to
    config.local.psd1, next to config.psd1. Every script loads config.local.psd1
    automatically (via Import-MigrationConfig in lib.ps1) and merges it on top of
    the versioned config.psd1 template, so operator values are never overwritten
    by a git pull and never need to be re-typed into config.psd1 by hand.

    By default only values missing from config.local.psd1 are asked — safe to
    re-run after pulling script updates that introduced new config keys (see
    $script:MigrationConfigSchema in lib.ps1). Pass -Full to revisit every value,
    for example to point at a different vCenter.

    This is not part of the numbered step pipeline: run it whenever
    config.local.psd1 is missing or incomplete, either standalone or triggered
    automatically by run-migration.ps1 when invoked with no arguments.

.PARAMETER ConfigFile
    Path to the config.psd1 template used for default values. Defaults to the
    file in this script's folder.

.PARAMETER Full
    Re-ask every question, including values already set in config.local.psd1.

.EXAMPLE
    .\configure-migration.ps1

.EXAMPLE
    .\configure-migration.ps1 -Full

.NOTES
    Part of the vmware2hyperv migration toolkit.
#>

param (
    [string]$ConfigFile,
    [switch]$Full
)

Set-StrictMode -Version Latest

. "$PSScriptRoot\lib.ps1"

if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration template"

Invoke-MigrationConfigWizard -ConfigFile $ConfigFile -Full:$Full
