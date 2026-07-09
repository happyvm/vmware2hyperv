<#
.SYNOPSIS
    Orchestrateur de phases step 3 — Instant Recovery, réseau, post-migration par VM.
.DESCRIPTION
    Refactoré de 1625 lignes monolithiques en orchestrateur ~150 lignes (BEA-276).
    Chaque phase est déléguée à un module step3/ spécialisé.
    Résultat structuré par phase → JSON lu par worker-step3.ps1.
    Modes de rejeu : -ForceNetworkConfigOnly (Network-only), -SkipInstantRecoveryStart (Incident recovery),
    -SkipNetworkAndPostConfig (IR-only), -Phases IRCommit,Network,HA (futur).
.PARAMETER BackupJobName
    Nom du job Veeam. Obligatoire.
.PARAMETER VMName
    Nom de la VM cible. Obligatoire.
.PARAMETER VlanId
    VLAN ID pour la VM restaurée. Obligatoire.
.PARAMETER Phases
    (Futur) Liste explicite des phases. Prioritaire sur les switches Skip*.
    Valeurs : IRStart, IRCommit, Network, IntegrationServices, OS, HA, LiveMigration, BackupTag.
.EXAMPLE
    .\step3-MigrateVM.ps1 -BackupJobName Backup-HypMig-lot-118 -VMName SRV-WEB01 -VlanId 100 -HyperVHost hv01
.EXAMPLE
    # Rejeu Network-only
    .\step3-MigrateVM.ps1 -BackupJobName ... -VMName SRV-WEB01 -VlanId 100 -ForceNetworkConfigOnly
.EXAMPLE
    # Rejeu Incident recovery (commit sur mount existant)
    .\step3-MigrateVM.ps1 -BackupJobName ... -VMName SRV-WEB01 -VlanId 100 -SkipInstantRecoveryStart
.NOTES
    Part of vmware2hyperv — BEA-276 / BEA-261.7. PowerShell 7+.
#>

param (
    [Parameter(Mandatory = $true)] [string]$BackupJobName,
    [Parameter(Mandatory = $true)] [string]$VMName,
    [Parameter(Mandatory = $true)] [string]$VlanId,

    [string]$AdapterVlanMapJson,
    [string]$OperatingSystem,
    [string]$Remark,
    [string]$SCVMMServer,
    [string]$HyperVHost,
    [string]$HyperVHost2,
    [string]$HyperVCluster,
    [string]$ClusterStorage,
    [string]$VmwareCluster,
    [string]$BackupTag,
    [int]$WaitingTimeoutSeconds = 1800,
    [int]$WaitingPollIntervalSeconds = 15,

    # ── Modes de rejeu lisibles ──────────────────────────────────────────
    # Standard                    : migration complète
    # -ForceNetworkConfigOnly     : Network-only (skip IR, réseau/OS/post-config)
    # -SkipInstantRecoveryStart   : Incident recovery (commit + réseau sur mount existant)
    # -SkipNetworkAndPostConfig   : IR-only (pas de réseau/post-config)
    [switch]$ForceNetworkConfigOnly,
    [switch]$SkipInstantRecoveryStart,
    [switch]$SkipInstantRecoveryFinalization,
    [switch]$SkipNetworkAndPostConfig,

    # ── Futur : sélection explicite de phases ────────────────────────────
    [ValidateSet('IRStart', 'IRCommit', 'Network', 'IntegrationServices', 'OS', 'HA', 'LiveMigration', 'BackupTag')]
    [string[]]$Phases,

    [string]$LogFile
)

# ── Initialisation ─────────────────────────────────────────────────────────
. "$PSScriptRoot\lib.ps1"
$Config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

if (-not $SCVMMServer)   { $SCVMMServer   = $Config.SCVMM.Server }
if (-not $LogFile)       { $LogFile       = "$($Config.Paths.LogDir)\step3-migrate-$VMName-$(Get-Date -Format 'yyyyMMdd').log" }

$target = Resolve-MigrationTarget -Config $Config -VmwareClusterName $VmwareCluster -LogFile $LogFile
if (-not $HyperVHost)    { $HyperVHost    = $target.HyperVHost }
if (-not $HyperVHost2)   { $HyperVHost2   = $target.HyperVHost2 }
if (-not $HyperVCluster) { $HyperVCluster = $target.HyperVCluster }
if (-not $ClusterStorage){ $ClusterStorage = $target.ClusterStorage }
if (-not $BackupTag)     { $BackupTag     = $Config.Tags.BackupTag }

if ($ForceNetworkConfigOnly) {
    $SkipInstantRecoveryStart = $true
    $SkipInstantRecoveryFinalization = $true
}

# ── Chargement des modules step3/ ──────────────────────────────────────────
$step3Dir = "$PSScriptRoot\step3"
foreach ($mod in @('Step3.TaskResult','Step3.VeeamRecovery','Step3.NetworkMapping',
                   'Step3.NetworkConfig','Step3.PostConfig','Step3.ConnectScvmm',
                   'Step3.ScvmmSession.Functions')) {
    $path = Join-Path $step3Dir "$mod.ps1"
    if (Test-Path $path) { . $path }
    else { Write-MigrationLog "[$VMName] Module $mod.ps1 absent — sera nécessaire." -Level WARNING -LogFile $LogFile }
}
if (Test-Path "$step3Dir\Step3.ScvmmSession.Functions.ps1") {
    Initialize-ScvmmSessionFunction -FunctionFiles @("$step3Dir\Step3.ScvmmSession.Functions.ps1")
}

# ── Modules requis ─────────────────────────────────────────────────────────
Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback
if (-not $SkipInstantRecoveryStart -or -not $SkipInstantRecoveryFinalization) {
    Import-RequiredModule -Name "Veeam.Backup.PowerShell" -LogFile $LogFile -UseWindowsPowerShellFallback
}

# ── Helpers ────────────────────────────────────────────────────────────────
function Should-RunPhase {
    param([string]$Name)
    if ($Phases) { return $Name -in $Phases }
    switch ($Name) {
        'IRStart'              { return -not $SkipInstantRecoveryStart }
        'IRCommit'             { return -not $SkipInstantRecoveryFinalization }
        { $_ -in @('Network','IntegrationServices','OS','HA','LiveMigration','BackupTag') } { return -not $SkipNetworkAndPostConfig }
        default                { return $true }
    }
}

function Invoke-Phase {
    param(
        [string]$Name,
        [string]$DisplayName,
        [scriptblock]$Action,
        [bool]$NonBlocking = $false
    )
    if (-not (Should-RunPhase $Name)) {
        Add-Step3PhaseResult -Result $result -Phase $DisplayName -Status 'Skipped' -Message "Désactivée"
        return
    }
    try {
        & $Action
        Add-Step3PhaseResult -Result $result -Phase $DisplayName -Status 'Success' -Message 'OK'
    } catch {
        $status = if ($NonBlocking) { 'Warning' } else { 'Failed' }
        Add-Step3PhaseResult -Result $result -Phase $DisplayName -Status $status -Message $_.Exception.Message
        if (-not $NonBlocking) { throw }
    }
}

# ── Contexte et TaskResult ─────────────────────────────────────────────────
$context = @{
    VMName = $VMName; VlanId = $VlanId; BackupJobName = $BackupJobName
    SCVMMServer = $SCVMMServer; HyperVHost = $HyperVHost; HyperVHost2 = $HyperVHost2
    HyperVCluster = $HyperVCluster; ClusterStorage = $ClusterStorage; BackupTag = $BackupTag
    OperatingSystem = $OperatingSystem; Remark = $Remark
    AdapterVlanMapJson = $AdapterVlanMapJson
    WaitingTimeoutSeconds = $WaitingTimeoutSeconds
    WaitingPollIntervalSeconds = $WaitingPollIntervalSeconds
    Config = $Config; LogFile = $LogFile
}
$result = New-Step3TaskResult -Context $context

# ── Phase 1 : Connexion SCVMM ──────────────────────────────────────────────
$VMMServerName = Invoke-SCVMMCommand -ScriptBlock {
    param($s) $srv = Get-SCVMMServer -ComputerName $s; if (-not $srv) { throw "SCVMM $s introuvable" }; $srv.Name
} -ArgumentList @($SCVMMServer)
$context.VMMServerName = $VMMServerName
Add-Step3PhaseResult -Result $result -Phase 'ScvmmConnection' -Status 'Success' -Message $VMMServerName

# ── Phase 2 : Instant Recovery — Start + Wait ──────────────────────────────
Invoke-Phase -Name 'IRStart' -DisplayName 'InstantRecoveryStart' -Action {
    Start-VmInstantRecovery -Context $context -Result $result
    Wait-InstantRecoveryUserAction -Context $context -Result $result
}

# ── Phase 3 : Instant Recovery — Finalization (Commit) ─────────────────────
Invoke-Phase -Name 'IRCommit' -DisplayName 'InstantRecoveryCommit' -Action {
    Complete-InstantRecovery -Context $context -Result $result
}

# ── Phase 4 : Configuration réseau ─────────────────────────────────────────
if (Should-RunPhase 'Network') {
    $adapterVlanMappings = @()
    if ($AdapterVlanMapJson) {
        try { $adapterVlanMappings = @(ConvertFrom-Json $AdapterVlanMapJson -ErrorAction Stop) }
        catch { Write-MigrationLog "[$VMName] JSON VLAN invalide, fallback VLAN ${VlanId}: $_" -Level WARNING -LogFile $LogFile }
    }
    $context.AdapterVlanMappings = $adapterVlanMappings
}
Invoke-Phase -Name 'Network' -DisplayName 'NetworkConfiguration' -Action {
    Set-VmNetworkConfiguration -Context $context -Result $result
}

# ── Phases 5-9 : Post-configuration (non-bloquantes sauf Network) ─────────
Invoke-Phase -Name 'IntegrationServices' -DisplayName 'IntegrationServices' -NonBlocking -Action {
    Set-VmIntegrationServices -Context $context -Result $result
}
Invoke-Phase -Name 'OS' -DisplayName 'OperatingSystem' -NonBlocking -Action {
    Set-SCVMMOperatingSystem -Context $context -Result $result
}
Invoke-Phase -Name 'HA' -DisplayName 'HighAvailability' -NonBlocking -Action {
    Register-VmHighAvailability -Context $context -Result $result
}
Invoke-Phase -Name 'LiveMigration' -DisplayName 'LiveMigration' -NonBlocking -Action {
    Move-VmToSecondHost -Context $context -Result $result
}
Invoke-Phase -Name 'BackupTag' -DisplayName 'BackupTag' -NonBlocking -Action {
    Set-VmBackupTag -Context $context -Result $result
}

# ── Finalisation ───────────────────────────────────────────────────────────
Complete-Step3TaskResult -Result $result
Write-Step3TaskResult -Result $result -Path "$LogFile.result.json"
Write-MigrationLog "[$VMName] Migration terminée — Status: $($result.Status)" -Level SUCCESS -LogFile $LogFile
$result