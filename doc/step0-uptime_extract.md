# step0-uptime_extract.ps1 — Extraction uptime VMware

Extraction des données d'uptime des VMs VMware et export CSV.

## Synopsis

```powershell
.\step0-uptime_extract.ps1
.\step0-uptime_extract.ps1 -Tag HypMig-lot-118 -OutputCsvPath D:\Scripts\uptime_vm.csv
```

## Description

Se connecte à vCenter et récupère l'uptime de toutes les VMs (ou filtrées par `-Tag`).
Affiche une table dans la console et exporte les résultats en CSV.

L'uptime est calculé via les informations VMware Tools (`BootTime` du guest ou `Runtime.BootTime` en fallback).

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-VCenterServer` | string | `Config.VCenter.Server` | Serveur vCenter |
| `-OutputCsvPath` | string | `Config.Paths.OutputCsv` | Chemin du CSV de sortie |
| `-Tag` | string | — | Tag pour filtrer les VMs et le nom du log |
| `-LogFile` | string | auto-généré | Fichier de log |

## Format de sortie CSV

| Colonne | Description |
|---------|-------------|
| `VMName` | Nom de la VM |
| `OS` | Nom complet de l'OS invité |
| `BootTime` | Date/heure de démarrage |
| `Uptime` | Uptime formaté (ex: `12 days, 5 hours, 30 minutes`) |

## Logs

```
{LogDir}/step0-uptime{-Tag}-{yyyyMMdd}.log
```

## Dépendances

- `lib.ps1` — `Connect-VCenter`, `Get-VMUptime`, `Write-MigrationLog`
- `config.psd1`
- Module `VMware.PowerCLI`

## Variante email

Voir [step0-uptime_extract_mail.ps1](step0-uptime_extract_mail.md) pour la version qui envoie les résultats par email.

## Voir aussi

- [step0-uptime_extract_mail.ps1](step0-uptime_extract_mail.md)
- [lib.ps1](lib.md) — fonction `Get-VMUptime`