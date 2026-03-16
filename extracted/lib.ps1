#requires -Version 7.0

# lib.ps1 — Common functions for VMware → Hyper-V migration scripts
# Load: . "$PSScriptRoot\lib.ps1"

# ---------------------------------------------------------------------------
# Write-Log : timestamped logging to console + file
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
# Assert-FileExists : stops the script if a file is missing
# ---------------------------------------------------------------------------
function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Label = "File",

        [string]$LogFile
    )

    if (-not (Test-Path $Path)) {
        $message = "$Label not found: $Path"
        Write-Log $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Connect-VCenter : vCenter connection using Multiple mode
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
        Write-Log "Connected to vCenter: $Server" -Level SUCCESS -LogFile $LogFile
    } catch {
        $message = "Failed to connect to vCenter $Server : $_"
        Write-Log $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Disconnect-VCenter : silent disconnection from vCenter
# ---------------------------------------------------------------------------
function Disconnect-VCenter {
    param([string]$LogFile)

    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Disconnected from vCenter." -Level INFO -LogFile $LogFile
}

# ---------------------------------------------------------------------------
# Import-RequiredModule : PowerShell 7-compatible module import
# ---------------------------------------------------------------------------
function Import-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$LogFile,

        [switch]$UseWindowsPowerShellFallback
    )

    if ($PSVersionTable.PSEdition -eq "Core" -and $UseWindowsPowerShellFallback) {
        try {
            Import-Module -Name $Name -UseWindowsPowerShell -ErrorAction Stop
            Write-Log "Module imported via Windows PowerShell compatibility mode: $Name" -Level WARNING -LogFile $LogFile
            return
        } catch {
            Write-Log "Windows PowerShell compatibility mode import failed for $Name, trying standard import." -Level WARNING -LogFile $LogFile
        }
    }

    try {
        Import-Module -Name $Name -ErrorAction Stop
        Write-Log "Module imported: $Name" -LogFile $LogFile
        return
    } catch {
        if ($PSVersionTable.PSEdition -eq "Core") {
            try {
                Import-Module -Name $Name -SkipEditionCheck -ErrorAction Stop
                Write-Log "Module imported via SkipEditionCheck fallback: $Name" -Level WARNING -LogFile $LogFile
                return
            } catch {
                $message = "Unable to import module $Name (standard import and fallbacks failed): $_"
                Write-Log $message -Level ERROR -LogFile $LogFile
                throw $message
            }
        }

        $message = "Unable to import module $Name : $_"
        Write-Log $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Send-HtmlMail : send an email in HTML format
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

        Write-Log "Email sent to: $($To -join ', ')" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-Log "Failed to send email : $_" -Level ERROR -LogFile $LogFile
    }
}
