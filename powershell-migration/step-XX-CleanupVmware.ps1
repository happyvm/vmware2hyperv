<#
.SYNOPSIS
    Clean up VMware resources after a successful Hyper-V migration.

.DESCRIPTION
    Deletes VMware VMs that are tagged with the given migration batch tag and are
    powered off. Powered-on VMs are skipped (and reported) to avoid accidental
    deletion of active workloads. The VMware tag itself is kept (remove it manually
    once the whole batch is validated).

    This script is meant to run AFTER step3 has completed and all migrated VMs have
    been validated in the Hyper-V environment.

.PARAMETER Tag
    Batch tag identifying the migration lot to clean up (e.g. HypMig-lot-118).

.PARAMETER ConfigFile
    Optional path to a PSD1 configuration file override.

.PARAMETER LogFile
    Path to the log file. Auto-generated if not provided.

.EXAMPLE
    .\step-XX-CleanupVmware.ps1 -Tag HypMig-lot-118

.NOTES
    Part of the vmware2hyperv migration toolkit.
    Requires PowerShell 7+ with VMware.PowerCLI module.
    Always verify migrated VMs are operational before running this script.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Tag,

    [string]$ConfigFile,
    [string]$LogFile
)

. "$PSScriptRoot\lib.ps1"
if (-not $ConfigFile) { $ConfigFile = "$PSScriptRoot\config.psd1" }
Assert-PathPresent -Path $ConfigFile -Label "Configuration file"

$Config = Import-PowerShellDataFile $ConfigFile
$VCenterServer = $Config.VCenter.Server

if (-not $LogFile) { $LogFile = "$($Config.Paths.LogDir)\step-XX-cleanup-vmware-$Tag-$(Get-Date -Format 'yyyyMMdd').log" }

Write-MigrationLog "Starting VMware cleanup step for tag '$Tag'." -LogFile $LogFile

Connect-VCenter -Server $VCenterServer -LogFile $LogFile

try {
    # Scope to the migration category: Remove-VM -DeletePermanently must never act on a
    # same-named tag from another category.
    $vmwareTag = Get-Tag -Name $Tag -Category $Config.Tags.Category -ErrorAction SilentlyContinue
    if (-not $vmwareTag) {
        Write-MigrationLog "Tag '$Tag' not found in VMware. Nothing to cleanup." -Level WARNING -LogFile $LogFile
        return
    }

    $tagAssignments = Get-TagAssignment -Tag $vmwareTag -ErrorAction SilentlyContinue |
        Where-Object { $_.Entity -and $_.Entity.GetType().Name -eq 'VirtualMachine' }

    if (-not $tagAssignments) {
        Write-MigrationLog "No VMware VM found with tag '$Tag'. Nothing to cleanup." -LogFile $LogFile
        return
    }

    $deletedCount = 0
    $skippedPoweredOnCount = 0

    foreach ($assignment in $tagAssignments) {
        $vm = VMware.VimAutomation.Core\Get-VM -Id $assignment.Entity.Id -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-MigrationLog "Unable to resolve VM from tag assignment '$Tag'. Skipping this entry." -Level WARNING -LogFile $LogFile
            continue
        }

        if ($vm.PowerState -eq 'PoweredOn') {
            Write-MigrationLog "Skipping VMware VM '$($vm.Name)' because it is powered on." -Level WARNING -LogFile $LogFile
            $skippedPoweredOnCount++
            continue
        }

        Write-MigrationLog "Deleting VMware VM '$($vm.Name)' (tag '$Tag', state '$($vm.PowerState)')." -Level WARNING -LogFile $LogFile
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false -ErrorAction Stop
        Write-MigrationLog "VMware VM '$($vm.Name)' deleted." -Level SUCCESS -LogFile $LogFile
        $deletedCount++
    }

    Write-MigrationLog "Cleanup summary for tag '$Tag': deleted=$deletedCount, skippedPoweredOn=$skippedPoweredOnCount." -Level SUCCESS -LogFile $LogFile
}
finally {
    Disconnect-VCenter -LogFile $LogFile
}

Write-MigrationLog "step-XX cleanup completed." -Level SUCCESS -LogFile $LogFile
