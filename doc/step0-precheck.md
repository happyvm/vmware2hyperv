# step0-precheck.ps1 — Pré-vérification vCenter

Script de pré-vérification qui audite l'inventaire VMware avant migration.

## Synopsis

```powershell
.\step0-precheck.ps1 -VCenter vcenter.domain.local -InputCsv D:\Scripts\lot.csv
```

## Description

`step0-precheck.ps1` lit un CSV contenant `vmname;tag` et effectue les opérations suivantes :

- Crée/applique un tag vSphere dans une catégorie Single-cardinality
- Calcule par lot : nombre de VMs, vCPUs, RAM configurée, stockage datastore
- Lit l'attribut personnalisé `NB_last_backup`
- Récupère l'uptime en jours via VMware Tools :
  - **Linux** : commande `uptime`
  - **Windows 2003/2008** : `wmic`
  - **Windows 2012+** : CIM
- Flag les VMs dont l'uptime dépasse le seuil configuré (`UptimeThresholdDays`, défaut 45j)
- Pour Windows 2003/2008/2008 R2 : exécute `ipconfig /all` et stocke la sortie dans `C:\temp`
- Essaie jusqu'à 5 credentials Windows locaux, exporte le label de celui qui a réussi
- Crée un fichier marqueur racine sur chaque volume Windows non-CD-ROM et supprime les lettres de lecteur CD-ROM sans reboot (Windows 2003 à 2025)

## Format CSV d'entrée

```csv
vmname;tag
SRV-APP-001;LOT-01
SRV-DB-001;LOT-01
SRV-LIN-001;LOT-02
```

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-VCenter` | string | `config.psd1` | Serveur vCenter |
| `-InputCsv` | string | `config.psd1` | CSV d'entrée |
| `-OutputFolder` | string | `.` | Dossier de sortie |
| `-TagCategoryName` | string | `MigrationLot` | Nom de la catégorie de tag |
| `-CustomAttributeName` | string | `NB_last_backup` | Attribut personnalisé pour le backup |
| `-ToolsWaitSecs` | int | `20` | Timeout VMware Tools |
| `-SkipGuestOperations` | switch | — | Désactive les opérations invité |
| `-LogFile` | string | `""` | Fichier de log |
| `-UptimeThresholdDays` | int | `45` | Seuil d'alerte uptime |
| `-CsvDelimiter` | string | `;` | Délimiteur CSV |

## Fichiers de sortie

| Fichier | Contenu |
|---------|---------|
| `migration_lot_detail.csv` | Détail par VM |
| `migration_lot_summary.csv` | Résumé par lot |
| `migration_lot_errors.csv` | Erreurs rencontrées |

## Configuration

Les credentials Windows et Linux sont définis dans `config.psd1` :

```powershell
Precheck = @{
    WindowsCredentials = @(
        @{ Label = "ADMIN-01"; UserName = "DOMAIN\admin"; Enabled = $true }
    )
    LinuxCredential = @{
        Label    = "LINUX-ADMIN-01"
        UserName = "root"
        Enabled  = $true
    }
}
```

Les mots de passe ne sont jamais stockés — ils sont demandés interactivement au runtime.

## Détection de l'année Windows

Le script détecte l'année Windows via :
1. Année explicite dans le nom complet de l'OS invité (ex: `Windows Server 2022`)
2. GuestId VMware pour les OS sans nom explicite (ex: `winNetEnterprise` → 2003)

## Dépendances

- `config.psd1`
- Module `VMware.PowerCLI`

## Voir aussi

- [config.psd1](config.md) — Configuration