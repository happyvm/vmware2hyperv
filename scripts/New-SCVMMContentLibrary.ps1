#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Cree un nouveau partage de bibliotheque SCVMM et recopie les permissions
    NTFS et SMB d'une bibliotheque source.

.DESCRIPTION
    Le script :
      1. lit le partage SMB source et ses permissions ;
      2. cree le dossier racine de destination ;
      3. copie la DACL NTFS de la racine source ;
      4. cree les sous-dossiers ISO et Template ;
      5. cree le partage SMB de destination ;
      6. remplace ses permissions SMB par celles du partage source ;
      7. ajoute le partage a la bibliotheque SCVMM ;
      8. force un refresh de la bibliotheque.

    Le script est idempotent : il peut etre relance. Si le partage SMB existe
    deja, son chemin doit correspondre a DestinationLocalPath.

.NOTES
    - A executer depuis un serveur disposant de la console/cmdlets SCVMM.
    - Le compte courant doit administrer les serveurs de fichiers source et
      destination, sauf si ComputerCredential est fourni.
    - La copie NTFS porte sur la DACL (droits et heritage), pas sur le
      proprietaire ni sur la SACL d'audit.
    - Cette version cible un serveur de fichiers Windows autonome. Pour une
      bibliotheque hautement disponible/SOFS, la creation du partage doit etre
      adaptee au ScopeName/role de cluster.

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

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMMServer,

    [Parameter(Mandatory)]
    [ValidatePattern('^\\\\[^\\]+\\[^\\]+$')]
    [string]$SourceLibraryShare,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationLibraryServer,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z]:\\')]
    [string]$DestinationLocalPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^\\/:*?"<>|]+$')]
    [string]$DestinationShareName,

    [ValidateNotNullOrEmpty()]
    [string[]]$ChildFolders = @('ISO', 'Template'),

    [ValidateNotNullOrEmpty()]
    [string]$Description = 'Bibliotheque de contenu SCVMM',

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
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Split-UncSharePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -notmatch '^\\\\(?<Server>[^\\]+)\\(?<Share>[^\\]+)$') {
        throw "Le chemin '$Path' doit designer la racine d'un partage UNC, par exemple \\serveur\partage."
    }

    [pscustomobject]@{
        Server = $Matches.Server
        Share  = $Matches.Share
    }
}

function New-ManagedCimSession {
    param(
        [Parameter(Mandatory)]
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
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
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
    param(
        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimSession]$SourceCimSession,

        [Parameter(Mandatory)]
        [string]$SourceShareName,

        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimSession]$DestinationCimSession,

        [Parameter(Mandatory)]
        [string]$DestinationShareName
    )

    $sourceAccess = @(
        Get-SmbShareAccess `
            -CimSession $SourceCimSession `
            -Name $SourceShareName `
            -ErrorAction Stop
    )

    if ($sourceAccess.Count -eq 0) {
        throw "Le partage source '$SourceShareName' ne contient aucune permission SMB."
    }

    $destinationAccess = @(
        Get-SmbShareAccess `
            -CimSession $DestinationCimSession `
            -Name $DestinationShareName `
            -ErrorAction Stop
    )

    # Suppression des ACE SMB existantes afin d'obtenir une copie exacte.
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

    # Application des autorisations, puis des refus explicites.
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
    throw 'La bibliotheque source et la bibliotheque de destination ne peuvent pas etre identiques.'
}

$sourceCim = $null
$destinationCim = $null

try {
    Write-Step "Connexion aux serveurs SMB"
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

    Write-Step "Lecture du partage source $SourceLibraryShare"
    $sourceShare = Get-SmbShare `
        -CimSession $sourceCim `
        -Name $source.Share `
        -ErrorAction Stop

    $sourceSddl = $null

    if ($CopyNtfsPermissions) {
        Write-Step 'Lecture de la DACL NTFS source'

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

    Write-Step "Creation et preparation du dossier $DestinationLocalPath"

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

                # Remplace uniquement la DACL. Le proprietaire et la SACL restent
                # ceux du dossier de destination.
                $destinationAcl.SetSecurityDescriptorSddlForm($SourceSddl, $sections)
                Set-Acl `
                    -LiteralPath $DestinationPath `
                    -AclObject $destinationAcl `
                    -ErrorAction Stop
            }

            # Creation apres application de la DACL pour que les dossiers
            # heritent des droits de la racine.
            foreach ($folder in $Folders) {
                $childPath = Join-Path -Path $DestinationPath -ChildPath $folder
                if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
                    New-Item -Path $childPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
            }
        } | Out-Null

    Write-Step "Creation ou validation du partage SMB $destinationUnc"

    $destinationShare = Get-SmbShare `
        -CimSession $destinationCim `
        -Name $DestinationShareName `
        -ErrorAction SilentlyContinue

    if ($destinationShare) {
        if ($destinationShare.Path.TrimEnd('\') -ine $DestinationLocalPath.TrimEnd('\')) {
            throw "Le partage '$DestinationShareName' existe deja mais pointe vers '$($destinationShare.Path)' au lieu de '$DestinationLocalPath'."
        }

        Write-Verbose "Le partage SMB '$DestinationShareName' existe deja."
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
        Write-Step 'Copie des permissions SMB source vers destination'

        Sync-SmbShareAccess `
            -SourceCimSession $sourceCim `
            -SourceShareName $source.Share `
            -DestinationCimSession $destinationCim `
            -DestinationShareName $DestinationShareName
    }

    if (-not $SkipVMMRegistration) {
        Write-Step "Connexion a SCVMM $VMMServer"
        Import-Module VirtualMachineManager -ErrorAction Stop
        $vmmConnection = Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop

        Write-Step "Verification du serveur de bibliotheque $DestinationLibraryServer"
        $libraryServer = Get-SCLibraryServer `
            -VMMServer $vmmConnection `
            -ComputerName $DestinationLibraryServer `
            -ErrorAction SilentlyContinue

        if (-not $libraryServer) {
            if (-not $AddLibraryServerIfMissing) {
                throw @"
Le serveur '$DestinationLibraryServer' n'est pas declare comme Library Server dans SCVMM.
Relancez avec -AddLibraryServerIfMissing, ou ajoutez-le d'abord dans la console SCVMM.
"@
            }

            if (-not $LibraryServerCredential) {
                $LibraryServerCredential = Get-Credential `
                    -Message "Compte administrateur du serveur de bibliotheque $DestinationLibraryServer"
            }

            Write-Step "Ajout de $DestinationLibraryServer comme Library Server"
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
            Write-Step "Enregistrement de $destinationUnc dans la bibliotheque SCVMM"

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
            Write-Verbose "Le partage est deja enregistre dans SCVMM."
        }

        Write-Step 'Refresh de la bibliotheque SCVMM'
        Read-SCLibraryShare `
            -LibraryShare $libraryShare `
            -ErrorAction Stop | Out-Null
    }

    Write-Step 'Controle final'

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
    Write-Host 'Permissions SMB appliquees :' -ForegroundColor Green
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
