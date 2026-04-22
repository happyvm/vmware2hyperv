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
