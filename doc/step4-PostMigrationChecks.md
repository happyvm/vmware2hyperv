# step4-PostMigrationChecks.ps1 — Vérifications post-migration

Boucle de validation post-migration qui vérifie la conformité des VMs dans SCVMM.

## Synopsis

```powershell
.\step4-PostMigrationChecks.ps1 -Tag HypMig-lot-118
.\step4-PostMigrationChecks.ps1 -Tag HypMig-lot-118 -PollIntervalSeconds 120 -MaxIterations 30
.\step4-PostMigrationChecks.ps1 -CsvFile D:\Scripts\lotissement.csv
```

## Description

Exécute une boucle de vérifications SCVMM jusqu'à ce que toutes les VMs du CSV soient conformes :

- VM exists and is running
- NIC is connected
- Integration Services appear healthy
- High Availability is enabled in SCVMM
- SCVMM backup tag is present (`Tags.BackupTag`)
- Guest IPv4 still matches the expected IP from CSV (`ExpectedIP` / `IP` / `IPAddress` columns)

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-ConfigFile` | string | `config.psd1` | Fichier de configuration |
| `-CsvFile` | string | `Config.Paths.CsvFile` | CSV batch |
| `-ExtractIpCsvFile` | string | `Config.Paths.ExtractIpCsv` | CSV des IPs extraites |
| `-Tag` | string | — | Tag pour filtrer les VMs |
| `-PollIntervalSeconds` | int | `60` | Intervalle entre itérations |
| `-MaxIterations` | int | `0` (illimité) | Nombre max d'itérations |
| `-LogFile` | string | auto-généré | Fichier de log |

## Vérifications

| Check | Description |
|-------|-------------|
| Présence SCVMM | La VM existe dans l'inventaire SCVMM |
| État | VM en cours d'exécution (`Running`) |
| NIC | Carte réseau connectée |
| Integration Services | Services d'intégration healthy |
| Haute disponibilité | HA activé dans SCVMM |
| Tag backup | Tag backup SCVMM présent |
| IP | IPv4 invitée correspond à l'IP attendue du CSV |

## Logs

```
{LogDir}/step4-postcheck{-Tag}-{yyyyMMdd-HHmmss}.log
```

## Dépendances

- `lib.ps1`
- `config.psd1`
- Module `VirtualMachineManager`

## Voir aussi

- [step5-StartVM.ps1](step5-StartVM.md) — Démarrage des VMs
- [step6-CleanupVmware.ps1](step6-CleanupVmware.md) — Nettoyage VMware