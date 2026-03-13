#requires -Version 7.0

# lib.ps1 — Fonctions communes aux scripts de migration VMware → Hyper-V
# Chargement : . "$PSScriptRoot\lib.ps1"

# ---------------------------------------------------------------------------
# Write-Log : logging horodaté vers console + fichier
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [string]$LogFile
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "Cyan" }
    }
    Write-Host $entry -ForegroundColor $color

    if ($LogFile) {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $entry
    }
}

# ---------------------------------------------------------------------------
# Assert-FileExists : arrête le script si un fichier est manquant
# ---------------------------------------------------------------------------
function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Label = "Fichier",

        [string]$LogFile
    )

    if (-not (Test-Path $Path)) {
        $message = "$Label introuvable : $Path"
        Write-Log $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Connect-VCenter : connexion vCenter avec mode Multiple
# ---------------------------------------------------------------------------
function Connect-VCenter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [string]$LogFile
    )

    Import-RequiredModule -Name "VMware.PowerCLI" -LogFile $LogFile

    if ((Get-PowerCLIConfiguration).DefaultVIServerMode -ne "Multiple") {
        Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Confirm:$false | Out-Null
    }

    try {
        Connect-VIServer -Server $Server | Out-Null
        Write-Log "Connecté à vCenter : $Server" -Level SUCCESS -LogFile $LogFile
    } catch {
        $message = "Échec de la connexion à vCenter $Server : $_"
        Write-Log $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Disconnect-VCenter : déconnexion silencieuse de vCenter
# ---------------------------------------------------------------------------
function Disconnect-VCenter {
    param([string]$LogFile)

    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Déconnecté de vCenter." -Level INFO -LogFile $LogFile
}

# ---------------------------------------------------------------------------
# Import-RequiredModule : import de module compatible PowerShell 7
# ---------------------------------------------------------------------------
function Import-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$LogFile,

        [switch]$UseWindowsPowerShellFallback
    )

    try {
        Import-Module -Name $Name -ErrorAction Stop
        Write-Log "Module importé : $Name" -LogFile $LogFile
        return
    } catch {
        if ($PSVersionTable.PSEdition -eq "Core" -and $UseWindowsPowerShellFallback) {
            try {
                Import-Module -Name $Name -UseWindowsPowerShell -SkipEditionCheck -ErrorAction Stop
                Write-Log "Module importé via compatibilité Windows PowerShell : $Name" -Level WARNING -LogFile $LogFile
                return
            } catch {
                $message = "Impossible d'importer le module $Name (import standard et mode compatibilité échoués) : $_"
                Write-Log $message -Level ERROR -LogFile $LogFile
                throw $message
            }
        }

        $message = "Impossible d'importer le module $Name : $_"
        Write-Log $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Send-HtmlMail : envoi d'un email au format HTML
# ---------------------------------------------------------------------------
function Send-HtmlMail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$From,

        [Parameter(Mandatory = $true)]
        [string[]]$To,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$HtmlBody,

        [Parameter(Mandatory = $true)]
        [string]$SmtpServer,

        [int]$Port = 25,

        [string]$LogFile
    )

    try {
        $mailMessage = [System.Net.Mail.MailMessage]::new()
        $mailMessage.From = [System.Net.Mail.MailAddress]::new($From)
        foreach ($recipient in $To) {
            [void]$mailMessage.To.Add($recipient)
        }
        $mailMessage.Subject = $Subject
        $mailMessage.Body = $HtmlBody
        $mailMessage.IsBodyHtml = $true

        $smtpClient = [System.Net.Mail.SmtpClient]::new($SmtpServer, $Port)
        $smtpClient.Send($mailMessage)

        $mailMessage.Dispose()
        $smtpClient.Dispose()

        Write-Log "Email envoyé à : $($To -join ', ')" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-Log "Échec de l'envoi du mail : $_" -Level ERROR -LogFile $LogFile
    }
}
