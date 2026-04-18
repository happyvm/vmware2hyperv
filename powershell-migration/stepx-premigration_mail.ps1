#requires -Version 7.0

param (
    [Parameter(Mandatory = $true)]
    [string]$tagName,             # Batch tag (e.g. HypMig-lot-118)

    [Parameter(Mandatory = $true)]
    [string]$recipientGroup,      # Recipient group (internal, provider)

    [switch]$SkipVCenterLogin,    # Bypasses vCenter connection if already connected

    [string]$vCenterServer,
    [string]$smtpServer,
    [int]$smtpPort    = 0,
    [string]$mailFrom,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $vCenterServer) { $vCenterServer = $Config.VCenter.Server }
if (-not $smtpServer)    { $smtpServer    = $Config.Smtp.Server }
if ($smtpPort -eq 0)     { $smtpPort      = $Config.Smtp.Port }
if (-not $mailFrom)      { $mailFrom      = $Config.Smtp.From }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\stepx-premigration-mail-$tagName-$(Get-Date -Format 'yyyyMMdd').log" }

# Recipients are defined in config.psd1
$recipients = $Config.Recipients

Write-MigrationLog "Starting stepx - pre-migration email for tag '$tagName'" -LogFile $LogFile
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null

if (-not $recipients.ContainsKey($recipientGroup)) {
    Write-MigrationLog "Invalid recipient group: '$recipientGroup'. Values: $($recipients.Keys -join ', ')." -Level ERROR -LogFile $LogFile
    exit 1
}

$mailTo      = $recipients[$recipientGroup]
$mailSubject = "VM Migration of $tagName tag"

if (-not (Get-Module -Name VMware.PowerCLI)) {
    Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile
}

if (-not $SkipVCenterLogin) {
    Connect-VCenter -Server $vCenterServer -LogFile $LogFile
} else {
    Write-MigrationLog "Bypassing vCenter connection (-SkipVCenterLogin enabled)." -Level WARNING -LogFile $LogFile
}

Write-MigrationLog "Searching VMs with tag '$tagName'..." -LogFile $LogFile
try {
    $tag = Get-Tag -Name $tagName -ErrorAction Stop
} catch {
    Write-MigrationLog "Unable to retrieve tag '$tagName' : $_" -Level ERROR -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    exit 1
}

if ($null -eq $tag) {
    Write-MigrationLog "Tag '$tagName' does not exist." -Level ERROR -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    exit 1
}

$vms = VMware.VimAutomation.Core\Get-VM | Where-Object { Get-TagAssignment -Entity $_ | Where-Object { $_.Tag -eq $tag } }
Write-MigrationLog "VMs found with tag '$tagName' : $($vms.Count)" -LogFile $LogFile

if ($vms.Count -eq 0) {
    Write-MigrationLog "No VM with tag '$tagName'." -Level WARNING -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    exit 0
}

# Generating HTML table
$htmlBody = @"
<html>
<head>
<style>
    body { font-family: Arial, sans-serif; }
    table { width: 100%; border-collapse: collapse; }
    th, td { border: 1px solid black; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; }
</style>
</head>
<body>
<h3>Server list and status — tag '$tagName' (migration in progress)</h3>
<table>
    <tr><th>Name</th><th>State</th></tr>
"@

foreach ($vm in $vms) {
    $status = if ($vm.PowerState -eq "PoweredOn") { "Up&Running" } else { "Shutdown" }
    $htmlBody += "<tr><td>$($vm.Name)</td><td>$status</td></tr>"
}

$htmlBody += "</table></body></html>"

Send-HtmlMail -From $mailFrom -To $mailTo -Subject $mailSubject -HtmlBody $htmlBody -SmtpServer $smtpServer -Port $smtpPort -LogFile $LogFile

if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
Write-MigrationLog "stepx completed successfully." -Level SUCCESS -LogFile $LogFile
exit 0
