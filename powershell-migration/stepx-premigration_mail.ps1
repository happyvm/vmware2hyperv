<#
.SYNOPSIS
    Send a pre-migration email notification to the configured recipient group.

.DESCRIPTION
    Queries vCenter for all VMs tagged with the given tag and sends an HTML email
    with the VM list to the specified recipient group. The email includes VM names
    and a notification that the migration will begin shortly.

    Recipient groups (e.g. 'internal', 'provider') are defined in config.psd1
    under the Recipients hashtable.

.PARAMETER tagName
    Batch tag identifying the migration lot (e.g. HypMig-lot-118).

.PARAMETER recipientGroup
    Recipient group key from config.psd1 Recipients (e.g. 'internal', 'provider').

.PARAMETER SkipVCenterLogin
    Bypass vCenter connection if already connected from a parent session.

.PARAMETER vCenterServer
    vCenter server name or IP. Defaults to Config.VCenter.Server.

.PARAMETER smtpServer
    SMTP server for sending the email. Defaults to Config.Smtp.Server.

.PARAMETER smtpPort
    SMTP port. Defaults to Config.Smtp.Port.

.PARAMETER mailFrom
    Sender email address. Defaults to Config.Smtp.From.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\stepx-premigration_mail.ps1 -tagName HypMig-lot-118 -recipientGroup internal

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI module.
    SMTP configuration must be present in config.psd1.
#>

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

if (-not $recipients.ContainsKey($recipientGroup)) {
    $message = "Invalid recipient group: '$recipientGroup'. Values: $($recipients.Keys -join ', ')."
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    throw $message
}

$mailTo      = $recipients[$recipientGroup]
$mailSubject = "VM Migration of $tagName tag"

# Import PowerCLI before touching Set-PowerCLIConfiguration: relying on module
# auto-loading fails when only VCF.PowerCLI is installed.
if (-not (Get-Module -Name VMware.PowerCLI, VCF.PowerCLI)) {
    Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile
}
# Session scope: the User scope rewrote the PowerCLI user profile on every run.
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false | Out-Null

if (-not $SkipVCenterLogin) {
    Connect-VCenter -Server $vCenterServer -LogFile $LogFile
} else {
    Write-MigrationLog "Bypassing vCenter connection (-SkipVCenterLogin enabled)." -Level WARNING -LogFile $LogFile
}

Write-MigrationLog "Searching VMs with tag '$tagName'..." -LogFile $LogFile
try {
    $tag = Get-Tag -Name $tagName -Category $Config.Tags.Category -ErrorAction Stop
} catch {
    $message = "Unable to retrieve tag '$tagName' : $_"
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    throw $message
}

if ($null -eq $tag) {
    $message = "Tag '$tagName' does not exist."
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    throw $message
}

$taggedVmIds = @(
    Get-TagAssignment -Tag $tag -ErrorAction SilentlyContinue |
        Where-Object { $_.Entity -and $_.Entity.GetType().Name -eq 'VirtualMachine' } |
        ForEach-Object { $_.Entity.Id }
)
$vms = if ($taggedVmIds) { @(VMware.VimAutomation.Core\Get-VM -Id $taggedVmIds) } else { @() }
Write-MigrationLog "VMs found with tag '$tagName' : $($vms.Count)" -LogFile $LogFile

if ($vms.Count -eq 0) {
    Write-MigrationLog "No VM with tag '$tagName'." -Level WARNING -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    return
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
    $status = if ($vm.PowerState -eq "PoweredOn") { "Up&amp;Running" } else { "Shutdown" }
    $htmlBody += "<tr><td>$(ConvertTo-HtmlEncoded $vm.Name)</td><td>$status</td></tr>"
}

$htmlBody += "</table></body></html>"

Send-HtmlMail -From $mailFrom -To $mailTo -Subject $mailSubject -HtmlBody $htmlBody -SmtpServer $smtpServer -Port $smtpPort -LogFile $LogFile

if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
Write-MigrationLog "stepx completed successfully." -Level SUCCESS -LogFile $LogFile
