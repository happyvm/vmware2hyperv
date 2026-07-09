# step3-MigrateVM.ps1 — Migration par VM

Script cœur de l'étape 3 : Instant Recovery, configuration réseau, et post-configuration OS pour une VM unique.

## Synopsis

```powershell
.\step3-MigrateVM.ps1 -BackupJobName Backup-HypMig-lot-118 -VMName SRV-WEB01 -VlanId 100 -HyperVHost hv01 -ClusterStorage C:\ClusterStorage\Volume1
```

## Description

`step3-MigrateVM.ps1` est le script de migration unitaire, invoqué par `worker-step3.ps1` pour chaque VM. Il exécute :

1. **Instant Recovery** : finalise le mount Veeam (commit)
2. **Réseau Hyper-V** : configuration VLAN sur le switch virtuel
3. **Configuration SCVMM** : refresh, affectation réseau logique, OS, tags
4. **Post-configuration** : properties SCVMM (HA, host affinity, CPU, RAM)
5. **Nettoyage** : arrêt de la session Veeam Instant Recovery

## Paramètres

| Paramètre | Type | Requis | Description |
|-----------|------|--------|-------------|
| `-BackupJobName` | string | Oui | Nom du job Veeam |
| `-VMName` | string | Oui | Nom de la VM cible |
| `-VlanId` | string | Oui | VLAN ID pour la VM restaurée |
| `-AdapterVlanMapJson` | string | Non | JSON mapping adaptateurs → VLANs (multi-NIC) |
| `-OperatingSystem` | string | Non | OS invité pour config OS-spécifique |
| `-Remark` | string | Non | Notes du CSV pour contexte |
| `-SCVMMServer` | string | Non | Serveur SCVMM (défaut: config) |
| `-HyperVHost` | string | Non | Hôte Hyper-V primaire |
| `-HyperVHost2` | string | Non | Hôte Hyper-V secondaire (affinité) |
| `-HyperVCluster` | string | Non | Cluster Hyper-V |
| `-ClusterStorage` | string | Non | Chemin CSV |
| `-VmwareCluster` | string | Non | Cluster VMware source |
| `-BackupTag` | string | Non | Tag backup (défaut: config) |
| `-WaitingTimeoutSeconds` | int | Non | Timeout opérations mount (défaut: 1800) |
| `-WaitingPollIntervalSeconds` | int | Non | Intervalle poll (défaut: 15) |
| `-ForceNetworkConfigOnly` | switch | Non | Skip IR, config réseau/OS uniquement |
| `-SkipInstantRecoveryStart` | switch | Non | Skip démarrage mount IR |
| `-SkipInstantRecoveryFinalization` | switch | Non | Skip finalisation (commit) IR |
| `-SkipNetworkAndPostConfig` | switch | Non | Skip config réseau/post-migration |

## Flux d'exécution

```
┌─ Phase 1 : Instant Recovery ─────────────────────────┐
│ 1. Vérifie que le restore point existe               │
│ 2. Si pas SkipInstantRecoveryStart :                  │
│    - Start-VBRHvInstantRecovery (ou attente si déjà   │
│      lancé par step3-StartInstantRecovery)            │
│ 3. Si pas SkipInstantRecoveryFinalization :           │
│    - Attend WaitingForUserAction                      │
│    - Commit l'Instant Recovery                        │
│    - Attend job completion dans Veeam                 │
└──────────────────────────────────────────────────────┘
┌─ Phase 2 : Configuration réseau Hyper-V ─────────────┐
│ 1. Configuration VLAN sur le switch virtuel           │
│ 2. Support multi-NIC avec AdapterVlanMapJson          │
│ 3. Fallback mapping VLAN si VLAN exact non trouvé     │
└──────────────────────────────────────────────────────┘
┌─ Phase 3 : Configuration SCVMM ──────────────────────┐
│ 1. Refresh SCVMM → détection de la VM                 │
│ 2. Migration hôte SCVMM si nécessaire                 │
│ 3. Configuration réseau logique (VMNetwork, subnet)   │
│ 4. Application de l'OS SCVMM via OperatingSystemMap   │
│ 5. Application du tag backup                          │
│ 6. Configuration HA, host affinity, CPU, RAM          │
│ 7. Démarrage de la VM                                 │
└──────────────────────────────────────────────────────┘
┌─ Nettoyage ──────────────────────────────────────────┐
│ 1. Stop de la session Veeam Instant Recovery          │
└──────────────────────────────────────────────────────┘
```

## Mapping OS → SCVMM

Les valeurs `OperatingSystem` du CSV ou CMDB sont normalisées puis mappées via `SCVMM.OperatingSystemMap` dans `config.psd1`. La normalisation :
- Ignore la casse
- Collapse les séparateurs (`/`, `_`, `-`)
- Supprime le préfixe `Microsoft`

Voir [lib.ps1](lib.md) fonctions `ConvertTo-NormalizedOperatingSystemName` et `Resolve-OperatingSystemMapping`.

## Modes spéciaux

| Mode | Switches | Usage |
|------|----------|-------|
| Standard | — | Migration complète |
| Network-only | `-ForceNetworkConfigOnly` | Rejoue uniquement réseau/OS/SCVMM |
| Incident recovery | `-SkipInstantRecoveryStart` | Commit + réseau sur mount existant |

## Logs

```
{LogDir}/step3-migrate-{VMName}-{yyyyMMdd}.log
```

## Dépendances

- `lib.ps1`
- `config.psd1`
- Modules `Veeam.Backup.PowerShell` et `VirtualMachineManager`

## Voir aussi

- [step3-StartInstantRecovery.ps1](step3-StartInstantRecovery.md) — Phase 1 bulk
- [worker-step3.ps1](worker-step3.md) — Worker qui invoque ce script
- [run-migration.ps1](run-migration.md) — Orchestrateur