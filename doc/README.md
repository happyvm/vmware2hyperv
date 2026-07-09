# Documentation des scripts — vmware2hyperv

Documentation détaillée de chaque script du toolkit de migration VMware vers Hyper-V.

## Scripts d'orchestration

| Script | Rôle | Étape |
|--------|------|-------|
| [run-migration.ps1](run-migration.md) | Orchestrateur principal | Toutes |
| [worker-step3.ps1](worker-step3.md) | Worker file-system queue | Step 3 |

## Étape 0 — Pré-flight

| Script | Rôle |
|--------|------|
| [step0-precheck.ps1](step0-precheck.md) | Pré-vérification vCenter : inventaire, uptime, ipconfig, tags |

## Étape 1 — Préparation

| Script | Rôle |
|--------|------|
| [step1-TagResources_CreateVeeamJob.ps1](step1-TagResources_CreateVeeamJob.md) | Tag VMware + création job Veeam |

## Étape 2 — Cutover

| Script | Rôle |
|--------|------|
| [step2-ShutdownVM_StartBackupVeeam.ps1](step2-ShutdownVM_StartBackupVeeam.md) | Arrêt VMs + backup Veeam + email pré-migration |

## Étape 3 — Migration

| Script | Rôle |
|--------|------|
| [step3-StartInstantRecovery.ps1](step3-StartInstantRecovery.md) | Bulk Instant Recovery + monitoring unifié |
| [step3-MigrateVM.ps1](step3-MigrateVM.md) | Migration par VM : commit, réseau, OS |

## Post-migration

| Script | Rôle |
|--------|------|
| [step4-PostMigrationChecks.ps1](step4-PostMigrationChecks.md) | Vérifications SCVMM post-migration |
| [step5-StartVM.ps1](step5-StartVM.md) | Démarrage VMs + Integration Services |
| [step6-CleanupVmware.ps1](step6-CleanupVmware.md) | Suppression des VMs sources VMware |

## Librairie partagée

| Script | Rôle |
|--------|------|
| [lib.ps1](lib.md) | 22 fonctions partagées (logging, connexions, VLAN, OS, mail) |

## Outils de diagnostic

| Script | Rôle |
|--------|------|
| [Test-HyperVNodeReadiness.ps1](Test-HyperVNodeReadiness.md) | Validation OS/hardware/réseau/AD pour nœuds Hyper-V |
| [Test-VeeamFlows.ps1](Test-VeeamFlows.md) | Validation connectivité réseau Veeam 12.3 |

## Configuration

| Fichier | Rôle |
|---------|------|
| [config.psd1](config.md) | Configuration centralisée (endpoints, tags, SMTP, mappings) |

## Architecture

- [ADR-001 : Décisions d'architecture](adr/001-architecture-decisions.md)
- [README principal](../README.md)