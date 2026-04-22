# lib.ps1 — Common functions for VMware → Hyper-V migration scripts
# Load: . "$PSScriptRoot\lib.ps1"

# ---------------------------------------------------------------------------
# Write-MigrationLog : timestamped logging to streams + file
# ---------------------------------------------------------------------------
function Write-MigrationLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [string]$LogFile
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    Write-Verbose -Message $entry

    switch ($Level) {
        "ERROR" {
            Write-Error -Message $entry -ErrorAction Continue
        }
        "WARNING" {
            Write-Warning -Message $entry
        }
        default {
            Write-Information -MessageData $entry -InformationAction Continue
        }
    }

    if ($LogFile) {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $entry
    }
}

# ---------------------------------------------------------------------------
# Assert-PathPresent : stops the script if a file is missing
# ---------------------------------------------------------------------------
function Assert-PathPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Label = "File",

        [string]$LogFile
    )

    if (-not (Test-Path $Path)) {
        $message = "$Label not found: $Path"
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
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
        Write-MigrationLog "Connected to vCenter: $Server" -Level SUCCESS -LogFile $LogFile
    } catch {
        $message = "Failed to connect to vCenter $Server : $_"
        Write-MigrationLog $message -Level ERROR -LogFile $LogFile
        throw $message
    }
}

# ---------------------------------------------------------------------------
# Disconnect-VCenter : silent disconnection from vCenter
# ---------------------------------------------------------------------------
function Disconnect-VCenter {
    param([string]$LogFile)

    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
    Write-MigrationLog "Disconnected from vCenter." -Level INFO -LogFile $LogFile
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

    $candidateNames = if ($Name -eq "VMware.PowerCLI") {
        @("VMware.PowerCLI", "VCF.PowerCLI")
    } else {
        @($Name)
    }

    foreach ($candidateName in $candidateNames) {
        if ($PSVersionTable.PSEdition -eq "Core" -and $UseWindowsPowerShellFallback) {
            try {
                Import-Module -Name $candidateName -UseWindowsPowerShell -DisableNameChecking -ErrorAction Stop 3>$null
                Write-MigrationLog "Module imported via Windows PowerShell compatibility mode: $candidateName" -Level WARNING -LogFile $LogFile
                return
            } catch {
                Write-MigrationLog "Windows PowerShell compatibility mode import failed for $candidateName, trying standard import." -Level WARNING -LogFile $LogFile
            }
        }

        try {
            Import-Module -Name $candidateName -DisableNameChecking -ErrorAction Stop 3>$null
            Write-MigrationLog "Module imported: $candidateName" -LogFile $LogFile
            return
        } catch {
            if ($PSVersionTable.PSEdition -eq "Core") {
                try {
                    Import-Module -Name $candidateName -SkipEditionCheck -DisableNameChecking -ErrorAction Stop 3>$null
                    Write-MigrationLog "Module imported via SkipEditionCheck fallback: $candidateName" -Level WARNING -LogFile $LogFile
                    return
                } catch {
                    Write-MigrationLog "Unable to import module $candidateName (standard import and fallbacks failed): $_" -Level WARNING -LogFile $LogFile
                }
            } else {
                Write-MigrationLog "Unable to import module $candidateName : $_" -Level WARNING -LogFile $LogFile
            }
        }
    }

    $candidateList = $candidateNames -join ", "
    $message = "Unable to import module $Name. Tried: $candidateList"
    Write-MigrationLog $message -Level ERROR -LogFile $LogFile
    throw $message
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

        Write-MigrationLog "Email sent to: $($To -join ', ')" -Level SUCCESS -LogFile $LogFile
    } catch {
        Write-MigrationLog "Failed to send email : $_" -Level ERROR -LogFile $LogFile
    }
}


# ---------------------------------------------------------------------------
# ConvertTo-NormalizedOperatingSystemName : normalize OS labels before mapping to SCVMM operating systems
# ---------------------------------------------------------------------------
function ConvertTo-NormalizedOperatingSystemName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $normalized = $Name.Trim().ToLowerInvariant()
    $normalized = $normalized -replace '[\/_-]+', ' '
    $normalized = $normalized -replace '\s+', ' '
    $normalized = $normalized -replace '^microsoft\s+', ''
    return $normalized.Trim()
}

# ---------------------------------------------------------------------------
# Resolve-OperatingSystemMapping : resolve a source OS value to an SCVMM OS name
# ---------------------------------------------------------------------------
function Resolve-OperatingSystemMapping {
    param(
        [AllowNull()]
        [string]$OperatingSystem,

        $OperatingSystemMap
    )

    $normalized = ConvertTo-NormalizedOperatingSystemName -Name $OperatingSystem
    if ([string]::IsNullOrWhiteSpace($normalized) -or -not $OperatingSystemMap) {
        return $null
    }

    foreach ($entry in $OperatingSystemMap.GetEnumerator()) {
        $entryKey = ConvertTo-NormalizedOperatingSystemName -Name ([string]$entry.Key)
        if ($entryKey -eq $normalized) {
            return [string]$entry.Value
        }
    }

    return $null
}
