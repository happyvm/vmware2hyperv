# Test-VeeamFlows.ps1 — Validation flux réseau Veeam

Validation des flux réseau Veeam Backup & Replication 12.3 selon le rôle de la machine.

## Synopsis

```powershell
# Mode interactif
.\Test-VeeamFlows.ps1

# Mode non-interactif depuis un hôte Hyper-V
.\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ProxyServer px01 -HyperVHosts hv02,hv03 -ExportCSV C:\Temp\flows.csv

# Mode continu toutes les 2 minutes
.\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01 -ContinuousIntervalMinutes 2
```

## Description

Sélectionne le rôle de la machine courante et ne demande que les variables nécessaires pour ce rôle. Teste uniquement les flux **sortants** depuis cette machine.

Basé sur la matrice de ports Veeam Backup & Replication 12.3.

## Rôles disponibles

| Rôle | Description | Cibles testées |
|------|-------------|----------------|
| `VBR` | Serveur VBR (proxy séparé) | vCenter, HyperV hosts, SCVMM, [ESXi], [SQL], [Proxy] |
| `VBRProxy` | Serveur VBR + proxy intégré | vCenter, HyperV hosts, SCVMM, [ESXi], [SQL] |
| `Proxy` | Proxy Veeam dédié | VBR, HyperV hosts |
| `SCVMM` | Serveur SCVMM | VBR, HyperV hosts, [SQL] |
| `HyperV` | Hôte Hyper-V | VBR, [Proxy], [autres hôtes Hyper-V] |

## Paramètres

| Paramètre | Type | Défaut | Description |
|-----------|------|--------|-------------|
| `-Role` | string | menu interactif | Rôle : VBR, VBRProxy, Proxy, SCVMM, HyperV |
| `-VBRServer` | string | — | FQDN/IP du serveur VBR |
| `-ProxyServer` | string | — | FQDN/IP du proxy Veeam |
| `-HyperVHosts` | string[] | — | Hôtes Hyper-V (séparés par des virgules) |
| `-SCVMMServer` | string | — | FQDN/IP du serveur SCVMM |
| `-VCenterServer` | string | — | FQDN/IP du vCenter |
| `-ESXiHosts` | string[] | — | Hôtes ESXi source (optionnel, pour NBD port 902) |
| `-SQLServer` | string | — | FQDN/IP du serveur SQL (optionnel) |
| `-ExportCSV` | string | — | Export CSV des résultats |
| `-ContinuousIntervalMinutes` | int | — | Intervalle en minutes pour tests continus |

## Exemples

### VBR + Proxy intégré (source VMware → cible Hyper-V)
```powershell
.\Test-VeeamFlows.ps1 -Role VBRProxy -VCenterServer vcenter01 `
    -ESXiHosts esxi01,esxi02 -HyperVHosts hv01,hv02,hv03 `
    -SCVMMServer scvmm01 -SQLServer sql01
```

### Hôte Hyper-V simple
```powershell
.\Test-VeeamFlows.ps1 -Role HyperV -VBRServer vbr01
```

## Notes

- Référence : matrice de ports Veeam Backup & Replication 12.3
- Teste uniquement les flux sortants
- Supporte le mode continu (`-ContinuousIntervalMinutes`) pour monitoring

## Voir aussi

- [Test-HyperVNodeReadiness.ps1](Test-HyperVNodeReadiness.md) — Validation nœuds Hyper-V
- [README.md](../README.md) — Vue d'ensemble du projet