#Requires -Version 5.1
<#
.SYNOPSIS
    Validation des flux reseau Veeam B&R selon le role de la machine.

.DESCRIPTION
    Selectionne le role de la machine courante et ne demande que les variables
    necessaires a ce role. Teste uniquement les flux partant de cette machine.

    Roles disponibles :
      VBR        - Serveur VBR seul (proxy sur machine separee)
      VBRProxy   - Serveur VBR qui fait aussi proxy integre
      Proxy      - Proxy Veeam off-host dedie
      SCVMM      - Serveur System Center VMM
      HyperV     - Hote Hyper-V

    Variables demandees par role :
      VBR        -> HyperV hosts, SCVMM, [SQL]
      VBRProxy   -> HyperV hosts, SCVMM, [SQL]
      Proxy      -> VBR, HyperV hosts, SCVMM
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

.PARAMETER SQLServer
    FQDN ou IP du serveur SQL (optionnel)

.PARAMETER ExportCSV
    Chemin du fichier CSV d'export (optionnel)

.EXAMPLE
    # Interactif : le script pose les bonnes questions selon le role choisi
    .\Test-VeeamFlows.ps1

.EXAMPLE
    # Non-interactif depuis un hote Hyper-V
    .\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ProxyServer px01 `
        -HyperVHosts hv02,hv03 -ExportCSV C:\Temp\flows.csv

.EXAMPLE
    # Non-interactif depuis le VBR+Proxy
    .\Test-VeeamFlows.ps1 -Role VBRProxy -HyperVHosts hv01,hv02,hv03 `
        -SCVMMServer scvmm01 -SQLServer sql01
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("VBR","VBRProxy","Proxy","SCVMM","HyperV")]
    [string]$Role,

    [Parameter(Mandatory=$false)] [string]   $VBRServer,
    [Parameter(Mandatory=$false)] [string]   $ProxyServer,
    [Parameter(Mandatory=$false)] [string[]] $HyperVHosts,
    [Parameter(Mandatory=$false)] [string]   $SCVMMServer,
    [Parameter(Mandatory=$false)] [string]   $SQLServer,
    [Parameter(Mandatory=$false)] [string]   $ExportCSV
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$script:Results    = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:TotalTests = 0
$script:PassCount  = 0
$script:FailCount  = 0

# ─────────────────────────────────────────────────────────────────────────────
# DEFINITIONS DES ROLES
# ─────────────────────────────────────────────────────────────────────────────

$RoleDefs = [ordered]@{
    VBR      = @{
        Label      = "VBR seul"
        Desc       = "Serveur VBR — le proxy est sur une machine separee"
        Required   = @("HyperVHosts","SCVMMServer")
        Optional   = @("SQLServer")
        NeedVBR    = $false
        NeedProxy  = $false
    }
    VBRProxy = @{
        Label      = "VBR + Proxy integre"
        Desc       = "Serveur VBR qui assure aussi le role de proxy"
        Required   = @("HyperVHosts","SCVMMServer")
        Optional   = @("SQLServer")
        NeedVBR    = $false
        NeedProxy  = $false
    }
    Proxy    = @{
        Label      = "Proxy off-host"
        Desc       = "Proxy Veeam dedie, separe du VBR"
        Required   = @("VBRServer","HyperVHosts","SCVMMServer")
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
    Write-Host ($Char * $Width) -ForegroundColor $Color
}

function Write-Banner {
    Write-Host ""
    Write-Line
    Write-Host "  VEEAM NETWORK FLOW VALIDATOR  --  Hyper-V / SCVMM  --  v3.0" -ForegroundColor White
    Write-Line
    Write-Host ("  Machine  : {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
    Write-Host ("  Heure    : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
    Write-Line "-" 100 "DarkGray"
    Write-Host ""
}

function Show-RoleMenu {
    Write-Host "  Quel est le role de cette machine ?" -ForegroundColor Yellow
    Write-Host ""
    $keys = @($RoleDefs.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $r = $RoleDefs[$keys[$i]]
        Write-Host ("  [{0}]  {1,-22} {2}" -f ($i+1), $r.Label, $r.Desc) -ForegroundColor White
    }
    Write-Host ""
    do {
        $raw = Read-Host "  Choix [1-$($keys.Count)]"
        $n   = 0
        $ok  = [int]::TryParse($raw,[ref]$n) -and $n -ge 1 -and $n -le $keys.Count
        if (-not $ok) { Write-Host "  Choix invalide." -ForegroundColor Red }
    } while (-not $ok)
    return $keys[$n - 1]
}

function Prompt-Required([string]$VarName, [string]$Label, [bool]$IsArray = $false) {
    do {
        $val = Read-Host ("  {0}" -f $Label)
        $val = $val.Trim()
    } while ([string]::IsNullOrWhiteSpace($val))

    if ($IsArray) {
        return ($val -split '\s*,\s*' | Where-Object { $_ -ne "" })
    }
    return $val
}

function Prompt-Optional([string]$Label, [bool]$IsArray = $false) {
    $val = Read-Host ("  {0} [Entree pour ignorer]" -f $Label)
    $val = $val.Trim()
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    if ($IsArray) {
        return ($val -split '\s*,\s*' | Where-Object { $_ -ne "" })
    }
    return $val
}

function Collect-Variables([string]$SelectedRole) {
    $def = $RoleDefs[$SelectedRole]

    Write-Host ""
    Write-Host "  Variables pour le role : $($def.Label)" -ForegroundColor Yellow
    Write-Line "-" 100 "DarkGray"
    Write-Host "  (Obligatoires marques *, optionnels entre crochets)" -ForegroundColor DarkGray
    Write-Host ""

    # VBR
    if ("VBRServer" -in $def.Required -and -not $VBRServer) {
        $script:VBRServer = Prompt-Required "VBRServer" "* Serveur VBR (FQDN ou IP)"
    }
    # Proxy
    if ("ProxyServer" -in $def.Required -and -not $ProxyServer) {
        $script:ProxyServer = Prompt-Required "ProxyServer" "* Proxy off-host (FQDN ou IP)"
    }
    if ("ProxyServer" -in $def.Optional -and -not $ProxyServer) {
        $script:ProxyServer = Prompt-Optional "  Proxy off-host (FQDN ou IP)"
    }
    # HyperV hosts
    if ("HyperVHosts" -in $def.Required -and (-not $HyperVHosts -or $HyperVHosts.Count -eq 0)) {
        $script:HyperVHosts = Prompt-Required "HyperVHosts" "* Hotes Hyper-V (FQDN/IP, separes par virgules)" -IsArray $true
    }
    if ("HyperVHosts" -in $def.Optional -and (-not $HyperVHosts -or $HyperVHosts.Count -eq 0)) {
        $v = Prompt-Optional "  Autres hotes Hyper-V pour Live Migration (virgules)" -IsArray $true
        if ($v) { $script:HyperVHosts = $v }
    }
    # SCVMM
    if ("SCVMMServer" -in $def.Required -and -not $SCVMMServer) {
        $script:SCVMMServer = Prompt-Required "SCVMMServer" "* Serveur SCVMM (FQDN ou IP)"
    }
    # SQL
    if ("SQLServer" -in $def.Optional -and -not $SQLServer) {
        $v = Prompt-Optional "  Serveur SQL distant (FQDN ou IP)"
        if ($v) { $script:SQLServer = $v }
    }

    Write-Host ""
}

function Show-Config([string]$SelectedRole) {
    $def = $RoleDefs[$SelectedRole]
    Write-Host ""
    Write-Line "-" 100 "DarkGray"
    Write-Host ("  Role      : {0} -- {1}" -f $def.Label, $def.Desc) -ForegroundColor Cyan
    Write-Host ("  Machine   : {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
    if ($script:VBRServer)    { Write-Host ("  VBR       : {0}" -f $script:VBRServer)    -ForegroundColor Gray }
    if ($script:ProxyServer)  { Write-Host ("  Proxy     : {0}" -f $script:ProxyServer)  -ForegroundColor Gray }
    if ($script:HyperVHosts)  { Write-Host ("  Hyper-V   : {0}" -f ($script:HyperVHosts -join ", ")) -ForegroundColor Gray }
    if ($script:SCVMMServer)  { Write-Host ("  SCVMM     : {0}" -f $script:SCVMMServer)  -ForegroundColor Gray }
    if ($script:SQLServer)    { Write-Host ("  SQL       : {0}" -f $script:SQLServer)    -ForegroundColor Gray }
    Write-Line "-" 100 "DarkGray"
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# TESTS
# ─────────────────────────────────────────────────────────────────────────────

function Write-SectionHeader([string]$Title) {
    Write-Host ""
    Write-Host ("  >> {0}" -f $Title) -ForegroundColor Yellow
    Write-Line "-" 95 "DarkGray"
    Write-Host ("  {0,-38} {1,-28} {2,-10} {3}" -f "DESTINATION","DESCRIPTION","PORT","RESULTAT") `
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
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $tcn = Test-NetConnection -ComputerName $Destination -Port $Port `
                   -WarningAction SilentlyContinue -InformationLevel Quiet
        $sw.Stop()
        if ($tcn.TcpTestSucceeded) {
            $status  = "PASS"
            $latency = "{0} ms" -f [int]$sw.ElapsedMilliseconds
            $script:PassCount++
        } else {
            $status = "FAIL"
            $script:FailCount++
        }
    } catch {
        $script:FailCount++
    }

    $color = switch ($status) { "PASS"{"Green"} "FAIL"{"Red"} default{"DarkYellow"} }
    $icon  = switch ($status) { "PASS"{"[OK]"}  "FAIL"{"[KO]"} default{"[??]"} }

    Write-Host ("  {0,-38} {1,-28} {2,-10} {3} {4,-7} {5}" -f `
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
            Write-Host ("  {0,-42} -> {1}" -f $h, $ip) -ForegroundColor Green
        } catch {
            Write-Host ("  {0,-42} -> ECHEC" -f $h) -ForegroundColor Red
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOCS PAR ROLE
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-VBR {
    # Flux de management uniquement (pas de data : le proxy gere ca)
    Write-SectionHeader "VBR -> Hotes Hyper-V  (management)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Host ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 6160 -Desc "Veeam Installer Service"
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

    $dns = @($script:SCVMMServer) + $script:HyperVHosts
    if ($script:SQLServer) { $dns += $script:SQLServer }
    Test-DNS $dns
}

function Invoke-VBRProxy {
    # Flux management + data (le VBR est aussi proxy)
    Write-SectionHeader "VBR+Proxy -> Hotes Hyper-V  (management + data)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Host ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 6160 -Desc "Veeam Installer Service"
        Test-Flow $hv 6162 -Desc "Veeam Data Mover"
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

    $dns = @($script:SCVMMServer) + $script:HyperVHosts
    if ($script:SQLServer) { $dns += $script:SQLServer }
    Test-DNS $dns
}

function Invoke-Proxy {
    Write-SectionHeader "Proxy -> Hotes Hyper-V  (data + deploiement agent)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Host ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 6160 -Desc "Veeam Installer Service"
        Test-Flow $hv 6162 -Desc "Veeam Data Mover"
        Test-Flow $hv 2500 -Desc "Data transfer (debut plage)"
        Test-Flow $hv 3300 -Desc "Data transfer (fin plage)"
    }

    Write-SectionHeader "Proxy -> VBR  (control channel retour)"
    Test-Flow $script:VBRServer 2500 -Desc "Data retour (debut plage)"
    Test-Flow $script:VBRServer 3300 -Desc "Data retour (fin plage)"
    Test-Flow $script:VBRServer 6162 -Desc "Veeam Data Mover"
    Test-Flow $script:VBRServer 9501 -Desc "Veeam Guest Agent"

    Write-SectionHeader "Proxy -> SCVMM"
    Test-Flow $script:SCVMMServer 135  -Desc "RPC Endpoint Mapper"
    Test-Flow $script:SCVMMServer 445  -Desc "SMB / CIFS"
    Test-Flow $script:SCVMMServer 8100 -Desc "SCVMM Agent"

    Test-DNS (@($script:VBRServer, $script:SCVMMServer) + $script:HyperVHosts)
}

function Invoke-SCVMM {
    Write-SectionHeader "SCVMM -> Hotes Hyper-V  (gestion VMM)"
    foreach ($hv in $script:HyperVHosts) {
        Write-Host ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 8100 -Desc "SCVMM Agent -> hote"
    }

    Write-SectionHeader "SCVMM -> VBR"
    Test-Flow $script:VBRServer 135  -Desc "RPC Endpoint Mapper"
    Test-Flow $script:VBRServer 445  -Desc "SMB / CIFS"
    Test-Flow $script:VBRServer 9392 -Desc "Veeam REST API"

    if ($script:SQLServer) {
        Write-SectionHeader "SCVMM -> SQL Server  (base SCVMM)"
        Test-Flow $script:SQLServer 1433 -Desc "SQL Server"
    }

    $dns = @($script:VBRServer) + $script:HyperVHosts
    if ($script:SQLServer) { $dns += $script:SQLServer }
    Test-DNS $dns
}

function Invoke-HyperV {
    # Consolider VBR et proxy comme cibles de data retour
    $dataTargets = @($script:VBRServer)
    if ($script:ProxyServer) { $dataTargets += $script:ProxyServer }

    Write-SectionHeader "Hyper-V -> VBR / Proxy  (data retour + agent)"
    foreach ($target in $dataTargets) {
        Write-Host ("  -- {0}" -f $target) -ForegroundColor DarkCyan
        Test-Flow $target 2500 -Desc "Data retour (debut plage)"
        Test-Flow $target 3300 -Desc "Data retour (fin plage)"
        Test-Flow $target 6162 -Desc "Veeam Data Mover"
        Test-Flow $target 9501 -Desc "Veeam Guest Agent"
        Test-Flow $target 9502 -Desc "Veeam Agent (Windows)"
    }

    Write-SectionHeader "Hyper-V -> VBR  (console / REST)"
    Test-Flow $script:VBRServer 443  -Desc "REST API / Console HTTPS"
    Test-Flow $script:VBRServer 9392 -Desc "Veeam REST API"

    if ($script:HyperVHosts -and $script:HyperVHosts.Count -gt 0) {
        Write-SectionHeader "Hyper-V -> Autres hotes  (Live Migration / Cluster)"
        foreach ($hv in $script:HyperVHosts) {
            Write-Host ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
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
    Write-Host ""
    Write-Line
    Write-Host ("  RESUME  --  {0}  --  {1}" -f $RoleDefs[$script:ActiveRole].Label, $env:COMPUTERNAME) `
        -ForegroundColor White
    Write-Line
    Write-Host ("  Tests     : {0}" -f $script:TotalTests) -ForegroundColor White
    Write-Host ("  [OK] PASS : {0}" -f $script:PassCount)  -ForegroundColor Green
    $fc = if ($script:FailCount -gt 0) {"Red"} else {"Gray"}
    Write-Host ("  [KO] FAIL : {0}" -f $script:FailCount)  -ForegroundColor $fc

    if ($script:FailCount -gt 0) {
        Write-Host ""
        Write-Host "  FLUX EN ECHEC -- a ouvrir dans le pare-feu :" -ForegroundColor Red
        $script:Results | Where-Object { $_.Status -ne "PASS" } | ForEach-Object {
            Write-Host ("    [KO]  {0} -> {1}  Port {2}/{3}  ({4})" -f `
                $env:COMPUTERNAME, $_.Destination, $_.Port, $_.Proto, $_.Description) `
                -ForegroundColor DarkRed
        }
    } else {
        Write-Host ""
        Write-Host "  Tous les flux sont ouverts." -ForegroundColor Green
    }

    Write-Line
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# POINT D'ENTREE
# ─────────────────────────────────────────────────────────────────────────────

# Promouvoir les params en variables de script pour permettre la mise a jour
# depuis Collect-Variables (contournement du scope PowerShell)
$script:VBRServer   = $VBRServer
$script:ProxyServer = $ProxyServer
$script:HyperVHosts = $HyperVHosts
$script:SCVMMServer = $SCVMMServer
$script:SQLServer   = $SQLServer

Write-Banner

# Selection du role
if ($Role) {
    $script:ActiveRole = $Role
} else {
    $script:ActiveRole = Show-RoleMenu
}

# Collecte des variables manquantes
Collect-Variables $script:ActiveRole

# Affichage de la configuration retenue
Show-Config $script:ActiveRole

# Dispatch
switch ($script:ActiveRole) {
    "VBR"      { Invoke-VBR      }
    "VBRProxy" { Invoke-VBRProxy }
    "Proxy"    { Invoke-Proxy    }
    "SCVMM"    { Invoke-SCVMM    }
    "HyperV"   { Invoke-HyperV   }
}

Write-Summary

# Export CSV
if ($ExportCSV) {
    try {
        $script:Results | Export-Csv -Path $ExportCSV -NoTypeInformation -Encoding UTF8
        Write-Host ("  Rapport exporte : {0}" -f $ExportCSV) -ForegroundColor Cyan
        Write-Host ""
    } catch {
        Write-Warning ("Export CSV impossible : {0}" -f $_.Exception.Message)
    }
}

exit $script:FailCount
