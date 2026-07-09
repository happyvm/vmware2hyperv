# Analyse des erreurs — vmware2hyperv — 2026-07-09

Analyse du code effectuée sur l'ensemble du dépôt (21 scripts PowerShell, ~10 600 lignes),
en complément de l'audit `AUDIT-2026-07-09.md`. Validation préalable :

- **Syntaxe** : 0 erreur de parsing sur tous les `.ps1` (PowerShell 7.6.3)
- **Tests Pester** : 122 réussis / 0 échec / 3 ignorés (conditions Windows-only)
- **PSScriptAnalyzer** : 1 « erreur » (faux positif dans un fichier de test) + 21 warnings (majoritairement faux positifs Pester/ThreadJob)

Les erreurs ci-dessous ont été trouvées par lecture du code ; les deux premières ont été
**vérifiées empiriquement**.

---

## 1. CRITIQUE — Les `exit 1` de step2 sont invisibles pour l'orchestrateur

**Fichiers** : `powershell-migration/step2-ShutdownVM_StartBackupVeeam.ps1` (lignes 80, 205, 260, 269),
`powershell-migration/run-migration.ps1` (lignes 110-128, 165-182)

`run-migration.ps1` exécute step2 via l'opérateur d'appel `&` dans un `try/catch`
(`Invoke-OrchestratorStep`). Or `exit 1` dans un script appelé in-process **ne lève pas
d'exception** : il termine seulement le script enfant et positionne `$LASTEXITCODE`,
que l'orchestrateur ne consulte jamais.

Comportement vérifié par test : le catch ne se déclenche pas et l'orchestrateur journalise
**« step2 completed successfully »** puis enchaîne sur step3.

Conséquence concrète — dans chacun de ces cas d'échec de step2 :
- aucune ligne CSV ne porte le tag demandé (l. 80) ;
- des VM refusent de s'éteindre après le power-off forcé (l. 205) ;
- le job Veeam `Backup-<Tag>` est introuvable ou ne démarre pas (l. 260, 269) ;

… l'orchestrateur continue et lance l'**Instant Recovery en step3**, potentiellement à
partir d'un backup obsolète ou inexistant, alors que les VM source peuvent encore tourner
(risque de double exécution / perte de données).

**Correctif proposé** : remplacer les `exit 1` de step2 par `throw` (comme le fait déjà
run-migration lui-même), ou vérifier `$LASTEXITCODE` après `& $Action` dans
`Invoke-OrchestratorStep`.

---

## 2. CRITIQUE — Exécution d'un `.bat` via `powershell.exe -File` (échec systématique)

**Fichier** : `powershell-migration/step-XX-StartVM.ps1` (ligne 431), config
`RemoteActions.WinRm.RemoveVmwareToolsScriptRemotePath = "C:\Temp\remove-vmware-tools.bat"`

Le job WinRM copie le script batch d'installation des Integration Services sur la VM puis
exécute :

```powershell
Invoke-Command -Session $session -ScriptBlock {
    param($ScriptPath)
    powershell.exe -ExecutionPolicy Bypass -File $ScriptPath
} -ArgumentList @($RemoteScriptPath)
```

`powershell.exe -File` **n'accepte que des fichiers `.ps1`** (« …does not have a '.ps1'
extension ») : la remédiation WinRM échoue à chaque tentative, sur les 20 essais, pour
toutes les VM 2012+. Le script `.bat` n'est jamais exécuté.

**Correctif proposé** : `cmd.exe /c $ScriptPath` (et récupérer `$LASTEXITCODE`, le batch
documentant des codes retour 0/1/2).

---

## 3. IMPORTANT — Sélection de session de restauration par préfixe de nom (`-like "$Vm*"`)

**Fichiers** : `powershell-migration/step3-MigrateVM.ps1` (lignes 1414, 1513),
`powershell-migration/step3-StartInstantRecovery.ps1` (ligne 200)

Le suivi Veeam sélectionne la session ainsi :

```powershell
Where-Object { $_.Name -eq $Vm -or $_.Name -eq "$Vm-migrationhyp" -or $_.Name -like "$Vm*" } |
    Sort-Object CreationTime -Descending | Select-Object -First 1
```

Si un nom de VM est le préfixe d'un autre dans le même lot (ex. `WEB1` / `WEB10`), le
filtre retient **les sessions des deux VM** et le tri par date peut renvoyer la session de
la mauvaise VM. Le monitoring de finalisation peut alors déclarer un succès (ou un échec)
sur la base de l'état d'une autre VM.

**Correctif proposé** : restreindre aux correspondances exactes (`-eq $Vm` /
`-eq "$Vm-migrationhyp"`), ou utiliser un motif borné (`-match "^$([regex]::Escape($Vm))(-migrationhyp)?$"`).

---

## 4. IMPORTANT — Échec de LiveMigration avalé : la tâche est marquée « Success »

**Fichier** : `powershell-migration/step3-MigrateVM.ps1` (lignes 1165-1219)

Tout le bloc LiveMigration (SCVMM `Move-SCVirtualMachine`, repli Hyper-V `Move-VM`,
validation avec timeout de 600 s) est enveloppé dans un `try/catch` qui **journalise
l'erreur sans la relancer** :

```powershell
} catch {
    ...
    Write-MigrationLog "[$Name] LiveMigration error: $_" -Level ERROR -LogFile $LogFile
}
```

Une VM restée sur le mauvais hôte (timeout de validation inclus) termine donc en tâche
`done/` avec `Status = "Success"` côté worker. Si ce comportement « non bloquant » est
voulu, il devrait au minimum être remonté dans l'état de la tâche (champ dédié), sinon
relancer l'exception.

---

## 5. IMPORTANT — VLAN invalide : step3 se termine en « SUCCESS » sans aucune post-configuration

**Fichier** : `powershell-migration/step3-MigrateVM.ps1` (lignes 269-274, 1610)

Dans `Invoke-SCVMMNetworkAndPostConfig` :

```powershell
if ($Vlan -notmatch "^\d+$") {
    Write-MigrationLog "[$Name] Invalid VLAN ID: '$Vlan' — network mapping skipped." -Level WARNING ...
    return
}
```

Le `return` sort de **toute** la fonction : réseau, Integration Services, OS SCVMM,
haute disponibilité, LiveMigration et tag de backup sont tous ignorés. Le script principal
journalise ensuite « Migration completed. » (SUCCESS) et le worker classe la tâche en
`done/`. Or `$VlanId` vaut fréquemment une valeur non numérique en amont
(« PortGroup not found », « VM not found », « No network adapter » produits par
run-migration). Une VM sans résolution VLAN traverse donc step3 « avec succès » sans
aucune configuration.

**Correctif proposé** : faire échouer la tâche (throw), ou au minimum propager un état
d'échec exploitable par le worker (le résumé `NetworkConfigurationState=NotDetected` est
aujourd'hui le seul indice).

---

## 6. MOYEN — `exit` dans stepx-premigration_mail.ps1 appelé in-process sans contrôle

**Fichiers** : `powershell-migration/stepx-premigration_mail.ps1` (lignes 79, 101, 107),
`powershell-migration/step2-ShutdownVM_StartBackupVeeam.ps1` (ligne 216)

step2 appelle le script mail via `& $PreMigrationMailScript ...` sans vérifier
`$LASTEXITCODE`. Un groupe de destinataires invalide ou un tag introuvable (exit 1) passe
donc totalement inaperçu. À noter aussi : `Set-PowerCLIConfiguration` (ligne 75) est
invoqué **avant** l'import de PowerCLI (lignes 85-87) — cela repose sur l'auto-chargement
de module et échoue si seul `VCF.PowerCLI` est présent.

---

## 7. MOYEN — Crash si le bloc `Orchestrator` est absent d'un config file custom

**Fichier** : `powershell-migration/run-migration.ps1` (ligne 531)

```powershell
$Config.Orchestrator.ContainsKey('InstantRecoveryStartDelaySec')
```

Avec un `-ConfigFile` personnalisé sans bloc `Orchestrator`, `.ContainsKey()` est appelé
sur `$null` → « You cannot call a method on a null-valued expression », **après** que
step1/step2 ont déjà tourné. Protéger comme pour les autres clés (`if ($Config.Orchestrator -and ...)`).

---

## 8. MOYEN — État « ConfiguredWithWarning » inatteignable dans le worker

**Fichiers** : `powershell-migration/worker-step3.ps1` (lignes 73-94),
`powershell-migration/step3-MigrateVM.ps1` (ligne 1108)

`Get-NetworkConfigurationState` teste d'abord la présence de
« Network configured (default VLAN » (→ `Configured`), puis « fallback mapping used »
(→ `ConfiguredWithWarning`). Or la ligne de succès est **toujours** écrite quand la
configuration aboutit, y compris quand des adaptateurs sont retombés sur le VLAN par
défaut (les warnings sont écrits avant, ligne 1097/1103). Une configuration dégradée est
donc toujours résumée `Configured`. Inverser l'ordre des tests.

---

## 9. MOYEN — step-XX-CleanupVmware : divergences doc/code et portée du tag

**Fichier** : `powershell-migration/step-XX-CleanupVmware.ps1`

- Le `.DESCRIPTION` annonce « removes the VMware tag itself after all VMs are processed » :
  le code ne supprime jamais le tag.
- `Get-Tag -Name $Tag` sans `-Category` (ligne 54) : un tag homonyme d'une **autre**
  catégorie peut être retenu, et ses VM éteintes supprimées définitivement
  (`Remove-VM -DeletePermanently`). Filtrer sur `$Config.Tags.Category`.

Le même défaut `Get-Tag` sans catégorie existe dans
`step1-TagResources_CreateVeeamJob.ps1` (lignes 89, 125) et
`stepx-premigration_mail.ps1` (ligne 97).

---

## 10. MINEUR

- **`step0-uptime_extract_mail.ps1`** : `-MailTo` est typé `[string]` alors que la doc
  annonce « address(es) » ; `"a@x,b@y"` devient une adresse unique invalide
  (`Send-HtmlMail` attend `[string[]]`).
- **`lib.ps1` `Disconnect-VCenter`** : `Disconnect-VIServer` sans `-Server` en mode
  `Multiple` déconnecte **toutes** les sessions vCenter du processus, y compris celles
  ouvertes par ailleurs.
- **Fichiers `.psd1` sans BOM** (`config.psd1`, `hyperv-check.psd1`,
  `PSScriptAnalyzerSettings.psd1`) : les commentaires accentués seront mal décodés sous
  Windows PowerShell 5.1 (sans impact fonctionnel, valeurs en ASCII).
- **`Send-HtmlMail`** (lib.ps1) : les échecs d'envoi sont seulement journalisés (pas de
  throw) — acceptable pour du mail, mais à connaître.
- **PSScriptAnalyzer** : l'unique « Error » (`PSAvoidUsingConvertToSecureStringWithPlainText`
  dans `tests/lib.Tests.ps1:199`) est un faux positif de mock ; les
  `PSUseDeclaredVarsMoreThanAssignments` dans les tests sont des faux positifs Pester
  (variables `BeforeAll` utilisées dans les blocs `It`) ; les 12
  `PSUseUsingScopeModifierInNewRunspaces` de `step-XX-StartVM.ps1` sont des faux positifs
  (paramètres du scriptblock passés via `-ArgumentList` à `Start-ThreadJob`).

---

## Synthèse des priorités

| # | Sévérité | Fichier | Correctif | Statut |
|---|---|---|---|---|
| 1 | Critique | step2 + run-migration | `exit 1` → `throw` + garde `$LASTEXITCODE` dans l'orchestrateur | ✅ Corrigé |
| 2 | Critique | step-XX-StartVM l.431 | `powershell -File .bat` → `cmd.exe /c` + gestion des codes retour 0/1/2 | ✅ Corrigé |
| 3 | Important | step3-MigrateVM, step3-StartInstantRecovery | motif borné `^VM($|[^\w-])` au lieu de `-like "$Vm*"` | ✅ Corrigé |
| 4 | Important | step3-MigrateVM l.1213 | échec LiveMigration propagé (`throw`), cas « runner sans Hyper-V » conservé en warning | ✅ Corrigé |
| 5 | Important | step3-MigrateVM l.271 | VLAN invalide (et VM absente de SCVMM) = échec de tâche | ✅ Corrigé |
| 6 | Moyen | stepx-premigration_mail | `exit` → `throw`, import avant Set-PowerCLIConfiguration ; appel rendu non bloquant dans step2 | ✅ Corrigé |
| 7 | Moyen | run-migration l.531 | garde null sur `Orchestrator` | ✅ Corrigé |
| 8 | Moyen | worker-step3 | tests d'état combinés (`ConfiguredWithWarning` atteignable) | ✅ Corrigé |
| 9 | Moyen | cleanup/step1/mail | `Get-Tag`/`New-TagAssignment` scopés à la catégorie ; doc cleanup alignée sur le code | ✅ Corrigé |
| 10 | Mineur | step0-uptime_extract_mail | `-MailTo` en `[string[]]`, `exit` → `throw` | ✅ Corrigé |

Validation post-correctifs : 0 erreur de syntaxe, 122 tests Pester verts, aucun nouveau
warning PSScriptAnalyzer. Restent volontairement non traités : BOM des `.psd1`
(commentaires seulement), portée globale de `Disconnect-VCenter` (comportement assumé),
`Send-HtmlMail` non bloquant (par conception).
