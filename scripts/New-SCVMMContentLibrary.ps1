#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Crée un nouveau partage de bibliothèque SCVMM et recopie les permissions
    NTFS et SMB d'une bibliothèque source.

.DESCRIPTION
    Le script :
      1. lit le partage SMB source et ses permissions ;
      2. crée le dossier racine de destination ;
      3. copie la DACL NTFS de la racine source ;
      4. crée les sous-dossiers ISO et Template ;
      5. crée le partage SMB de destination ;
      6. remplace ses permissions SMB par celles du partage source ;
      7. ajoute le partage à la bibliothèque SCVMM ;
      8. force un refresh de la bibliothèque.

    Le script est idempotent : il peut être relancé. Si le partage SMB existe
    déjà, son chemin doit correspondre à DestinationLocalPath.

.PARAMETER VMMServer
    Nom FQDN ou NetBIOS du serveur SCVMM à utiliser pour l'enregistrement de la bibliothèque.

.PARAMETER SourceLibraryShare
    Chemin UNC de la bibliothèque source dont les permissions NTFS/SMB servent de référence.

.PARAMETER DestinationLibraryServer
    Nom FQDN ou NetBIOS du serveur de fichiers qui héberge la nouvelle bibliothèque.

.PARAMETER DestinationLocalPath
    Chemin local du dossier racine à créer ou valider sur le serveur de destination.

.PARAMETER DestinationShareName
    Nom du partage SMB à créer ou valider pour la bibliothèque de destination.

.PARAMETER ChildFolders
    Sous-dossiers à garantir sous la racine de destination après application de la DACL.

.PARAMETER Description
    Description appliquée au partage SMB et au partage de bibliothèque SCVMM.

.PARAMETER CopyNtfsPermissions
    Copie la DACL NTFS de la racine source vers la racine de destination lorsque la valeur est $true.

.PARAMETER CopySmbPermissions
    Remplace les permissions SMB de destination par celles du partage source lorsque la valeur est $true.

.PARAMETER AddLibraryServerIfMissing
    Ajoute le serveur de destination comme Library Server SCVMM s'il n'est pas encore déclaré.

.PARAMETER SkipVMMRegistration
    Prépare uniquement le dossier et le partage SMB, sans enregistrer le partage dans SCVMM.

.PARAMETER ComputerCredential
    Identifiants utilisés pour les connexions CIM/PowerShell Remoting vers les serveurs de fichiers.

.PARAMETER LibraryServerCredential
    Identifiants administrateur requis par SCVMM pour ajouter le serveur de bibliothèque si nécessaire.

.NOTES
    - À exécuter depuis un serveur disposant de la console/cmdlets SCVMM,
      sauf lorsque -SkipVMMRegistration est utilisé.
    - Le compte courant doit administrer les serveurs de fichiers source et
      destination, sauf si ComputerCredential est fourni.
    - La copie NTFS porte sur la DACL (droits et héritage), pas sur le
      propriétaire ni sur la SACL d'audit.
    - Cette version cible un serveur de fichiers Windows autonome. Pour une
      bibliothèque hautement disponible/SOFS, la création du partage doit être
      adaptée au ScopeName/role de cluster.

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
    [string]$Description = 'Bibliothèque de contenu SCVMM',

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
        throw "Le chemin '$Path' doit désigner la racine d'un partage UNC, par exemple \\serveur\partage."
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
    throw 'La bibliothèque source et la bibliothèque de destination ne peuvent pas être identiques.'
}

$target = "bibliothèque SCVMM '$destinationUnc' sur '$DestinationLibraryServer'"
$action = 'Créer/valider le partage SMB, synchroniser les permissions et enregistrer dans SCVMM'

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    return
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

    Write-Step "Création et préparation du dossier $DestinationLocalPath"

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

                # Remplace uniquement la DACL. Le propriétaire et la SACL restent
                # ceux du dossier de destination.
                $destinationAcl.SetSecurityDescriptorSddlForm($SourceSddl, $sections)
                Set-Acl `
                    -LiteralPath $DestinationPath `
                    -AclObject $destinationAcl `
                    -ErrorAction Stop
            }

            # Création après application de la DACL pour que les dossiers
            # héritent des droits de la racine.
            foreach ($folder in $Folders) {
                $childPath = Join-Path -Path $DestinationPath -ChildPath $folder
                if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
                    New-Item -Path $childPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
            }
        } | Out-Null

    Write-Step "Création ou validation du partage SMB $destinationUnc"

    $destinationShare = Get-SmbShare `
        -CimSession $destinationCim `
        -Name $DestinationShareName `
        -ErrorAction SilentlyContinue

    if ($destinationShare) {
        if ($destinationShare.Path.TrimEnd('\') -ine $DestinationLocalPath.TrimEnd('\')) {
            throw "Le partage '$DestinationShareName' existe déjà mais pointe vers '$($destinationShare.Path)' au lieu de '$DestinationLocalPath'."
        }

        Write-Verbose "Le partage SMB '$DestinationShareName' existe déjà."
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
        Write-Step "Connexion à SCVMM $VMMServer"
        Import-Module VirtualMachineManager -ErrorAction Stop
        $vmmConnection = Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop

        Write-Step "Vérification du serveur de bibliothèque $DestinationLibraryServer"
        $libraryServer = Get-SCLibraryServer `
            -VMMServer $vmmConnection `
            -ComputerName $DestinationLibraryServer `
            -ErrorAction SilentlyContinue

        if (-not $libraryServer) {
            if (-not $AddLibraryServerIfMissing) {
                throw @"
Le serveur '$DestinationLibraryServer' n'est pas déclaré comme Library Server dans SCVMM.
Relancez avec -AddLibraryServerIfMissing, ou ajoutez-le d'abord dans la console SCVMM.
"@
            }

            if (-not $LibraryServerCredential) {
                throw "Le serveur '$DestinationLibraryServer' doit être ajouté à SCVMM, mais -LibraryServerCredential n'a pas été fourni. Relancez avec -LibraryServerCredential pour rester compatible avec une exécution non interactive."
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
            Write-Step "Enregistrement de $destinationUnc dans la bibliothèque SCVMM"

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
            Write-Verbose "Le partage est déjà enregistré dans SCVMM."
        }

        Write-Step 'Refresh de la bibliothèque SCVMM'
        Read-SCLibraryShare `
            -LibraryShare $libraryShare `
            -ErrorAction Stop | Out-Null
    }

    Write-Step 'Contrôle final'

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
    Write-Host 'Permissions SMB appliquées :' -ForegroundColor Green
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
