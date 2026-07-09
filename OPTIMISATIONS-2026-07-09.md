# Optimisations identifiées — vmware2hyperv — 2026-07-09

Revue de performance du pipeline complet. Le code est déjà bien optimisé par endroits
(cache d'inventaire SCVMM de step3, requêtes bulk de step-precheck et run-migration,
import Veeam paresseux du worker). Les points ci-dessous sont classés par gain estimé.

> ✅ = déjà appliqué dans ce commit. Les autres sont des propositions, à prendre dans
> l'ordre du tableau de synthèse en fin de document.

---

## ✅ 0. step2 : reconnexion vCenter inutile pour l'email (appliqué)

step2 déconnectait vCenter puis appelait `stepx-premigration_mail.ps1`, qui se
reconnectait immédiatement au même vCenter (connexion PowerCLI complète : 5-15 s +
prompt de credentials si le pass-through échoue). L'appel mail est désormais fait
**avant** `Disconnect-VCenter`, avec `-SkipVCenterLogin`.

---

## ✅ 1. step-XX-PostMigrationChecks : 1 round-trip SCVMM par VM et par itération (appliqué)

**Fichier** : `step-XX-PostMigrationChecks.ps1` (lignes 276-278)

`Test-SCVMMVmHealth` fait un `Invoke-SCVMMCommand` **par VM**, et chaque scriptblock
refait `Get-SCVMMServer` (handshake SCVMM complet). Pour un lot de 50 VM en polling
60 s, cela fait 50 connexions + 50 round-trips par minute, pendant potentiellement des
heures.

**Proposition** : batcher toutes les VM en attente dans **un seul** scriptblock qui
boucle côté SCVMM — exactement le pattern déjà utilisé par `Get-SCVMMVmInventory` dans
`step-XX-StartVM.ps1` (une connexion, une liste de noms, un objet résultat par VM).

**Appliqué** : `Test-SCVMMVmHealth` prend désormais `-VmEntries` (le lot complet) et
boucle côté SCVMM dans un seul scriptblock — une connexion et un round-trip par
itération, quel que soit le nombre de VM.

---

## ✅ 2. step3-MigrateVM : boucle de validation LiveMigration trop bavarde (appliqué)

**Fichier** : `step3-MigrateVM.ps1` (lignes 1193-1208)

Chaque poll (15 s, jusqu'à 600 s) exécute `Update-SCVMMVirtualMachine` **puis**
`Get-SCVMMVmRuntimeState`, soit 2 `Invoke-SCVMMCommand` distincts, chacun refaisant
`Get-SCVMMServer` + `Get-SCVirtualMachine`. Au pire : 40 polls × 2 commandes × 2 requêtes
= 160 appels SCVMM **par VM**, multiplié par 5 workers en parallèle.

**Proposition** : fusionner refresh + lecture d'état dans un seul scriptblock
(`Read-SCVirtualMachine` puis retour de l'état, une seule connexion).

**Appliqué** : `Get-SCVMMVmRuntimeState -Refresh` fait le `Read-SCVirtualMachine` et la
lecture d'état dans le même scriptblock ; `Update-SCVMMVirtualMachine` (devenue sans
appelant) a été supprimée. Par poll : 1 connexion / 1 lookup au lieu de 2 / 3.

---

## 3. `Get-SCVMMServer` ré-exécuté dans chaque scriptblock

**Fichiers** : `step3-MigrateVM.ps1` (11 occurrences), `step-XX-StartVM.ps1`,
`step-XX-PostMigrationChecks.ps1`

Chaque `Invoke-SCVMMCommand` ouvre sa « connexion » SCVMM via `Get-SCVMMServer`. Or la
session compat WinPS est **persistante** (c'est déjà exploité par le cache
`$script:ScvmmInventoryCacheByServer`) : la connexion peut être mise en cache de la même
façon.

**Proposition** : dans les scriptblocks, remplacer
`$server = Get-SCVMMServer -ComputerName $VmmServerName` par un helper mis en cache :

```powershell
if (-not $script:CachedVmmServer -or $script:CachedVmmServerName -ne $VmmServerName) {
    $script:CachedVmmServer = Get-SCVMMServer -ComputerName $VmmServerName
    $script:CachedVmmServerName = $VmmServerName
}
$server = $script:CachedVmmServer
```

À faire proprement dans le cadre du refactoring step3 (fonction partagée enregistrée
dans la session compat — voir `doc/refactoring-step3.md`).

**Gain estimé** : élimine des dizaines de handshakes par VM migrée. **Effort** : 1 h
(couplé au refactoring).

---

## ✅ 4. step1 : requêtes vCenter en N+1 (appliqué)

**Fichier** : `step1-TagResources_CreateVeeamJob.ps1`

Trois motifs N+1 dans les boucles :
- ligne ~131 : `Get-VM -Name $vmName` **par ligne CSV** → un seul `Get-VM -Name <liste>`
  en amont + hashtable par nom (pattern déjà présent dans `run-migration.ps1` l.385-390) ;
- ligne ~104 : `Get-VM -Id $assignment.Entity.Id` **par assignment** dans la boucle de
  cleanup → un seul `Get-VM -Id <liste d'ids>` ;
- ligne ~137 : `Get-TagAssignment -Entity $vm` **par VM** → un seul
  `Get-TagAssignment -Category $TagCategory` indexé par entity Id (pattern déjà présent
  dans `step-precheck.ps1` l.661-677).

**Appliqué** : `Get-VM -Name <liste>` unique + hashtable, `Get-VM -Id <liste>` unique
pour le cleanup, `Get-TagAssignment -Category` en bulk indexé par entity Id (avec repli
par VM si la requête bulk échoue). Les lignes CSV dupliquées sont désormais ignorées
avec un warning (l'ancien code retirait puis re-posait le tag).

---

## ✅ 5. Get-VMUptime : chargement de toutes les VM puis filtrage client (appliqué)

**Fichier** : `lib.ps1` (lignes 548-580), utilisé par step0 et step0-mail

`Invoke-VMwareGetVM` (= `Get-VM`) matérialise **toutes** les VM du vCenter (objets
complets), puis filtre `PowerState -eq "PoweredOn"` côté client. Sur un vCenter de
plusieurs milliers de VM, c'est lent et mémoire-intensif.

**Proposition** : `Get-View -ViewType VirtualMachine -Filter @{'Runtime.PowerState'='poweredOn'}`
avec `-Property Name, Guest, Runtime.BootTime` (filtre serveur + projection — pattern
déjà utilisé dans `step-precheck.ps1` l.610-635). Attention : adapter le mock
`Invoke-VMwareGetVM` des tests `lib.Tests.ps1`.

**Appliqué** : nouveau wrapper `Invoke-VMwareGetPoweredOnVMView` (`Get-View` avec filtre
`Runtime.PowerState=poweredOn` et projection `Name/Guest/Runtime.BootTime`) ;
`Get-VMUptime` consomme les vues, mocks des tests adaptés.

---

## 6. step3 : 5 workers construisent chacun le même inventaire SCVMM

**Fichier** : `step3-MigrateVM.ps1` (cache `Get-ScvmmInventoryCache`)

Chaque worker (processus séparé) charge son propre inventaire complet
(`Get-SCVMNetwork` + `Get-SCVMSubnet` + `Get-SCPortClassification` + uplinks du logical
switch). Avec 5 workers : 5 inventaires identiques, généralement dans la même minute.

**Proposition** (2 niveaux) :
1. *Court terme* : résoudre les mappings VLAN → VMNetwork/VMSubnet **une fois dans
   run-migration** (qui connaît déjà tous les VLAN du lot) et passer les noms résolus
   dans le payload de tâche. Les workers n'auraient plus qu'à résoudre nom → objet.
2. *Long terme* : voir le refactoring step3 (`doc/refactoring-step3.md`) qui isole
   l'inventaire dans un module dédié.

**Gain estimé** : -80 % de requêtes d'inventaire SCVMM au démarrage du lot.
**Effort** : 2-3 h (niveau 1).

---

## ✅ 7. Écriture de logs : `Add-Content` ligne à ligne, partagé entre threads (appliqué)

**Fichiers** : `lib.ps1` (`Write-MigrationLog`), `step-XX-StartVM.ps1` (`Write-JobLog`)

Chaque ligne de log ouvre/écrit/ferme le fichier. Deux points d'attention :
- dans `step-XX-StartVM.ps1`, plusieurs ThreadJobs écrivent **le même** `$LogFile` en
  parallèle → risque d'`IOException` (« file in use ») et de lignes perdues ;
- dans les boucles de polling, le coût I/O est mesurable mais secondaire.

**Appliqué** : chaque ThreadJob écrit dans un log dérivé du log principal avec un
suffixe `-<VMName>` (dérivation dans `Start-WinRmRemediationJob`). Le log principal
conserve le suivi d'orchestration.

---

## 8. Micro-optimisations (à faire opportunément)

| Où | Quoi |
|---|---|
| `run-migration.ps1` l.566 | `Unblock-File` sur tous les .ps1 à chaque run — inutile hors première exécution ; ignorer les erreurs coûte peu, laisser tel quel ou conditionner à la présence du flux `Zone.Identifier` |
| `step3-MigrateVM.ps1` | ✅ appliqué — `VMNetworksById`/`VMNetworksByExactName` ajoutés au cache, `Resolve-ScvmmVlanMapping` n'a plus de scan linéaire |
| `step2` boucle d'arrêt | `Get-VM -Name $pendingNames` toutes les 10 s : correct (bulk), mais le timeout de 300 s est global au lot et non par VM — une VM lente peut consommer la fenêtre des autres ; acceptable, à documenter |
| `worker-step3.ps1` | quand la queue est vide mais `dispatch.complete` absent, poll de 3 s : OK (cas transitoire uniquement) |
| `stepx-premigration_mail.ps1` | ✅ appliqué — `Set-PowerCLIConfiguration -Scope Session` |

---

## Synthèse

| # | Optimisation | Gain | Statut |
|---|---|---|---|
| 0 | step2 : mail avant déconnexion vCenter | 1 connexion PowerCLI par lot | ✅ appliqué |
| 1 | PostMigrationChecks : batch SCVMM | ~50× moins d'appels/itération | ✅ appliqué |
| 2 | Validation LiveMigration : refresh+état fusionnés | ÷4 charge SCVMM en phase 3 | ✅ appliqué |
| 4 | step1 : suppression des N+1 vCenter | O(3N) → O(3) requêtes | ✅ appliqué |
| 5 | Get-VMUptime : filtre serveur Get-View | dépend de la taille du vCenter | ✅ appliqué |
| 7 | Un log par ThreadJob (StartVM) | fiabilité | ✅ appliqué |
| 3 | Cache de connexion SCVMM dans la session compat | dizaines de handshakes/VM | ⏳ avec le refactoring step3 (étape 2 du plan) |
| 6 | Mappings VLAN résolus une fois dans run-migration | -80 % inventaires SCVMM | ⏳ avec le refactoring step3 |
