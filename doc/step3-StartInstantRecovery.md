# step3-StartInstantRecovery.ps1 — Bulk Instant Recovery

Lancement bulk du Veeam Instant Recovery avec monitoring unifié de la progression.

## Synopsis

```powershell
.\step3-StartInstantRecovery.ps1 -BackupJobName Backup-HypMig-lot-118 -TasksFile D:\Scripts\Logs\ir-tasks.json
```

## Description

Phase 1 de l'étape 3. Lance l'Instant Recovery de **toutes** les VMs listées dans le fichier de tâches :

- Démarrage asynchrone (`-RunAsync`) quand le module Veeam le supporte, synchrone sinon
- Monitoring unifié : une seule requête Veeam par poll couvrant toutes les VMs
- Attend que chaque session atteigne l'état `WaitingForUserAction`
- Dashboard de progression rafraîchi à chaque poll dans la console

## Format du fichier de tâches

```json
[
  {
    "VMName": "SRV-WEB01",
    "HyperVHost": "hv01.domain.local",
    "ClusterStorage": "C:\\ClusterStorage\\Volume2"
  }
]
```

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-BackupJobName` | string | Oui | — | Nom du job Veeam |
| `-TasksFile` | string | Oui | — | JSON des tâches |
| `-StartDelaySeconds` | int | Non | `2` | Délai entre deux starts IR |
| `-WaitingTimeoutSeconds` | int | Non | `1800` | Timeout max d'attente |
| `-WaitingPollIntervalSeconds` | int | Non | `15` | Intervalle de poll |
| `-LogFile` | string | Non | auto-généré | Fichier de log |

## Détection de l'état WaitingForUserAction

Le script utilise deux méthodes de détection :

1. **Instant Recovery state** — `Get-VBRInstantRecovery` → `State -eq 'WaitingForUserAction'`
2. **Restore session log** — `$restoreSession.Logger.GetLog()` → parsing du texte `'Waiting for user action'`

Chaque VM est trackée avec son état :
- `Mounting` → en cours
- `Ready` → `WaitingForUserAction` détecté
- `Failed` → session terminée en échec
- `TimedOut` → timeout atteint

## Dashboard de progression

```
Instant Recovery progress: 12/15 ready (elapsed: 240s / timeout: 1800s)

VM              Status   InstantRecovery          RestoreSession  Progress
----            ------   ----------------         --------------  --------
SRV-WEB01       Ready    WaitingForUserAction     Stopped         100%
SRV-DB01        Mounting Mounting                 Working         45%
SRV-APP01       Ready    WaitingForUserAction     Stopped         100%
```

## Codes de sortie

| Code | Signification |
|------|--------------|
| 0 | Toutes les VMs sont en état Ready |
| 1 (throw) | Échec de démarrage ou timeout — liste les VMs concernées |

## Dépendances

- `lib.ps1` — `Invoke-VeeamCommand`, `Write-MigrationLog`
- `config.psd1`
- Module `Veeam.Backup.PowerShell`

## Voir aussi

- [step3-MigrateVM.ps1](step3-MigrateVM.md) — Phase 2 : commit + config par VM
- [worker-step3.ps1](worker-step3.md) — Worker qui appelle step3-MigrateVM
- [run-migration.ps1](run-migration.md) — Orchestrateur