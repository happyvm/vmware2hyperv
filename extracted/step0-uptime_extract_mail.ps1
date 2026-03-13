#requires -Version 7.0

param (
    [string]$VCenterServer,
    [string]$SMTPServer,
    [string]$MailFrom,
    [string]$MailTo,
    [string]$Tag,      # Optionnel - pour contextualiser le log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $SMTPServer)    { $SMTPServer    = $Config.Smtp.Server }
if (-not $MailFrom)      { $MailFrom      = $Config.Smtp.From }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step0-uptime-mail$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }
# MailTo est obligatoire si absent de la config — doit être fourni en paramètre
if (-not $MailTo) {
    Write-Log "Paramètre -MailTo obligatoire (non présent dans config.psd1)" -Level ERROR -LogFile $LogFile
    exit 1
}

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile

Write-Log "Démarrage step0 - uptime mail" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$Subject = "Uptime des VMs - $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
$VMs     = Get-VMWareVM | Where-Object { $_.PowerState -eq "PoweredOn" }
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

Write-Log "Génération du tableau HTML" -LogFile $LogFile

$HTMLTable  = "<html><body>"
$HTMLTable += "<h2>Uptime des VMs</h2>"
$HTMLTable += "<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse;'>"
$HTMLTable += "<tr><th>VM Name</th><th>OS</th><th>Boot Time</th><th>Uptime</th></tr>"

foreach ($VM in $Results) {
    $HTMLTable += "<tr><td>$($VM.VMName)</td><td>$($VM.OS)</td><td>$($VM.BootTime)</td><td>$($VM.Uptime)</td></tr>"
}

$HTMLTable += "</table></body></html>"

Send-HtmlMail -From $MailFrom -To $MailTo -Subject $Subject -HtmlBody $HTMLTable -SmtpServer $SMTPServer -Port $Config.Smtp.Port -LogFile $LogFile
Disconnect-VCenter -LogFile $LogFile
