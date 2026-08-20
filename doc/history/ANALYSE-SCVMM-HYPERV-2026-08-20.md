# Analyse SCVMM / Hyper-V des scripts de migration — 2026-08-20

Périmètre : chaîne `powershell-migration/` côté **SCVMM et Hyper-V**
(`step3/`, `step4-StartVM.ps1`, `step5-ValidateMigration.ps1`,
`Invoke-Rollback.ps1`, `lib.ps1`). Les scripts de `scripts/` ont déjà été
audités le 2026-07-15 (voir `ANALYSE-SCRIPTS-2026-07-15.md`) ; ils n'ont pas
été revus ici, sauf pour réutiliser leurs conventions (heuristique de
conversion mémoire, lectures de propriétés gardées).

État de départ vérifié dans cette session (pwsh 7.6.5, Linux) :

- Pester `tests/` + `scripts/tests/` : **347 verts, 2 rouges** — deux échecs
  préexistants sur `main` (voir S7).
- `Test-ScriptParse.ps1 -Path .` : tous les fichiers parsent proprement.
- `Invoke-ScriptAnalyzer -Settings PSScriptAnalyzerSettings.psd1` : 60 findings
  (BOM manquants, verbes non approuvés, `$using:` — tous préexistants et hors
  périmètre de cette passe).

---

## Priorité 1 — Bugs

### S1. `Invoke-Rollback.ps1` — aucune connexion SCVMM : risque de split-brain

`Get-HyperVVmInfo` et les deux blocs d'arrêt appelaient
`Get-SCVirtualMachine -Name $Name` **sans `-VMMServer`**, et le script ne
faisait jamais de `Get-SCVMMServer`. C'était le seul endroit du dépôt dans ce
cas (tous les autres appels passent par `Get-SCVMMServer -ComputerName …`).

Conséquences, en cascade :

1. sans serveur VMM explicite, les cmdlets ciblent la machine locale — et
   échouent d'emblée dans la session de compatibilité WinPS, où aucune
   connexion VMM n'est établie ;
2. l'erreur était avalée par `-ErrorAction SilentlyContinue`, donc `$vm` est
   `$null` et la VM Hyper-V est rapportée **introuvable** ;
3. le rollback journalise « Hyper-V VM not found in SCVMM — nothing to stop »,
   n'arrête rien, **puis rallume la VM VMware source**.

Résultat : la copie Hyper-V et la source VMware tournent simultanément avec la
même identité et la même IP. C'est exactement ce que le rollback est censé
empêcher.

**Correctif** : `SCVMM.Server` est résolu une fois au démarrage (erreur claire
s'il est absent) et passé à chaque scriptblock via `-VMMServer $server`. En
prime, `Get-HyperVVmInfo` distingue désormais « VM absente » de « requête
SCVMM en échec » (`QueryFailed`) : dans le second cas `Invoke-PowerOnRollback`
**refuse de rallumer la VMware** et remonte l'échec pour cette VM au lieu de
supposer qu'aucune copie ne tourne. L'échec reste cantonné à la VM concernée,
le lot continue.

### S2. `step5-ValidateMigration.ps1` — la mémoire VMM est en Mo, pas en octets

`$memoryGB = [math]::Round([double]$vm.Memory / 1GB, 1)`.

SCVMM expose `VirtualMachine.Memory` en **mégaoctets** (le setter est
`Set-SCVirtualMachine -MemoryMB`). Pour une VM de 4 Go, le calcul donnait
`4096 / 1073741824 ≈ 0.0000038`, arrondi à **0.0**. Le contrôle `MemoryGB`
(`$hv.MemoryGB -eq $vw.MemoryGB`) échouait donc pour **toutes** les VM de tous
les lots, et le rapport de validation affichait « Source: 4 GB | Target: 0 GB ».
Le script ne pouvait structurellement pas rendre un verdict PASS complet.

**Correctif** : nouvelle fonction pure `ConvertTo-ScvmmMemoryGigabytes` dans
`lib.ps1` (avec son jumeau inline dans le scriptblock SCVMM, comme les helpers
IPv4 — `lib.ps1` n'est pas chargé dans la session compat). La garde `> 1e8`
reprend l'heuristique de `ConvertTo-MemoryMegabytes`
(`Invoke-SCVMMHostPatchBaseline.ps1`) pour rester correcte si une version de
VMM renvoyait un jour des octets.

### S3. `step4-StartVM.ps1` — boucle infinie sur une VM absente de SCVMM

La liste de rafraîchissement était filtrée sur `VmFound` :

```powershell
Where-Object { $_.VmFound -and -not $_.DisplayCompleted }
```

Une VM absente de SCVMM au moment du snapshot initial (step3 en échec, ou
inventaire VMM pas encore à jour) n'était donc **plus jamais réinterrogée**.
Comme elle ne peut pas devenir conforme, `$refreshNeeded` reste `$true` — et
`IntegrationMaxIterations` vaut **0 (illimité) par défaut**. Le script tourne
indéfiniment, affiche « VM not found » à chaque rafraîchissement, et ne
remarque jamais son apparition ultérieure dans SCVMM.

**Correctif** : toutes les VM non conformes sont rafraîchies,
`VmFound` est réévalué à chaque snapshot, et une VM qui apparaît est
journalisée, redevient éligible à la remédiation WinRM (`ActionState`
`Skipped` → `Queued`) et est démarrée. Le démarrage tardif est restreint aux
VM qui **viennent** d'apparaître : redemander le démarrage de toute VM
non démarrée à chaque poll saturerait SCVMM pour les VM qui échouent à booter.

### S4. `Resolve-ScvmmVlanMapping` — VMNetwork et VMSubnet appariés au hasard

Dans la passe de repli « VLAN déduit des noms/descriptions » :

```powershell
VMNetwork = $matchingNetworks | Select-Object -First 1
VMSubnet  = $matchingSubnets  | Select-Object -First 1
```

Les deux listes sont **indépendantes** (l'une vient de `VMNetworksByVlan`,
l'autre de `VMSubnetsByVlan`, chacune triée par nom). Rien ne garantit que le
sous-réseau retenu appartienne au VMNetwork retenu. Avec plusieurs objets
portant les mêmes chiffres de VLAN — cas courant : `VLAN-400-A` /
`VLAN-400-B` —, la carte finit attachée au sous-réseau d'un **autre** réseau,
ou `Set-SCVirtualNetworkAdapter` rejette le couple.

**Correctif** : on retient le premier VMNetwork candidat qui possède
réellement l'un des sous-réseaux candidats (comparaison par
`VMNetwork.ID` / `VMNetworkID`, puis par `VMNetworkName`). Le couple non
apparenté reste un dernier recours, et il est alors marqué `Ambiguous` — donc
journalisé en WARNING par `Set-VmNetworkConfiguration` — dès lors que le
sous-réseau désigne explicitement un autre réseau. Un sous-réseau qui n'expose
aucune information de rattachement reste non ambigu : il n'y avait pas de
choix à faire.

### S5. `Step3.NetworkConfig.ps1` — cartes source sans VLAN numérique perdues

```powershell
$adapterMappings = @($AdapterVlanMappings | Where-Object { $_.VlanId -match '^\d+$' })
```

`run-migration.ps1` écrit littéralement `'PortGroup not found'` dans `VlanId`
quand le port group VMware n'est pas résolvable. Ces cartes étaient purement
et simplement supprimées de la liste source, avec deux effets :

- leur `MacAddress` et leur `NetworkName` étaient perdus, alors que
  `networkMappingsBySourceNetworkName` existe précisément pour rattacher une
  carte par nom de réseau source ;
- surtout, la suppression **décale les indices** : le repli par ordre
  apparie ensuite les cartes cibles restantes avec les **mauvaises** cartes
  source (cible n°0 appariée à source n°1, etc.).

**Correctif** : toute carte porteuse d'une information exploitable (VLAN
numérique **ou** nom de réseau **ou** MAC) est conservée, ce qui préserve
l'ordre positionnel et la résolution par nom. Une carte qui ne résout
toujours rien retombe sur le VLAN par défaut, comme avant. La pré-résolution
VLAN ne tente plus `Resolve-ScvmmVlanMapping` sur une valeur non numérique.

### S6. `Step3.NetworkConfig.ps1` — VLAN taggé incohérent avec le sous-réseau

Pour une résolution `source-network-name`, le VLAN appliqué était
`if ($mappingVlan -match '^\d+$') { $mappingVlan } else { $Vlan }` : quand le
VLAN source n'est pas numérique, la carte recevait le VLAN **par défaut de la
VM** tout en étant placée sur le VMNetwork/VMSubnet trouvé par nom. Le tag
VLAN et le sous-réseau divergent — trafic isolé, VM injoignable.

Le correctif S5 rend ce chemin nettement plus fréquent, il fallait donc le
traiter dans la même passe.

**Correctif** : nouvelle fonction `Get-ScvmmSubnetRealVlanId`
(`Step3.ScvmmSession.Functions.ps1`, poussée dans la session compat comme le
reste du fichier) — le VLAN provient du sous-réseau réellement retenu
(`SubnetVLans[].VLanID`, puis `VLanID`), avec repli sur le VLAN source
numérique puis sur le VLAN par défaut. Le VLAN 0 (untagged côté SCVMM) n'est
jamais retenu comme clé.

### S7. `tests/step1-VeeamJob.Tests.ps1` — CI rouge sur `main` (CRLF)

Deux assertions utilisent `(?m)…$` sur le source d'un `.ps1`. `.gitattributes`
matérialise les `.ps1` en **CRLF** ; en regex .NET multiligne, `$` matche avant
`\n` mais pas avant `\r`, donc `[^\r\n]*$` et `…'Stop'$` ne matchent jamais.
Les tests échouaient sur tout runner — y compris la CI — alors que le script
testé est correct. C'est la même classe de bug que T2 (2026-07-15).

**Correctif** : les motifs ancrés se terminent par `\r?$`.

---

## Priorité 2 — Constats non corrigés

Relevés pendant l'analyse, volontairement laissés en l'état (risque ou
bénéfice insuffisant pour cette passe) :

- **`Get-ScvmmInventoryCache` — clé de cache incomplète.** Le cache est indexé
  par nom de serveur seul, alors que son contenu dépend aussi de
  `AllowedVmNetworkNames`, `AllowedVmSubnetNames` et `LogicalSwitch`. Dans un
  worker persistant, les filtres de la première VM sont réutilisés pour les
  suivantes. Sans effet aujourd'hui (ces valeurs viennent de `config.psd1` et
  sont constantes sur un run), mais la clé devrait inclure un hash des filtres.
- **`Get-IntegrationStatusSummary` (step4) — regex trop large.** L'alternative
  `Up` matche « Update required » / « Upgrade available », et `Version` matche
  n'importe quelle chaîne de version : un état d'Integration Services
  « à mettre à jour » est compté comme prêt. Resserrer demande de connaître les
  libellés exacts renvoyés par la version de VMM cible.
- **`step4-StartVM.ps1` — champ mort.** `LastForcedIpRefresh` est initialisé à
  `0` et jamais lu ni écrit.
- **Lectures de propriétés hétérogènes.** `step4`/`step5` définissent
  `Get-VmPropertyText` pour les lectures gardées, puis accèdent directement à
  `$vm.IsHighlyAvailable`, `$vm.Tag`, `$vm.OperatingSystem`,
  `$adapter.IPv4Addresses`. Ces propriétés existent sur tous les objets VMM
  courants, contrairement à `$vm.VMHost` (corrigé, voir ci-dessous), mais
  l'uniformisation reste souhaitable.
- **`Move-VmToSecondHost`** : le repli Hyper-V `Move-VM -Name $Name
  -DestinationHost` s'exécute depuis le runner et suppose que la VM y est
  visible localement ; le message d'erreur final le dit, mais le chemin n'est
  atteignable que sur un nœud Hyper-V.

---

## Transversal — `$null.Propriété` sous StrictMode

Vérifié dans cette session sur pwsh 7.6.5 : avec
`Set-StrictMode -Version Latest`, `$null.Foo` **lève** (« The property 'Foo'
cannot be found on this object »), tout comme l'accès *par point* à une clé de
hashtable absente — seul l'accès *par index* `$h['Foo']` renvoie `$null`.

Or `[string]$vm.VMHost.ComputerName` était écrit sans garde dans
`step4-StartVM.ps1`, `step5-ValidateMigration.ps1` et `Invoke-Rollback.ps1`
(et `[string]$vm.VMHost.Name` côté VMware). `VMHost` vaut `$null` pour une VM
stockée en bibliothèque ou laissée dans un état de cluster incohérent : la
lecture lève **à l'intérieur du scriptblock d'inventaire**, ce qui fait
échouer l'inventaire SCVMM du **lot entier** à cause d'une seule VM.

Ce chemin ne se manifeste qu'en mode direct (module VMM importé in-process) :
via la session de compatibilité WinPS, le scriptblock s'exécute sans
StrictMode. Les deux modes sont supportés par `Invoke-SCVMMCommand`.

**Correctif** : garde `if ($vm.VMHost) { … } else { $null }` aux quatre
emplacements.

---

## Récapitulatif

| # | Fichier | Type | Gravité | Statut |
|---|---------|------|---------|--------|
| S1 | Invoke-Rollback.ps1 | Pas de connexion SCVMM → split-brain | Critique | Corrigé |
| S2 | step5-ValidateMigration.ps1 | Mémoire VMM en Mo lue comme octets | Haute | Corrigé |
| S3 | step4-StartVM.ps1 | Boucle infinie sur VM absente de SCVMM | Haute | Corrigé |
| S4 | Step3.ScvmmSession.Functions.ps1 | VMNetwork/VMSubnet appariés au hasard | Haute | Corrigé |
| S5 | Step3.NetworkConfig.ps1 | Cartes source sans VLAN supprimées | Moyenne | Corrigé |
| S6 | Step3.NetworkConfig.ps1 | VLAN taggé ≠ sous-réseau appliqué | Moyenne | Corrigé |
| S7 | tests/step1-VeeamJob.Tests.ps1 | Regex CRLF → CI rouge sur `main` | Moyenne | Corrigé |
| — | step4 / step5 / Invoke-Rollback | `$null.VMHost` sous StrictMode | Moyenne | Corrigé |
| P2 | (divers) | Constats non corrigés | Basse | Documenté |

## Validation

- Pester : **374 verts, 0 rouge** (347 + 2 rouges avant la passe ; 25 nouveaux
  tests dans `tests/scvmm-hyperv-regressions.Tests.ps1`, dont 19 échouent sur
  le code d'avant — vérifié par `git stash`).
- `Test-ScriptParse.ps1 -Path .` : propre.
- PSScriptAnalyzer : **aucun finding nouveau** (comparaison avant/après sur
  l'ensemble du dépôt).
