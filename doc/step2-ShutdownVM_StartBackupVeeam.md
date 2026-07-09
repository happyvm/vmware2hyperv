# step2-ShutdownVM_StartBackupVeeam.ps1 — Arrêt VMs + Backup

Arrête les VMs sources VMware, envoie l'email pré-migration et déclenche le backup Veeam.

## Synopsis

```powershell
.\step2-ShutdownVM_StartBackupVeeam.ps1 -Tag HypMig-lot-118
```

## Description

Step 2 de la pipeline de migration :

1. **Arrêt des VMs** : shutdown graceful de toutes les VMs du lot
2. **Déconnexion réseau** : déconnecte les NICs des VMs arrêtées
3. **Email pré-migration** : notifie les destinataires configurés
4. **Backup Veeam** : démarre le job de backup et attend sa complétion

En PowerShell 7, le démarrage du job Veeam est délégué à `powershell.exe` (Windows PowerShell).

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-Tag` | string | Oui | — | Tag du lot |
| `-VCenterServer` | string | Non | `Config.VCenter.Server` | Serveur vCenter |
| `-CsvFile` | string | Non | `Config.Paths.CsvFile` | CSV batch |
| `-PreMigrationMailScript` | string | Non | `stepx-premigration_mail.ps1` | Script email |
| `-RecipientGroup` | string | Non | `infogerant` | Groupe destinataires |
| `-LogFile` | string | Non | auto-généré | Fichier de log |

## Algorithme d'arrêt

```
1. Pour chaque VM du CSV (filtrée par Tag) :
   ├─ Si déjà PoweredOff → déconnecte les NICs, skip
   └─ Sinon → Stop-VMGuest (shutdown graceful)
2. Boucle de polling (timeout: 300s, intervalle: 10s) :
   ├─ Vérifie l'état de chaque VM
   ├─ Si timeout → Stop-VM (power-off forcé)
   └─ Si toujours powered-on après 300s de grâce → abort
3. Déconnecte les NICs de toutes les VMs arrêtées
```

## Logs

```
{LogDir}/step2-shutdown-backup-{Tag}-{yyyyMMdd}.log
```

## Dépendances

- `lib.ps1`
- `config.psd1`
- `stepx-premigration_mail.ps1`
- Module `VMware.PowerCLI`
- Module `Veeam.Backup.PowerShell` (dans Windows PowerShell)

## Voir aussi

- [step1-TagResources_CreateVeeamJob.ps1](step1-TagResources_CreateVeeamJob.md) — Étape précédente
- [stepx-premigration_mail.ps1](stepx-premigration_mail.md) — Script email
- [run-migration.ps1](run-migration.md) — Orchestrateur