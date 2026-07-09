<#
.SYNOPSIS
    Extract VMware VM uptime data and send it as an HTML email.

.DESCRIPTION
    Connects to vCenter, retrieves uptime data for all VMs (or VMs filtered
    by the optional -Tag parameter), formats the results as an HTML table, and
    sends them via SMTP to the specified recipient.

    This is the email variant of step0-uptime_extract.ps1 — useful for
    scheduled uptime reports before a migration campaign.

.PARAMETER VCenterServer
    vCenter server name or IP. Defaults to Config.VCenter.Server.

.PARAMETER SMTPServer
    SMTP server for sending the email. Defaults to Config.Smtp.Server.

.PARAMETER MailFrom
    Sender email address. Defaults to Config.Smtp.From.

.PARAMETER MailTo
    Recipient email address(es). **Mandatory** — not read from config.psd1.

.PARAMETER Tag
    Optional batch tag to filter VMs by VMware tag.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step0-uptime_extract_mail.ps1 -MailTo admin@domain.local

.EXAMPLE
    .\step0-uptime_extract_mail.ps1 -MailTo admin@domain.local -Tag HypMig-lot-118

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI module.
    SMTP configuration must be present in config.psd1.
#>

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
    $Results = Get-VMUptime -LogFile $LogFile
}
catch {
    Write-MigrationLog "Failed to retrieve VMs from vCenter '$VCenterServer': $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
    Disconnect-VCenter -LogFile $LogFile
    exit 1
}

Write-MigrationLog "Generating HTML table" -LogFile $LogFile

$HTMLTable  = "<html><body>"
$HTMLTable += "<h2>VM uptime</h2>"
$HTMLTable += "<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse;'>"
$HTMLTable += "<tr><th>VM Name</th><th>OS</th><th>Boot Time</th><th>Uptime</th></tr>"

foreach ($VM in $Results) {
    $HTMLTable += "<tr><td>$(ConvertTo-HtmlEncoded $VM.VMName)</td><td>$(ConvertTo-HtmlEncoded $VM.OS)</td><td>$($VM.BootTime)</td><td>$($VM.Uptime)</td></tr>"
}

$HTMLTable += "</table></body></html>"

Send-HtmlMail -From $MailFrom -To $MailTo -Subject $Subject -HtmlBody $HTMLTable -SmtpServer $SMTPServer -Port $Config.Smtp.Port -LogFile $LogFile
Disconnect-VCenter -LogFile $LogFile
