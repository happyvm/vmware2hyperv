# Test-HyperVNodeReadiness.ps1 — Validation nœuds Hyper-V

Outil de diagnostic complet pour valider la préparation d'un nœud Hyper-V ou d'un cluster de failover.

## Synopsis

```powershell
# Avec fichier de configuration (recommandé)
.\Test-HyperVNodeReadiness.ps1

# Avec config explicite
.\Test-HyperVNodeReadiness.ps1 -ConfigFile C:\Admin\hyperv-check.psd1
```

## Description

Exécute une batterie de tests exhaustive basée sur la documentation Microsoft pour valider qu'un serveur Windows est prêt à devenir un nœud Hyper-V (WS2022/2025) et/ou un nœud de cluster de failover.

## Catégories de tests

| Catégorie | Checks |
|-----------|--------|
| **A. OS** | Édition (Datacenter/Standard), build, cible WS2022/WS2025 |
| **B. Sécurité** | Secure Boot, TPM, BitLocker, VBS/Credential Guard, HVCI |
| **C. Matériel** | CPU virtualisation, SLAT, DEP, RAM, fonctionnalités Hyper-V/Failover-Clustering |
| **D. Réseau** | Nombre de NICs, IPs statiques, RDMA (S2D), DNS, WinRM |
| **E. Active Directory** | Appartenance domaine, atteignabilité DC, compte ordinateur, SPN, délégation Kerberos Live Migration, CredSSP |
| **F. DNS** | Résolution directe/inverse, enregistrements SRV AD, mise à jour dynamique |
| **G. Time** | Synchronisation W32TM, décalage Kerberos < 5 minutes |
| **H. Firewall** | Règles cluster/SMB/Live-Migration, ports TCP critiques |
| **I. Stockage** | SAN (MPIO, ALUA, iSCSI/FC, disques) ou S2D (disques physiques, bus, RDMA, SMB Direct) |
| **J. Cluster** | Recommandation quorum, cohérence cross-node OS/domaine/hotfix, Test-Cluster, ségrégation réseau |
| **K. Compte de service** | Existe et activé, admin local, permissions AD (CreateChild, Write All Properties, dnsNode), scavenging DNS, CNO/VCO |
| **L. Event Log** | Erreurs critiques 24h (System/Application), erreurs disque/stockage/réseau/Hyper-V/Cluster |
| **M. Connectivité** | Ports TCP/UDP : DC, cluster, witness, iSCSI, SCVMM |

## Modes

| Mode | Description |
|------|-------------|
| `PreNode` | Valide cette machine comme hôte Hyper-V standalone |
| `PreCluster` | Valide cette machine et les nœuds distants pour le clustering |
| `Both` | Tous les checks (défaut) |

## Vérifications réseau avancées

- Cohérence IPv6 (activation/désactivation uniforme entre nœuds)
- Détection LBFO déprécié (migrer vers SET sur WS2022/2025)
- Checks NIC par rôle via `NetworkAdapters`/`NetworkRoles`
- MTU / Jumbo frames uniquement sur NICs iSCSI et S2D
- VMQ sur trafic VM, pas sur management/cluster heartbeat
- RSS (Receive Side Scaling)
- RDMA/PFC/DCB uniquement sur stockage S2D ou Live Migration RDMA

## Paramètres

| Paramètre | Type | Description |
|-----------|------|-------------|
| `-ConfigFile` | string | Chemin vers `hyperv-check.psd1` |

## Configuration

```powershell
# hyperv-check.psd1
@{
    Mode = 'Both'
    ClusterName = 'CLUSTER01'
    Nodes = @('HV01', 'HV02')
    # ... paramètres réseau, stockage, AD
}
```

Sans fichier de config, le script passe en mode interactif.

## Codes de sortie

| Code | Signification |
|------|--------------|
| 0 | Tous les tests OK (ou warnings uniquement) |
| 1 | Au moins un test en échec |

## Notes

- Doit être exécuté en tant que Domain Administrator ou compte délégué avec accès lecture aux ACLs AD
- ~2800 lignes, outil de diagnostic interactif avec sortie console colorée
- Références : documentation Microsoft Hyper-V, Failover Clustering, Quorum, AD, S2D

## Voir aussi

- [Test-VeeamFlows.ps1](Test-VeeamFlows.md) — Validation connectivité Veeam
- [README.md](../README.md) — Vue d'ensemble du projet