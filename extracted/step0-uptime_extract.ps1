#requires -Version 7.0

param (
    [string]$VCenterServer,
    [string]$OutputCsvPath,
    [string]$Tag,      # Optionnel - pour contextualiser le log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $OutputCsvPath) { $OutputCsvPath = $Config.Paths.OutputCsv }
if (-not $LogFile)       { $LogFile = "$($Config.Paths.LogDir)\step0-uptime$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile
Set-Alias -Name Get-VMWareVM -Value VMware.VimAutomation.Core\Get-VM

Write-Log "Démarrage step0 - extraction uptime" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$VMs = Get-VMWareVM | Where-Object { $_.PowerState -eq "PoweredOn" }
Write-Log "VMs allumées : $($VMs.Count)" -LogFile $LogFile

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
        $Uptime = "{0} jours, {1} heures, {2} minutes" -f $UptimeSpan.Days, $UptimeSpan.Hours, $UptimeSpan.Minutes
    } else {
        $Uptime = "Indisponible"
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

Write-Log "Résultats exportés vers : $OutputCsvPath" -Level SUCCESS -LogFile $LogFile
Disconnect-VCenter -LogFile $LogFile
