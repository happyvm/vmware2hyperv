# step1-TagResources_CreateVeeamJob.ps1 — Tag VMware + Job Veeam

Applique les tags VMware et crée les jobs de backup Veeam pour un lot de migration.

## Synopsis

```powershell
.\step1-TagResources_CreateVeeamJob.ps1 -Tag HypMig-lot-118
```

## Description

Step 1 de la pipeline de migration :

1. **Tag VMware** : lit le CSV batch, applique les tags vSphere aux VMs listées
2. **Nettoyage** : supprime les assignations de tag précédentes avant d'appliquer les nouvelles
3. **Job Veeam** : crée ou met à jour les jobs de backup Veeam correspondants

En PowerShell 7, le script délègue la création des jobs Veeam à `powershell.exe` (Windows PowerShell) pour éviter les conflits d'assembly `VimService` entre VMware et Veeam et les objets désérialisés.

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-VCenterServer` | string | `Config.VCenter.Server` | Serveur vCenter |
| `-CsvFile` | string | `Config.Paths.CsvFile` | CSV batch |
| `-TagCategory` | string | `Config.Tags.Category` | Catégorie de tag VMware |
| `-BackupRepoName` | string | `Config.Veeam.BackupRepo` | Repository Veeam |
| `-BackupProxyName` | string | `Config.Veeam.BackupProxy` | Proxy Veeam (optionnel) |
| `-Tag` | string | — | Tag pour contexte de log |
| `-LogFile` | string | auto-généré | Fichier de log |

## Flux d'exécution

```
┌─ Tag VMware ──────────────────────────────────────────┐
│ 1. Vérifie/crée la catégorie de tag                   │
│ 2. Nettoie les assignations existantes des tags CSV   │
│ 3. Pour chaque VM du CSV :                            │
│    - Crée le tag s'il n'existe pas                    │
│    - Retire l'ancien tag de la même catégorie         │
│    - Applique le nouveau tag                          │
└───────────────────────────────────────────────────────┘
┌─ Job Veeam (délégué à powershell.exe sous PS7) ──────┐
│ 1. Résout le repository Veeam                        │
│ 2. Résout le proxy (si configuré)                    │
│ 3. Pour chaque tag unique du CSV :                    │
│    - Cherche le tag dans l'inventaire Veeam/VMware    │
│    - Crée le job "Backup-{tag}" s'il n'existe pas    │
└───────────────────────────────────────────────────────┘
```

## Détail : délégation Windows PowerShell

Sous PS7, le script construit un script Windows PowerShell inline, l'encode en base64, et l'exécute via :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript
```

Les paramètres sont passés via variables d'environnement (`$env:VMW2HV_*`), nettoyées après exécution.

## Logs

```
{LogDir}/step1-tag-veeam{-Tag}-{yyyyMMdd}.log
```

## Dépendances

- `lib.ps1`
- `config.psd1`
- Module `VMware.PowerCLI`
- Module `Veeam.Backup.PowerShell` (dans Windows PowerShell)

## Voir aussi

- [step2-ShutdownVM_StartBackupVeeam.ps1](step2-ShutdownVM_StartBackupVeeam.md) — Étape suivante
- [run-migration.ps1](run-migration.md) — Orchestrateur