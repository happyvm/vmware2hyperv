# step-XX-CleanupVmware.ps1 — Nettoyage VMware

Suppression des VMs sources VMware après une migration réussie vers Hyper-V.

## Synopsis

```powershell
.\step-XX-CleanupVmware.ps1 -Tag HypMig-lot-118
```

## Description

Nettoie les ressources VMware après la migration :
- Supprime définitivement les VMs portant le tag de migration et étant éteintes
- Skip les VMs encore powered-on (avec avertissement)
- Supprime le tag VMware après traitement

Ce script doit être exécuté UNIQUEMENT après validation du bon fonctionnement des VMs dans l'environnement Hyper-V.

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-Tag` | string | Oui | — | Tag du lot à nettoyer |
| `-ConfigFile` | string | Non | `config.psd1` | Fichier de configuration |
| `-LogFile` | string | Non | auto-généré | Fichier de log |

## Comportement

```
1. Connexion vCenter
2. Recherche du tag dans VMware
3. Pour chaque VM taggée :
   ├─ PoweredOn → SKIP (avertissement)
   └─ PoweredOff → Remove-VM -DeletePermanently
4. Résumé : deleted=N, skippedPoweredOn=M
```

## Logs

```
{LogDir}/step-XX-cleanup-vmware-{Tag}-{yyyyMMdd}.log
```

## Sécurité

- Ne supprime que les VMs **éteintes** (PoweredOff)
- Les VMs powered-on ne sont jamais supprimées (protection contre les suppressions accidentelles)
- Vérifier que les VMs migrées fonctionnent avant d'exécuter ce script

## Dépendances

- `lib.ps1` — `Connect-VCenter`, `Disconnect-VCenter`
- `config.psd1`
- Module `VMware.PowerCLI`

## Voir aussi

- [step-XX-PostMigrationChecks.ps1](step-XX-PostMigrationChecks.md) — Valider avant de nettoyer
- [step-XX-StartVM.ps1](step-XX-StartVM.md) — Démarrer les VMs avant nettoyage