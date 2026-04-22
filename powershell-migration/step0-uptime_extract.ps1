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
