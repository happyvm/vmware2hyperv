#requires -Version 7.0

param (
    [string]$VCenterServer,
    [string]$SMTPServer,
    [string]$MailFrom,
    [string]$MailTo,
    [string]$Tag,      # Optional - to add context to the log
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $VCenterServer) { $VCenterServer = $Config.VCenter.Server }
if (-not $SMTPServer)    { $SMTPServer    = $Config.Smtp.Server }
if (-not $MailFrom)      { $MailFrom      = $Config.Smtp.From }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step0-uptime-mail$(if ($Tag) { "-$Tag" })-$(Get-Date -Format 'yyyyMMdd').log" }
# MailTo is mandatory if missing from config — it must be provided as a parameter
if (-not $MailTo) {
    Write-MigrationLog "-MailTo parameter is mandatory (not present in config.psd1)" -Level ERROR -LogFile $LogFile
    exit 1
}

Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile

Write-MigrationLog "Starting step0 - uptime email" -LogFile $LogFile
Connect-VCenter -Server $VCenterServer -LogFile $LogFile

$Subject = "VM uptime - $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
try {
    $VMs = VMware.VimAutomation.Core\Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" }
    Write-MigrationLog "Powered-on VMs: $($VMs.Count)" -LogFile $LogFile
}
catch {
    Write-MigrationLog "Failed to retrieve VMs from vCenter '$VCenterServer': $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
    Disconnect-VCenter -LogFile $LogFile
    exit 1
}
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

Write-MigrationLog "Generating HTML table" -LogFile $LogFile

$HTMLTable  = "<html><body>"
$HTMLTable += "<h2>VM uptime</h2>"
$HTMLTable += "<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse;'>"
$HTMLTable += "<tr><th>VM Name</th><th>OS</th><th>Boot Time</th><th>Uptime</th></tr>"

foreach ($VM in $Results) {
    $HTMLTable += "<tr><td>$($VM.VMName)</td><td>$($VM.OS)</td><td>$($VM.BootTime)</td><td>$($VM.Uptime)</td></tr>"
}

$HTMLTable += "</table></body></html>"

Send-HtmlMail -From $MailFrom -To $MailTo -Subject $Subject -HtmlBody $HTMLTable -SmtpServer $SMTPServer -Port $Config.Smtp.Port -LogFile $LogFile
Disconnect-VCenter -LogFile $LogFile
