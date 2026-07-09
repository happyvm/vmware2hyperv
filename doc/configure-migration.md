# configure-migration.ps1 — Assistant de configuration

Assistant interactif qui pose des questions et écrit `config.local.psd1`.

## Synopsis

```powershell
.\configure-migration.ps1
.\configure-migration.ps1 -Full
```

## Description

`configure-migration.ps1` n'est pas une étape numérotée de la pipeline — c'est un outil à lancer avant (ou entre) les migrations pour renseigner les valeurs propres à l'environnement : serveurs vCenter/SCVMM, SMTP, chemins de CSV, destinataires d'email, etc.

Les réponses sont écrites dans `config.local.psd1`, à côté de `config.psd1`. Ce fichier n'est jamais versionné (voir `.gitignore`) et est fusionné par-dessus `config.psd1` au chargement par tous les scripts de la pipeline (`Import-MigrationConfig` dans `lib.ps1`) — `config.psd1` reste le template versionné avec ses valeurs d'exemple.

Par défaut, seules les valeurs **absentes** de `config.local.psd1` sont demandées : relancer le script après un `git pull` qui a mis à jour des scripts (et donc potentiellement ajouté de nouvelles clés dans `$script:MigrationConfigSchema`, dans `lib.ps1`) ne redemande que les nouvelles questions, sans toucher aux réponses déjà données. Utiliser `-Full` pour tout reposer, par exemple pour changer de vCenter cible.

Ce même mécanisme est déclenché automatiquement par [run-migration.ps1](run-migration.md) lorsqu'il est lancé sans argument.

Les structures complexes (`SCVMM.OperatingSystemMap`, `Precheck.WindowsCredentials`, `MigrationMappings.ClusterMappings`...) ne sont pas couvertes par l'assistant — elles restent éditées à la main dans `config.psd1`.

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-ConfigFile` | string | Non | `config.psd1` (dossier du script) | Template utilisé pour les valeurs par défaut affichées |
| `-Full` | switch | Non | — | Repose toutes les questions, y compris celles déjà répondues |

## Liste des questions posées

Définie dans `$script:MigrationConfigSchema` (`lib.ps1`) :

| Section | Clé | Question |
|---------|-----|----------|
| `VCenter` | `Server` | Serveur vCenter |
| `SCVMM` | `Server` | Serveur SCVMM |
| `HyperV` | `Host1` / `Host2` / `Cluster` / `ClusterStorage` | Hôtes/cluster Hyper-V par défaut |
| `Veeam` | `BackupRepo` / `BackupProxy` (optionnel) | Repository / proxy de backup |
| `Tags` | `Category` / `BackupTag` | Tag vSphere du lot / tag post-migration |
| `Smtp` | `Server` / `Port` / `From` / `Enabled` | Configuration SMTP |
| `Recipients` | `internal` / `infogerant` | Listes de destinataires (emails séparés par des virgules) |
| `Paths` | `CsvFile` / `ExtractIpCsv` (optionnel) / `CmdbExtractCsv` (optionnel) / `LogDir` | Chemins des CSV et des logs |

## Exemple de config.local.psd1 généré

```powershell
# config.local.psd1 — valeurs spécifiques à cet environnement (vCenter, SCVMM, SMTP, chemins...).
# Généré/complété par configure-migration.ps1 — ne pas versionner (voir .gitignore).
# Fusionné par-dessus config.psd1 au chargement (Import-MigrationConfig dans lib.ps1).
@{
    VCenter = @{
        Server = 'vcenter-prod.corp.local'
    }
    Smtp = @{
        Enabled = $true
    }
    Recipients = @{
        internal = @('ops@corp.local', 'infra@corp.local')
    }
}
```

Seules les sections/clés effectivement répondues apparaissent — le reste continue de venir de `config.psd1`.

## Dépendances

- `lib.ps1` — `Import-MigrationConfig`, `Get-MigrationConfigMissingKeys`, `Invoke-MigrationConfigWizard`, `Save-MigrationLocalConfig`, `Merge-Hashtable`
- `config.psd1`

## Voir aussi

- [run-migration.ps1](run-migration.md) — Déclenche cet assistant automatiquement en mode interactif
- [config.psd1](config.md) — Détail des sections de configuration
- [lib.ps1](lib.md) — Fonctions de fusion de configuration
