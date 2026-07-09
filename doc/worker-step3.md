# worker-step3.ps1 — Worker file-system queue

Worker longue durée qui traite les tâches step3 depuis une file d'attente basée sur le système de fichiers.

## Synopsis

```powershell
.\worker-step3.ps1 -QueueRoot D:\Scripts\Logs\step3-queue -WorkerName step3-worker-01
```

## Description

`worker-step3.ps1` est un processus persistant lancé par `run-migration.ps1`. Il surveille une file d'attente sur disque et traite les tâches de migration step3 une par une.

Chaque worker est un processus `pwsh` indépendant, ce qui garantit l'isolation : un crash dans un worker (ex: corruption d'objet COM Veeam) n'affecte pas les autres.

## Structure de la queue

```
{QueueRoot}/
├── pending/          ← tâches JSON à traiter
├── processing/       ← tâche en cours (move atomique)
├── done/             ← tâches réussies (JSON enrichi)
├── failed/           ← tâches échouées (JSON + erreurs)
└── dispatch.complete ← flag : plus aucune tâche à venir
```

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-QueueRoot` | string | Oui | — | Racine de la file d'attente |
| `-WorkerName` | string | Non | `step3-worker-01` | Nom unique du worker |
| `-PollIntervalSeconds` | int | Non | `3` | Intervalle de poll de la queue |
| `-LogFile` | string | Non | auto-généré | Fichier de log |

## Boucle de traitement

```
while (true) :
  1. Cherche le prochain fichier .json dans pending/ (trié par nom)
  2. Si aucun et dispatch.complete existe → FIN
  3. Si aucun → sleep PollIntervalSeconds, continue
  4. Move atomique pending/ → processing/
  5. Parse le JSON de la tâche
  6. Exécute step3-MigrateVM.ps1 avec les paramètres de la tâche
  7. Enrichit le JSON avec Status, timestamps, NetworkConfigurationState
  8. Move processing/ → done/ (succès) ou failed/ (échec)
```

## Enrichissement des tâches

Chaque tâche JSON est enrichie par le worker :

```json
{
  "WorkerName": "step3-worker-01",
  "StartedAt": "2026-07-09T10:30:00.0000000+02:00",
  "Status": "Success",
  "CompletedAt": "2026-07-09T10:35:00.0000000+02:00",
  "ErrorMessage": null,
  "NetworkConfigurationState": "Configured"
}
```

## États NetworkConfigurationState

| État | Signification |
|------|--------------|
| `Configured` | VLAN configuré avec succès |
| `ConfiguredWithWarning` | Fallback mapping utilisé |
| `NotDetected` | Aucune trace de config réseau |
| `Unknown` | Log de VM inaccessible |

## Initialisation

Au démarrage, le worker pré-charge le module SCVMM (`VirtualMachineManager`) pour éviter la latence de premier import. Le module Veeam est chargé à la demande (lazy) uniquement pour les tâches non network-only.

## Logs

```
{LogDir}/step3-worker-{NN}-{Tag}-{yyyyMMdd-HHmmss}.log
```

## Dépendances

- `lib.ps1`
- `step3-MigrateVM.ps1` — invoqué pour chaque tâche

## Voir aussi

- [run-migration.ps1](run-migration.md) — Lance les workers
- [step3-MigrateVM.ps1](step3-MigrateVM.md) — Script exécuté par tâche
- [ADR-001](../docs/adr/001-architecture-decisions.md) — Décision 2 : file-system queue