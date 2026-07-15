#Requires -Version 5.1
<#
.SYNOPSIS
    Validate Veeam B&R 12.3 network flows based on the machine role.

.DESCRIPTION
    Selects the current machine role and only prompts for variables
    required for that role. Tests only outbound flows from this machine.

    Reference: Veeam Backup & Replication 12.3 port matrix.

    Available roles:
      VBR        - VBR server only (proxy on a separate machine)
      VBRProxy   - VBR server also acting as integrated proxy
      Proxy      - Dedicated off-host Veeam proxy
      SCVMM      - Serveur System Center VMM
      HyperV     - Hyper-V Host

    Variables requested by role:
      VBR        -> vCenter, HyperV hosts, SCVMM, [ESXi hosts], [SQL], [Proxy]
      VBRProxy   -> vCenter, HyperV hosts, SCVMM, [ESXi hosts], [SQL]
      Proxy      -> VBR, HyperV hosts
      SCVMM      -> VBR, HyperV hosts, [SQL]
      HyperV     -> VBR, [Proxy], [other Hyper-V hosts]

.PARAMETER Role
    Machine role. If omitted, an interactive menu is shown.
    Valeurs : VBR | VBRProxy | Proxy | SCVMM | HyperV

.PARAMETER VBRServer
    FQDN or IP of the VBR server

.PARAMETER ProxyServer
    FQDN or IP of the off-host Veeam proxy (used based on role)

.PARAMETER HyperVHosts
    Array of Hyper-V host FQDNs or IPs (comma-separated in interactive mode)

.PARAMETER SCVMMServer
    FQDN or IP of the SCVMM server

.PARAMETER VCenterServer
    FQDN or IP of the vCenter server (source VMware infrastructure)

.PARAMETER ESXiHosts
    Array of source ESXi host FQDNs or IPs (optional).
    Required to test the NBD channel (port 902) in VBRProxy mode.

.PARAMETER SQLServer
    FQDN or IP of the SQL server (optional)

.PARAMETER ExportCSV
    Path to the CSV export file (optional)

.PARAMETER ContinuousIntervalMinutes
    Interval in minutes to rerun tests continuously (e.g., 2).
    If not specified, the script runs only once.

.PARAMETER ContinuousIntervalMinutes
    Intervalle en minutes pour relancer les tests en continu (ex: 2).
    Si non renseigne, le script ne fait qu'un seul passage.

.EXAMPLE
    # Interactive: the script asks the right questions for the selected role
    .\Test-VeeamFlows.ps1

.EXAMPLE
    # Non-interactive from a Hyper-V host
    .\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ProxyServer px01 `
        -HyperVHosts hv02,hv03 -ExportCSV C:\Temp\flows.csv

.EXAMPLE
    # Non-interactive VBR+Proxy (VMware source -> Hyper-V target, VBR 12.3)
    .\Test-VeeamFlows.ps1 -Role VBRProxy -VCenterServer vcenter01 `
        -ESXiHosts esxi01,esxi02 -HyperVHosts hv01,hv02,hv03 `
        -SCVMMServer scvmm01 -SQLServer sql01

.EXAMPLE
    # Continuous mode every 2 minutes (Ctrl+C to stop)
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

function Write-FlowOutput {
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
# ROLE DEFINITIONS
# ─────────────────────────────────────────────────────────────────────────────

$RoleDefs = [ordered]@{
    VBR      = @{
        Label      = "VBR only"
        Desc       = "VBR server — proxy is on a separate machine"
        Required   = @("HyperVHosts","SCVMMServer","VCenterServer")
        Optional   = @("SQLServer","ESXiHosts","ProxyServer")
        NeedVBR    = $false
        NeedProxy  = $false
    }
    VBRProxy = @{
        Label      = "VBR + Integrated Proxy"
        Desc       = "VBR server that also acts as the proxy"
        Required   = @("HyperVHosts","SCVMMServer","VCenterServer")
        Optional   = @("SQLServer","ESXiHosts")
        NeedVBR    = $false
        NeedProxy  = $false
    }
    Proxy    = @{
        Label      = "Off-host Proxy"
        Desc       = "Dedicated Veeam proxy, separate from VBR"
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
        Label      = "Hyper-V Host"
        Desc       = "Hyper-V node — tests return flows to VBR/proxy"
        Required   = @("VBRServer")
        Optional   = @("ProxyServer","HyperVHosts")
        NeedVBR    = $true
        NeedProxy  = $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# UI HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Line([string]$Char = "=", [int]$Width = 100, [string]$Color = "Cyan") {
    Write-FlowOutput ($Char * $Width) -ForegroundColor $Color
}

function Write-Banner {
    Write-FlowOutput ""
    Write-Line
    Write-FlowOutput "  VEEAM NETWORK FLOW VALIDATOR  --  Hyper-V / SCVMM / VMware  --  VBR 12.3" -ForegroundColor White
    Write-Line
    Write-FlowOutput ("  Machine  : {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
    Write-FlowOutput ("  Time     : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
    Write-Line "-" 100 "DarkGray"
    Write-FlowOutput ""
}

function Show-RoleMenu {
    Write-FlowOutput "  What is this machine role?" -ForegroundColor Yellow
    Write-FlowOutput ""
    $keys = @($RoleDefs.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $r = $RoleDefs[$keys[$i]]
        Write-FlowOutput ("  [{0}]  {1,-22} {2}" -f ($i+1), $r.Label, $r.Desc) -ForegroundColor White
    }
    Write-FlowOutput ""
    do {
        $raw = Read-Host "  Choix [1-$($keys.Count)]"
        $n   = 0
        $ok  = [int]::TryParse($raw,[ref]$n) -and $n -ge 1 -and $n -le $keys.Count
        if (-not $ok) { Write-FlowOutput "  Invalid choice." -ForegroundColor Red }
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
    $val = Read-Host ("  {0} [Enter to skip]" -f $Label)
    $val = $val.Trim()
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    if ($IsArray) {
        return ($val -split '\s*,\s*' | Where-Object { $_ -ne "" })
    }
    return $val
}

function Initialize-Variables([string]$SelectedRole) {
    $def = $RoleDefs[$SelectedRole]

    Write-FlowOutput ""
    Write-FlowOutput "  Variables for role: $($def.Label)" -ForegroundColor Yellow
    Write-Line "-" 100 "DarkGray"
    Write-FlowOutput "  (Required marked *, optional in brackets)" -ForegroundColor DarkGray
    Write-FlowOutput ""

    # VBR
    if ("VBRServer" -in $def.Required -and -not $script:VBRServer) {
        $script:VBRServer = Read-RequiredInput "VBRServer" "* VBR Server (FQDN or IP)"
    }
    # Proxy
    if ("ProxyServer" -in $def.Required -and -not $script:ProxyServer) {
        $script:ProxyServer = Read-RequiredInput "ProxyServer" "* Off-host Proxy (FQDN ou IP)"
    }
    if ("ProxyServer" -in $def.Optional -and -not $script:ProxyServer) {
        $script:ProxyServer = Read-OptionalInput "  Off-host Proxy (FQDN ou IP)"
    }
    # HyperV hosts
    if ("HyperVHosts" -in $def.Required -and (-not $script:HyperVHosts -or $script:HyperVHosts.Count -eq 0)) {
        $script:HyperVHosts = Read-RequiredInput "HyperVHosts" "* Hotes Hyper-V (FQDN/IP, separes par virgules)" -IsArray $true
    }
    if ("HyperVHosts" -in $def.Optional -and (-not $script:HyperVHosts -or $script:HyperVHosts.Count -eq 0)) {
        $v = Read-OptionalInput "  Other Hyper-V hosts for Live Migration (comma-separated)" -IsArray $true
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

    Write-FlowOutput ""
}

function Show-Config([string]$SelectedRole) {
    $def = $RoleDefs[$SelectedRole]
    Write-FlowOutput ""
    Write-Line "-" 100 "DarkGray"
    Write-FlowOutput ("  Role      : {0} -- {1}" -f $def.Label, $def.Desc) -ForegroundColor Cyan
    Write-FlowOutput ("  Machine   : {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
    if ($script:VBRServer)     { Write-FlowOutput ("  VBR       : {0}" -f $script:VBRServer)     -ForegroundColor Gray }
    if ($script:ProxyServer)   { Write-FlowOutput ("  Proxy     : {0}" -f $script:ProxyServer)   -ForegroundColor Gray }
    if ($script:HyperVHosts)   { Write-FlowOutput ("  Hyper-V   : {0}" -f ($script:HyperVHosts -join ", "))  -ForegroundColor Gray }
    if ($script:SCVMMServer)   { Write-FlowOutput ("  SCVMM     : {0}" -f $script:SCVMMServer)   -ForegroundColor Gray }
    if ($script:VCenterServer) { Write-FlowOutput ("  vCenter   : {0}" -f $script:VCenterServer) -ForegroundColor Gray }
    if ($script:ESXiHosts)     { Write-FlowOutput ("  ESXi      : {0}" -f ($script:ESXiHosts -join ", "))     -ForegroundColor Gray }
    if ($script:SQLServer)     { Write-FlowOutput ("  SQL       : {0}" -f $script:SQLServer)     -ForegroundColor Gray }
    Write-Line "-" 100 "DarkGray"
    Write-FlowOutput ""
}

# ─────────────────────────────────────────────────────────────────────────────
# TESTS
# ─────────────────────────────────────────────────────────────────────────────

function Write-SectionHeader([string]$Title) {
    Write-FlowOutput ""
    Write-FlowOutput ("  >> {0}" -f $Title) -ForegroundColor Yellow
    Write-Line "-" 95 "DarkGray"
    Write-FlowOutput ("  {0,-38} {1,-28} {2,-10} {3}" -f "DESTINATION","DESCRIPTION","PORT","RESULTAT") `
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

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $ar  = $tcp.BeginConnect($Destination, $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
        $sw.Stop()
        if ($ok) {
            # EndConnect completes the async connect and surfaces a refused
            # connection (RST) that finished within the timeout as an exception.
            try { $tcp.EndConnect($ar) } catch { Write-Verbose "EndConnect: $($_.Exception.Message)" }
        }
        if ($ok -and $tcp.Connected) {
            $status  = "PASS"
            $latency = "{0} ms" -f [int]$sw.ElapsedMilliseconds
            $script:PassCount++
        } else {
            $status = "FAIL"
            $script:FailCount++
        }
    } catch {
        $script:FailCount++
    } finally {
        # Close in finally: an exception (e.g. DNS failure) previously leaked the socket.
        if ($tcp) { try { $tcp.Close() } catch { Write-Verbose "TCP close: $($_.Exception.Message)" } }
    }

    $color = switch ($status) { "PASS"{"Green"} "FAIL"{"Red"} default{"DarkYellow"} }
    $icon  = switch ($status) { "PASS"{"[OK]"}  "FAIL"{"[KO]"} default{"[??]"} }

    Write-FlowOutput ("  {0,-38} {1,-28} {2,-10} {3} {4,-7} {5}" -f `
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
            Write-FlowOutput ("  {0,-42} -> {1}" -f $h, $ip) -ForegroundColor Green
        } catch {
            Write-FlowOutput ("  {0,-42} -> ECHEC" -f $h) -ForegroundColor Red
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
        Write-FlowOutput "  Note : port 902 NBD gere par le proxy off-host" -ForegroundColor DarkGray
        foreach ($esxi in $script:ESXiHosts) {
            Write-FlowOutput ("  -- {0}" -f $esxi) -ForegroundColor DarkCyan
            Test-Flow $esxi 443 -Desc "vSphere API (HTTPS)"
        }
    }

    # --- Infrastructure Hyper-V cible (management uniquement) ---
    Write-SectionHeader "VBR -> Hotes Hyper-V  (management)"
    foreach ($hv in $script:HyperVHosts) {
        Write-FlowOutput ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
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
        Write-SectionHeader "VBR -> Off-host Proxy  (deploiement + controle Data Mover)"
        Write-FlowOutput ("  -- {0}" -f $script:ProxyServer) -ForegroundColor DarkCyan
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
            Write-FlowOutput ("  -- {0}" -f $esxi) -ForegroundColor DarkCyan
            Test-Flow $esxi 443 -Desc "vSphere API (HTTPS)"
            Test-Flow $esxi 902 -Desc "VMware Host Agent (NBD data)"
        }
    } else {
        Write-FlowOutput ""
        Write-FlowOutput "  [!] ESXiHosts non specifie : port 902 NBD non teste." -ForegroundColor DarkYellow
        Write-FlowOutput "      Utilisez -ESXiHosts esxi01,esxi02 pour valider le canal NBD." -ForegroundColor DarkYellow
    }

    # --- Infrastructure Hyper-V cible (management + data) ---
    Write-SectionHeader "VBR+Proxy -> Hotes Hyper-V  (management + data)"
    foreach ($hv in $script:HyperVHosts) {
        Write-FlowOutput ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 6160 -Desc "Veeam Installer Service"
        Test-Flow $hv 6162 -Desc "Veeam Data Mover"
        Test-Flow $hv 6163 -Desc "Veeam Hyper-V Integration Service"
        Test-Flow $hv 2500 -Desc "Data transfer (range start)"
        Test-Flow $hv 3300 -Desc "Data transfer (range end)"
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
    Write-SectionHeader "Proxy -> Hyper-V Hosts  (data + agent deployment)"
    foreach ($hv in $script:HyperVHosts) {
        Write-FlowOutput ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 6162 -Desc "Veeam Data Mover"
        Test-Flow $hv 6163 -Desc "Veeam Hyper-V Integration Service"
        Test-Flow $hv 2500 -Desc "Data transfer (range start)"
        Test-Flow $hv 3300 -Desc "Data transfer (range end)"
    }

    Write-SectionHeader "Proxy -> VBR  (control channel)"
    Test-Flow $script:VBRServer 6162 -Desc "Veeam Data Mover"
    Test-Flow $script:VBRServer 9501 -Desc "Veeam Guest Agent"

    Test-DNS (@($script:VBRServer) + $script:HyperVHosts)
}

function Invoke-SCVMM {
    Write-SectionHeader "SCVMM -> Hyper-V Hosts  (VMM management)"
    foreach ($hv in $script:HyperVHosts) {
        Write-FlowOutput ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
        Test-Flow $hv 135  -Desc "RPC Endpoint Mapper"
        Test-Flow $hv 445  -Desc "SMB / CIFS"
        Test-Flow $hv 5985 -Desc "WinRM HTTP"
        Test-Flow $hv 5986 -Desc "WinRM HTTPS"
        Test-Flow $hv 8100 -Desc "SCVMM Agent -> host"
    }

    Write-SectionHeader "SCVMM -> VBR"
    Test-Flow $script:VBRServer 135  -Desc "RPC Endpoint Mapper"
    Test-Flow $script:VBRServer 445  -Desc "SMB / CIFS"
    Test-Flow $script:VBRServer 9392 -Desc "VBR Console"
    Test-Flow $script:VBRServer 9419 -Desc "VBR REST API (12.x)"

    if ($script:SQLServer) {
        Write-SectionHeader "SCVMM -> SQL Server  (SCVMM database)"
        Test-Flow $script:SQLServer 1433 -Desc "SQL Server"
        Test-Flow $script:SQLServer 1434 -Desc "SQL Browser (named instance)"
    }

    $dns = @($script:VBRServer) + $script:HyperVHosts
    if ($script:SQLServer) { $dns += $script:SQLServer }
    Test-DNS $dns
}

function Invoke-HyperV {
    if ($script:ProxyServer) {
        # Case 1: standalone VBR + off-host proxy
        # Hyper-V Data Mover connects to the proxy (not VBR)
        Write-SectionHeader "Hyper-V -> Off-host Proxy  (return data)"
        Write-FlowOutput ("  -- {0}" -f $script:ProxyServer) -ForegroundColor DarkCyan
        Test-Flow $script:ProxyServer 2500 -Desc "Data transfer (range start)"
        Test-Flow $script:ProxyServer 3300 -Desc "Data transfer (range end)"
        Test-Flow $script:ProxyServer 6162 -Desc "Veeam Data Mover"

        Write-SectionHeader "Hyper-V -> VBR  (agent)"
        Write-FlowOutput ("  -- {0}" -f $script:VBRServer) -ForegroundColor DarkCyan
        Test-Flow $script:VBRServer 9501 -Desc "Veeam Guest Agent"
        Test-Flow $script:VBRServer 9502 -Desc "Veeam Agent (Windows)"
    } else {
        # Case 2: VBRProxy (VBR is also proxy) or VBR only
        # All data + control connections go to VBR
        Write-SectionHeader "Hyper-V -> VBR/VBRProxy  (return data + agent)"
        Write-FlowOutput ("  -- {0}" -f $script:VBRServer) -ForegroundColor DarkCyan
        Test-Flow $script:VBRServer 2500 -Desc "Data transfer (range start)"
        Test-Flow $script:VBRServer 3300 -Desc "Data transfer (range end)"
        Test-Flow $script:VBRServer 6162 -Desc "Veeam Data Mover"
        Test-Flow $script:VBRServer 9501 -Desc "Veeam Guest Agent"
        Test-Flow $script:VBRServer 9502 -Desc "Veeam Agent (Windows)"
    }

    if ($script:HyperVHosts -and $script:HyperVHosts.Count -gt 0) {
        Write-SectionHeader "Hyper-V -> Other hosts  (Live Migration / Cluster)"
        foreach ($hv in $script:HyperVHosts) {
            Write-FlowOutput ("  -- {0}" -f $hv) -ForegroundColor DarkCyan
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
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Write-Summary {
    Write-FlowOutput ""
    Write-Line
    Write-FlowOutput ("  SUMMARY  --  {0}  --  {1}" -f $RoleDefs[$script:ActiveRole].Label, $env:COMPUTERNAME) `
        -ForegroundColor White
    Write-Line
    Write-FlowOutput ("  Tests     : {0}" -f $script:TotalTests) -ForegroundColor White
    Write-FlowOutput ("  [OK] PASS : {0}" -f $script:PassCount)  -ForegroundColor Green
    $fc = if ($script:FailCount -gt 0) {"Red"} else {"Gray"}
    Write-FlowOutput ("  [KO] FAIL : {0}" -f $script:FailCount)  -ForegroundColor $fc

    if ($script:FailCount -gt 0) {
        Write-FlowOutput ""
        Write-FlowOutput "  FLUX EN ECHEC -- a ouvrir dans le pare-feu :" -ForegroundColor Red
        $script:Results | Where-Object { $_.Status -ne "PASS" } | ForEach-Object {
            Write-FlowOutput ("    [KO]  {0} -> {1}  Port {2}/{3}  ({4})" -f `
                $env:COMPUTERNAME, $_.Destination, $_.Port, $_.Proto, $_.Description) `
                -ForegroundColor DarkRed
        }
    } else {
        Write-FlowOutput ""
        Write-FlowOutput "  All flows are open." -ForegroundColor Green
    }

    Write-Line
    Write-FlowOutput ""
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
    Write-FlowOutput ("  Cycle de test : {0}" -f $CycleNumber) -ForegroundColor Yellow

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
            # Append from the second cycle onwards: overwriting on every cycle in
            # continuous mode kept only the last run (rows carry a Timestamp).
            $exportParameters = @{ Path = $ExportCSV; NoTypeInformation = $true; Encoding = 'UTF8' }
            if ($CycleNumber -gt 1) { $exportParameters['Append'] = $true }
            $script:Results | Export-Csv @exportParameters
            Write-FlowOutput ("  Report exported: {0}" -f $ExportCSV) -ForegroundColor Cyan
            Write-FlowOutput ""
        } catch {
            Write-Warning ("CSV export failed: {0}" -f $_.Exception.Message)
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

# Promote params to script variables to allow updates
# from Initialize-Variables (PowerShell scope workaround)
$script:VBRServer     = $VBRServer
$script:ProxyServer   = $ProxyServer
$script:HyperVHosts   = $HyperVHosts
$script:SCVMMServer   = $SCVMMServer
$script:VCenterServer = $VCenterServer
$script:ESXiHosts     = $ESXiHosts
$script:SQLServer     = $SQLServer

Write-Banner

# Role selection
if ($Role) {
    $script:ActiveRole = $Role
} else {
    $script:ActiveRole = Show-RoleMenu
}

# Collect missing variables
Initialize-Variables $script:ActiveRole

# Display selected configuration
Show-Config $script:ActiveRole

if ($ContinuousIntervalMinutes) {
    Write-FlowOutput ("  Continuous mode enabled: one cycle every {0} minute(s). Ctrl+C to stop." -f $ContinuousIntervalMinutes) -ForegroundColor Yellow
    Write-FlowOutput ""

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
