<#
.SYNOPSIS
    Extract VMware VM uptime data and export to CSV.

.DESCRIPTION
    Connects to vCenter and retrieves uptime data for all VMs (or VMs filtered
    by the optional -Tag parameter). Outputs a table to the console and exports
    the results to a CSV file at the configured path.

    The uptime calculation uses VMware Tools guest information and supports both
    Windows and Linux guests.

.PARAMETER VCenterServer
    vCenter server name or IP. Defaults to Config.VCenter.Server.

.PARAMETER OutputCsvPath
    Path for the output CSV file. Defaults to Config.Paths.OutputCsv.

.PARAMETER Tag
    Optional batch tag to filter VMs by VMware tag.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step0-uptime_extract.ps1

.EXAMPLE
    .\step0-uptime_extract.ps1 -Tag HypMig-lot-118 -OutputCsvPath D:\Scripts\uptime_vm.csv

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI module.
#>

param (
    [string]$VCenterServer,
    [string]$OutputCsvPath,
    [string]$Tag,      # Optional - to add context to the log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $OutputCsvPath) { $OutputCsvPath = $Config.Paths.OutputCsv }
if (-not $LogFile)       { $LogFile = "$($Config.Paths.LogDir)\step0-uptime$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile

Write-MigrationLog "Starting step0 - uptime extraction" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$Results = Get-VMUptime -LogFile $LogFile

$Results | Format-Table -AutoSize
$Results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

Write-MigrationLog "Results exported to: $OutputCsvPath" -Level SUCCESS -LogFile $LogFile
Disconnect-VCenter -LogFile $LogFile
