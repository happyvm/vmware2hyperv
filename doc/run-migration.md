# run-migration.ps1 — Orchestrateur principal

Orchestrateur de la pipeline de migration VMware → Hyper-V en 3 étapes.

## Synopsis

```powershell
.\run-migration.ps1 -Tag HypMig-lot-118
.\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3
.\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step2 -RecipientGroup internal -NonInteractive
```

## Description

`run-migration.ps1` est le point d'entrée unique de la migration. Il orchestre les 3 étapes :

1. **Step 1** : Tag des ressources VMware et création du job Veeam
2. **Step 2** : Arrêt des VMs sources, déclenchement du backup Veeam, envoi de l'email pré-migration
3. **Step 3** : Instant Recovery bulk + workers parallèles pour commit/réseau/OS

L'orchestrateur supporte la reprise depuis n'importe quelle étape, le mode incident recovery mono-VM, et l'exécution non-interactive pour l'automatisation.

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-Tag` | string | Oui | — | Tag du lot à migrer (ex: `HypMig-lot-118`) |
| `-StartFrom` | string | Non | `step1` | Étape de départ : `step1`, `step2`, `step3` |
| `-RecipientGroup` | string | Non | `infogerant` | Groupe de destinataires pour l'email pré-migration |
| `-ConfigFile` | string | Non | `config.psd1` | Fichier de configuration alternatif |
| `-ForceNetworkConfigOnly` | switch | Non | — | Rejoue uniquement la config réseau/OS de step3 |
| `-Step3VmName` | string | Non | — | Restreint step3 à une seule VM (incident recovery) |
| `-Step3RecoveryMode` | string | Non | `Standard` | Mode recovery : `Standard`, `FullStep3`, `CommitAndNetwork` |
| `-NonInteractive` | switch | Non | — | Désactive les prompts interactifs |
| `-SkipManualValidation` | switch | Non | — | Saute la pause de validation manuelle avant step3 |

## Architecture du pool de workers (step3)

Le fichier génère des tâches JSON dans une file d'attente basée sur le système de fichiers :

```
{LogDir}/step3-worker-queue-{Tag}-{timestamp}/
├── pending/          ← tâches à traiter
├── processing/       ← tâche en cours par un worker
├── done/             ← succès
├── failed/           ← échecs avec traces
└── dispatch.complete ← flag de fin de dispatch
```

N workers `worker-step3.ps1` sont lancés comme processus `pwsh` séparés. Chacun :
1. Claim une tâche dans `pending/` (move → `processing/`)
2. Exécute `step3-MigrateVM.ps1` avec les paramètres de la tâche
3. Déplace le résultat dans `done/` ou `failed/`

L'orchestrateur attend que tous les workers aient fini, puis vérifie l'état final de la queue.

## Résolution VLAN

Avant de lancer les workers, l'orchestrateur se connecte à vCenter pour résoudre les VLANs de chaque VM via une pipeline multi-couche :

1. **Distributed Virtual Switch** — propriété `VlanId` directe
2. **VlanConfiguration** — parsing regex pour trunks
3. **Standard PortGroup** — `VLanId` du port group standard
4. **ExtensionData.Backing** — fallback via `Get-View`
5. **Nom du port group** — extraction du VLAN depuis le nom (ex: `dvPG-LAN_1816` → `1816`)

Les résultats sont injectés dans les tâches JSON des workers.

## Résolution de cible de migration

Pour chaque VM, l'orchestrateur :
1. Récupère le cluster VMware source (`Get-Cluster`, puis traversée de `Parent`)
2. Cherche un mapping dans `MigrationMappings.ClusterMappings`
3. Applique les hosts/storage/cluster Hyper-V correspondants
4. Fallback sur le bloc `HyperV` par défaut si aucun mapping ne match

## Exemples

### Migration complète
```powershell
.\run-migration.ps1 -Tag HypMig-lot-118
```

### Reprise depuis step3
```powershell
.\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3
```

### Rejeu config réseau uniquement
```powershell
.\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3 -ForceNetworkConfigOnly
```

### Incident recovery mono-VM (commit + réseau)
```powershell
.\run-migration.ps1 -Tag HypMig-lot-118 -StartFrom step3 -Step3VmName SRV-WEB01 -Step3RecoveryMode CommitAndNetwork
```

### Mode non-interactif
```powershell
.\run-migration.ps1 -Tag HypMig-lot-118 -NonInteractive -SkipManualValidation
```

## Dépendances

- `lib.ps1` — fonctions partagées
- `config.psd1` — configuration
- `step1-TagResources_CreateVeeamJob.ps1` — exécuté pour step1
- `step2-ShutdownVM_StartBackupVeeam.ps1` — exécuté pour step2
- `step3-StartInstantRecovery.ps1` — exécuté pour la phase 1 de step3
- `worker-step3.ps1` — workers lancés pour la phase 2 de step3

## Logs

- Log principal : `{LogDir}/run-migration-{Tag}-{yyyyMMdd-HHmmss}.log`
- Logs par VM : `{LogDir}/migration-{Tag}-{VMName}-{yyyyMMdd-HHmmss}.log`
- Logs workers : `{LogDir}/step3-worker-{NN}-{Tag}-{yyyyMMdd-HHmmss}.log`

## Codes de sortie

| Code | Signification |
|------|--------------|
| 0 | Succès |
| 1 (throw) | Échec d'une étape — le message indique la commande de reprise |

## Voir aussi

- [worker-step3.ps1](worker-step3.md) — Détail du worker
- [step3-StartInstantRecovery.ps1](step3-StartInstantRecovery.md) — Bulk IR
- [step3-MigrateVM.ps1](step3-MigrateVM.md) — Migration par VM
- [ADR-001](adr/001-architecture-decisions.md) — Décisions d'architecture