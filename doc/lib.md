# lib.ps1 — Librairie de fonctions partagées

Bibliothèque centrale importée par tous les scripts de migration via dot-sourcing.

## Synopsis

```powershell
# Dans chaque script :
. "$PSScriptRoot\lib.ps1"

# Utilisation des fonctions :
Write-MigrationLog "Étape terminée." -Level SUCCESS -LogFile $LogFile
Connect-VCenter -Server "vcenter.domain.local" -LogFile $LogFile
```

## Description

`lib.ps1` fournit 22 fonctions réutilisables couvrant tous les aspects transverses de la migration. Elle est importée par dot-sourcing dans chaque script.

## Fonctions

### Logging

| Fonction | Description |
|----------|-------------|
| `Write-MigrationLog` | Log horodaté multi-stream (INFO/WARNING/ERROR/SUCCESS) avec sortie fichier |
| `Assert-PathPresent` | Vérifie la présence d'un fichier et throw si absent |

### Connexions

| Fonction | Description |
|----------|-------------|
| `Connect-VCenter` | Connexion vCenter avec fallback credential prompt, mis en cache en mémoire par serveur pour toute l'exécution |
| `Disconnect-VCenter` | Déconnexion silencieuse |
| `Import-RequiredModule` | Import de module avec stratégie de fallback PS7/WinPS |

### Compatibilité modules (PowerShell 7)

| Fonction | Description |
|----------|-------------|
| `Get-ModuleImportStrategies` | Stratégies d'import ordonnées selon l'édition PS |
| `Repair-WindowsOnlyModuleImport` | Ré-import via WinPS compat session après échec runtime |
| `Install-RsatHyperV` | Installation automatique des outils RSAT Hyper-V |
| `Invoke-SCVMMCommand` | Proxy SCVMM via WinPS compat session |
| `Invoke-VeeamCommand` | Proxy Veeam via WinPS compat session |

Les modules Windows-only (`VirtualMachineManager`, `Veeam.Backup.PowerShell`, `FailoverClusters`) sont chargés prioritairement via la session de compatibilité Windows PowerShell pour éviter les erreurs .NET type-initializer dans PS7.

`Connect-VCenter` essaie d'abord l'authentification intégrée Windows. Si elle
échoue, la saisie explicite n'est demandée qu'une fois par vCenter et réutilisée
par les étapes suivantes du même processus PowerShell. Le cache est uniquement
en mémoire (aucun mot de passe n'est écrit dans la configuration ou sur disque)
et les identifiants de deux vCenters différents ne sont jamais mélangés.

### Mapping OS

| Fonction | Description |
|----------|-------------|
| `ConvertTo-NormalizedOperatingSystemName` | Normalise un label OS (case, séparateurs, préfixe Microsoft) |
| `Get-OperatingSystemFamilyKey` | Réduit un label OS à `"<distribution> <version majeure>"` (`RHEL 8.6`, `RHEL 8 (64-bit)`, `RHEL release 8.9 (Ootpa)` → `red hat enterprise linux 8`). Retourne `$null` pour Windows, dont la version n'est pas en fin de label |
| `Resolve-OperatingSystemMapping` | Mappe un OS source vers un OS SCVMM : correspondance exacte, puis repli sur la clé de famille. Voir [config.md](config.md#operatingsystemmap) |
| `Get-OsGeneration` | Extrait l'année de release (2003-2025) d'un nom d'OS |

### VLAN

| Fonction | Description |
|----------|-------------|
| *(résolution VLAN intégrée dans `run-migration.ps1`)* | |

### VMware

| Fonction | Description |
|----------|-------------|
| `Test-VmwareVirtualMachineEntity` | Teste si une entité de `Get-TagAssignment` est une VM. PowerCLI renvoie le type d'implémentation (`UniversalVirtualMachineImpl`, `VirtualMachineImpl`), jamais `VirtualMachine` : la fonction accepte le nom de type **ou** le préfixe de l'`Id` managé (`VirtualMachine-vm-…`) |
| `Get-VmwareAdapterConnectionState` | Lit les drapeaux `Connected` (lien en cours) et `StartConnected` (branchée au démarrage) d'une NIC, quelle que soit la forme exposée par PowerCLI (`ConnectionState`, propriétés à plat, ou `ExtensionData.Connectable`) |
| `Set-VmwareVmNetworkAdapterConnection` | Branche ou débranche toutes les NICs d'une VM. Écrit **toujours** `StartConnected` (c'est lui qui survit à un cycle d'alimentation), et `Connected` seulement si la VM tourne. Retourne un récapitulatif (`ChangedCount`, `UnchangedCount`, `FailedCount`) pour qu'un échec ne soit jamais silencieux |
| `Resolve-AdapterVlanId` | Résout le VLAN d'une carte réseau VMware (port group distribué, puis standard, puis backing, puis suffixe de nom). Rejette VLAN 0 (untagged), 4095 et les port groups trunk : retourne `PortGroup not found` plutôt qu'un VLAN inventé. Définie ici et non dans `run-migration.ps1` pour que la suite Pester exerce l'implémentation réelle |

### SCVMM

| Fonction | Description |
|----------|-------------|
| `ConvertTo-ScvmmMemoryGigabytes` | Convertit la mémoire d'une VM SCVMM (`VirtualMachine.Memory`, exprimée en **Mo**) en Go ; tolère une valeur en octets. Un jumeau inline existe dans le scriptblock SCVMM de `step5-ValidateMigration.ps1`, qui s'exécute dans la session de compatibilité WinPS où `lib.ps1` n'est pas chargé |

### Ciblage migration

| Fonction | Description |
|----------|-------------|
| `Resolve-MigrationTarget` | Résout la cible Hyper-V depuis le cluster VMware source via `ClusterMappings` |

### Email

| Fonction | Description |
|----------|-------------|
| `Send-HtmlMail` | Envoi d'email HTML via SMTP |
| `ConvertTo-HtmlEncoded` | Encodage HTML sécurisé pour templates d'email |

### CSV / Helpers

| Fonction | Description |
|----------|-------------|
| `Get-FirstPropertyValue` | Retourne la première valeur non-vide parmi des noms de colonnes candidats |

### Config layering (config.psd1 + config.local.psd1)

| Fonction | Description |
|----------|-------------|
| `Merge-Hashtable` | Fusion récursive de deux hashtables ; `Override` gagne sur les clés en conflit |
| `Import-MigrationConfig` | Charge `config.psd1` puis fusionne `config.local.psd1` par-dessus s'il existe |
| `Get-MigrationConfigMissingKeys` | Liste les entrées de `$script:MigrationConfigSchema` absentes de `config.local.psd1` |
| `Invoke-MigrationConfigWizard` | Boucle de prompts interactifs ; écrit `config.local.psd1` via `Save-MigrationLocalConfig` |
| `Save-MigrationLocalConfig` | Sérialise un hashtable `{ Section = { Clé = valeur } }` en `config.local.psd1` valide |
| `ConvertTo-Psd1ScalarLiteral` | Convertit une valeur scalaire/tableau PowerShell en littéral PSD1 (string échappée, `$true`/`$false`, `@(...)`) |

Voir [config.psd1](config.md#configpsd1-vs-configlocalpsd1) pour le rôle de chaque fichier et [configure-migration.ps1](configure-migration.md) pour l'outil interactif.

## Stratégie d'import des modules

```
┌─ PS7 sur Windows ?
│  ├─ Module dans WindowsOnlyManagementModules ?
│  │  └─ OUI → WinPS compat session d'abord, puis Standard, puis SkipEditionCheck
│  └─ NON  → Standard, puis WinPS compat, puis SkipEditionCheck
└─ Windows PS 5.1 → Standard uniquement
```

## Exemple de log

```
[2026-07-09 10:15:32] [INFO] Starting step1 - tagging and creating Veeam jobs
[2026-07-09 10:15:33] [SUCCESS] Connected to vCenter using current Windows credentials: vcenter.domain.local
[2026-07-09 10:15:35] [WARNING] Module imported via Windows PowerShell compatibility mode: VirtualMachineManager
```

## Voir aussi

- [config.psd1](config.md) — Configuration centralisée
- [ADR-001](adr/001-architecture-decisions.md) — Décision 3 : stratégie d'import
