#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Create a new SCVMM library share and copy the
    NTFS and SMB permissions from a source library.

.DESCRIPTION
    The script:
      1. reads the source SMB share and its permissions;
      2. creates the destination root folder;
      3. copies the NTFS DACL from the source root;
      4. creates the ISO and Template subfolders;
      5. creates the destination SMB share;
      6. replaces its SMB permissions with those from the source share;
      7. adds the share to the SCVMM library;
      8. forces a library refresh.

    The script is idempotent: it can be run again. If the SMB share exists
    already, its path must match DestinationLocalPath.

.PARAMETER VMMServer
    FQDN or NetBIOS name of the SCVMM server used for library registration.

.PARAMETER SourceLibraryShare
    UNC path of the source library whose NTFS/SMB permissions are used as the reference.

.PARAMETER DestinationLibraryServer
    FQDN or NetBIOS name of the file server that hosts the new library.

.PARAMETER DestinationLocalPath
    Local root folder path to create or validate on the destination server.

.PARAMETER DestinationShareName
    SMB share name to create or validate for the destination library.

.PARAMETER ChildFolders
    Subfolders to ensure under the destination root after applying the DACL.

.PARAMETER Description
    Description applied to the SMB share and SCVMM library share.

.PARAMETER CopyNtfsPermissions
    Copy the NTFS DACL from the source root to the destination root when set to $true.

.PARAMETER CopySmbPermissions
    Replace destination SMB permissions with those from the source share when set to $true.

.PARAMETER AddLibraryServerIfMissing
    Add the destination server as a SCVMM Library Server if it is not already declared.

.PARAMETER SkipVMMRegistration
    Prepare only the folder and SMB share, without registering the share in SCVMM.

.PARAMETER ComputerCredential
    Credentials used for CIM/PowerShell Remoting connections to the file servers.

.PARAMETER LibraryServerCredential
    Administrator credentials required by SCVMM to add the library server when needed.

.NOTES
    - Run from a server that has the SCVMM console/cmdlets,
      unless -SkipVMMRegistration is used.
    - The current account must administer the source and destination
      file servers unless ComputerCredential is provided.
    - The NTFS copy covers the DACL (rights and inheritance), not the
      owner or audit SACL.
    - This version targets a standalone Windows file server. For a
      highly available/SOFS library, share creation must be
      adapted to the cluster ScopeName/role.

.EXAMPLE
    .\New-SCVMMContentLibrary.ps1 `
        -VMMServer "scvmm01.contoso.local" `
        -SourceLibraryShare "\\lib01\MSSCVMMLibrary" `
        -DestinationLibraryServer "lib02.contoso.local" `
        -DestinationLocalPath "D:\SCVMM\ContentLibrary" `
        -DestinationShareName "SCVMMContentLibrary" `
        -AddLibraryServerIfMissing

.EXAMPLE
    $cred = Get-Credential "CONTOSO\svc-scvmm"
    .\New-SCVMMContentLibrary.ps1 `
        -VMMServer "scvmm01.contoso.local" `
        -SourceLibraryShare "\\lib01\MSSCVMMLibrary" `
        -DestinationLibraryServer "lib01.contoso.local" `
        -DestinationLocalPath "E:\SCVMM\NewLibrary" `
        -DestinationShareName "NewLibrary" `
        -ComputerCredential $cred
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMMServer,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\\\\[^\\]+\\[^\\]+$')]
    [string]$SourceLibraryShare,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationLibraryServer,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]:\\')]
    [string]$DestinationLocalPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^\\/:*?"<>|]+$')]
    [string]$DestinationShareName,

    [ValidateNotNullOrEmpty()]
    [string[]]$ChildFolders = @('ISO', 'Template'),

    [ValidateNotNullOrEmpty()]
    [string]$Description = 'SCVMM content library',

    [bool]$CopyNtfsPermissions = $true,

    [bool]$CopySmbPermissions = $true,

    [switch]$AddLibraryServerIfMissing,

    [switch]$SkipVMMRegistration,

    [PSCredential]$ComputerCredential,

    [PSCredential]$LibraryServerCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Split-UncSharePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -notmatch '^\\\\(?<Server>[^\\]+)\\(?<Share>[^\\]+)$') {
        throw "Path '$Path' must designate the root of a UNC share, for example \\server\share."
    }

    [pscustomobject]@{
        Server = $Matches.Server
        Share  = $Matches.Share
    }
}

function New-ManagedCimSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [PSCredential]$Credential
    )

    $parameters = @{
        ComputerName = $ComputerName
        ErrorAction  = 'Stop'
    }

    if ($Credential) {
        $parameters.Credential = $Credential
    }

    New-CimSession @parameters
}

function Invoke-ManagedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [PSCredential]$Credential
    )

    $parameters = @{
        ComputerName = $ComputerName
        ScriptBlock  = $ScriptBlock
        ArgumentList = $ArgumentList
        ErrorAction  = 'Stop'
    }

    if ($Credential) {
        $parameters.Credential = $Credential
    }

    Invoke-Command @parameters
}

function Sync-SmbShareAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimSession]$SourceCimSession,

        [Parameter(Mandatory = $true)]
        [string]$SourceShareName,

        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimSession]$DestinationCimSession,

        [Parameter(Mandatory = $true)]
        [string]$DestinationShareName
    )

    $sourceAccess = @(
        Get-SmbShareAccess `
            -CimSession $SourceCimSession `
            -Name $SourceShareName `
            -ErrorAction Stop
    )

    if ($sourceAccess.Count -eq 0) {
        throw "Source share '$SourceShareName' does not contain any SMB permissions."
    }

    $destinationAccess = @(
        Get-SmbShareAccess `
            -CimSession $DestinationCimSession `
            -Name $DestinationShareName `
            -ErrorAction Stop
    )

    # Remove existing SMB ACEs to obtain an exact copy.
    foreach ($ace in $destinationAccess) {
        if ([string]$ace.AccessControlType -eq 'Allow') {
            Revoke-SmbShareAccess `
                -CimSession $DestinationCimSession `
                -Name $DestinationShareName `
                -AccountName $ace.AccountName `
                -Force `
                -Confirm:$false `
                -ErrorAction Stop | Out-Null
        }
        elseif ([string]$ace.AccessControlType -eq 'Deny') {
            Unblock-SmbShareAccess `
                -CimSession $DestinationCimSession `
                -Name $DestinationShareName `
                -AccountName $ace.AccountName `
                -Force `
                -Confirm:$false `
                -ErrorAction Stop | Out-Null
        }
    }

    # Apply allowed entries, then explicit denies.
    foreach ($ace in $sourceAccess | Where-Object { [string]$_.AccessControlType -eq 'Allow' }) {
        Grant-SmbShareAccess `
            -CimSession $DestinationCimSession `
            -Name $DestinationShareName `
            -AccountName $ace.AccountName `
            -AccessRight ([string]$ace.AccessRight) `
            -Force `
            -Confirm:$false `
            -ErrorAction Stop | Out-Null
    }

    foreach ($ace in $sourceAccess | Where-Object { [string]$_.AccessControlType -eq 'Deny' }) {
        Block-SmbShareAccess `
            -CimSession $DestinationCimSession `
            -Name $DestinationShareName `
            -AccountName $ace.AccountName `
            -Force `
            -Confirm:$false `
            -ErrorAction Stop | Out-Null
    }
}

$source = Split-UncSharePath -Path $SourceLibraryShare
$destinationUnc = "\\{0}\{1}" -f $DestinationLibraryServer, $DestinationShareName

if ($SourceLibraryShare.TrimEnd('\') -ieq $destinationUnc.TrimEnd('\')) {
    throw 'The source library and destination library cannot be identical.'
}

$target = "SCVMM library '$destinationUnc' on '$DestinationLibraryServer'"
$action = 'Create/validate the SMB share, synchronize permissions, and register in SCVMM'

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    return
}

$sourceCim = $null
$destinationCim = $null

try {
    Write-Step "Connecting to SMB servers"
    $sourceCim = New-ManagedCimSession `
        -ComputerName $source.Server `
        -Credential $ComputerCredential

    if ($source.Server -ieq $DestinationLibraryServer) {
        $destinationCim = $sourceCim
    }
    else {
        $destinationCim = New-ManagedCimSession `
            -ComputerName $DestinationLibraryServer `
            -Credential $ComputerCredential
    }

    Write-Step "Reading source share $SourceLibraryShare"
    $sourceShare = Get-SmbShare `
        -CimSession $sourceCim `
        -Name $source.Share `
        -ErrorAction Stop

    $sourceSddl = $null

    if ($CopyNtfsPermissions) {
        Write-Step 'Reading source NTFS DACL'

        $sourceSddl = Invoke-ManagedCommand `
            -ComputerName $source.Server `
            -Credential $ComputerCredential `
            -ArgumentList @($sourceShare.Path) `
            -ScriptBlock {
                param([string]$SourceLocalPath)

                $acl = Get-Acl -LiteralPath $SourceLocalPath -ErrorAction Stop
                $sections = [System.Security.AccessControl.AccessControlSections]::Access
                $acl.GetSecurityDescriptorSddlForm($sections)
            }
    }

    Write-Step "Creating and preparing folder $DestinationLocalPath"

    Invoke-ManagedCommand `
        -ComputerName $DestinationLibraryServer `
        -Credential $ComputerCredential `
        -ArgumentList @(
            $DestinationLocalPath,
            $sourceSddl,
            [bool]$CopyNtfsPermissions,
            ($ChildFolders -join "`0")
        ) `
        -ScriptBlock {
            param(
                [string]$DestinationPath,
                [string]$SourceSddl,
                [bool]$ApplyNtfsPermissions,
                [string]$FoldersSerialized
            )

            $Folders = @($FoldersSerialized -split "`0" | Where-Object { $_ })

            if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
                New-Item -Path $DestinationPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            if ($ApplyNtfsPermissions) {
                $destinationAcl = Get-Acl -LiteralPath $DestinationPath -ErrorAction Stop
                $sections = [System.Security.AccessControl.AccessControlSections]::Access

                # Replace only the DACL. The owner and SACL remain
                # those of the destination folder.
                $destinationAcl.SetSecurityDescriptorSddlForm($SourceSddl, $sections)
                Set-Acl `
                    -LiteralPath $DestinationPath `
                    -AclObject $destinationAcl `
                    -ErrorAction Stop
            }

            # Create after DACL application so folders
            # inherit permissions from the root.
            foreach ($folder in $Folders) {
                $childPath = Join-Path -Path $DestinationPath -ChildPath $folder
                if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
                    New-Item -Path $childPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
            }
        } | Out-Null

    Write-Step "Creating or validating SMB share $destinationUnc"

    $destinationShare = Get-SmbShare `
        -CimSession $destinationCim `
        -Name $DestinationShareName `
        -ErrorAction SilentlyContinue

    if ($destinationShare) {
        if ($destinationShare.Path.TrimEnd('\') -ine $DestinationLocalPath.TrimEnd('\')) {
            throw "Share '$DestinationShareName' already exists but points to '$($destinationShare.Path)' instead of '$DestinationLocalPath'."
        }

        Write-Verbose "SMB share '$DestinationShareName' already exists."
    }
    else {
        $bootstrapAccount = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

        $newShareParameters = @{
            CimSession            = $destinationCim
            Name                  = $DestinationShareName
            Path                  = $DestinationLocalPath
            Description           = $Description
            FullAccess            = $bootstrapAccount
            CachingMode           = [string]$sourceShare.CachingMode
            FolderEnumerationMode = [string]$sourceShare.FolderEnumerationMode
            EncryptData           = [bool]$sourceShare.EncryptData
            ErrorAction           = 'Stop'
        }

        $destinationShare = New-SmbShare @newShareParameters
    }

    if ($CopySmbPermissions) {
        Write-Step 'Copying SMB permissions from source to destination'

        Sync-SmbShareAccess `
            -SourceCimSession $sourceCim `
            -SourceShareName $source.Share `
            -DestinationCimSession $destinationCim `
            -DestinationShareName $DestinationShareName
    }

    if (-not $SkipVMMRegistration) {
        Write-Step "Connecting to SCVMM $VMMServer"
        Import-Module VirtualMachineManager -ErrorAction Stop
        $vmmConnection = Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop

        Write-Step "Checking library server $DestinationLibraryServer"
        $libraryServer = Get-SCLibraryServer `
            -VMMServer $vmmConnection `
            -ComputerName $DestinationLibraryServer `
            -ErrorAction SilentlyContinue

        if (-not $libraryServer) {
            if (-not $AddLibraryServerIfMissing) {
                throw @"
Server '$DestinationLibraryServer' is not declared as a Library Server in SCVMM.
Run again with -AddLibraryServerIfMissing, or add it first in the SCVMM console.
"@
            }

            if (-not $LibraryServerCredential) {
                throw "Le serveur '$DestinationLibraryServer' doit être ajouté à SCVMM, mais -LibraryServerCredential n'a pas été fourni. Relancez avec -LibraryServerCredential pour rester compatible avec une exécution non interactive."
            }

            Write-Step "Adding $DestinationLibraryServer as Library Server"
            Add-SCLibraryServer `
                -VMMServer $vmmConnection `
                -ComputerName $DestinationLibraryServer `
                -Credential $LibraryServerCredential `
                -ErrorAction Stop | Out-Null

            $libraryServer = Get-SCLibraryServer `
                -VMMServer $vmmConnection `
                -ComputerName $DestinationLibraryServer `
                -ErrorAction Stop
        }

        $libraryShare = Get-SCLibraryShare -VMMServer $vmmConnection |
            Where-Object {
                $sharePathProperty = $_.PSObject.Properties['SharePath']
                $registeredSharePath = if ($sharePathProperty) {
                    [string]$sharePathProperty.Value
                }
                else {
                    $null
                }

                ($registeredSharePath -and $registeredSharePath.TrimEnd('\') -ieq $destinationUnc.TrimEnd('\')) -or
                (
                    $_.Name -ieq $DestinationShareName -and
                    $_.LibraryServer.Name -ieq $libraryServer.Name
                )
            } |
            Select-Object -First 1

        if (-not $libraryShare) {
            Write-Step "Registering $destinationUnc in the SCVMM library"

            $addLibraryShareParameters = @{
                VMMServer   = $vmmConnection
                SharePath   = $destinationUnc
                Description = $Description
                ErrorAction = 'Stop'
            }

            if ($LibraryServerCredential) {
                $addLibraryShareParameters.Credential = $LibraryServerCredential
            }

            $libraryShare = Add-SCLibraryShare @addLibraryShareParameters
        }
        else {
            Write-Verbose "The share is already registered in SCVMM."
        }

        Write-Step 'Refreshing the SCVMM library'
        Read-SCLibraryShare `
            -LibraryShare $libraryShare `
            -ErrorAction Stop | Out-Null
    }

    Write-Step 'Final check'

    $finalShareAccess = Get-SmbShareAccess `
        -CimSession $destinationCim `
        -Name $DestinationShareName `
        -ErrorAction Stop

    [pscustomobject]@{
        VMMServer                = $VMMServer
        SourceLibraryShare       = $SourceLibraryShare
        DestinationLibraryShare  = $destinationUnc
        DestinationLocalPath     = $DestinationLocalPath
        ChildFolders             = $ChildFolders -join ', '
        NtfsPermissionsCopied    = $CopyNtfsPermissions
        SmbPermissionsCopied     = $CopySmbPermissions
        RegisteredInVMM          = -not $SkipVMMRegistration
        SmbPermissionCount       = @($finalShareAccess).Count
        Status                   = 'OK'
    }

    Write-Host ''
    Write-Host 'Applied SMB permissions:' -ForegroundColor Green
    $finalShareAccess |
        Sort-Object AccountName, AccessControlType |
        Format-Table AccountName, AccessControlType, AccessRight -AutoSize
}
finally {
    if ($destinationCim -and $destinationCim -ne $sourceCim) {
        $destinationCim | Remove-CimSession -ErrorAction SilentlyContinue
    }

    if ($sourceCim) {
        $sourceCim | Remove-CimSession -ErrorAction SilentlyContinue
    }
}
