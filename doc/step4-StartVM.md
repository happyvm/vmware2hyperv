# step4-StartVM.ps1 — Démarrage VMs + Integration Services

Démarre les VMs migrées et configure les Integration Services, avec retrait des VMware Tools.

## Synopsis

```powershell
.\step4-StartVM.ps1 -Tag HypMig-lot-118
```

## Description

Script post-migration qui :
- Démarre chaque VM listée dans le CSV batch
- Monte une ISO Integration Services pour Windows Server 2003/2008
- Tente WinRM (HTTPS puis HTTP) sur Windows Server 2012+ pour uploader et exécuter un script de retrait VMware Tools
- Boucle sur les checks Integration Services SCVMM jusqu'à succès ou timeout
- Reporte les actions manuelles nécessaires si OS < 2012 ou WinRM indisponible

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-ConfigFile` | string | `config.psd1` | Fichier de configuration |
| `-CsvFile` | string | `Config.Paths.CsvFile` | CSV batch |
| `-Tag` | string | — | Tag pour filtrer les VMs |
| `-LogFile` | string | auto-généré | Fichier de log |
| `-IntegrationPollIntervalSeconds` | int | `30` | Intervalle poll Integration Services |
| `-IntegrationMaxIterations` | int | `10` | Itérations max Integration Services |
| `-WinRmRetryDelaySeconds` | int | `15` | Délai entre tentatives WinRM |
| `-WinRmMaxAttempts` | int | `20` | Tentatives max WinRM |

## Flux d'exécution

```
Pour chaque VM du CSV (filtrée par Tag) :
├─ Récupère l'inventaire SCVMM (état, OS configuré)
├─ Démarre la VM (Start-SCVirtualMachine)
├─ Si OS ≤ 2008 :
│  ├─ Monte l'ISO Integration Services (selon OS)
│  └─ Reporte l'action manuelle
├─ Si OS ≥ 2012 :
│  ├─ Attend l'IP invitée
│  ├─ Tente WinRM HTTPS
│  ├─ Fallback WinRM HTTP
│  ├─ Upload + exécution script retrait VMware Tools
│  └─ Si WinRM indisponible → reporte action manuelle
└─ Boucle Integration Services :
   ├─ Vérifie heartbeat, time sync, data exchange, backup, guest services
   └─ Timeout après IntegrationMaxIterations × IntegrationPollIntervalSeconds
```

## Configuration Integration Services

```powershell
IntegrationServices = @{
    IsoByOsFamily = @{
        "2003" = "\\server\share\vmguest2003.iso"
        "2008" = "\\server\share\vmguest2008.iso"
    }
}
```

## Logs

```
{LogDir}/step4-startvm{-Tag}-{yyyyMMdd-HHmmss}.log
```

## Dépendances

- `lib.ps1`
- `config.psd1`
- Module `VirtualMachineManager`

## Voir aussi

- [step5-PostMigrationChecks.ps1](step5-PostMigrationChecks.md) — Vérifications post-migration
- [step6-CleanupVmware.ps1](step6-CleanupVmware.md) — Nettoyage VMware