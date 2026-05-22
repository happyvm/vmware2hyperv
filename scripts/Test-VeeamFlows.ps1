#Requires -Version 5.1
<#
.SYNOPSIS
    Validation des flux reseau Veeam B&R 12.3 selon le role de la machine.

.DESCRIPTION
    Selectionne le role de la machine courante et ne demande que les variables
    necessaires a ce role. Teste uniquement les flux partant de cette machine.

    Reference : matrice de ports Veeam Backup & Replication 12.3.

    Roles disponibles :
      VBR        - Serveur VBR seul (proxy sur machine separee)
      VBRProxy   - Serveur VBR qui fait aussi proxy integre
      Proxy      - Proxy Veeam off-host dedie
      SCVMM      - Serveur System Center VMM
      HyperV     - Hote Hyper-V

    Variables demandees par role :
      VBR        -> vCenter, HyperV hosts, SCVMM, [ESXi hosts], [SQL], [Proxy]
      VBRProxy   -> vCenter, HyperV hosts, SCVMM, [ESXi hosts], [SQL]
      Proxy      -> VBR, HyperV hosts
      SCVMM      -> VBR, HyperV hosts, [SQL]
      HyperV     -> VBR, [Proxy], [autres hotes HyperV]

.PARAMETER Role
    Role de la machine. Si omis, menu interactif.
    Valeurs : VBR | VBRProxy | Proxy | SCVMM | HyperV

.PARAMETER VBRServer
    FQDN ou IP du serveur VBR

.PARAMETER ProxyServer
    FQDN ou IP du proxy Veeam off-host (utilise selon le role)

.PARAMETER HyperVHosts
    Tableau de FQDN ou IP des hotes Hyper-V (separes par virgule en interactif)

.PARAMETER SCVMMServer
    FQDN ou IP du serveur SCVMM

.PARAMETER VCenterServer
    FQDN ou IP du serveur vCenter (infrastructure VMware source)

.PARAMETER ESXiHosts
    Tableau de FQDN ou IP des hotes ESXi source (optionnel).
    Requis pour tester le canal NBD (port 902) en mode VBRProxy.

.PARAMETER SQLServer
    FQDN ou IP du serveur SQL (optionnel)

.PARAMETER ExportCSV
    Chemin du fichier CSV d'export (optionnel)

.PARAMETER ContinuousIntervalMinutes
    Intervalle en minutes pour relancer les tests en continu (ex: 2).
    Si non renseigne, le script ne fait qu'un seul passage.

.EXAMPLE
    # Interactif : le script pose les bonnes questions selon le role choisi
    .\Test-VeeamFlows.ps1

.EXAMPLE
    # Non-interactif depuis un hote Hyper-V
    .\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ProxyServer px01 `
        -HyperVHosts hv02,hv03 -ExportCSV C:\Temp\flows.csv

.EXAMPLE
    # Non-interactif VBR+Proxy (source VMware -> cible Hyper-V, VBR 12.3)
    .\Test-VeeamFlows.ps1 -Role VBRProxy -VCenterServer vcenter01 `
        -ESXiHosts esxi01,esxi02 -HyperVHosts hv01,hv02,hv03 `
        -SCVMMServer scvmm01 -SQLServer sql01

.EXAMPLE
    # Mode continu toutes les 2 minutes (Ctrl+C pour arreter)
    .\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ContinuousIntervalMinutes 2
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Script helper names use infrastructure acronyms and role terms.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Console UX intentionally uses colorized host output via local wrapper.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("VBR","VBRProxy","Proxy","SCVMM","HyperV")]
    [string]$Role,

    [Parameter(Mandatory=$false)] [string]   $VBRServer,
    [Parameter(Mandatory=$false)] [string]   $ProxyServer,
    [Parameter(Mandatory=$false)] [string[]] $HyperVHosts,
    [Parameter(Mandatory=$false)] [string]   $SCVMMServer,
    [Parameter(Mandatory=$false)] [string]   $VCenterServer,
    [Parameter(Mandatory=$false)] [string[]] $ESXiHosts,
    [Parameter(Mandatory=$false)] [string]   $SQLServer,
    [Parameter(Mandatory=$false)] [string]   $ExportCSV,
    [Parameter(Mandatory=$false)] [ValidateRange(1,1440)] [int] $ContinuousIntervalMinutes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
$InformationPreference = 'Continue'

$script:Results    = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:TotalTests = 0
$script:PassCount  = 0
$script:FailCount  = 0

function Write-Information {
    param(
        [Parameter(Position=0, ValueFromRemainingArguments=$true)]
        [object[]]$MessageData,
        [string]$ForegroundColor
    )

    $message = ($MessageData -join '')
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        Write-Host $message -ForegroundColor $ForegroundColor
    } else {
        Write-Host $message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# DEFINITIONS DES ROLES
# ─────────────────────────────────────────────────────────────────────────────

$RoleDefs = [ordered]@{
    VBR      = @{
        Label      = "VBR seul"
        Desc       = "Serveur VBR — le proxy est sur une machine separee"
        Required   = @("HyperVHosts","SCVMMServer","VCenterServer")
        Optional   = @("SQLServer","ESXiHosts","ProxyServer")
        NeedVBR    = $false
        NeedProxy  = $false
    }
    VBRProxy = @{
        Label      = "VBR + Proxy integre"
        Desc       = "Serveur VBR qui assure aussi le role de proxy"
        Required   = @("HyperVHosts","SCVMMServer","VCenterServer")
        Optional   = @("SQLServer","ESXiHosts")
        NeedVBR    = $false
        NeedProxy  = $false
    }
    Proxy    = @{
        Label      = "Proxy off-host"
        Desc       = "Proxy Veeam dedie, separe du VBR"
        Required   = @("VBRServer","HyperVHosts")
        Optional   = @()
        NeedVBR    = $true
        NeedProxy  = $false
    }
    SCVMM    = @{
        Label      = "SCVMM"
        Desc       = "Serveur System Center Virtual Machine Manager"
        Required   = @("VBRServer","HyperVHosts")
        Optional   = @("SQLServer")
        NeedVBR    = $true
        NeedProxy  = $false
    }
    HyperV   = @{
        Label      = "Hote Hyper-V"
        Desc       = "Noeud Hyper-V — teste les flux retour vers VBR/proxy"
        Required   = @("VBRServer")
        Optional   = @("ProxyServer","HyperVHosts")
        NeedVBR    = $true
        NeedProxy  = $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS UI
# ─────────────────────────────────────────────────────────────────────────────

function Write-Line([string]$Char = "=", [int]$Width = 100, [string]$Color = "Cyan") {
    Write-Information ($Char * $Width) -ForegroundColor $Color
}

function Write-Banner {
    Write-Information ""
    Write-Line
    Write-Information "  VEEAM NETWORK FLOW VALIDATOR  --  Hyper-V / SCVMM / VMware  --  VBR 12.3" -ForegroundColor White
    Write-Line
    Write-Information ("  Machine  : {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
    Write-Information ("  Heure    : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
    Write-Line "-" 100 "DarkGray"
    Write-Information ""
}

function Show-RoleMenu {
    Write-Information "  Quel est le role de cette machine ?" -ForegroundColor Yellow
    Write-Information ""
    $keys = @($RoleDefs.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $r = $RoleDefs[$keys[$i]]
        Write-Information ("  [{0}]  {1,-22} {2}" -f ($i+1), $r.Label, $r.Desc) -ForegroundColor White
    }
    Write-Information ""
    do {
        $raw = Read-Host "  Choix [1-$($keys.Count)]"
        $n   = 0
        $ok  = [int]::TryParse($raw,[ref]$n) -and $n -ge 1 -and $n -le $keys.Count
        if (-not $ok) { Write-Information "  Choix invalide." -ForegroundColor Red }
    } while (-not $ok)
    return $keys[$n - 1]
}

function Read-RequiredInput([string]$VarName, [string]$Label, [bool]$IsArray = $false) {
    do {
        $val = Read-Host ("  {0}" -f $Label)
        $val = $val.Trim()
    } while ([string]::IsNullOrWhiteSpace($val))

    if ($IsArray) {
        return ($val -split '\s*,\s*' | Where-Object { $_ -ne "" })
    }
    return $val
}

function Read-OptionalInput([string]$Label, [bool]$IsArray = $false) {
    $val = Read-Host ("  {0} [Entree pour ignorer]" -f $Label)
    $val = $val.Trim()
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    if ($IsArray) {
        return ($val -split '\s*,\s*' | Where-Object { $_ -ne "" })
    }
    return $val
}

function Initialize-Variables([string]$SelectedRole) {
    $def = $RoleDefs[$SelectedRole]

    Write-Information ""
    Write-Information "  Variables pour le role : $($def.Label)" -ForegroundColor Yellow
    Write-Line "-" 100 "DarkGray"
    Write-Information "  (Obligatoires marques *, optionnels entre crochets)" -ForegroundColor DarkGray
    Write-Information ""

    # VBR
    if ("VBRServer" -in $def.Required -and -not $script:VBRServer) {
        $script:VBRServer = Read-RequiredInput "VBRServer" "* Serveur VBR (FQDN ou IP)"
    }
    # Proxy
    if ("ProxyServer" -in $def.Required -and -not $script:ProxyServer) {
        $script:ProxyServer = Read-RequiredInput "ProxyServer" "* Proxy off-host (FQDN ou IP)"
    }
    if ("ProxyServer" -in $def.Optional -and -not $script:ProxyServer) {
        $script:ProxyServer = Read-OptionalInput "  Proxy off-host (FQDN ou IP)"
    }
    # HyperV hosts
    if ("HyperVHosts" -in $def.Required -and (-not $script:HyperVHosts -or $script:HyperVHosts.Count -eq 0)) {
        $script:HyperVHosts = Read-RequiredInput "HyperVHosts" "* Hotes Hyper-V (FQDN/IP, separes par virgules)" -IsArray $true
    }
    if ("HyperVHosts" -in $def.Optional -and (-not $script:HyperVHosts -or $script:HyperVHosts.Count -eq 0)) {
        $v = Read-OptionalInput "  Autres hotes Hyper-V pour Live Migration (virgules)" -IsArray $true
        if ($v) { $script:HyperVHosts = $v }
    }
    # SCVMM
    if ("SCVMMServer" -in $def.Required -and -not $script:SCVMMServer) {
        $script:SCVMMServer = Read-RequiredInput "SCVMMServer" "* Serveur SCVMM (FQDN ou IP)"
    }
    # vCenter (source VMware)
    if ("VCenterServer" -in $def.Required -and -not $script:VCenterServer) {
        $script:VCenterServer = Read-RequiredInput "VCenterServer" "* Serveur vCenter source (FQDN ou IP)"
    }
    # ESXi hosts (optionnel — requis pour test NBD en VBRProxy)
    if ("ESXiHosts" -in $def.Optional -and (-not $script:ESXiHosts -or $script:ESXiHosts.Count -eq 0)) {
        $v = Read-OptionalInput "  Hotes ESXi source (FQDN/IP, virgules) -- requis pour test NBD (port 902)" -IsArray $true
        if ($v) { $script:ESXiHosts = $v }
    }
    # SQL
    if ("SQLServer" -in $def.Optional -and -not $script:SQLServer) {
        $v = Read-OptionalInput "  Serveur SQL distant (FQDN ou IP)"
        if ($v) { $script:SQLServer = $v }
    }

    Write-Information ""
}

function Show-Config([string]$SelectedRole) {
    $def = $RoleDefs[$SelectedRole]
    Write-Information ""
    Write-Line "-" 100 "DarkGray"
    Write-Information ("  Role      : {0} -- {1}" -f $def.Label, $def.Desc) -ForegroundColor Cyan
    Write-Information ("  Machine   : {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
    if ($script:VBRServer)     { Write-Information ("  VBR       : {0}" -f $script:VBRServer)     -ForegroundColor Gray }
    if ($script:ProxyServer)   { Write-Information ("  Proxy     : {0}" -f $script:ProxyServer)   -ForegroundColor Gray }
    if ($script:HyperVHosts)   { Write-Information ("  Hyper-V   : {0}" -f ($script:HyperVHosts -join ", "))  -ForegroundColor Gray }
    if ($script:SCVMMServer)   { Write-Information ("  SCVMM     : {0}" -f $script:SCVMMServer)   -ForegroundColor Gray }
    if ($script:VCenterServer) { Write-Information ("  vCenter   : {0}" -f $script:VCenterServer) -ForegroundColor Gray }
    if ($script:ESXiHosts)     { Write-Information ("  ESXi      : {0}" -f ($script:ESXiHosts -join ", "))     -ForegroundColor Gray }
    if ($script:SQLServer)     { Write-Information ("  SQL       : {0}" -f $script:SQLServer)     -ForegroundColor Gray }
    Write-Line "-" 100 "DarkGray"
    Write-Information ""
}

# ─────────────────────────────────────────────────────────────────────────────
# TESTS
# ─────────────────────────────────────────────────────────────────────────────

function Write-SectionHeader([string]$Title) {
    Write-Information ""
    Write-Information ("  >> {0}" -f $Title) -ForegroundColor Yellow
    Write-Line "-" 95 "DarkGray"
    Write-Information ("  {0,-38} {1,-28} {2,-10} {3}" -f "DESTINATION","DESCRIPTION","PORT","RESULTAT") `
        -ForegroundColor DarkCyan
    Write-Line "-" 95 "DarkGray"
}

function Test-Flow {
    param(
        [string]$Destination,
        [int]$Port,
        [string]$Proto = "TCP",
        [string]$Desc  = ""
    )
    $script:TotalTests++
    $portStr = "{0}/{1}" -f $Port, $Proto
    $status  = "ERROR"
    $latency = "--"

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $ar  = $tcp.BeginConnect($Destination, $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
        $sw.Stop()
        if ($ok -and $tcp.Connected) {
            $status  = "PASS"
            $latency = "{0} ms" -f [int]$sw.ElapsedMilliseconds
            $script:PassCount++
        } else {
            $status = "FAIL"
            $script:FailCount++
        }
        $tcp.Close()
    } catch {
        $script:FailCount++
    }

    $color = switch ($status) { "PASS"{"Green"} "FAIL"{"Red"} default{"DarkYellow"} }
    $icon  = switch ($status) { "PASS"{"[OK]"}  "FAIL"{"[KO]"} default{"[??]"} }

    Write-Information ("  {0,-38} {1,-28} {2,-10} {3} {4,-7} {5}" -f `
        $Destination, $Desc, $portStr, $icon, $status, $latency) -ForegroundColor $color

    $script:Results.Add([PSCustomObject]@{
        Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Machine     = $env:COMPUTERNAME
        Role        = $script:ActiveRole
        Destination = $Destination
        Port        = $Port
        Proto       = $Proto
        Description = $Desc
        Status      = $status
        Latency     = $latency
    })
}

function Test-DNS([string[]]$Hosts) {
    Write-SectionHeader "Resolution DNS"
    foreach ($h in ($Hosts | Sort-Object -Unique)) {
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($h) | Select-Object -First 1).IPAddressToString
            Write-Information ("  {0,-42} -> {1}" -f $h, $ip) -ForegroundColor Green
        } catch {
            Write-Information ("  {0,-42} -> ECHEC" -f $h) -ForegroundColor Red
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOCS PAR ROLE
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-VBR {
    # --- VMware source (infrastructure de depart) ---
    Write-SectionHeader "VBR -> vCenter Server  (VMware source - API)"
    Test-Flow $script:VCenterServer 443 -Desc "vSphere API (HTTPS)"
    Test-Flow $script:VCenterServer 80  -Desc "HTTP (redirect HTTPS)"

    if ($script:ESXiHosts -and $script:ESXiHosts.Count -gt 0) {
        Write-SectionHeader "VBR -> Hotes ESXi  (VMware source - API uniquement)"
        Write-Information "  Note : port 902 NBD gere par le proxy off-host" -ForegroundColor DarkGray
        foreach ($esxi in $script:ESXiHosts) {
            Write-Information ("  -- {0}" -f $esxi) -ForegroundColor DarkCyan
            Test-Flow $esxi 443 -Desc "vSphere API (HTTPS)"
        }
    }

    # --- Infrastructure Hyper-V cible (management uniquement) ---
    Write-SectionHeader "VBR -> Hotes Hyper-V  (management)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Information ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 6160 -Desc "Veeam Installer Service"
        Test-Flow $hv 6163 -Desc "Veeam Hyper-V Integration Service"
        # Pas de 6162/2500-3300 : gere par le proxy off-host
    }

    Write-SectionHeader "VBR -> SCVMM"
    Test-Flow $script:SCVMMServer 135  -Desc "RPC Endpoint Mapper"
    Test-Flow $script:SCVMMServer 445  -Desc "SMB / CIFS"
    Test-Flow $script:SCVMMServer 5985 -Desc "WinRM HTTP"
    Test-Flow $script:SCVMMServer 5986 -Desc "WinRM HTTPS"
    Test-Flow $script:SCVMMServer 8100 -Desc "SCVMM Agent"
    Test-Flow $script:SCVMMServer 8101 -Desc "SCVMM Agent (alt)"

    if ($script:SQLServer) {
        Write-SectionHeader "VBR -> SQL Server"
        Test-Flow $script:SQLServer 1433 -Desc "SQL Server"
        Test-Flow $script:SQLServer 1434 -Desc "SQL Browser"
    }

    if ($script:ProxyServer) {
        Write-SectionHeader "VBR -> Proxy off-host  (deploiement + controle Data Mover)"
        Write-Information ("  -- {0}" -f $script:ProxyServer) -ForegroundColor DarkCyan
        Test-Flow $script:ProxyServer 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $script:ProxyServer 445  -Desc "SMB / CIFS"
        Test-Flow $script:ProxyServer 6160 -Desc "Veeam Installer Service"
        Test-Flow $script:ProxyServer 6162 -Desc "Veeam Data Mover"
    }

    $dns = @($script:VCenterServer, $script:SCVMMServer) + $script:HyperVHosts
    if ($script:ESXiHosts)   { $dns += $script:ESXiHosts }
    if ($script:SQLServer)   { $dns += $script:SQLServer }
    if ($script:ProxyServer) { $dns += $script:ProxyServer }
    Test-DNS $dns
}

function Invoke-VBRProxy {
    # --- VMware source (infrastructure de depart) ---
    Write-SectionHeader "VBR+Proxy -> vCenter Server  (VMware source - API)"
    Test-Flow $script:VCenterServer 443 -Desc "vSphere API (HTTPS)"
    Test-Flow $script:VCenterServer 80  -Desc "HTTP (redirect HTTPS)"

    if ($script:ESXiHosts -and $script:ESXiHosts.Count -gt 0) {
        Write-SectionHeader "VBR+Proxy -> Hotes ESXi  (VMware source - API + NBD)"
        foreach ($esxi in $script:ESXiHosts) {
            Write-Information ("  -- {0}" -f $esxi) -ForegroundColor DarkCyan
            Test-Flow $esxi 443 -Desc "vSphere API (HTTPS)"
            Test-Flow $esxi 902 -Desc "VMware Host Agent (NBD data)"
        }
    } else {
        Write-Information ""
        Write-Information "  [!] ESXiHosts non specifie : port 902 NBD non teste." -ForegroundColor DarkYellow
        Write-Information "      Utilisez -ESXiHosts esxi01,esxi02 pour valider le canal NBD." -ForegroundColor DarkYellow
    }

    # --- Infrastructure Hyper-V cible (management + data) ---
    Write-SectionHeader "VBR+Proxy -> Hotes Hyper-V  (management + data)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Information ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 6160 -Desc "Veeam Installer Service"
        Test-Flow $hv 6162 -Desc "Veeam Data Mover"
        Test-Flow $hv 6163 -Desc "Veeam Hyper-V Integration Service"
        Test-Flow $hv 2500 -Desc "Data transfer (debut plage)"
        Test-Flow $hv 3300 -Desc "Data transfer (fin plage)"
    }

    Write-SectionHeader "VBR+Proxy -> SCVMM"
    Test-Flow $script:SCVMMServer 135  -Desc "RPC Endpoint Mapper"
    Test-Flow $script:SCVMMServer 445  -Desc "SMB / CIFS"
    Test-Flow $script:SCVMMServer 5985 -Desc "WinRM HTTP"
    Test-Flow $script:SCVMMServer 5986 -Desc "WinRM HTTPS"
    Test-Flow $script:SCVMMServer 8100 -Desc "SCVMM Agent"
    Test-Flow $script:SCVMMServer 8101 -Desc "SCVMM Agent (alt)"

    if ($script:SQLServer) {
        Write-SectionHeader "VBR+Proxy -> SQL Server"
        Test-Flow $script:SQLServer 1433 -Desc "SQL Server"
        Test-Flow $script:SQLServer 1434 -Desc "SQL Browser"
    }

    $dns = @($script:VCenterServer, $script:SCVMMServer) + $script:HyperVHosts
    if ($script:ESXiHosts) { $dns += $script:ESXiHosts }
    if ($script:SQLServer) { $dns += $script:SQLServer }
    Test-DNS $dns
}

function Invoke-Proxy {
    Write-SectionHeader "Proxy -> Hotes Hyper-V  (data + deploiement agent)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Information ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 6162 -Desc "Veeam Data Mover"
        Test-Flow $hv 6163 -Desc "Veeam Hyper-V Integration Service"
        Test-Flow $hv 2500 -Desc "Data transfer (debut plage)"
        Test-Flow $hv 3300 -Desc "Data transfer (fin plage)"
    }

    Write-SectionHeader "Proxy -> VBR  (canal de controle)"
    Test-Flow $script:VBRServer 6162 -Desc "Veeam Data Mover"
    Test-Flow $script:VBRServer 9501 -Desc "Veeam Guest Agent"

    Test-DNS (@($script:VBRServer) + $script:HyperVHosts)
}

function Invoke-SCVMM {
    Write-SectionHeader "SCVMM -> Hotes Hyper-V  (gestion VMM)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Information ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 8100 -Desc "SCVMM Agent -> hote"
    }

    Write-SectionHeader "SCVMM -> VBR"
    Test-Flow $script:VBRServer 135  -Desc "RPC Endpoint Mapper"
    Test-Flow $script:VBRServer 445  -Desc "SMB / CIFS"
    Test-Flow $script:VBRServer 9392 -Desc "VBR Console"
    Test-Flow $script:VBRServer 9419 -Desc "VBR REST API (12.x)"

    if ($script:SQLServer) {
        Write-SectionHeader "SCVMM -> SQL Server  (base SCVMM)"
        Test-Flow $script:SQLServer 1433 -Desc "SQL Server"
        Test-Flow $script:SQLServer 1434 -Desc "SQL Browser (instance nommee)"
    }

    $dns = @($script:VBRServer) + $script:HyperVHosts
    if ($script:SQLServer) { $dns += $script:SQLServer }
    Test-DNS $dns
}

function Invoke-HyperV {
    if ($script:ProxyServer) {
        # Cas 1 : VBR standalone + proxy off-host
        # Data Mover HyperV se connecte au proxy (pas au VBR)
        Write-SectionHeader "Hyper-V -> Proxy off-host  (data retour)"
        Write-Information ("  -- {0}" -f $script:ProxyServer) -ForegroundColor DarkCyan
        Test-Flow $script:ProxyServer 2500 -Desc "Data transfer (debut plage)"
        Test-Flow $script:ProxyServer 3300 -Desc "Data transfer (fin plage)"
        Test-Flow $script:ProxyServer 6162 -Desc "Veeam Data Mover"

        Write-SectionHeader "Hyper-V -> VBR  (agent)"
        Write-Information ("  -- {0}" -f $script:VBRServer) -ForegroundColor DarkCyan
        Test-Flow $script:VBRServer 9501 -Desc "Veeam Guest Agent"
        Test-Flow $script:VBRServer 9502 -Desc "Veeam Agent (Windows)"
    } else {
        # Cas 2 : VBRProxy (VBR est aussi proxy) ou VBR seul
        # Toutes les connexions data + control vont vers le VBR
        Write-SectionHeader "Hyper-V -> VBR/VBRProxy  (data retour + agent)"
        Write-Information ("  -- {0}" -f $script:VBRServer) -ForegroundColor DarkCyan
        Test-Flow $script:VBRServer 2500 -Desc "Data transfer (debut plage)"
        Test-Flow $script:VBRServer 3300 -Desc "Data transfer (fin plage)"
        Test-Flow $script:VBRServer 6162 -Desc "Veeam Data Mover"
        Test-Flow $script:VBRServer 9501 -Desc "Veeam Guest Agent"
        Test-Flow $script:VBRServer 9502 -Desc "Veeam Agent (Windows)"
    }

    if ($script:HyperVHosts -and $script:HyperVHosts.Count -gt 0) {
        Write-SectionHeader "Hyper-V -> Autres hotes  (Live Migration / Cluster)"
        foreach ($hv in $script:HyperVHosts) {
            Write-Information ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
            Test-Flow $hv 445  -Desc "SMB (Live Migration)"
            Test-Flow $hv 6600 -Desc "Live Migration (Hyper-V)"
            Test-Flow $hv 3343 -Desc "Cluster heartbeat"
        }
    }

    $dns = @($script:VBRServer)
    if ($script:ProxyServer)  { $dns += $script:ProxyServer }
    if ($script:HyperVHosts)  { $dns += $script:HyperVHosts }
    Test-DNS $dns
}

# ─────────────────────────────────────────────────────────────────────────────
# RESUME
# ─────────────────────────────────────────────────────────────────────────────

function Write-Summary {
    Write-Information ""
    Write-Line
    Write-Information ("  RESUME  --  {0}  --  {1}" -f $RoleDefs[$script:ActiveRole].Label, $env:COMPUTERNAME) `
        -ForegroundColor White
    Write-Line
    Write-Information ("  Tests     : {0}" -f $script:TotalTests) -ForegroundColor White
    Write-Information ("  [OK] PASS : {0}" -f $script:PassCount)  -ForegroundColor Green
    $fc = if ($script:FailCount -gt 0) {"Red"} else {"Gray"}
    Write-Information ("  [KO] FAIL : {0}" -f $script:FailCount)  -ForegroundColor $fc

    if ($script:FailCount -gt 0) {
        Write-Information ""
        Write-Information "  FLUX EN ECHEC -- a ouvrir dans le pare-feu :" -ForegroundColor Red
        $script:Results | Where-Object { $_.Status -ne "PASS" } | ForEach-Object {
            Write-Information ("    [KO]  {0} -> {1}  Port {2}/{3}  ({4})" -f `
                $env:COMPUTERNAME, $_.Destination, $_.Port, $_.Proto, $_.Description) `
                -ForegroundColor DarkRed
        }
    } else {
        Write-Information ""
        Write-Information "  Tous les flux sont ouverts." -ForegroundColor Green
    }

    Write-Line
    Write-Information ""
}


function Reset-RunStats {
    $script:Results.Clear()
    $script:TotalTests = 0
    $script:PassCount  = 0
    $script:FailCount  = 0
}

function Invoke-TestCycle {
    param([int]$CycleNumber = 1)

    Reset-RunStats
    Write-Information ("  Cycle de test : {0}" -f $CycleNumber) -ForegroundColor Yellow

    switch ($script:ActiveRole) {
        "VBR"      { Invoke-VBR      }
        "VBRProxy" { Invoke-VBRProxy }
        "Proxy"    { Invoke-Proxy    }
        "SCVMM"    { Invoke-SCVMM    }
        "HyperV"   { Invoke-HyperV   }
    }

    Write-Summary

    if ($ExportCSV) {
        try {
            $script:Results | Export-Csv -Path $ExportCSV -NoTypeInformation -Encoding UTF8
            Write-Information ("  Rapport exporte : {0}" -f $ExportCSV) -ForegroundColor Cyan
            Write-Information ""
        } catch {
            Write-Warning ("Export CSV impossible : {0}" -f $_.Exception.Message)
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# POINT D'ENTREE
# ─────────────────────────────────────────────────────────────────────────────

# Promouvoir les params en variables de script pour permettre la mise a jour
# depuis Initialize-Variables (contournement du scope PowerShell)
$script:VBRServer     = $VBRServer
$script:ProxyServer   = $ProxyServer
$script:HyperVHosts   = $HyperVHosts
$script:SCVMMServer   = $SCVMMServer
$script:VCenterServer = $VCenterServer
$script:ESXiHosts     = $ESXiHosts
$script:SQLServer     = $SQLServer

Write-Banner

# Selection du role
if ($Role) {
    $script:ActiveRole = $Role
} else {
    $script:ActiveRole = Show-RoleMenu
}

# Collecte des variables manquantes
Initialize-Variables $script:ActiveRole

# Affichage de la configuration retenue
Show-Config $script:ActiveRole

if ($ContinuousIntervalMinutes) {
    Write-Information ("  Mode continu active : un cycle toutes les {0} minute(s). Ctrl+C pour arreter." -f $ContinuousIntervalMinutes) -ForegroundColor Yellow
    Write-Information ""

    $cycle = 1
    while ($true) {
        Invoke-TestCycle -CycleNumber $cycle
        $cycle++
        Start-Sleep -Seconds ($ContinuousIntervalMinutes * 60)
    }
} else {
    Invoke-TestCycle -CycleNumber 1
}

exit $script:FailCount
