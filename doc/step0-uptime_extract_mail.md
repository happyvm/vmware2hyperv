# step0-uptime_extract_mail.ps1 — Uptime VMware par email

Extraction de l'uptime des VMs VMware et envoi par email HTML.

## Synopsis

```powershell
.\step0-uptime_extract_mail.ps1 -MailTo admin@domain.local
.\step0-uptime_extract_mail.ps1 -MailTo admin@domain.local -Tag HypMig-lot-118
```

## Description

Variante email de `step0-uptime_extract.ps1`. Se connecte à vCenter, récupère l'uptime des VMs, formate les résultats en tableau HTML et les envoie via SMTP.

Utile pour les rapports d'uptime planifiés avant une campagne de migration.

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-VCenterServer` | string | `Config.VCenter.Server` | Serveur vCenter |
| `-SMTPServer` | string | `Config.Smtp.Server` | Serveur SMTP |
| `-MailFrom` | string | `Config.Smtp.From` | Adresse expéditeur |
| `-MailTo` | string | **Obligatoire** | Adresse(s) destinataire |
| `-Tag` | string | — | Tag pour filtrer les VMs |
| `-LogFile` | string | auto-généré | Fichier de log |

## Format de l'email

L'email contient un tableau HTML avec les colonnes :
- **VM Name** — nom de la VM
- **OS** — OS invité
- **Boot Time** — date/heure de démarrage
- **Uptime** — uptime formaté

## Logs

```
{LogDir}/step0-uptime-mail{-Tag}-{yyyyMMdd}.log
```

## Dépendances

- `lib.ps1` — `Connect-VCenter`, `Get-VMUptime`, `Send-HtmlMail`, `ConvertTo-HtmlEncoded`
- `config.psd1` — sections `VCenter`, `Smtp`
- Module `VMware.PowerCLI`

## Voir aussi

- [step0-uptime_extract.ps1](step0-uptime_extract.md) — Export CSV simple
- [lib.ps1](lib.md) — fonction `Send-HtmlMail`