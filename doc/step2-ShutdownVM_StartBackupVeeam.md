# step2-ShutdownVM_StartBackupVeeam.ps1 — Arrêt VMs + Backup

Arrête les VMs sources VMware, envoie l'email pré-migration et déclenche le backup Veeam.

## Synopsis

```powershell
.\step2-ShutdownVM_StartBackupVeeam.ps1 -Tag HypMig-lot-118
```

## Description

Step 2 de la pipeline de migration :

1. **Arrêt des VMs** : shutdown graceful de toutes les VMs du lot
2. **Déconnexion réseau** : déconnecte les NICs des VMs arrêtées, **y compris au démarrage**
3. **Email pré-migration** : notifie les destinataires configurés (liste des VMs du tag et leur état)
4. **Backup Veeam** : démarre un active full du job de backup

Le job est toujours lancé avec `Start-VBRJob -FullBackup` : chaque migration produit donc un active full et ne dépend pas du CBT pour une chaîne incrémentale. En PowerShell 7, ce démarrage est délégué à `powershell.exe` (Windows PowerShell).

### Déconnexion réseau : runtime *et* au démarrage

Chaque NIC vSphere porte deux drapeaux indépendants :

| Drapeau | Signification |
|---------|---------------|
| `Connected` | État du lien **en cours**. N'a de sens que pendant que la VM tourne. |
| `StartConnected` | La NIC est-elle branchée **au démarrage de la VM**. |

Le script efface **toujours** `StartConnected`, et n'écrit `Connected` que si la
VM tourne encore (vSphere refuse ou ignore une (dé)connexion runtime sur une VM
éteinte). Sans cela, la VM source rejoint le réseau dès que quelqu'un la
rallume — en conflit d'identité et d'IP avec la VM Hyper-V migrée, qui a repris
son nom et son adresse.

Corollaire : les VM **déjà éteintes** à l'entrée du script sont traitées elles
aussi. Leur état de lien runtime ne veut rien dire, mais leur `StartConnected`
est précisément ce qu'il faut effacer.

Une NIC qui n'a pas pu être débranchée est loggée en **ERROR** avec la
conséquence explicite (la VM peut rejoindre le réseau si elle est rallumée) :
l'étape continue — les VM sont déjà arrêtées — mais l'opérateur doit débrancher
la carte manuellement dans vCenter avant de valider le lot.

[`Invoke-Rollback.ps1`](../powershell-migration/Invoke-Rollback.ps1) rebranche
les cartes (`StartConnected` compris) avant de rallumer la source : sans cela,
un rollback restaurerait une VM sans réseau.

L'envoi de l'email pré-migration est géré directement par ce script (plus de script externe séparé) et peut être désactivé globalement via `Config.Smtp.Enabled = $false`. Un échec de l'email (destinataire invalide, tag introuvable, SMTP indisponible...) est non bloquant : il est loggé en WARNING et le backup Veeam continue.

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-Tag` | string | Oui | — | Tag du lot |
| `-VCenterServer` | string | Non | `Config.VCenter.Server` | Serveur vCenter |
| `-CsvFile` | string | Non | `Config.Paths.CsvFile` | CSV batch |
| `-RecipientGroup` | string | Non | `infogerant` | Groupe destinataires (clé dans `Config.Recipients`) |
| `-LogFile` | string | Non | auto-généré | Fichier de log |

## Algorithme d'arrêt

```
0. Résout TOUTES les VM du lot avant la moindre action :
   └─ Un nom porté par plusieurs VM dans vCenter → abort (aucun arrêt)
1. Pour chaque VM du CSV (filtrée par Tag) :
   ├─ Si déjà PoweredOff → débranche les NICs (dont StartConnected), skip
   └─ Sinon → Stop-VMGuest (shutdown graceful)
2. Boucle de polling (timeout: 300s, intervalle: 10s) :
   ├─ Vérifie l'état de chaque VM
   ├─ Si timeout → Stop-VM (power-off forcé)
   └─ Si toujours powered-on après 300s de grâce → abort
3. Débranche les NICs de toutes les VMs arrêtées :
   ├─ StartConnected = $false  (toujours)
   └─ Connected     = $false  (uniquement si la VM tourne encore)
```

## Logs

```
{LogDir}/step2-shutdown-backup-{Tag}-{yyyyMMdd}.log
```

## Dépendances

- `lib.ps1` — `Connect-VCenter`, `Send-HtmlMail`, `ConvertTo-HtmlEncoded`
- `config.psd1` — sections `VCenter`, `Paths`, `Smtp`, `Recipients`, `Tags`
- Module `VMware.PowerCLI`
- Module `Veeam.Backup.PowerShell` (dans Windows PowerShell)

## Voir aussi

- [step1-TagResources_CreateVeeamJob.ps1](step1-TagResources_CreateVeeamJob.md) — Étape précédente
- [run-migration.ps1](run-migration.md) — Orchestrateur