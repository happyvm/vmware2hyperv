<#
.SYNOPSIS
    VMware migration batching pre-check script.

.DESCRIPTION
    - Reads an input CSV containing: vmname;tag
    - tag = migration batch name
    - Creates/applies a vSphere tag in a Single-cardinality category
    - Computes per batch:
        - VM count
        - configured vCPUs
        - configured RAM
        - datastore committed storage
    - Reads the NB_last_backup custom attribute
    - Retrieves uptime in days via VMware Tools:
        - Linux
        - Windows 2003 and later (wmic for 2003/2008, CIM for 2012+)
    - Flags VMs whose uptime exceeds $UptimeThresholdDays days
    - For Windows 2003 / 2008 / 2008 R2:
        - runs ipconfig /all
        - stores the output in C:\temp inside the VM
    - Tries up to 5 local Windows credentials
    - Exports the label of the credential that succeeded
    - Creates a root marker file on each non-CD-ROM Windows volume from inside the guest OS
      and removes CD-ROM drive letters without requiring a reboot (Windows 2003 through 2025)

    All configurable values (defaults, guest account usernames) are read from
    config.psd1 located in the same folder as the script, layered with
    config.local.psd1 if present (operator overrides — see configure-migration.ps1).
    Parameters supplied explicitly on the command line always take priority.

.INPUT CSV
    vmname;tag
    SRV-APP-001;LOT-01
    SRV-DB-001;LOT-01
    SRV-LIN-001;LOT-02

.OUTPUT
    migration_lot_detail.csv
    migration_lot_summary.csv
    migration_lot_errors.csv

.PARAMETER VCenter
    vCenter server hostname or IP. Can also be set via the VCenter.Server key in
    config.psd1 or config.local.psd1.

.PARAMETER InputCsv
    Path to the input CSV file. Can also be set via the Precheck.InputCsv key in
    config.psd1 or config.local.psd1.

.PARAMETER LogFile
    Path to a log file. If empty (default), output goes to the console only.

.PARAMETER UptimeThresholdDays
    Uptime threshold in days above which UptimeOverThreshold is set to true (default: 45).

.PARAMETER CsvDelimiter
    CSV delimiter used for reading the input file and writing output files (default: ;).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VCenter  = "",

    [string]$InputCsv = "",

    [string]$OutputFolder = ".",

    [string]$TagCategoryName = "MigrationLot",

    [string]$CustomAttributeName = "NB_last_backup",

    [int]$ToolsWaitSecs = 20,

    [switch]$SkipGuestOperations,

    [string]$LogFile = "",

    [int]$UptimeThresholdDays = 45,

    [string]$CsvDelimiter = ";"
)

# ============================================================
# Load config.psd1, layered with config.local.psd1 (operator overrides —
# see Import-MigrationConfig in lib.ps1). Explicit CLI parameters always
# take priority over both files.
# Passwords are never stored in the config file.
# ============================================================

. "$PSScriptRoot\lib.ps1"

$script:ConfigFilePath = Join-Path $PSScriptRoot "config.psd1"

if (-not (Test-Path -LiteralPath $script:ConfigFilePath)) {
    throw "Configuration file not found: $script:ConfigFilePath"
}

$cfg = Import-MigrationConfig -ConfigFile $script:ConfigFilePath

# Safe hashtable lookup. Avoids the ?? operator (PowerShell 7 only) so the script
# still parses and runs under Windows PowerShell 5.1.
function Get-PrecheckConfigValue {
    param(
        $Section,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        $Default = $null
    )

    if ($Section -is [hashtable] -and $Section.ContainsKey($Key) -and $null -ne $Section[$Key]) {
        return $Section[$Key]
    }

    return $Default
}

$precheckCfg = Get-PrecheckConfigValue -Section $cfg -Key 'Precheck' -Default @{}

if (-not $PSBoundParameters.ContainsKey('VCenter')) {
    $vcenterCfg = Get-PrecheckConfigValue -Section $cfg -Key 'VCenter'
    $VCenter = if ($vcenterCfg -is [hashtable]) {
        [string](Get-PrecheckConfigValue -Section $vcenterCfg -Key 'Server' -Default '')
    }
    else {
        [string]$vcenterCfg
    }
}

# Config overrides the parameter default; an explicit CLI parameter always wins.
if (-not $PSBoundParameters.ContainsKey('InputCsv'))            { $InputCsv            = [string](Get-PrecheckConfigValue -Section $precheckCfg -Key 'InputCsv'            -Default $InputCsv) }
if (-not $PSBoundParameters.ContainsKey('OutputFolder'))        { $OutputFolder        = [string](Get-PrecheckConfigValue -Section $precheckCfg -Key 'OutputFolder'        -Default $OutputFolder) }
if (-not $PSBoundParameters.ContainsKey('TagCategoryName'))     { $TagCategoryName     = [string](Get-PrecheckConfigValue -Section $precheckCfg -Key 'TagCategoryName'     -Default $TagCategoryName) }
if (-not $PSBoundParameters.ContainsKey('CustomAttributeName')) { $CustomAttributeName = [string](Get-PrecheckConfigValue -Section $precheckCfg -Key 'CustomAttributeName' -Default $CustomAttributeName) }
if (-not $PSBoundParameters.ContainsKey('ToolsWaitSecs'))       { $ToolsWaitSecs       = [int](Get-PrecheckConfigValue    -Section $precheckCfg -Key 'ToolsWaitSecs'       -Default $ToolsWaitSecs) }
if (-not $PSBoundParameters.ContainsKey('LogFile'))             { $LogFile             = [string](Get-PrecheckConfigValue -Section $precheckCfg -Key 'LogFile'             -Default $LogFile) }
if (-not $PSBoundParameters.ContainsKey('UptimeThresholdDays')) { $UptimeThresholdDays = [int](Get-PrecheckConfigValue    -Section $precheckCfg -Key 'UptimeThresholdDays' -Default $UptimeThresholdDays) }
if (-not $PSBoundParameters.ContainsKey('CsvDelimiter'))        { $CsvDelimiter        = [string](Get-PrecheckConfigValue -Section $precheckCfg -Key 'CsvDelimiter'        -Default $CsvDelimiter) }

if ([string]::IsNullOrWhiteSpace($VCenter))  { throw "VCenter address is required (parameter -VCenter or config key 'VCenter.Server')." }
if ([string]::IsNullOrWhiteSpace($InputCsv)) { throw "Input CSV path is required (parameter -InputCsv or config key 'Precheck.InputCsv')." }

# Windows credentials — usernames and labels only; passwords are prompted at runtime.
$WindowsCredentialDefinitions = @(
    foreach ($entry in @(Get-PrecheckConfigValue -Section $precheckCfg -Key 'WindowsCredentials' -Default @())) {
        [PSCustomObject]@{
            Label    = [string]$entry.Label
            UserName = [string]$entry.UserName
            Enabled  = [bool]$entry.Enabled
        }
    }
)

# Linux credential
$linuxCredentialCfg = Get-PrecheckConfigValue -Section $precheckCfg -Key 'LinuxCredential' -Default @{}

$LinuxCredentialDefinition = [PSCustomObject]@{
    Label    = [string](Get-PrecheckConfigValue -Section $linuxCredentialCfg -Key 'Label'    -Default 'LINUX-ADMIN-01')
    UserName = [string](Get-PrecheckConfigValue -Section $linuxCredentialCfg -Key 'UserName' -Default 'root')
    Enabled  = [bool](Get-PrecheckConfigValue   -Section $linuxCredentialCfg -Key 'Enabled'  -Default $true)
}

# ============================================================
# Functions
# ============================================================

function Write-ExecutionLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $ts   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts][$Level] $Message"

    switch ($Level) {
        "WARN"  { Write-Warning $line }
        "ERROR" { Write-Error $line }
        default { Write-Information $line -InformationAction Continue }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        $line | Out-File -FilePath $script:LogPath -Append -Encoding UTF8
    }
}

function Resolve-VMView {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$VmIndex,

        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    if (-not $VmIndex.ContainsKey($VMName)) {
        return [PSCustomObject]@{ View = $null; Error = "VM not found in vCenter" }
    }

    $vmMatches = @($VmIndex[$VMName])

    if ($vmMatches.Count -gt 1) {
        return [PSCustomObject]@{ View = $null; Error = "Ambiguous VM name: multiple VMs share this name in vCenter" }
    }

    return [PSCustomObject]@{ View = $vmMatches[0]; Error = $null }
}

function Get-WindowsYearFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    # Explicit year in the guest OS full name.
    switch -Regex ($Text) {
        "2003" { return 2003 }
        "2008" { return 2008 }
        "2012" { return 2012 }
        "2016" { return 2016 }
        "2019" { return 2019 }
        "2022" { return 2022 }
        "2025" { return 2025 }
    }

    # vSphere GuestId families that do not spell out the year (the full name can
    # be empty or stale when VMware Tools is old, which is common on 2003):
    #   winNet*         -> Windows Server 2003 (".NET Server")
    #   winLonghorn*    -> Windows Server 2008
    #   windows7Server* -> Windows Server 2008 R2
    #   windows8Server* -> Windows Server 2012 / 2012 R2
    #   windows9Server* -> Windows Server 2016+
    switch -Regex ($Text) {
        "(?i)winNet(Standard|Enterprise|Datacenter|Web|Business)" { return 2003 }
        "(?i)winLonghorn"                                         { return 2008 }
        "(?i)windows7Server"                                      { return 2008 }
        "(?i)windows8Server"                                      { return 2012 }
        "(?i)windows9Server"                                      { return 2016 }
    }

    return $null
}

function Get-GuestFamily {
    param(
        [string]$GuestFullName,
        [string]$GuestId
    )

    $text = "$GuestFullName $GuestId"

    if ($text -match "(?i)\bwindows?\b") {
        return "Windows"
    }

    # vSphere GuestId families without a standalone "windows" word — the same
    # identifiers Get-WindowsYearFromText decodes (GuestFullName can be empty or
    # stale when VMware Tools is old, which is common on 2003):
    #   winNet* / winLonghorn* / windows7Server* / windows8Server* / windows9Server*
    if ($text -match "(?i)winNet(Standard|Enterprise|Datacenter|Web|Business)|winLonghorn|windows\d+Server") {
        return "Windows"
    }

    if ($text -match "(?i)linux|ubuntu|debian|centos|red hat|rhel|suse|oracle linux|rocky|alma") {
        return "Linux"
    }

    return "Unknown"
}

function Test-VMwareToolsRunning {
    param(
        $VMView
    )

    $runningStatus = [string]$VMView.Guest.ToolsRunningStatus
    $legacyStatus  = [string]$VMView.Guest.ToolsStatus

    return (
        $runningStatus -eq "guestToolsRunning" -or
        $legacyStatus -eq "toolsOk"
    )
}

function Invoke-GuestScriptSafe {
    param(
        [Parameter(Mandatory = $true)]
        $VMObject,

        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PowerShell", "Bat", "Bash")]
        [string]$ScriptType,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$GuestCredential,

        [int]$ToolsWaitSecs = 20
    )

    try {
        $result = Invoke-VMScript `
            -VM $VMObject `
            -ScriptText $ScriptText `
            -ScriptType $ScriptType `
            -GuestCredential $GuestCredential `
            -ToolsWaitSecs $ToolsWaitSecs `
            -ErrorAction Stop

        return [PSCustomObject]@{
            Success = $true
            Output  = ($result.ScriptOutput -replace "`r", "").Trim()
            Error   = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            Output  = $null
            Error   = $_.Exception.Message
        }
    }
}

function Invoke-WindowsGuestScriptWithCredentialFallback {
    param(
        [Parameter(Mandatory = $true)]
        $VMObject,

        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PowerShell", "Bat")]
        [string]$ScriptType,

        [Parameter(Mandatory = $true)]
        [object[]]$AuthCandidates,

        [string]$PreferredAuthLabel,

        [int]$ToolsWaitSecs = 20
    )

    if (-not $AuthCandidates -or $AuthCandidates.Count -eq 0) {
        return [PSCustomObject]@{
            Success         = $false
            Output          = $null
            Error           = "No Windows credential candidates provided."
            CredentialLabel = $null
            CredentialUser  = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredAuthLabel)) {
        $ordered = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $AuthCandidates) {
            if ($c.Label -eq $PreferredAuthLabel) { $ordered.Insert(0, $c) } else { $ordered.Add($c) }
        }
        $orderedCandidates = $ordered
    }
    else {
        $orderedCandidates = $AuthCandidates
    }

    $attemptErrors = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in $orderedCandidates) {
        $result = Invoke-GuestScriptSafe `
            -VMObject $VMObject `
            -ScriptText $ScriptText `
            -ScriptType $ScriptType `
            -GuestCredential $candidate.Credential `
            -ToolsWaitSecs $ToolsWaitSecs

        if ($result.Success) {
            return [PSCustomObject]@{
                Success         = $true
                Output          = $result.Output
                Error           = $null
                CredentialLabel = $candidate.Label
                CredentialUser  = $candidate.UserName
            }
        }

        $attemptErrors.Add("$($candidate.Label) / $($candidate.UserName) : $($result.Error)")
    }

    return [PSCustomObject]@{
        Success         = $false
        Output          = $null
        Error           = ($attemptErrors -join " || ")
        CredentialLabel = $null
        CredentialUser  = $null
    }
}

function Get-UptimeDaysFromWmicOutput {
    param(
        [string]$WmicOutput
    )

    if ([string]::IsNullOrWhiteSpace($WmicOutput)) {
        return $null
    }

    if ($WmicOutput -match "LastBootUpTime=([0-9]{14})") {
        $datePart = $Matches[1]

        try {
            $bootTime = [datetime]::ParseExact(
                $datePart,
                "yyyyMMddHHmmss",
                [System.Globalization.CultureInfo]::InvariantCulture
            )

            return [math]::Round(((Get-Date) - $bootTime).TotalDays, 2)
        }
        catch {
            return $null
        }
    }

    return $null
}

function Resolve-LotTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LotName,

        [Parameter(Mandatory = $true)]
        $Category
    )

    if ($script:tagCache.ContainsKey($LotName)) {
        return $script:tagCache[$LotName]
    }

    $tagObject = Get-Tag -Name $LotName -Category $Category -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $tagObject) {
        $tagObject = New-Tag -Name $LotName -Category $Category -ErrorAction Stop
    }

    $script:tagCache[$LotName] = $tagObject
    return $tagObject
}

# ============================================================
# Preparation
# ============================================================

$script:LogPath = $LogFile

if (-not (Test-Path $InputCsv)) {
    throw "Input CSV not found: $InputCsv"
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$detailCsv  = Join-Path $OutputFolder "migration_lot_detail.csv"
$summaryCsv = Join-Path $OutputFolder "migration_lot_summary.csv"
$errorCsv   = Join-Path $OutputFolder "migration_lot_errors.csv"

foreach ($file in @($detailCsv, $summaryCsv, $errorCsv)) {
    if (Test-Path $file) {
        Remove-Item -Path $file -Force
    }
}

Write-ExecutionLog ("Reading CSV: {0}" -f $InputCsv)
$rawRows = @(Import-Csv -Path $InputCsv -Delimiter $CsvDelimiter)
Write-ExecutionLog ("{0} row(s) loaded" -f $rawRows.Count)

if (-not $rawRows -or $rawRows.Count -eq 0) {
    throw "The CSV is empty."
}

$columns = @($rawRows[0].PSObject.Properties.Name)
$normalizedColumnMap = @{}

foreach ($column in $columns) {
    $normalized = ([string]$column).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($normalized) -and -not $normalizedColumnMap.ContainsKey($normalized)) {
        $normalizedColumnMap[$normalized] = $column
    }
}

if (-not $normalizedColumnMap.ContainsKey("vmname") -or -not $normalizedColumnMap.ContainsKey("tag")) {
    $detectedColumns = ($columns -join ", ")
    throw "CSV must contain columns: vmname, tag. Detected columns: $detectedColumns"
}

$vmNameColumn = $normalizedColumnMap["vmname"]
$tagColumn    = $normalizedColumnMap["tag"]

$inputRows = @(
    foreach ($row in $rawRows) {
        $vmName = ([string]$row.$vmNameColumn).Trim()
        $lot    = ([string]$row.$tagColumn).Trim()

        if (-not [string]::IsNullOrWhiteSpace($vmName) -and -not [string]::IsNullOrWhiteSpace($lot)) {
            [PSCustomObject]@{
                VMName = $vmName
                Lot    = $lot
            }
        }
    }
)

$inputRows = @($inputRows | Sort-Object VMName, Lot -Unique)

if (-not $inputRows -or $inputRows.Count -eq 0) {
    throw "No usable rows found in the CSV."
}

$vmInMultipleLots = @(
    $inputRows |
        Group-Object VMName |
        Where-Object {
            @($_.Group.Lot | Sort-Object -Unique).Count -gt 1
        }
)

if ($vmInMultipleLots.Count -gt 0) {
    $badVMs = ($vmInMultipleLots | Select-Object -ExpandProperty Name) -join ", "
    throw "Batching error: some VMs appear in multiple lots: $badVMs"
}

# ============================================================
# vCenter connection
# ============================================================

$script:ConnectedByScript = $false

$existingSession = @(
    (Get-Variable -Name 'DefaultVIServers' -Scope Global -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue) |
    Where-Object { $_.Name -eq $VCenter -and $_.IsConnected }
)

if ($existingSession.Count -gt 0) {
    Write-ExecutionLog "Reusing existing vCenter session for $VCenter"
}
else {
    Write-ExecutionLog "WARNING: vCenter SSL certificate validation is disabled for this session (InvalidCertificateAction = Ignore, Scope Session)." -Level WARN
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

    try {
        Connect-VIServer -Server $VCenter -ErrorAction Stop | Out-Null
        $script:ConnectedByScript = $true
    }
    catch {
        throw "Cannot connect to $VCenter : $_"
    }
}

try {
    # ========================================================
    # Single-cardinality tag category
    # ========================================================

    $tagCategory = Get-TagCategory -Name $TagCategoryName -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $tagCategory) {
        $tagCategory = New-TagCategory `
            -Name $TagCategoryName `
            -Cardinality Single `
            -EntityType VirtualMachine `
            -ErrorAction Stop
    }
    else {
        if ($tagCategory.Cardinality -ne "Single") {
            throw "Tag category '$TagCategoryName' already exists but is not Single cardinality."
        }

        $entityTypes = @($tagCategory.EntityType | ForEach-Object { [string]$_ })

        if ($entityTypes.Count -gt 0 -and $entityTypes -notcontains "VirtualMachine") {
            throw "Tag category '$TagCategoryName' already exists but does not apply to VirtualMachine."
        }
    }

    # ========================================================
    # NB_last_backup custom attribute
    # ========================================================

    $serviceInstance    = Get-View ServiceInstance
    $customFieldsManager = Get-View $serviceInstance.Content.CustomFieldsManager

    $backupField = $customFieldsManager.Field |
        Where-Object {
            $_.Name -eq $CustomAttributeName -and
            ($null -eq $_.ManagedObjectType -or $_.ManagedObjectType -eq "VirtualMachine")
        } |
        Select-Object -First 1

    if (-not $backupField) {
        Write-ExecutionLog "Custom attribute '$CustomAttributeName' not found. Column will be empty." -Level WARN
    }

    # ========================================================
    # Load VM views from vCenter
    # ========================================================

    # Server-side name filter to avoid loading all VMs from vCenter.
    # Get-View filters by "contains"; $vmIndex enforces exact-name resolution.
    # Names are queried in chunks so the regex filter stays small even for large
    # CSVs, and views are de-duplicated by MoRef because a "contains" match can
    # return the same VM from more than one chunk.
    $viewProperties = @(
        'Name',
        'Runtime.PowerState',
        'Summary.Config',
        'Summary.Storage',
        'Config.GuestFullName',
        'Config.GuestId',
        'Guest.GuestFullName',
        'Guest.GuestId',
        'Guest.ToolsStatus',
        'Guest.ToolsRunningStatus',
        'CustomValue'
    )

    $vmNames       = @($inputRows.VMName)
    $nameChunkSize = 100
    $allVmViews    = [System.Collections.Generic.List[object]]::new()

    for ($chunkStart = 0; $chunkStart -lt $vmNames.Count; $chunkStart += $nameChunkSize) {
        $chunkEnd    = [math]::Min($chunkStart + $nameChunkSize, $vmNames.Count) - 1
        $namePattern = ($vmNames[$chunkStart..$chunkEnd] | ForEach-Object { [regex]::Escape($_) }) -join '|'

        foreach ($view in @(Get-View -ViewType VirtualMachine -Filter @{ "Name" = $namePattern } -Property $viewProperties)) {
            $allVmViews.Add($view)
        }
    }

    $vmIndex      = @{}
    $seenVmMoRefs = @{}

    foreach ($vmView in $allVmViews) {
        $moRefKey = [string]$vmView.MoRef

        if ($seenVmMoRefs.ContainsKey($moRefKey)) { continue }
        $seenVmMoRefs[$moRefKey] = $true

        if (-not $vmIndex.ContainsKey($vmView.Name)) {
            $vmIndex[$vmView.Name] = [System.Collections.Generic.List[object]]::new()
        }

        $vmIndex[$vmView.Name].Add($vmView)
    }

    # ========================================================
    # Tag assignment
    # ========================================================

    Write-ExecutionLog "Starting VM tagging"

    # Single bulk query for the whole category instead of one Get-TagAssignment
    # call per VM (N+1 avoidance). Entries are indexed by entity Id.
    $assignmentsByEntityId = @{}

    try {
        foreach ($assignment in @(Get-TagAssignment -Category $tagCategory -ErrorAction Stop)) {
            $entityId = [string]$assignment.Entity.Id

            if (-not $assignmentsByEntityId.ContainsKey($entityId)) {
                $assignmentsByEntityId[$entityId] = [System.Collections.Generic.List[object]]::new()
            }

            $assignmentsByEntityId[$entityId].Add($assignment)
        }
    }
    catch {
        Write-ExecutionLog "Bulk tag assignment lookup failed ($($_.Exception.Message)); falling back to per-VM queries." -Level WARN
        $assignmentsByEntityId = $null
    }

    $script:tagCache   = @{}
    $tagStatusByVmLot  = @{}
    $vmObjectCache     = @{}
    $detailRows        = New-Object System.Collections.Generic.List[object]
    $errorRows         = New-Object System.Collections.Generic.List[object]

    $tagCounter = 0
    $tagTotal   = $inputRows.Count

    foreach ($row in $inputRows) {
        $tagCounter++
        $vmName  = $row.VMName
        $lotName = $row.Lot
        $rowKey  = "$vmName||$lotName"
        $tagStatusByVmLot[$rowKey] = "NotProcessed"

        Write-Progress -Activity "Tagging VMs" `
            -Status ("VM {0}/{1}: {2} (batch {3})" -f $tagCounter, $tagTotal, $vmName, $lotName) `
            -PercentComplete (($tagCounter / $tagTotal) * 100)

        Write-Verbose ("Tagging {0}/{1}: {2} (batch {3})" -f $tagCounter, $tagTotal, $vmName, $lotName)

        $resolved = Resolve-VMView -VmIndex $vmIndex -VMName $vmName

        if ($resolved.Error) {
            continue
        }

        try {
            $vmObject = Get-VIObjectByVIView -VIView $resolved.View -ErrorAction Stop
            $vmObjectCache[$vmName] = $vmObject
            $lotTag = Resolve-LotTag -LotName $lotName -Category $tagCategory
            $currentAssignments = if ($null -ne $assignmentsByEntityId) {
                $vmEntityId = [string]$vmObject.Id
                if ($assignmentsByEntityId.ContainsKey($vmEntityId)) { @($assignmentsByEntityId[$vmEntityId]) } else { @() }
            }
            else {
                @(Get-TagAssignment -Entity $vmObject -Category $tagCategory -ErrorAction SilentlyContinue)
            }
            $assignmentsToRemove = @($currentAssignments | Where-Object { $_.Tag.Name -ne $lotName })

            if ($assignmentsToRemove.Count -gt 0 -and $PSCmdlet.ShouldProcess($vmName, "Remove existing tag '$($assignmentsToRemove[0].Tag.Name)'")) {
                $assignmentsToRemove | Remove-TagAssignment -Confirm:$false | Out-Null
            }

            $alreadyAssigned = @($currentAssignments | Where-Object { $_.Tag.Name -eq $lotName })

            if ($alreadyAssigned.Count -eq 0) {
                if ($PSCmdlet.ShouldProcess($vmName, "Assign tag '$lotName'")) {
                    New-TagAssignment -Tag $lotTag -Entity $vmObject -ErrorAction Stop | Out-Null
                    $tagStatusByVmLot[$rowKey] = "Assigned"
                }
                else {
                    $tagStatusByVmLot[$rowKey] = "WhatIf"
                }
            }
            else {
                $tagStatusByVmLot[$rowKey] = "AlreadyAssigned"
            }
        }
        catch {
            $tagStatusByVmLot[$rowKey] = "TagError"
            $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = $_.Exception.Message })
        }
    }

    Write-Progress -Activity "Tagging VMs" -Completed
    Write-ExecutionLog "VM tagging complete"

    # ========================================================
    # Determine which guest credentials are needed
    # ========================================================

    $needWindowsCredentials = $false
    $needLinuxCredential    = $false

    if (-not $SkipGuestOperations) {
        foreach ($row in $inputRows) {
            $resolved = Resolve-VMView -VmIndex $vmIndex -VMName $row.VMName

            if ($resolved.Error) { continue }

            $vmView = $resolved.View

            if ($vmView.Runtime.PowerState -ne "poweredOn") { continue }
            if (-not (Test-VMwareToolsRunning -VMView $vmView)) { continue }

            $guestFullName = $vmView.Guest.GuestFullName
            if ([string]::IsNullOrWhiteSpace($guestFullName)) { $guestFullName = $vmView.Config.GuestFullName }

            $guestId = $vmView.Guest.GuestId
            if ([string]::IsNullOrWhiteSpace($guestId)) { $guestId = $vmView.Config.GuestId }

            $guestFamily = Get-GuestFamily -GuestFullName $guestFullName -GuestId $guestId

            if ($guestFamily -eq "Windows") { $needWindowsCredentials = $true }
            if ($guestFamily -eq "Linux")   { $needLinuxCredential    = $true }
        }
    }

    $windowsGuestCredentials        = [System.Collections.Generic.List[object]]::new()
    $linuxGuestCredential           = $null
    $preferredWindowsCredentialLabel = $null

    Write-ExecutionLog "Starting credential prompts"

    if (-not $SkipGuestOperations -and $needWindowsCredentials) {
        foreach ($definition in ($WindowsCredentialDefinitions | Where-Object { $_.Enabled -eq $true })) {
            $credential = Get-Credential `
                -UserName $definition.UserName `
                -Message "Password for Windows account [$($definition.Label)] - $($definition.UserName)"

            if ($null -eq $credential) { throw "Windows credential prompt cancelled ([$($definition.Label)])." }

            $windowsGuestCredentials.Add([PSCustomObject]@{
                Label      = $definition.Label
                UserName   = $credential.UserName
                Credential = $credential
            })
        }
    }

    if (-not $SkipGuestOperations -and $needLinuxCredential -and $LinuxCredentialDefinition.Enabled -eq $true) {
        $credential = Get-Credential `
            -UserName $LinuxCredentialDefinition.UserName `
            -Message "Password for Linux account [$($LinuxCredentialDefinition.Label)] - $($LinuxCredentialDefinition.UserName)"

        if ($null -eq $credential) { throw "Linux credential prompt cancelled ([$($LinuxCredentialDefinition.Label)])." }

        $linuxGuestCredential = [PSCustomObject]@{
            Label      = $LinuxCredentialDefinition.Label
            UserName   = $credential.UserName
            Credential = $credential
        }
    }

    Write-ExecutionLog "Credential prompts complete"

    # ========================================================
    # Main processing loop
    # ========================================================

    $vmCounter = 0
    $vmTotal   = $inputRows.Count

    foreach ($row in $inputRows) {
        $vmCounter++
        $vmName  = $row.VMName
        $lotName = $row.Lot

        Write-Progress -Activity "Processing VMs" `
            -Status ("VM {0}/{1}: {2} (batch {3})" -f $vmCounter, $vmTotal, $vmName, $lotName) `
            -PercentComplete (($vmCounter / $vmTotal) * 100)

        Write-ExecutionLog ("Processing VM {0}/{1}: {2} (batch {3})" -f $vmCounter, $vmTotal, $vmName, $lotName)

        $resolved = Resolve-VMView -VmIndex $vmIndex -VMName $vmName

        if ($resolved.Error) {
            $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = $resolved.Error })
            continue
        }

        $vmView = $resolved.View

        if ($vmObjectCache.ContainsKey($vmName)) {
            $vmObject = $vmObjectCache[$vmName]
        }
        else {
            try {
                $vmObject = Get-VIObjectByVIView -VIView $vmView -ErrorAction Stop
                $vmObjectCache[$vmName] = $vmObject
            }
            catch {
                Write-ExecutionLog "Cannot resolve VIView object for $vmName : $_" -Level ERROR
                $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = "VIView resolution failed: $_" })
                continue
            }
        }

        $rowKey   = "$vmName||$lotName"
        $tagStatus = if ($tagStatusByVmLot.ContainsKey($rowKey)) { $tagStatusByVmLot[$rowKey] } else { "NotProcessed" }
        # ----------------------------------------------------
        # NB_last_backup
        # ----------------------------------------------------

        $lastBackup = $null

        if ($backupField -and $vmView.CustomValue) {
            $customValue = $vmView.CustomValue |
                Where-Object { $_.Key -eq $backupField.Key } |
                Select-Object -First 1

            if ($customValue) { $lastBackup = $customValue.Value }
        }

        # ----------------------------------------------------
        # Configured capacity / datastore committed storage
        # ----------------------------------------------------

        $vCpuConfigured  = [int]$vmView.Summary.Config.NumCpu
        $ramConfiguredGB = [math]::Round(($vmView.Summary.Config.MemorySizeMB / 1024), 2)

        $storageUsedGB = 0
        if ($vmView.Summary.Storage -and $null -ne $vmView.Summary.Storage.Committed) {
            $storageUsedGB = [math]::Round(($vmView.Summary.Storage.Committed / 1GB), 2)
        }

        # ----------------------------------------------------
        # OS detection
        # ----------------------------------------------------

        $guestFullName = $vmView.Guest.GuestFullName
        if ([string]::IsNullOrWhiteSpace($guestFullName)) { $guestFullName = $vmView.Config.GuestFullName }

        $guestId = $vmView.Guest.GuestId
        if ([string]::IsNullOrWhiteSpace($guestId)) { $guestId = $vmView.Config.GuestId }

        $guestFamily = Get-GuestFamily -GuestFullName $guestFullName -GuestId $guestId
        $windowsYear = $null

        if ($guestFamily -eq "Windows") {
            $windowsYear = Get-WindowsYearFromText -Text "$guestFullName $guestId"
        }

        $toolsRunning = Test-VMwareToolsRunning -VMView $vmView

        # ----------------------------------------------------
        # Guest operation variables
        # ----------------------------------------------------

        $uptimeStatus    = "Skipped"
        $uptimeDays      = $null
        $uptimeOverThreshold      = $false
        $guestOperationError      = $null

        $ipconfigStatus  = "Skipped"
        $ipconfigPath    = $null
        $ipconfigError   = $null

        $cdRomDisableStatus   = "Skipped"
        $cdRomDriveCount      = $null
        $volumeMarkerFileCount = $null
        $cdRomDisableError    = $null

        $windowsCredentialLabelUsed     = $null
        $windowsCredentialUserUsed      = $null
        $windowsCredentialAttemptErrors = $null

        $linuxCredentialLabelUsed  = $null
        $linuxCredentialUserUsed   = $null

        # ----------------------------------------------------
        # VMware Tools guest operations
        # ----------------------------------------------------

        if (-not $SkipGuestOperations) {
            if ($vmView.Runtime.PowerState -ne "poweredOn") {
                $uptimeStatus        = "SkippedPoweredOff"
                $ipconfigStatus      = "SkippedPoweredOff"
                $cdRomDisableStatus = "SkippedPoweredOff"
            }
            elseif (-not $toolsRunning) {
                $uptimeStatus        = "SkippedToolsNotRunning"
                $ipconfigStatus      = "SkippedToolsNotRunning"
                $cdRomDisableStatus = "SkippedToolsNotRunning"
            }
            else {
                # ------------------------------
                # Linux: uptime in days
                # ------------------------------
                if ($guestFamily -eq "Linux") {
                    if ($null -eq $linuxGuestCredential) {
                        $uptimeStatus        = "Error"
                        $guestOperationError = "No Linux credential configured or provided."
                        $linuxCredentialLabelUsed = "NoCredentialConfigured"
                    }
                    else {
                        $linuxScript = @'
awk '{print $1}' /proc/uptime
'@

                        $uptimeResult = Invoke-GuestScriptSafe `
                            -VMObject $vmObject `
                            -ScriptText $linuxScript `
                            -ScriptType Bash `
                            -GuestCredential $linuxGuestCredential.Credential `
                            -ToolsWaitSecs $ToolsWaitSecs

                        if ($uptimeResult.Success) {
                            $rawSeconds    = ($uptimeResult.Output -replace ",", ".").Trim()
                            $parsedSeconds = 0.0

                            if ([double]::TryParse(
                                $rawSeconds,
                                [System.Globalization.NumberStyles]::Float,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [ref]$parsedSeconds
                            )) {
                                $uptimeDays          = [math]::Round(($parsedSeconds / 86400), 2)
                                $uptimeOverThreshold = [bool]($uptimeDays -gt $UptimeThresholdDays)
                                $uptimeStatus        = "OK"

                                $linuxCredentialLabelUsed = $linuxGuestCredential.Label
                                $linuxCredentialUserUsed  = $linuxGuestCredential.UserName
                            }
                            else {
                                $uptimeStatus        = "ParseError"
                                $guestOperationError = "Failed to parse Linux uptime output: $($uptimeResult.Output)"
                            }
                        }
                        else {
                            $uptimeStatus             = "Error"
                            $guestOperationError      = $uptimeResult.Error
                            $linuxCredentialLabelUsed = "CredentialError"
                        }
                    }

                    $ipconfigStatus      = "NotApplicable"
                    $cdRomDisableStatus = "NotApplicable"
                }

                # ------------------------------
                # Windows
                # ------------------------------
                if ($guestFamily -eq "Windows") {
                    $isWindows2003 = ($windowsYear -eq 2003)
                    $isWindows2008 = ($windowsYear -eq 2008)

                    if (-not $windowsGuestCredentials -or $windowsGuestCredentials.Count -eq 0) {
                        $windowsCredentialLabelUsed = "NoCredentialConfigured"
                    }

                    # Create marker files on non-CD-ROM volumes, then remove CD-ROM drive letters
                    # from inside the guest OS without requiring a reboot.
                    # Windows 2003/2008 use WMIC from cmd.exe; Windows 2012+ uses PowerShell/CIM.
                    if ($null -ne $windowsYear -and $windowsYear -ge 2012) {
                        $windowsCdRomDisableScript = @'
$ErrorActionPreference = "Stop"
$removed = 0
$volumeMarkerFiles = 0
$removeErrors = 0
$volumeMarkerErrors = 0
$volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType <> 5" -ErrorAction SilentlyContinue)
if (-not $volumes -or $volumes.Count -eq 0) {
    $volumes = @(Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType <> 5" -ErrorAction SilentlyContinue)
}
foreach ($volume in $volumes) {
    $volumeLetter = ([string]$volume.DeviceID).Trim()
    if (-not [string]::IsNullOrWhiteSpace($volumeLetter)) {
        $letter = $volumeLetter.Substring(0, 1).ToLowerInvariant()
        $markerPath = "${volumeLetter}\$letter.txt"
        try {
            Set-Content -Path $markerPath -Value "Volume marker for $volumeLetter" -Encoding ASCII -Force
            $volumeMarkerFiles++
        }
        catch {
            $volumeMarkerErrors++
        }
    }
}
$cdRomDrives = @(Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction SilentlyContinue)
if (-not $cdRomDrives -or $cdRomDrives.Count -eq 0) {
    $cdRomDrives = @(Get-WmiObject -Class Win32_CDROMDrive -ErrorAction SilentlyContinue)
}
foreach ($drive in $cdRomDrives) {
    $driveLetter = ([string]$drive.Drive).Trim()
    if (-not [string]::IsNullOrWhiteSpace($driveLetter)) {
        & mountvol $driveLetter /D | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $removed++
        }
        else {
            $removeErrors++
        }
    }
}
Write-Output "VOLUME_MARKER_FILES_CREATED=$volumeMarkerFiles;CDROM_DRIVE_LETTERS_REMOVED=$removed;VOLUME_MARKER_FILE_ERRORS=$volumeMarkerErrors;CDROM_DRIVE_LETTER_REMOVE_ERRORS=$removeErrors"
'@
                        $cdRomScriptType = "PowerShell"
                    }
                    else {
                        $windowsCdRomDisableScript = @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set CDROM_REMOVED=0
set VOLUME_MARKER_FILES=0
set VOLUME_MARKER_ERRORS=0
set CDROM_REMOVE_ERRORS=0
for /f "skip=1 tokens=1" %%V in ('%windir%\system32\wbem\wmic.exe logicaldisk where "DriveType ^<^> 5" get DeviceID 2^>nul') do (
    if not "%%V"=="" (
        set "VOLUME_DRIVE=%%V"
        set "VOLUME_LETTER=!VOLUME_DRIVE:~0,1!"
        for %%L in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do if /I "!VOLUME_LETTER!"=="%%L" set "VOLUME_LETTER=%%L"
        > "!VOLUME_DRIVE!\!VOLUME_LETTER!.txt" echo Volume marker for !VOLUME_DRIVE!
        if errorlevel 1 (
            set /a VOLUME_MARKER_ERRORS+=1
        ) else (
            set /a VOLUME_MARKER_FILES+=1
        )
    )
)
for /f "skip=1 tokens=1" %%D in ('%windir%\system32\wbem\wmic.exe cdrom get Drive 2^>nul') do (
    if not "%%D"=="" (
        %windir%\system32\mountvol.exe %%D /D > nul
        if errorlevel 1 (
            set /a CDROM_REMOVE_ERRORS+=1
        ) else (
            set /a CDROM_REMOVED+=1
        )
    )
)
echo VOLUME_MARKER_FILES_CREATED=%VOLUME_MARKER_FILES%;CDROM_DRIVE_LETTERS_REMOVED=%CDROM_REMOVED%;VOLUME_MARKER_FILE_ERRORS=%VOLUME_MARKER_ERRORS%;CDROM_DRIVE_LETTER_REMOVE_ERRORS=%CDROM_REMOVE_ERRORS%
'@
                        $cdRomScriptType = "Bat"
                    }

                    $cdRomDisableResult = Invoke-WindowsGuestScriptWithCredentialFallback `
                        -VMObject $vmObject `
                        -ScriptText $windowsCdRomDisableScript `
                        -ScriptType $cdRomScriptType `
                        -AuthCandidates $windowsGuestCredentials `
                        -PreferredAuthLabel $preferredWindowsCredentialLabel `
                        -ToolsWaitSecs $ToolsWaitSecs

                    if ($cdRomDisableResult.Success) {
                        $windowsCredentialLabelUsed      = $cdRomDisableResult.CredentialLabel
                        $windowsCredentialUserUsed       = $cdRomDisableResult.CredentialUser
                        $preferredWindowsCredentialLabel = $cdRomDisableResult.CredentialLabel

                        if ($cdRomDisableResult.Output -match "VOLUME_MARKER_FILES_CREATED=([0-9]+);CDROM_DRIVE_LETTERS_REMOVED=([0-9]+);VOLUME_MARKER_FILE_ERRORS=([0-9]+);CDROM_DRIVE_LETTER_REMOVE_ERRORS=([0-9]+)") {
                            $volumeMarkerFileCount = [int]$Matches[1]
                            $cdRomDriveCount       = [int]$Matches[2]
                            $markerErrorCount      = [int]$Matches[3]
                            $removeErrorCount      = [int]$Matches[4]
                            if ($markerErrorCount -gt 0 -or $removeErrorCount -gt 0) {
                                $cdRomDisableStatus = "Error"
                                $cdRomDisableError  = "Volume marker errors: $markerErrorCount; CD-ROM drive-letter removal errors: $removeErrorCount"
                            }
                            elseif ($cdRomDriveCount -eq 0) {
                                $cdRomDisableStatus = "NoCdRomDriveLetter"
                            }
                            else {
                                $cdRomDisableStatus = "DriveLettersRemovedInGuest"
                            }
                        }
                        else {
                            $cdRomDisableStatus = "VerificationError"
                            $cdRomDisableError  = "Volume marker/CD-ROM removal command did not return the expected verification marker. Output: $($cdRomDisableResult.Output)"
                        }
                    }
                    else {
                        $cdRomDisableStatus          = "Error"
                        $cdRomDisableError           = $cdRomDisableResult.Error
                        $windowsCredentialLabelUsed  = "CredentialError"
                        $windowsCredentialAttemptErrors = (@($windowsCredentialAttemptErrors, $cdRomDisableResult.Error) |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " || "
                    }

                    # Windows 2003/2008: uptime via wmic (CIM/PowerShell not available on these versions)
                    # Windows 2012+: uptime via CIM PowerShell (wmic deprecated since 2012)
                    if ($null -ne $windowsYear -and $windowsYear -ge 2003) {
                        if ($windowsYear -ge 2012) {
                            $windowsUptimeScript = @'
$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Output ("LastBootUpTime={0}" -f $os.LastBootUpTime.ToString("yyyyMMddHHmmss"))
'@
                            $uptimeScriptType = "PowerShell"
                        }
                        else {
                            $windowsUptimeScript = @'
%windir%\system32\wbem\wmic.exe os get LastBootUpTime /value
'@
                            $uptimeScriptType = "Bat"
                        }

                        $uptimeResult = Invoke-WindowsGuestScriptWithCredentialFallback `
                            -VMObject $vmObject `
                            -ScriptText $windowsUptimeScript `
                            -ScriptType $uptimeScriptType `
                            -AuthCandidates $windowsGuestCredentials `
                            -PreferredAuthLabel $preferredWindowsCredentialLabel `
                            -ToolsWaitSecs $ToolsWaitSecs

                        if ($uptimeResult.Success) {
                            $windowsCredentialLabelUsed      = $uptimeResult.CredentialLabel
                            $windowsCredentialUserUsed       = $uptimeResult.CredentialUser
                            $preferredWindowsCredentialLabel = $uptimeResult.CredentialLabel

                            $uptimeDays = Get-UptimeDaysFromWmicOutput -WmicOutput $uptimeResult.Output

                            if ($null -ne $uptimeDays) {
                                $uptimeOverThreshold = [bool]($uptimeDays -gt $UptimeThresholdDays)
                                $uptimeStatus        = "OK"
                            }
                            else {
                                $uptimeStatus        = "ParseError"
                                $guestOperationError = "Failed to parse LastBootUpTime from guest output."
                            }
                        }
                        else {
                            $uptimeStatus                   = "Error"
                            $guestOperationError            = $uptimeResult.Error
                            $windowsCredentialLabelUsed     = "CredentialError"
                            $windowsCredentialAttemptErrors = $uptimeResult.Error
                        }
                    }
                    elseif ($null -eq $windowsYear) {
                        $uptimeStatus = "SkippedUnknownWindowsVersion"
                    }
                    else {
                        $uptimeStatus = "SkippedWindowsTooOld"
                    }

                    # Windows 2003 / 2008 / 2008 R2: run ipconfig /all and store output in C:\temp.
                    # Newer versions: not applicable.
                    #
                    # Known pitfalls on these old guests that this script works around:
                    #   - The VMware Tools guest process can start with a minimal PATH where
                    #     "ipconfig" does not resolve; cmd still exits 0 and Invoke-VMScript
                    #     reports Success=true. Fix: full %windir%\system32 executable paths.
                    #   - Quoting the redirect path ("> "C:\path"") fails silently on old CMD.
                    #     Fix: no quotes (path has no spaces after sanitisation).
                    #   - md/redirect failures are silent in batch. Fix: the script verifies
                    #     its own work and prints an IPCONFIG_RESULT marker parsed below,
                    #     all in a single guest call.
                    #   - Buffer not fully flushed before the guest process exits.
                    #     Fix: trailing ping adds ~1 s delay before the file checks.
                    if ($isWindows2003 -or $isWindows2008) {
                        $safeVmFileName        = ($vmName -replace '[\\/:*?"<>|&^%!()\s]', '_')
                        $ipconfigPathCandidate = "C:\temp\ipconfig_all_$safeVmFileName.txt"

                        $ipconfigScript = @"
@echo off
if not exist C:\temp md C:\temp
if not exist C:\temp (
    echo IPCONFIG_RESULT=TEMP_DIR_CREATE_FAILED
    goto :done
)
%windir%\system32\ipconfig.exe /all > $ipconfigPathCandidate
%windir%\system32\ping.exe -n 2 127.0.0.1 > nul
if not exist $ipconfigPathCandidate (
    echo IPCONFIG_RESULT=FILE_NOT_CREATED
    goto :done
)
for %%A in ($ipconfigPathCandidate) do (
    if %%~zA GTR 0 (
        echo IPCONFIG_RESULT=OK
    ) else (
        echo IPCONFIG_RESULT=FILE_EMPTY
    )
)
:done
"@

                        $ipconfigResult = Invoke-WindowsGuestScriptWithCredentialFallback `
                            -VMObject $vmObject `
                            -ScriptText $ipconfigScript `
                            -ScriptType Bat `
                            -AuthCandidates $windowsGuestCredentials `
                            -PreferredAuthLabel $preferredWindowsCredentialLabel `
                            -ToolsWaitSecs $ToolsWaitSecs

                        if ($ipconfigResult.Success) {
                            $windowsCredentialLabelUsed      = $ipconfigResult.CredentialLabel
                            $windowsCredentialUserUsed       = $ipconfigResult.CredentialUser
                            $preferredWindowsCredentialLabel = $ipconfigResult.CredentialLabel

                            if ($ipconfigResult.Output -match "IPCONFIG_RESULT=OK") {
                                $ipconfigPath   = $ipconfigPathCandidate
                                $ipconfigStatus = "OK"
                            }
                            elseif ($ipconfigResult.Output -match "IPCONFIG_RESULT=TEMP_DIR_CREATE_FAILED") {
                                $ipconfigPath   = "NotPresent"
                                $ipconfigStatus = "Error"
                                $ipconfigError  = "C:\temp could not be created inside the guest (permissions, or C:\temp exists as a file)."
                            }
                            elseif ($ipconfigResult.Output -match "IPCONFIG_RESULT=FILE_EMPTY") {
                                $ipconfigPath   = "NotPresent"
                                $ipconfigStatus = "FileNotCreated"
                                $ipconfigError  = "Output file was created but is empty (ipconfig or redirect failed): $ipconfigPathCandidate"
                            }
                            elseif ($ipconfigResult.Output -match "IPCONFIG_RESULT=FILE_NOT_CREATED") {
                                $ipconfigPath   = "NotPresent"
                                $ipconfigStatus = "FileNotCreated"
                                $ipconfigError  = "ipconfig ran but the output file was not created in the guest: $ipconfigPathCandidate"
                            }
                            else {
                                $ipconfigPath   = "NotPresent"
                                $ipconfigStatus = "VerificationError"
                                $ipconfigError  = "Guest script did not return the expected IPCONFIG_RESULT marker. Output: $($ipconfigResult.Output)"
                            }
                        }
                        else {
                            $ipconfigStatus             = "Error"
                            $ipconfigError              = $ipconfigResult.Error
                            $windowsCredentialLabelUsed = "CredentialError"

                            $windowsCredentialAttemptErrors = (@($windowsCredentialAttemptErrors, $ipconfigResult.Error) |
                                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " || "
                        }
                    }
                    else {
                        $ipconfigStatus = "NotApplicable"
                    }
                }
            }
        }

        if ($cdRomDisableStatus -in @("Error", "VerificationError")) {
            Write-ExecutionLog "Cannot disable CD-ROM device in guest OS for $vmName : $cdRomDisableError" -Level ERROR
            $errorRows.Add([PSCustomObject]@{ VMName = $vmName; Lot = $lotName; Error = "Guest OS CD-ROM disable failed: $cdRomDisableError" })
        }

        # ----------------------------------------------------
        # VM detail row
        # ----------------------------------------------------

        $detailRows.Add([PSCustomObject]@{
            Lot                            = $lotName
            VMName                         = $vmName
            PowerState                     = $vmView.Runtime.PowerState

            GuestFamily                    = $guestFamily
            WindowsYearDetected            = $windowsYear
            VMwareToolsRunning             = $toolsRunning

            CdRomDisableStatus             = $cdRomDisableStatus
            CdRomDriveCount                = $cdRomDriveCount
            VolumeMarkerFileCount          = $volumeMarkerFileCount
            CdRomDisableError              = $cdRomDisableError

            vCPUConfigured                 = $vCpuConfigured
            RAMConfiguredGB                = $ramConfiguredGB
            StorageUsedDatastoreGB         = $storageUsedGB
            NB_last_backup                 = $lastBackup

            UptimeStatus                   = $uptimeStatus
            UptimeDays                     = $uptimeDays
            UptimeOverThreshold            = $uptimeOverThreshold

            IpconfigStatus                 = $ipconfigStatus
            IpconfigPath                   = $ipconfigPath
            IpconfigError                  = $ipconfigError

            WindowsCredentialLabelUsed     = $windowsCredentialLabelUsed
            WindowsCredentialUserUsed      = $windowsCredentialUserUsed
            WindowsCredentialAttemptErrors = $windowsCredentialAttemptErrors

            LinuxCredentialLabelUsed       = $linuxCredentialLabelUsed
            LinuxCredentialUserUsed        = $linuxCredentialUserUsed

            GuestOperationError            = $guestOperationError
            TagStatus                      = $tagStatus
        })
    }

    Write-Progress -Activity "Processing VMs" -Completed

    # ========================================================
    # Per-batch summary
    # ========================================================

    $summaryRows = $detailRows |
        Group-Object Lot |
        ForEach-Object {
            $group = $_.Group

            [PSCustomObject]@{
                Lot                        = $_.Name
                VMCount                    = $group.Count
                PoweredOnVM                = @($group | Where-Object { $_.PowerState -eq "poweredOn" }).Count
                PoweredOffVM               = @($group | Where-Object { $_.PowerState -eq "poweredOff" }).Count
                vCPUConfiguredTotal        = [int](($group | Measure-Object -Property vCPUConfigured -Sum).Sum)
                RAMConfiguredTotalGB       = [math]::Round((($group | Measure-Object -Property RAMConfiguredGB -Sum).Sum), 2)
                StorageUsedTotalGB         = [math]::Round((($group | Measure-Object -Property StorageUsedDatastoreGB -Sum).Sum), 2)
                VMWithoutLastBackup        = @($group | Where-Object { [string]::IsNullOrWhiteSpace($_.NB_last_backup) }).Count
                VMWithUptimeOK             = @($group | Where-Object { $_.UptimeStatus -eq "OK" }).Count
                VMWithUptimeError          = @($group | Where-Object { $_.UptimeStatus -in @("Error", "ParseError") }).Count
                VMWithUptimeSkipped        = @($group | Where-Object { $_.UptimeStatus -like "Skipped*" -or $_.UptimeStatus -eq "NotApplicable" }).Count
                VMWithUptimeOverThreshold  = @($group | Where-Object { $_.UptimeOverThreshold -eq $true }).Count
                VMWithIpconfigOK           = @($group | Where-Object { $_.IpconfigStatus -eq "OK" }).Count
                VMWithIpconfigError        = @($group | Where-Object { $_.IpconfigStatus -in @("Error", "FileNotCreated", "VerificationError") }).Count
                VMWithCdRomDisabled        = @($group | Where-Object { $_.CdRomDisableStatus -eq "DriveLettersRemovedInGuest" }).Count
                VMWithVolumeMarkerFile     = @($group | Where-Object { $_.VolumeMarkerFileCount -gt 0 }).Count
                VMWithCdRomDisableError    = @($group | Where-Object { $_.CdRomDisableStatus -in @("Error", "VerificationError") }).Count
                VMWithTagError             = @($group | Where-Object { $_.TagStatus -eq "TagError" }).Count
            }
        } |
        Sort-Object Lot

    # ========================================================
    # CSV exports
    # ========================================================

    $detailRows |
        Sort-Object Lot, VMName |
        Export-Csv -Path $detailCsv -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter

    $summaryRows |
        Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter

    # Always export the error file (at minimum with the header row).
    # Export-Csv writes nothing at all for an empty collection, so emit the header manually.
    if ($errorRows.Count -gt 0) {
        $errorRows |
            Export-Csv -Path $errorCsv -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter
    }
    else {
        Set-Content -Path $errorCsv -Value ('"VMName"{0}"Lot"{0}"Error"' -f $CsvDelimiter) -Encoding UTF8
    }

    Write-Information "" -InformationAction Continue
    Write-ExecutionLog ("VM detail export   : {0}" -f $detailCsv)
    Write-ExecutionLog ("Batch summary export: {0}" -f $summaryCsv)
    Write-ExecutionLog ("Error export       : {0}" -f $errorCsv)

    $overThreshold = @($detailRows | Where-Object { $_.UptimeOverThreshold -eq $true }).Count
    Write-Information "" -InformationAction Continue
    Write-ExecutionLog "--- Execution summary ---"
    Write-ExecutionLog ("VMs processed: {0} | Structural errors: {1} | Uptime > {2} days: {3}" -f $detailRows.Count, $errorRows.Count, $UptimeThresholdDays, $overThreshold)

    if ($errorRows.Count -gt 0) {
        Write-ExecutionLog ("WARNING: {0} structural error(s) detected — see {1}" -f $errorRows.Count, $errorCsv) -Level WARN
    }

    Write-Information "" -InformationAction Continue
    $summaryRows | Format-Table -AutoSize
}
finally {
    if ($script:ConnectedByScript) {
        Disconnect-VIServer -Server $VCenter -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
}
