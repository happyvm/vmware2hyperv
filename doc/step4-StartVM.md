# step4-StartVM.ps1 — Démarrage VMs + validation post-migration

Démarre les VMs migrées et boucle jusqu'à ce qu'elles soient pleinement conformes.

## Synopsis

```powershell
.\step4-StartVM.ps1 -Tag HypMig-lot-118
.\step4-StartVM.ps1 -Tag HypMig-lot-118 -IntegrationMaxIterations 20
```

## Description

Exécuté automatiquement par [run-migration.ps1](run-migration.md) après la pause de validation manuelle qui suit step3 (peut aussi être relancé seul, ou via `run-migration.ps1 -StartFrom step4`).

Ce script réunit en un seul passage sur l'inventaire SCVMM ce qui était auparavant réparti entre le démarrage des VMs et une étape de vérification post-migration séparée (`step5-PostMigrationChecks.ps1`, supprimé). Il :

- Démarre chaque VM listée dans le CSV batch (`Start-SCVirtualMachine`)
- Tente WinRM (HTTPS puis HTTP) sur Windows Server 2012+ pour uploader et exécuter un script de retrait VMware Tools ; pour les OS antérieurs (2003/2008) ou en cas d'échec WinRM, reporte une action manuelle
- Boucle jusqu'à ce que chaque VM soit **conforme**, c'est-à-dire :
  - démarrée et sa carte réseau connectée
  - son IPv4 invitée correspond à l'IP attendue (`Paths.ExtractIpCsv`, si le fichier existe)
  - ses Integration Services sont opérationnels (heartbeat, time sync, data exchange, guest agent)
  - la Haute Disponibilité SCVMM est activée
  - le tag de backup post-migration (`Tags.BackupTag`) est présent
- Par défaut la boucle est **illimitée** (`-IntegrationMaxIterations 0`) : elle continue jusqu'à conformité totale ou jusqu'à interruption manuelle (Ctrl+C) — les VMs déjà démarrées ne sont pas affectées par l'interruption. Une valeur positive borne le nombre d'itérations ; dans ce cas, le script sort avec le code 2 s'il reste des VMs non conformes à la fin.

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-ConfigFile` | string | `config.psd1` | Fichier de configuration |
| `-CsvFile` | string | `Config.Paths.CsvFile` | CSV batch |
| `-ExtractIpCsvFile` | string | `Config.Paths.ExtractIpCsv` | CSV d'IP attendues (optionnel — ignoré si absent) |
| `-Tag` | string | — | Tag pour filtrer les VMs |
| `-LogFile` | string | auto-généré | Fichier de log |
| `-IntegrationPollIntervalSeconds` | int | `30` | Intervalle entre deux vérifications de conformité |
| `-IntegrationMaxIterations` | int | `0` | Itérations max (`0` = illimité) |
| `-WinRmRetryDelaySeconds` | int | `15` | Délai entre tentatives WinRM |
| `-WinRmMaxAttempts` | int | `20` | Tentatives max WinRM |

## Flux d'exécution

```
Pour chaque VM du CSV (filtrée par Tag) :
├─ Récupère l'inventaire SCVMM (état, OS configuré, réseau, HA, tag, IP)
├─ Démarre la VM (Start-SCVirtualMachine)
├─ Si OS ≥ 2012 :
│  ├─ Tente WinRM HTTPS puis HTTP
│  ├─ Upload + exécution script retrait VMware Tools
│  └─ Si WinRM indisponible → reporte action manuelle
├─ Si OS < 2012 ou inconnu → reporte action manuelle
└─ Boucle de conformité (jusqu'à IntegrationMaxIterations, ou sans limite si 0) :
   ├─ Démarrée + NIC connectée + IP attendue + Integration Services OK + HA + tag backup
   └─ Retire la VM du tableau de suivi dès qu'elle est conforme
```

## Dashboard

À chaque itération, la console affiche les VMs encore non conformes avec la liste des non-conformités (`NIC non connectée`, `IP inattendue`, `Integration Services non OK`, `HA non activée`, `tag backup absent`, `non démarrée`).

## Résumé de sortie

Un CSV `step4-startvm-summary-{yyyyMMdd-HHmmss}.csv` est exporté dans `Paths.LogDir`, avec une colonne `Compliant` par VM et le détail de chaque critère (réseau, IP, Integration Services, HA, tag backup).

## Logs

```
{LogDir}/step4-startvm{-Tag}-{yyyyMMdd-HHmmss}.log
{LogDir}/step4-startvm-summary-{yyyyMMdd-HHmmss}.csv
```

## Dépendances

- `lib.ps1`
- `config.psd1` — sections `SCVMM`, `Tags`, `Paths`, `RemoteActions`, `StartVm`
- Module `VirtualMachineManager`

## Voir aussi

- [run-migration.ps1](run-migration.md) — Orchestrateur, exécute cette étape après step3
- [step6-CleanupVmware.ps1](step6-CleanupVmware.md) — Nettoyage VMware
