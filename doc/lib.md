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
| `Connect-VCenter` | Connexion vCenter avec fallback credential prompt |
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

### Mapping OS

| Fonction | Description |
|----------|-------------|
| `ConvertTo-NormalizedOperatingSystemName` | Normalise un label OS (case, séparateurs, préfixe Microsoft) |
| `Resolve-OperatingSystemMapping` | Mappe un OS source vers un OS SCVMM |
| `Get-OsGeneration` | Extrait l'année de release (2003-2025) d'un nom d'OS |

### VLAN

| Fonction | Description |
|----------|-------------|
| *(résolution VLAN intégrée dans `run-migration.ps1`)* | |

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