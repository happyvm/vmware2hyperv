# Analyse VMware / PowerCLI des scripts de migration — 2026-08-20

Périmètre : chaîne `powershell-migration/` **côté source VMware** — tout ce qui
passe par PowerCLI : `lib.ps1` (connexion vCenter), `step0-precheck.ps1`,
`step1-TagResources_CreateVeeamJob.ps1`,
`step2-ShutdownVM_StartBackupVeeam.ps1`, `step5-ValidateMigration.ps1`,
`step6-CleanupVmware.ps1`, `Invoke-Rollback.ps1` et le bloc de résolution VLAN
de `run-migration.ps1`.

Passe symétrique de `ANALYSE-SCVMM-HYPERV-2026-08-20.md` (même journée, même
branche), qui couvrait la cible SCVMM/Hyper-V.

État de départ (pwsh 7.6.5, Linux) : Pester **376 verts / 0 rouge**
(après la passe SCVMM), `Test-ScriptParse` propre, PSScriptAnalyzer 60 findings
préexistants.

---

## Priorité 1 — Bugs

### W1. Le filtre d'entité des tags ne matche jamais (3 occurrences)

```powershell
Where-Object { $_.Entity -and $_.Entity.GetType().Name -eq 'VirtualMachine' }
```

`Get-TagAssignment` renvoie des entités dont le type **runtime** est la classe
d'implémentation PowerCLI — `UniversalVirtualMachineImpl` (PowerCLI 12/13 sur
vSphere 6.5+) ou `VirtualMachineImpl` — **jamais** le nom d'interface nu
`VirtualMachine`. `GetType()` retourne toujours le type concret, donc la
comparaison `-eq 'VirtualMachine'` est constamment fausse et **écarte la
totalité des affectations**.

Le dépôt savait pourtant le faire : `Get-VMwareClusterNameForVm`
(`run-migration.ps1`) teste `-match 'Cluster|ClusterImpl'`, précisément parce
que les noms d'impl portent un suffixe. Les trois filtres de tags utilisaient
`-eq`.

Conséquences par script, toutes silencieuses (le code journalise « rien à
faire » et poursuit) :

| Script | Effet |
|--------|-------|
| `step1` | Le nettoyage des affectations de tags précédentes **ne s'exécute jamais**. Une VM retirée du CSV conserve son tag de lot, reste donc dans le périmètre du job Veeam (qui cible le tag) et repart en sauvegarde/migration. |
| `step2` | La liste des VM du lot est toujours vide → « No VM with tag » → **l'email de pré-migration n'est jamais envoyé**. |
| `step6` | « No VMware VM found with tag. Nothing to cleanup » → **le nettoyage VMware ne supprime jamais rien**. |

**Correctif** : fonction partagée `Test-VmwareVirtualMachineEntity` dans
`lib.ps1`, utilisée par les trois scripts. Elle accepte deux signaux
indépendants pour survivre à un renommage de type PowerCLI : le nom de type
d'implémentation (`-match 'VirtualMachine'`) et l'`Id` de l'objet managé, que
vSphere préfixe toujours par le type (`VirtualMachine-vm-1234`).

Note sur `step6` (destructif) : accepter l'`Id` fait aussi passer un *template*
(`TemplateImpl`, `Id = VirtualMachine-vm-…`). Ce n'est pas un risque : les deux
scripts résolvent ensuite l'entité via `Get-VM -Id`, qui ne renvoie pas les
templates — l'entrée est alors ignorée avec un avertissement.

### W2. `Resolve-AdapterVlanId` — le rejet du VLAN 0 est du code mort

```powershell
if ($rawId -ge 1 -and $rawId -le 4094) { return [string]$rawId }   # rejette 0
...
if ([string]$distributedPortGroup.VlanConfiguration -match '\d+') {
    return [string]$matches[0]                                     # ...et le réintroduit
}
```

La garde `-ge 1` écarte bien `VlanId = 0`, mais la ligne suivante racle le
premier nombre de la représentation textuelle de `VlanConfiguration` : pour un
port group non taggé, `'VLAN 0'` redonne **`'0'`**.

Le test `tests/step3-MigrateVM.Tests.ps1` documentait exactement ce bug :
l'`It` s'appelle **« rejects VLAN 0 (untagged) from DVS VlanId »** et son
assertion était `$result | Should -Be '0'` — c'est-à-dire le comportement que
son propre nom dit devoir être empêché. Le test était vert.

Même mécanisme pour un **port group trunk** : `'Trunk (0-4094)'` donne `'0'`,
et `'Trunk (1-4094)'` donne `'1'`. Un port group trunk n'a pas de VLAN unique ;
la valeur produite est inventée.

En aval, ce `'0'` traverse toute la chaîne comme un VLAN numérique valide. Côté
SCVMM, `Get-ScvmmInventoryCache` exclut explicitement le VLAN 0 de ses clés
(« VLAN 0 means untagged in SCVMM; never a valid VMware VLAN mapping key ») :
`Resolve-ScvmmVlanMapping -VlanKey '0'` bascule donc sur la correspondance par
nom/description et rattache la carte à **n'importe quel VMNetwork dont le nom
contient un zéro**.

**Correctif** : une garde unique `$isUsableVlanId` (1-4094) appliquée à
**tous** les chemins de résolution, y compris le repli textuel et le port group
standard (où `4095` signifie « tous les VLAN »). Un `VlanId` explicite hors
plage est traité comme une réponse, pas comme un échec : les replis plus laxistes
ne sont plus consultés. Les configurations trunk sont détectées
(`Ranges`, ou `Trunk` dans la chaîne) et ignorées. Un port group sans VLAN
exploitable retombe sur `"PortGroup not found"`, ce qui est la réponse honnête.

**Cause racine du test vert** : `Resolve-AdapterVlanId` était définie *inline*
dans `run-migration.ps1`, et le test en gardait une **copie** dans son
`BeforeAll`. La copie a divergé de la production. La fonction est donc déplacée
dans `lib.ps1` — même geste que l'extraction de `Step3.NetworkMapping.ps1`
(cf. `doc/refactoring-step3.md` §5) — et le test dot-source désormais
l'implémentation réelle.

### W3. `step2` — arrêt et débranchement de VM homonymes

`Get-VM -Name` renvoie **un objet par correspondance**, et vCenter autorise le
même nom de VM dans plusieurs dossiers ou datacenters — au point que
`step0-precheck.ps1` refuse explicitement ces noms
(« Ambiguous VM name: multiple VMs share this name in vCenter »).

`step2`, qui est l'étape destructive, ne faisait aucune vérification :

```powershell
$vmObj = VMware.VimAutomation.Core\Get-VM -Name $vmName -ErrorAction SilentlyContinue
...
if ($vmObj.PowerState -eq "PoweredOff") { ... }
VMware.VimAutomation.Core\Stop-VMGuest -VM $vmObj ...
```

Trois effets sur un nom en double :

1. `Stop-VMGuest -VM <tableau>` arrête **toutes** les homonymes, y compris une
   VM de production hors périmètre ;
2. `Disconnect-VmNetworkAdapters` re-résolvait la VM par nom de son côté et
   débranchait donc **les cartes réseau de toutes les homonymes** ;
3. `$vmObj.PowerState -eq "PoweredOff"` sur un tableau ne renvoie pas un
   booléen mais le **sous-ensemble correspondant** — donc une valeur *vraie*
   dès qu'**une** homonyme est éteinte. La VM réellement allumée était alors
   journalisée « already powered off », jamais arrêtée, et sauvegardée à chaud.

**Correctif** : toutes les VM du lot sont résolues **avant** la moindre action.
Un nom ambigu est journalisé puis fait échouer l'étape avant tout arrêt — même
posture que la garde existante « refusing to shut down VMs from other batches ».
`Disconnect-VmNetworkAdapters` reçoit l'objet déjà résolu au lieu de le
re-chercher (un aller-retour vCenter en moins par VM).

### W4. `step1` — comparaison d'un objet catégorie avec un nom

```powershell
Get-TagAssignment -Entity $vm | Where-Object { $_.Tag.Category -eq $TagCategory }
```

`$_.Tag.Category` est un objet `TagCategory`, `$TagCategory` une chaîne : la
comparaison ne matche jamais. C'est le chemin de **repli**, emprunté quand la
requête groupée `Get-TagAssignment -Category` échoue. Dans ce cas les tags
précédents ne sont pas retirés, et comme la catégorie est créée en
`-Cardinality Single`, le `New-TagAssignment` qui suit échoue : le repli censé
sauver l'étape la casse.

**Correctif** : comparer `[string]$_.Tag.Category.Name`.

### W5. `Invoke-Rollback` — la VM rallumée n'est pas celle qui a été inspectée

`Get-VmwareVmState` résolvait la VM avec `-Server $VcenterServer` et
`Select-Object -First 1`, mais l'allumage la re-cherchait **par nom, sans
`-Server`** :

```powershell
$vm = VMware.VimAutomation.Core\Get-VM -Name $VMName | Where-Object { $_.PowerState -eq 'PoweredOff' } | ...
```

Sur un nom en double, la VM démarrée peut être une autre que celle dont l'état
vient d'être lu et journalisé dans le manifeste de rollback.

**Correctif** : `Get-VmwareVmState` remonte l'`Id` (moref) de la VM inspectée,
et l'allumage fait `Get-VM -Id … -Server $VcenterServer`. Le manifeste et
l'action portent sur le même objet, par construction.

---

## Transversal — `$null.Propriété` sous StrictMode (suite)

Même classe que la passe SCVMM. Côté VMware :

- `Get-VMwareClusterNameForVm` (`run-migration.ps1`) faisait
  `$parent = $VMObject.VMHost.Parent` sans garde. Une VM orpheline ou dont
  l'hôte est déconnecté expose un `VMHost` nul → l'exception **interrompt toute
  la passe de résolution VLAN du lot** pour une seule VM.
- `Get-VmwareVmState` (`Invoke-Rollback.ps1`) : `[string]$vm.VMHost.Name`
  (corrigé dans la passe SCVMM du même jour, rappelé ici pour mémoire).

**Correctif** : garde de présence avant déréférencement.

---

## Priorité 2 — Constats non corrigés

- **Crédentiel vCenter redemandé à chaque étape, et blocage en non-interactif.**
  `$script:VCenterCredentialFallback` (`lib.ps1`) est portée par le scope de
  dot-source : `run-migration.ps1` invoque `step1`/`step2` avec `&`, chacun
  dot-source `lib.ps1` dans **son propre** scope, donc le cache n'est jamais
  partagé et l'opérateur est resollicité à chaque étape. Pire : le repli est un
  `Get-Credential` inconditionnel — sous `-NonInteractive`, un échec de
  pass-through Windows fait **attendre indéfiniment** au lieu d'échouer
  proprement. Le correctif demande de trancher la provenance des crédentiels
  (portée `$global:`, coffre, ou paramètre explicite) : hors périmètre d'une
  passe de correction de bugs.
- **`DefaultVIServerMode Multiple` + cmdlets sans `-Server`.** `Connect-VCenter`
  impose le mode `Multiple`, et la plupart des appels PowerCLI (`Get-Tag`,
  `Get-VDPortgroup`, `Get-VM`, `Remove-VM`) omettent `-Server`. Sans effet
  aujourd'hui — un seul vCenter est configuré — mais le jour où une seconde
  connexion coexiste, ces cmdlets s'exécutent sur **toutes** les connexions,
  `Remove-VM -DeletePermanently` compris.
- **Sessions vCenter fuitées sur chemin d'erreur.** `step1` et `step2` appellent
  `Disconnect-VCenter` en fin de script, hors `try/finally` : une exception en
  cours de route laisse la session ouverte. Sans conséquence pratique (le
  processus se termine), contrairement à `step5`/`step6` qui utilisent
  correctement `finally`.
- **Cache de port group standard partagé entre hôtes.**
  `$StandardPortGroupCache` est indexé par nom seul, alors qu'un port group
  standard existe par hôte et peut porter un VLAN différent sur chacun. La
  boucle retient le premier VLAN numérique rencontré.
- **`step0` — `ShouldProcess` partiel.** Le message ne cite que
  `$assignmentsToRemove[0].Tag.Name` alors que toutes les affectations sont
  retirées (cosmétique).

---

## Récapitulatif

| # | Fichier | Type | Gravité | Statut |
|---|---------|------|---------|--------|
| W1 | step1 / step2 / step6 | Filtre d'entité de tag jamais vrai | Haute | Corrigé |
| W2 | run-migration.ps1 (+ test) | VLAN 0 / trunk inventés ; garde morte | Haute | Corrigé |
| W3 | step2 | Arrêt/débranchement de VM homonymes | Haute | Corrigé |
| W4 | step1 | Objet catégorie comparé à un nom | Moyenne | Corrigé |
| W5 | Invoke-Rollback.ps1 | VM rallumée ≠ VM inspectée | Moyenne | Corrigé |
| — | run-migration.ps1 | `$null.VMHost` sous StrictMode | Moyenne | Corrigé |
| P2 | (divers) | Constats non corrigés | Basse | Documenté |

## Validation

- Pester : **399 verts, 0 rouge** (376 avant cette passe ; 23 nouveaux tests
  dans `tests/vmware-regressions.Tests.ps1`, dont **20 échouent** sur le code
  d'avant — vérifié par `git stash`). `tests/step3-MigrateVM.Tests.ps1` exerce
  désormais la vraie `Resolve-AdapterVlanId` et non une copie, et son test
  VLAN 0 assure enfin ce que son nom annonce.
- `Test-ScriptParse.ps1 -Path .` : propre.
- PSScriptAnalyzer : **aucun finding nouveau**.
