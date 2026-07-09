# stepx-premigration_mail.ps1 — Email pré-migration

Envoi d'un email HTML listant les VMs taggées avant leur migration.

## Synopsis

```powershell
.\stepx-premigration_mail.ps1 -tagName HypMig-lot-118 -recipientGroup internal
```

## Description

Interroge vCenter pour toutes les VMs portant le tag spécifié et envoie un email HTML avec la liste des VMs et leur état (Up&Running / Shutdown). Les groupes de destinataires sont définis dans `config.psd1` sous la section `Recipients`.

## Paramètres

| Paramètre | Type | Requis | Défaut | Description |
|-----------|------|--------|--------|-------------|
| `-tagName` | string | Oui | — | Tag du lot de migration |
| `-recipientGroup` | string | Oui | — | Clé du groupe dans `Recipients` |
| `-SkipVCenterLogin` | switch | Non | — | By-passe la connexion vCenter |
| `-vCenterServer` | string | Non | `Config.VCenter.Server` | Serveur vCenter |
| `-smtpServer` | string | Non | `Config.Smtp.Server` | Serveur SMTP |
| `-smtpPort` | int | Non | `Config.Smtp.Port` | Port SMTP |
| `-mailFrom` | string | Non | `Config.Smtp.From` | Adresse expéditeur |
| `-LogFile` | string | Non | auto-généré | Fichier de log |

## Groupes de destinataires

```powershell
# config.psd1
Recipients = @{
    internal  = @("admin@domain.local", "manager@domain.local")
    provider  = @("support@provider.com")
}
```

## Format de l'email

L'email contient un tableau HTML avec :
- **Name** — nom de la VM
- **State** — `Up&Running` (PoweredOn) ou `Shutdown` (PoweredOff)

## Logs

```
{LogDir}/stepx-premigration-mail-{tagName}-{yyyyMMdd}.log
```

## Dépendances

- `lib.ps1` — `Connect-VCenter`, `Send-HtmlMail`, `ConvertTo-HtmlEncoded`
- `config.psd1` — sections `VCenter`, `Smtp`, `Recipients`
- Module `VMware.PowerCLI`

## Voir aussi

- [step2-ShutdownVM_StartBackupVeeam.ps1](step2-ShutdownVM_StartBackupVeeam.md) — Appelle ce script