# Proposition de refactoring — découpage de step3-MigrateVM.ps1

*2026-07-09 — document de conception, aucun code modifié.*

## 1. Constat

`step3-MigrateVM.ps1` fait **1 629 lignes** et concentre toute la logique de la phase 3 :

| Bloc actuel | Lignes (~) | Contenu |
|---|---|---|
| Params + config + résolution de cible | 79-132 | contrat d'appel du worker |
| `Start-SCVMMHostMigration`, `Get-SCVMMVmRuntimeState`, `Update-SCVMMVirtualMachine` | 134-246 | helpers SCVMM unitaires |
| `Invoke-SCVMMNetworkAndPostConfig` | 248-1250 | **~1 000 lignes** : validation config, inventaire, mapping VLAN, matching adaptateurs, Integration Services, HA, LiveMigration, tag backup |
| → dont scriptblock distant | 304-1078 | **~780 lignes** exécutées dans la session compat WinPS, avec 6 fonctions imbriquées |
| `Set-SCVMMOperatingSystem` | 1252-1305 | mapping OS SCVMM |
| Connexion SCVMM + reprise « IndigoLayer » | 1307-1342 | |
| Phase Instant Recovery : start + attente | 1344-1487 | Veeam |
| Phase Instant Recovery : finalisation | 1489-1590 | Veeam |
| Phase réseau/post-config (appel) | 1596-1629 | |

Problèmes induits :

1. **Testabilité** : `tests/step3-MigrateVM.Tests.ps1` ne couvre que les helpers de
   *run-migration* (Resolve-AdapterVlanId, etc.). La logique la plus risquée — matching
   MAC/ordre des adaptateurs, résolution VLAN→VMNetwork — est enfouie dans un scriptblock
   et n'est pas testable unitairement.
2. **Duplication** : le motif de sélection de session Veeam existe en **3 copies**
   (2 dans step3-MigrateVM, 1 dans step3-StartInstantRecovery) — le bug du préfixe
   (`-like "$Vm*"`) a dû être corrigé 3 fois.
3. **Modes de rejeu opaques** : `ForceNetworkConfigOnly` / `CommitAndNetwork` /
   `SkipNetworkAndPostConfig` combinent des flags qui sautent des morceaux d'une
   fonction monolithique, au lieu d'appeler ou non des phases nommées.
4. **Observabilité** : le worker devine l'état réseau en *grepant le log* de la VM
   (fragile — cf. bug n°8 de l'analyse) faute de résultat structuré.

## 2. Contrainte structurante : la session compat WinPS

Le gros scriptblock est exécuté via `Invoke-Command -Session WinPSCompatSession`
(cf. `Invoke-SCVMMCommand` dans lib.ps1). **Les fonctions doivent exister dans la
session distante**, c'est pourquoi elles sont aujourd'hui imbriquées dans le scriptblock.
Un simple découpage en fichiers dot-sourcés côté PS7 ne suffit donc pas.

Deux stratégies possibles :

**Option A — enregistrement des fonctions dans la session (recommandée)**

Un fichier ne contenant *que des définitions de fonctions* est poussé une fois dans la
session compat (et dot-sourcé localement pour le mode sans compat) :

```powershell
function Initialize-ScvmmSessionFunction {
    param([string[]]$FunctionFiles)

    $compatSession = Get-PSSession -Name 'WinPSCompatSession' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    foreach ($file in $FunctionFiles) {
        if ($compatSession) {
            Invoke-Command -Session $compatSession -FilePath $file   # définit les fonctions côté WinPS
        }
        . $file                                                       # et côté PS7 (mode direct)
    }
}
```

Les scriptblocks passés à `Invoke-SCVMMCommand` deviennent courts : ils *appellent* des
fonctions déjà définies. Bonus performance : avec les **workers persistants**, les
fonctions ne sont parsées qu'une fois par worker (aujourd'hui, ~780 lignes sont
re-sérialisées et re-parsées à chaque appel), et on peut y loger le cache de connexion
`Get-SCVMMServer` (optimisation n°3 du document OPTIMISATIONS).

**Option B — scriptblock généré depuis un fichier**

`[scriptblock]::Create((Get-Content -Raw $file))` : garde l'auto-containment actuel,
fichier analysable par PSSA/tests, mais conserve le re-parse à chaque appel et n'aide
pas le partage. À réserver aux cas ponctuels.

## 3. Arborescence cible

```
powershell-migration/
├── step3-MigrateVM.ps1                 # ~150 lignes : params, contexte, appels de phases
└── step3/
    ├── Step3.VeeamRecovery.ps1         # phase Instant Recovery (PS7, via Invoke-VeeamCommand)
    │     Find-VmRestoreSession           ← motif borné, PARTAGÉ avec step3-StartInstantRecovery
    │     Assert-VeeamScvmmRegistered
    │     Start-VmInstantRecovery
    │     Wait-InstantRecoveryUserAction
    │     Complete-InstantRecovery        (commit + attente Success/Warning/Failed)
    ├── Step3.ScvmmConnection.ps1       # PS7
    │     Connect-Step3Scvmm              (connexion + reprise IndigoLayer, l.1307-1342 actuelles)
    ├── Step3.ScvmmSession.Functions.ps1  # ★ fonctions POUSSÉES dans la session compat
    │     Get-CachedScvmmServer           (cache de connexion — nouveau)
    │     Get-ScvmmInventoryCache         (l.319-595 actuelles)
    │     Resolve-ScvmmVlanMapping        (l.599-662)
    │     Get-ScvmmNetworkAdapters        (l.714-749 + boucle de retry)
    │     ConvertTo-NormalizedMacAddress / Test-IsZeroMacAddress / Convert-ToScvmmStaticMacAddress
    ├── Step3.NetworkMapping.ps1        # logique PURE (testable sans SCVMM)
    │     Get-AdapterMappingPlan          (passes MAC exact → ordre → VLAN défaut,
    │                                      l.856-998 actuelles, entrées/sorties = tableaux)
    ├── Step3.NetworkConfig.ps1         # PS7, orchestre le mapping via Invoke-SCVMMCommand
    │     Set-VmNetworkConfiguration      (applique le plan : Set-SCVirtualNetworkAdapter)
    │     Set-VmIntegrationServices       (l.1046-1059 + description)
    ├── Step3.PostConfig.ps1            # PS7
    │     Set-SCVMMOperatingSystem        (déplacée telle quelle)
    │     Register-VmHighAvailability     (l.1117-1163)
    │     Move-VmToSecondHost             (LiveMigration + validation, l.1165-1219,
    │                                      avec refresh+état fusionnés — optimisation n°2)
    │     Set-VmBackupTag                 (l.1221-1232)
    └── Step3.TaskResult.ps1
          New-Step3TaskResult / Write-Step3TaskResult
                                          (résultat JSON par phase — remplace le grep de log
                                           de Get-NetworkConfigurationState dans worker-step3)
```

Chargement dans `step3-MigrateVM.ps1` :

```powershell
Get-ChildItem "$PSScriptRoot\step3\Step3.*.ps1" |
    Where-Object Name -ne 'Step3.ScvmmSession.Functions.ps1' |
    ForEach-Object { . $_.FullName }

Initialize-ScvmmSessionFunction -FunctionFiles @("$PSScriptRoot\step3\Step3.ScvmmSession.Functions.ps1")
```

## 4. Le script principal après découpage (squelette)

```powershell
# step3-MigrateVM.ps1 (~150 lignes)
param( ... contrat inchangé : worker-step3 n'est pas modifié ... )

. "$PSScriptRoot\lib.ps1"
# ... chargement des modules step3/ (cf. §3) ...

$context = [pscustomobject]@{
    VMName = $VMName; VlanId = $VlanId; AdapterVlanMappings = $adapterVlanMappings
    SCVMMServer = $SCVMMServer; HyperVHost = $HyperVHost; HyperVHost2 = $HyperVHost2
    HyperVCluster = $HyperVCluster; ClusterStorage = $ClusterStorage
    BackupJobName = $BackupJobName; BackupTag = $BackupTag
    Config = $Config; LogFile = $LogFile
}
$result = New-Step3TaskResult -Context $context

Connect-Step3Scvmm -Context $context

if (-not $SkipInstantRecoveryStart) {
    Start-VmInstantRecovery        -Context $context -Result $result
    Wait-InstantRecoveryUserAction -Context $context -Result $result
}
if (-not $SkipInstantRecoveryFinalization) {
    Complete-InstantRecovery       -Context $context -Result $result
}
if (-not $SkipNetworkAndPostConfig) {
    Set-VmNetworkConfiguration     -Context $context -Result $result
    Set-VmIntegrationServices      -Context $context -Result $result
    Set-SCVMMOperatingSystem       -Context $context -Result $result
    Register-VmHighAvailability    -Context $context -Result $result
    Move-VmToSecondHost            -Context $context -Result $result
    Set-VmBackupTag                -Context $context -Result $result
}

Write-Step3TaskResult -Result $result   # JSON à côté du log VM ; lu par worker-step3
```

Bénéfices immédiats de cette forme :

- les modes de rejeu deviennent lisibles : `CommitAndNetwork` = sauter les deux premiers
  blocs ; `ForceNetworkConfigOnly` = ne garder que le troisième ; on peut même exposer
  `-Phases IR,Commit,Network,HA,Move,Tag` à terme ;
- chaque phase écrit son état (`Success`/`Warning`/`Failed`/`Skipped`) dans `$result` :
  le worker n'a plus à grepper le log, et `run-migration` peut agréger un tableau de bord
  par phase ;
- `Move-VmToSecondHost` peut redevenir « non bloquant mais visible » si souhaité :
  échec enregistré comme `Warning` dans le résultat au lieu d'un throw, décision
  explicite et localisée.

## 5. Extraction de la logique pure (exemple : matching adaptateurs)

La partie la plus précieuse à tester est le plan de mapping (l.856-998). Extraite en
fonction pure, elle ne touche plus SCVMM :

```powershell
function Get-AdapterMappingPlan {
    param(
        [object[]]$TargetAdapters,     # @{ Index; MacAddress }
        [object[]]$SourceAdapters,     # @{ MacAddress; NetworkName; VlanId }
        [string]$DefaultVlan
    )
    # passes : 1) MAC exact  2) ordre résiduel  3) VLAN par défaut
    # retour : @( @{ TargetIndex; Source; Resolution = 'mac'|'index'|'default' } )
}
```

Tests Pester directs, sans mock SCVMM : NIC sans MAC, MAC 00:00…, plus de NIC cible que
source (et inversement), doublons de MAC, casse/format des MAC. C'est le cœur du risque
de mauvaise configuration réseau — aujourd'hui zéro test.

Même approche pour `Resolve-ScvmmVlanMapping` (déjà quasi-pure : prend le cache, rend un
mapping) et `Find-VmRestoreSession` (le motif borné corrigé, testé une fois, utilisé
partout).

## 6. Plan de migration incrémental

Chaque étape est livrable seule, sans changement de comportement (sauf mention) :

| Étape | Contenu | Risque | Effort |
|---|---|---|---|
| 1 | Extraire `Find-VmRestoreSession` dans `step3/Step3.VeeamRecovery.ps1`, remplacer les 3 copies (step3-MigrateVM ×2, step3-StartInstantRecovery ×1) + tests du motif | faible | 2 h |
| 2 | Créer `Initialize-ScvmmSessionFunction` + `Step3.ScvmmSession.Functions.ps1` (inventaire + résolution VLAN + cache `Get-CachedScvmmServer`), réduire le scriptblock géant à l'orchestration | moyen (session compat) | 1 j |
| 3 | Extraire `Get-AdapterMappingPlan` (pure) + suite de tests Pester | faible | 0,5 j |
| 4 | Sortir HA / LiveMigration / tag backup de `Invoke-SCVMMNetworkAndPostConfig` vers `Step3.PostConfig.ps1` (fusion refresh+état au passage — optimisation n°2) | moyen | 0,5 j |
| 5 | Extraire la phase Veeam complète (`Step3.VeeamRecovery.ps1`) | faible | 0,5 j |
| 6 | Introduire `Step3.TaskResult.ps1` + adapter `worker-step3.ps1` (suppression du grep de log) — *changement de contrat worker↔step3, à tester sur un lot pilote* | moyen | 0,5 j |
| 7 | Réécrire `step3-MigrateVM.ps1` en orchestrateur de phases (§4) | moyen | 0,5 j |

Total : ~4 jours, découpables en 7 PRs indépendantes. Ordre conçu pour que les étapes
les plus rentables (1-3 : duplication supprimée, cœur testable) arrivent en premier.

## 7. Points de vigilance

- **Contrat du worker inchangé** jusqu'à l'étape 6 : mêmes paramètres, mêmes codes
  d'échec (throw). Les étapes 1-5 sont invisibles de l'extérieur.
- **Objets désérialisés** : tout ce qui traverse la session compat arrive désérialisé
  (test existant `GetType().FullName -notlike 'Deserialized.*'` l.723) — les fonctions
  poussées dans la session doivent continuer à manipuler les objets *côté WinPS* et ne
  renvoyer que des données simples (le découpage §3 respecte cette frontière).
- **`$script:` scope dans la session compat** : les caches (`ScvmmInventoryCacheByServer`,
  futur `CachedVmmServer`) persistent par session — comportement déjà exploité, à
  documenter dans `Step3.ScvmmSession.Functions.ps1`.
- **PSScriptAnalyzer** : les nouveaux fichiers de fonctions sont analysables (contrairement
  au contenu du scriptblock actuel, partiellement ignoré par certaines règles).
- **Dot-sourcing multiple** : coût de chargement négligeable (~ms) ; les workers sont
  persistants donc payé une fois par worker.
