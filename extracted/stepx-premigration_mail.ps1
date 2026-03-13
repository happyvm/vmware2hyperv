#requires -Version 7.0

param (
    [Parameter(Mandatory = $true)]
    [string]$tagName,             # Tag du lot (ex: HypMig-lot-118)

    [Parameter(Mandatory = $true)]
    [string]$recipientGroup,      # Groupe de destinataires (internal, infogerant)

    [switch]$SkipVCenterLogin,    # Bypasse la connexion à vCenter si déjà connecté

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

# Les destinataires sont définis dans config.psd1
$recipients = $Config.Recipients

Write-Log "Démarrage stepx - mail pré-migration pour le tag '$tagName'" -LogFile $LogFile
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null

if (-not $recipients.ContainsKey($recipientGroup)) {
    Write-Log "Groupe de destinataires invalide : '$recipientGroup'. Valeurs : $($recipients.Keys -join ', ')." -Level ERROR -LogFile $LogFile
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
    Write-Log "Bypass de la connexion à vCenter (-SkipVCenterLogin activé)." -Level WARNING -LogFile $LogFile
}

Write-Log "Recherche des VMs avec le tag '$tagName'..." -LogFile $LogFile
try {
    $tag = Get-Tag -Name $tagName -ErrorAction Stop
} catch {
    Write-Log "Impossible de récupérer le tag '$tagName' : $_" -Level ERROR -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    exit 1
}

if ($null -eq $tag) {
    Write-Log "Le tag '$tagName' n'existe pas." -Level ERROR -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    exit 1
}

$vms = VMware.VimAutomation.Core\Get-VM | Where-Object { Get-TagAssignment -Entity $_ | Where-Object { $_.Tag -eq $tag } }
Write-Log "VMs trouvées avec le tag '$tagName' : $($vms.Count)" -LogFile $LogFile

if ($vms.Count -eq 0) {
    Write-Log "Aucune VM avec le tag '$tagName'." -Level WARNING -LogFile $LogFile
    if (-not $SkipVCenterLogin) { Disconnect-VCenter -LogFile $LogFile }
    exit 0
}

# Génération du tableau HTML
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
Write-Log "stepx terminé avec succès." -Level SUCCESS -LogFile $LogFile
exit 0
