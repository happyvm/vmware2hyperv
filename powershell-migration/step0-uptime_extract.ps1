#requires -Version 7.0

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

Write-Log "Starting step0 - uptime extraction" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$VMs = VMware.VimAutomation.Core\Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" }
Write-Log "Powered-on VMs: $($VMs.Count)" -LogFile $LogFile

$Results = @()

foreach ($VM in $VMs) {
    $GuestInfo = $VM.ExtensionData.Guest
    $BootTime  = $null
    $Uptime    = $null

    if ($GuestInfo.ToolsStatus -eq "toolsOk" -and $GuestInfo.BootTime) {
        $BootTime = $GuestInfo.BootTime
    } else {
        $BootTime = $VM.ExtensionData.Runtime.BootTime
    }

    if ($BootTime) {
        $UptimeSpan = (Get-Date) - $BootTime
        $Uptime = "{0} days, {1} hours, {2} minutes" -f $UptimeSpan.Days, $UptimeSpan.Hours, $UptimeSpan.Minutes
    } else {
        $Uptime = "Unavailable"
    }

    $Results += [PSCustomObject]@{
        VMName   = $VM.Name
        OS       = $GuestInfo.GuestFullName
        BootTime = $BootTime
        Uptime   = $Uptime
    }
}

$Results | Format-Table -AutoSize
$Results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

Write-Log "Results exported to: $OutputCsvPath" -Level SUCCESS -LogFile $LogFile
Disconnect-VCenter -LogFile $LogFile
