param (
    [string]$ConfigFile,
    [string]$CsvFile,
    [string]$ExtractIpCsvFile,
    [string]$Tag,
    [int]$PollIntervalSeconds = 60,
    [int]$MaxIterations = 0,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config = Import-PowerShellDataFile $ConfigFile
if (-not $CsvFile) { $CsvFile = $Config.Paths.CsvFile }
Assert-PathPresent -Path $CsvFile -Label "Batch CSV"
if (-not $ExtractIpCsvFile) {
    if ($Config.Paths.ExtractIpCsv) {
        $ExtractIpCsvFile = [string]$Config.Paths.ExtractIpCsv
    } else {
        $batchFolder = Split-Path -Path $CsvFile -Parent
        $ExtractIpCsvFile = Join-Path -Path $batchFolder -ChildPath "extract-ip.csv"
    }
}
Assert-PathPresent -Path $ExtractIpCsvFile -Label "Extract IP CSV"

if (-not $LogFile) {
    $batchLabel = if ([string]::IsNullOrWhiteSpace($Tag)) { 'all' } else { $Tag }
    $LogFile = "$($Config.Paths.LogDir)\step-XX-postcheck-$batchLabel-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

Import-RequiredModule -Name "VirtualMachineManager" -LogFile $LogFile -UseWindowsPowerShellFallback

function Get-BatchVms {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$ExpectedIpMap,

        [string]$BatchTag
    )

    $rows = Import-Csv -Path $Path -Delimiter ";"
    $filteredRows = $rows | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.VMName) -and (
            [string]::IsNullOrWhiteSpace($BatchTag) -or $_.Tag -eq $BatchTag
        )
    }

    $vmRows = foreach ($row in $filteredRows) {
        $vmName = [string]$row.VMName
        $lookupKey = $vmName.ToLowerInvariant()
        $expectedIp = $null
        if ($ExpectedIpMap.ContainsKey($lookupKey)) {
            $expectedIp = [string]$ExpectedIpMap[$lookupKey]
        }

        [pscustomobject]@{
            VMName     = $vmName
            ExpectedIP = $expectedIp
            BatchTag   = [string]$row.Tag
        }
    }

    return @($vmRows | Sort-Object -Property VMName -Unique)
}

function Get-ExpectedIpMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rows = Import-Csv -Path $Path -Delimiter ";"
    $map = @{}

    foreach ($row in $rows) {
        $vmName = Get-FirstPropertyValue -InputObject $row -PropertyNames @(
            'VMName', 'VmName', 'Name', 'NomVM'
        )
        $ip = Get-FirstPropertyValue -InputObject $row -PropertyNames @(
            'ExpectedIP', 'ExpectedIp', 'IPAttendue', 'TargetIP', 'TargetIp', 'IP', 'IPAddress', 'IpAddress'
        )

        if ([string]::IsNullOrWhiteSpace($vmName) -or [string]::IsNullOrWhiteSpace($ip)) {
            continue
        }

        $map[$vmName.ToLowerInvariant()] = $ip
    }

    return $map
}

function Test-SCVMMVmHealth {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [string]$ExpectedIP,

        [string]$ExpectedBackupTag
    )

    return Invoke-SCVMMCommand -ScriptBlock {
        param($VmmServerName, $Name, $IpExpected, $BackupTag)

        $server = Get-SCVMMServer -ComputerName $VmmServerName
        $vm = Get-SCVirtualMachine -Name $Name -VMMServer $server | Select-Object -First 1

        if (-not $vm) {
            return [pscustomobject]@{
                VMName                   = $Name
                ExistsInSCVMM            = $false
                Running                  = $false
                NetworkConnected         = $false
                IntegrationServicesReady = $false
                HighAvailabilityEnabled  = $false
                BackupTagPresent         = $false
                IPMatches                = $false
                CurrentIPs               = @()
                CurrentTag               = $null
                Details                  = "VM introuvable dans SCVMM"
            }
        }

        $statusRaw = @([string]$vm.Status, [string]$vm.StatusString) -join ' '
        $running = $statusRaw -match 'Running|Power.*On|En cours d.?exécution|Démarré'

        $adapters = @(Get-SCVirtualNetworkAdapter -VM $vm -ErrorAction SilentlyContinue)
        $connectedAdapters = @($adapters | Where-Object {
            $state = [string]$_.ConnectionState
            $state -match 'Connected|Connecté|OK|On' -or
            (-not [string]::IsNullOrWhiteSpace([string]$_.VMNetwork)) -or
            (-not [string]::IsNullOrWhiteSpace([string]$_.VMSubnet))
        })
        $networkConnected = $connectedAdapters.Count -gt 0

        $allIps = @(
            foreach ($adapter in $adapters) {
                foreach ($address in @($adapter.IPv4Addresses)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$address)) {
                        [string]$address
                    }
                }
            }
        ) | Select-Object -Unique

        $ipMatches = if ([string]::IsNullOrWhiteSpace($IpExpected)) {
            $true
        } else {
            $allIps -contains $IpExpected
        }

        $integrationSignals = @(
            [string]$vm.HeartbeatStatus,
            [string]$vm.HeartbeatEnabled,
            [string]$vm.GuestAgentStatus,
            [string]$vm.IntegrationServicesState,
            [string]$vm.VMAddition,
            [string]$vm.VirtualMachineState
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $integrationText = ($integrationSignals -join ' ')
        $integrationReady = $false
        if (-not [string]::IsNullOrWhiteSpace($integrationText)) {
            if ($integrationText -match 'OK|Running|Operational|Up|Ready|Responding|Actif|Fonctionnel') {
                $integrationReady = $true
            }
            if ($integrationText -match 'Not|Disabled|Stopped|Error|Unknown|Unavailable|N.?A|Inconnu|Arrêté') {
                $integrationReady = $false
            }
        }

        $highAvailabilityEnabled = [bool]$vm.IsHighlyAvailable

        $currentTag = [string]$vm.Tag
        $backupTagPresent = if ([string]::IsNullOrWhiteSpace($BackupTag)) {
            $true
        } else {
            $currentTag -split ';|,' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $BackupTag } | Measure-Object | Select-Object -ExpandProperty Count
        }
        $backupTagPresent = [bool]$backupTagPresent

        $issues = @()
        if (-not $running) { $issues += 'VM non démarrée' }
        if (-not $networkConnected) { $issues += 'NIC non connectée' }
        if (-not $integrationReady) { $issues += 'Integration Services non OK' }
        if (-not $highAvailabilityEnabled) { $issues += 'High Availability non activée' }
        if (-not $backupTagPresent) { $issues += "Tag backup absent ($BackupTag)" }
        if (-not $ipMatches) { $issues += "IP attendue '$IpExpected' absente" }

        [pscustomobject]@{
            VMName                   = [string]$vm.Name
            ExistsInSCVMM            = $true
            Running                  = [bool]$running
            NetworkConnected         = [bool]$networkConnected
            IntegrationServicesReady = [bool]$integrationReady
            HighAvailabilityEnabled  = [bool]$highAvailabilityEnabled
            BackupTagPresent         = [bool]$backupTagPresent
            IPMatches                = [bool]$ipMatches
            CurrentIPs               = @($allIps)
            CurrentTag               = $currentTag
            Details                  = if ($issues) { $issues -join '; ' } else { 'OK' }
        }
    } -ArgumentList @($ServerName, $VMName, $ExpectedIP, $ExpectedBackupTag)
}

$expectedIpMap = Get-ExpectedIpMap -Path $ExtractIpCsvFile
$batchVms = Get-BatchVms -Path $CsvFile -ExpectedIpMap $expectedIpMap -BatchTag $Tag
if (-not $batchVms) {
    $target = if ([string]::IsNullOrWhiteSpace($Tag)) { 'all rows' } else { "tag '$Tag'" }
    Write-MigrationLog "No VM found in CSV for $target." -Level ERROR -LogFile $LogFile
    exit 1
}

$missingExpectedIp = @($batchVms | Where-Object { [string]::IsNullOrWhiteSpace($_.ExpectedIP) })
if ($missingExpectedIp) {
    Write-MigrationLog "$($missingExpectedIp.Count) VM(s) from lotissement CSV have no matching IP in '$ExtractIpCsvFile'." -Level WARNING -LogFile $LogFile
}

Write-MigrationLog "Starting post-migration checks for $($batchVms.Count) VMs (tag filter: '$Tag')." -LogFile $LogFile
Write-MigrationLog "Loop settings: PollIntervalSeconds=$PollIntervalSeconds; MaxIterations=$MaxIterations (0=infinite)." -LogFile $LogFile

$iteration = 0
$pendingVms = @($batchVms)

while ($pendingVms.Count -gt 0) {
    $iteration++
    Write-MigrationLog "----- Validation iteration #$iteration (pending: $($pendingVms.Count)) -----" -LogFile $LogFile

    $results = foreach ($vmRow in $pendingVms) {
        Test-SCVMMVmHealth -ServerName $Config.SCVMM.Server -VMName $vmRow.VMName -ExpectedIP $vmRow.ExpectedIP -ExpectedBackupTag $Config.Tags.BackupTag
    }

    $results |
        Sort-Object -Property VMName |
        Format-Table -AutoSize VMName, ExistsInSCVMM, Running, NetworkConnected, IntegrationServicesReady, HighAvailabilityEnabled, BackupTagPresent, IPMatches, Details |
        Out-String |
        ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_.Trim())) {
                Write-MigrationLog $_ -LogFile $LogFile
            }
        }

    $failed = @($results | Where-Object {
        -not ($_.ExistsInSCVMM -and $_.Running -and $_.NetworkConnected -and $_.IntegrationServicesReady -and $_.HighAvailabilityEnabled -and $_.BackupTagPresent -and $_.IPMatches)
    })

    if (-not $failed) {
        break
    }

    $pendingNames = @($failed | ForEach-Object { $_.VMName })
    $pendingVms = @($pendingVms | Where-Object { $pendingNames -contains $_.VMName })

    Write-MigrationLog "Iteration #$iteration => $($failed.Count) VM(s) still not compliant." -Level WARNING -LogFile $LogFile
    foreach ($entry in $failed) {
        $ips = if ($entry.CurrentIPs) { $entry.CurrentIPs -join ',' } else { 'none' }
        Write-MigrationLog "[$($entry.VMName)] $($entry.Details) | CurrentIP=$ips | Tag=$($entry.CurrentTag)" -Level WARNING -LogFile $LogFile
    }

    if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) {
        Write-MigrationLog "MaxIterations reached ($MaxIterations). Exiting with non-compliant VMs." -Level ERROR -LogFile $LogFile
        exit 2
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}

Write-MigrationLog "All VMs are compliant after $iteration iteration(s)." -Level SUCCESS -LogFile $LogFile
exit 0
