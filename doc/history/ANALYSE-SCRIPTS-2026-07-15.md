# Analyse des scripts PowerShell du dossier `scripts/` — 2026-07-15

Périmètre : `Configure-SCVMMWSUS.ps1`, `Invoke-SCVMMHostPatchBaseline.ps1`,
`New-SCVMMContentLibrary.ps1`, `Test-HyperVNodeReadiness.ps1`,
`Test-ScriptParse.ps1`, `Test-VeeamFlows.ps1` (+ `hyperv-check.psd1`).

Axes : **bugs**, **performance**, **hardening**.

État de départ vérifié dans cette session :

- `Invoke-ScriptAnalyzer -Settings PSScriptAnalyzerSettings.psd1` : 3 avertissements
  (tous `PSUseBOMForUnicodeEncodedFile`, voir T1).
- `Test-ScriptParse.ps1 -Path scripts` : tous les fichiers parsent proprement.
- Pester `scripts/tests/` : 42/42 verts (pwsh 7.6.3).

Le socle est sain : `Set-StrictMode`, `$ErrorActionPreference = 'Stop'`,
`SupportsShouldProcess`/`ConfirmImpact = 'High'` sur les scripts mutateurs,
credentials via `[PSCredential]`, encodage HTML du rapport, probes TCP avec
`EndConnect`. Les points ci-dessous sont classés par priorité.

---

## Priorité 1 — Bugs à corriger

### T1. Fichiers non-ASCII sans BOM UTF-8 (transversal)

`Invoke-SCVMMHostPatchBaseline.ps1`, `Test-ScriptParse.ps1` et
`scripts/hyperv-check.psd1` contiennent des caractères non-ASCII **sans BOM**.
Tous les scripts déclarent `#Requires -Version 5.1` : Windows PowerShell 5.1
lit un fichier sans BOM en ANSI (Windows-1252), donc :

- les messages français d'`Invoke-SCVMMHostPatchBaseline.ps1` (« Connexion à… »,
  « Remédiation… ») sortent en mojibake sur les machines opérateur ;
- le texte d'aide de `Test-ScriptParse.ps1` (qui contient littéralement `ï»¿`)
  s'affiche corrompu — ironique pour l'outil censé détecter ce problème ;
- les commentaires de `hyperv-check.psd1` sont dégradés à l'édition.

C'est exactement la classe de corruption que `Test-ScriptParse.ps1` a été écrit
pour détecter (voir son en-tête). PSScriptAnalyzer le signale déjà.

**Correctif** : réencoder ces 3 fichiers en UTF-8 avec BOM (les 4 autres
scripts l'ont déjà). Optionnel : ajouter la détection « non-ASCII sans BOM »
dans `Test-ScriptParse.ps1` et/ou un garde-fou CI.

### T2. `Test-ScriptParse.ps1` — le marqueur de conflit `=======` n'est jamais détecté (CRLF)

`scripts/Test-ScriptParse.ps1:48` : le contenu est découpé avec
`$raw -split "`n"`, ce qui laisse le `\r` final sur chaque ligne (les .ps1 du
repo sont matérialisés en CRLF via `.gitattributes`). Le motif `={7}$` ne
matche donc jamais `=======\r` : le séparateur de conflit git du milieu passe
inaperçu (les marqueurs `<<<<<<< ` et `>>>>>>> ` restent détectés grâce à
l'espace qui suit).

**Correctif** : `-split '\r?\n'` ou motif `'^(<{7} |={7}\r?$|>{7} )'`.

### T3. `Invoke-SCVMMHostPatchBaseline.ps1` — jobs « SucceedWithInfo » traités comme échec

`Wait-SCJobCompletion` (ligne 157) lève une exception dès que
`Status -ne 'Completed'`. Les jobs SCVMM peuvent se terminer en
**succès avec informations** (statut `SucceedWithInfo` selon la version VMM) :
une remédiation réussie avec avertissement ferait alors échouer tout le cycle
planifié. À vérifier sur l'environnement cible, puis élargir la liste des
statuts de succès (`'Completed', 'SucceedWithInfo'`).

### T4. `Invoke-SCVMMHostPatchBaseline.ps1` — groupe d'hôtes ambigu ou imbriqué

Lignes 246-250 :

- `Get-SCVMHostGroup -Name` peut retourner **plusieurs** groupes (même nom à
  des chemins différents). `$hostGroup` devient un tableau, `$hostGroup.ID`
  aussi, et le filtre `-eq` ne matche plus rien → le script s'arrête sur un
  « Aucun hôte trouvé » trompeur.
- Le filtre `VMHostGroup.ID -eq $hostGroup.ID` ne retient que les hôtes
  **directement** dans le groupe : les hôtes des sous-groupes sont exclus,
  alors que la doc du paramètre suggère « le groupe contenant les hôtes ».

**Correctif** : détecter et rejeter l'ambiguïté (`if (@($hostGroup).Count -gt 1) { throw … -Path }`),
et cibler `$hostGroup.AllChildHosts` (ou comparer sur le chemin du groupe) pour
inclure les sous-groupes — ou documenter explicitement la non-récursivité.

### T5. `Invoke-SCVMMHostPatchBaseline.ps1` — `$baseline` peut être `$null` en mode `-Confirm`

Si l'opérateur répond « Non » à la création/mise à jour de la baseline mais
« Oui » aux étapes suivantes (ou en cas de mélange `-WhatIf`/`-Confirm`),
`Set-SCBaseline -Baseline $null -VMHost …` (ligne 311) échoue avec une erreur
de binding brute. Ajouter après le bloc création :

```powershell
if (-not $baseline) {
    Write-Host 'Baseline non créée (refus ShouldProcess) — arrêt.'
    return
}
```

### T6. `Test-HyperVNodeReadiness.ps1` — `$dnsNodeClassGuid` peut être non défini (StrictMode)

Le GUID `dnsNode` est déclaré ligne 2241 **à l'intérieur** du `try` de lecture
de la DACL de l'OU (K.3), mais consommé ligne 2338 dans le bloc K.4 (ACL de la
zone DNS). Si le `try` K.3 échoue avant la ligne 2241
(`GetAccessRules` refusé, par ex.), K.4 lève une erreur StrictMode « variable
non définie », avalée par son `catch` avec le message trompeur
« Cannot read DNS zone ACL ». Déplacer les trois GUID de schéma en tête de
fonction (ou en constantes script).

---

## Priorité 2 — Hardening

### H1. `Test-HyperVNodeReadiness.ps1` — échappement LDAP incomplet

L'assainisseur `ConvertTo-LdapEscapedFilterValue` existe et est appliqué dans
`Get-ADComputerForNode`, mais **pas** :

- ligne 2117 : `(samAccountName=$samName)` (section K.1) ;
- ligne 2360 : `(name=$ClusterName)` (section K.5, CNO préprovisionné).

Un nom contenant `* ( ) \` casse le filtre ou l'élargit (injection de filtre
LDAP). Le risque est faible (valeurs fournies par l'opérateur via psd1), mais
la correction est triviale et rend le code cohérent : passer les deux valeurs
par l'assainisseur existant. Ajouter les cas Pester correspondants.

### H2. `Test-VeeamFlows.ps1` — `$ErrorActionPreference = 'SilentlyContinue'` global

Ligne 103. Toutes les erreurs du script sont masquées, pas seulement celles des
probes réseau (qui ont déjà leur `try/catch/finally` dans `Test-Flow`). Une
vraie défaillance (chemin CSV invalide non couvert, saisie interactive sur
stdin fermé, faute de frappe future) devient silencieuse et produit un
diagnostic réseau faux. Passer à `'Stop'` (ou au minimum `'Continue'`) et
laisser les blocs `try/catch` localisés absorber les erreurs attendues.

### H3. `Test-HyperVNodeReadiness.ps1` — un log inaccessible fait tout planter

`Add-Result` → `Write-ReadinessLog` → `Add-Content $script:LogFile` sous
`$ErrorActionPreference = 'Stop'`. Si le chemin de log n'est pas inscriptible
(CWD en lecture seule, chemin réseau perdu), **chaque** `Add-Result` lève — y
compris celui du `catch` d'`Invoke-CheckSection`, ce qui tue le run complet au
lieu de dégrader. Encapsuler l'écriture fichier :

```powershell
try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
catch { if (-not $script:LogWriteWarned) { $script:LogWriteWarned = $true; Write-Warning "Log inaccessible : $($_.Exception.Message) — sortie console uniquement." } }
```

### H4. `New-SCVMMContentLibrary.ps1` — compte bootstrap incohérent avec `-ComputerCredential`

Ligne 406 : `FullAccess` du nouveau partage est accordé à
`[WindowsIdentity]::GetCurrent().Name` (identité **locale**), alors que la
création s'effectue sur le serveur **distant** via la session CIM, potentiellement
sous `-ComputerCredential`. Deux effets : l'ACE bootstrap peut référencer un
compte sans signification sur le serveur cible, et si `-CopySmbPermissions:$false`
le partage reste durablement avec cette unique ACE. Utiliser
`$ComputerCredential.UserName` quand il est fourni, et documenter l'état final
du partage quand la copie des permissions SMB est désactivée.

### H5. Divers (faible enjeu)

- `Test-HyperVNodeReadiness.ps1:1975` : `Test-Path $WitnessShare` →
  `-LiteralPath` (crochets `[]` interprétés comme jokers).
- `Test-HyperVNodeReadiness.ps1` : l'objet COM `Microsoft.Update.AutoUpdate`
  (ligne 392) n'est jamais libéré (`ReleaseComObject` dans un `finally`).
- `New-SCVMMContentLibrary.ps1:482` : `$_.LibraryServer.Name` sans garde null,
  contrairement au style défensif (`PSObject.Properties`) du reste du fichier.

---

## Priorité 3 — Performance

### P1. `Test-HyperVNodeReadiness.ps1` — requêtes distantes séquentielles (sections I, J, M)

Pour chaque nœud distant : `Test-Connection` (2 pings) + 2 × `Get-CimInstance`
+ 2 × `Invoke-Command` (hotfix, feature) + 1 × `Invoke-Command` (LUN), soit ~7
allers-retours WinRM/CIM **en série**. Sur 4 nœuds dont un injoignable, le run
s'étire de plusieurs minutes.

- Ouvrir **une** `New-PSSession`/`New-CimSession` par nœud et la réutiliser ;
- ou exploiter le fan-out natif : `Invoke-Command -ComputerName $Nodes` exécute
  en parallèle (ThrottleLimit 32) et remonte `PSComputerName` pour regrouper.

Même logique section M : chaque port fermé/filtré coûte son timeout complet
(2 s) en série — un DC injoignable = 9 ports × 2 s = 18 s. Lancer les
`BeginConnect` d'un même endpoint en parallèle puis attendre collectivement
(`WaitHandle.WaitAll` ou `Task.WaitAll` sur `ConnectAsync`) diviserait le temps
par le nombre de ports.

### P2. `Test-HyperVNodeReadiness.ps1` — journal ligne à ligne et événements non bornés

- `Add-Content` ouvre/ferme le fichier de log à chaque `Add-Result` (200+ écritures
  par run). Un `StreamWriter` gardé ouvert (ou un buffer vidé en fin de section)
  supprime ce coût — à combiner avec H3.
- Section L : `Get-WinEvent -FilterHashtable` sans `-MaxEvents` charge la
  totalité des événements des 24 h avant `Select-Object -First 3`. Sur un
  serveur bruyant, cela représente des milliers d'objets. Plafonner (ex.
  `-MaxEvents 500`) et afficher « 500+ » quand le plafond est atteint.

### P3. `Invoke-SCVMMHostPatchBaseline.ps1` — filtrage du catalogue d'updates

`Get-SCUpdate` retourne le catalogue entier (souvent des dizaines de milliers
d'objets), filtré ensuite par un **appel de fonction par objet**
(`Test-UpdateClassification`) puis deux passes regex supplémentaires. Inliner
le test dans un unique `Where-Object` avec un `HashSet[string]` des
classifications, et fusionner les trois passes en une seule. Au passage,
exclure si disponibles les correctifs `IsSuperseded`/déclinés, qui gonflent
inutilement la baseline et les scans de conformité.

### P4. `Test-VeeamFlows.ps1` — probes séquentielles

Même schéma que P1 : rôle VBRProxy avec 10 hôtes Hyper-V ≈ 100 tests ; chaque
échec consomme ses 2 s → un pare-feu fermé partout ≈ 3-4 min par cycle (gênant
en mode continu). Options : timeout paramétrable, ou parallélisation des
`ConnectAsync` par section avec agrégation des résultats avant affichage.

---

## Priorité 4 — Qualité / robustesse (mineur)

- **Scopes incohérents** (`Test-HyperVNodeReadiness.ps1`) : les fonctions lisent
  tantôt `$script:StorageType`, tantôt `$StorageType` (idem `Mode`,
  `WitnessShare`, `ServiceAccount`, `ClusterOU`, `ClusterName`,
  `SkipClusterValidation`). Cela fonctionne par remontée de portée, mais une
  future variable locale homonyme casserait silencieusement le comportement.
  Uniformiser sur `$script:`.
- **Section K, condition d'entrée trompeuse** (`Test-HyperVNodeReadiness.ps1:2805`) :
  la section est lancée si `ServiceAccount` **ou** `ClusterOU` est défini, mais
  retourne immédiatement si `ServiceAccount` est vide — configurer uniquement
  `ClusterOU` ne teste donc rien. Aligner la condition (ou le message de skip).
- **Cohérence des correctifs par simple comptage**
  (`Test-HyperVNodeReadiness.ps1:2030`) : deux nœuds avec le même *nombre* de
  KB mais des listes différentes passent PASS. Comparer les `HotFixID`
  (`Compare-Object`) plutôt que le compte.
- **`Test-UdpPort`** (`Test-HyperVNodeReadiness.ps1:2550`) : le socket UDP n'est
  fermé que sur le chemin succès → fuite sur exception. Passer en
  `try/finally` + `Dispose()` comme `Test-TcpPort`. La branche
  `ConnectionReset` retourne la même valeur que le cas général (code mort à
  clarifier ou supprimer).
- **`Test-VeeamFlows.ps1`** : bloc `.PARAMETER ContinuousIntervalMinutes`
  dupliqué dans l'aide (lignes 55-61) ; `exit $script:FailCount` peut dépasser
  255 (tronqué sur certains hôtes non-Windows) — préférer `exit ($FailCount -gt 0 ? 1 : 0)`
  ou borner ; en mode continu, le premier cycle écrase le CSV d'un run
  précédent (assumé, mais mérite une ligne dans l'aide).
- **`New-SCVMMContentLibrary.ps1`** : le script émet un `[pscustomobject]` de
  synthèse **puis** un `Format-Table` — les objets de formatage partent aussi
  dans le pipeline, donc `$r = .\New-SCVMMContentLibrary.ps1 …` capture un
  mélange objet/formatage. Envoyer le tableau vers l'hôte (`| Out-Host`) pour
  garder une sortie objet propre. La comparaison source/destination
  (ligne 290) ne détecte pas l'identité si un côté est en nom court et l'autre
  en FQDN.
- **`Configure-SCVMMWSUS.ps1`** : rien de bloquant. Amélioration possible :
  valider les codes `-Languages` contre la liste WSUS (une faute « fr-FR » au
  lieu de « fr » ne se voit qu'à l'exécution SCVMM).

---

## Récapitulatif

| # | Fichier | Type | Gravité | Statut |
|---|---------|------|---------|--------|
| T1 | 3 fichiers sans BOM | Bug encodage (PS 5.1) | Haute | Corrigé |
| T2 | Test-ScriptParse.ps1 | Bug détection `=======` (CRLF) | Haute | Corrigé |
| T3 | Invoke-SCVMMHostPatchBaseline.ps1 | Bug statut job SucceedWithInfo | Haute (à confirmer) | Corrigé |
| T4 | Invoke-SCVMMHostPatchBaseline.ps1 | Bug groupe ambigu / sous-groupes | Haute | Corrigé |
| T5 | Invoke-SCVMMHostPatchBaseline.ps1 | Bug `$baseline` null (`-Confirm`) | Moyenne | Corrigé |
| T6 | Test-HyperVNodeReadiness.ps1 | Bug portée GUID (StrictMode) | Moyenne | Corrigé |
| H1 | Test-HyperVNodeReadiness.ps1 | Échappement LDAP incomplet | Moyenne | Corrigé |
| H2 | Test-VeeamFlows.ps1 | EAP SilentlyContinue global | Moyenne | Corrigé |
| H3 | Test-HyperVNodeReadiness.ps1 | Log inaccessible = plantage | Moyenne | Corrigé |
| H4 | New-SCVMMContentLibrary.ps1 | ACE bootstrap vs credential distant | Moyenne | Corrigé |
| P1-P4 | Readiness / PatchBaseline / VeeamFlows | Performance (séquentiel, catalogue, log) | Moyenne | Corrigé |
| P4+ | (divers) | Qualité mineure | Basse | Corrigé |

---

## Résolution — 2026-07-15

Tous les points ci-dessus ont été corrigés le jour même sur la branche
d'analyse. Détails d'implémentation notables :

- **T1** : BOM UTF-8 ajouté aux 3 fichiers. Les fichiers de
  `powershell-migration/` et `tests/` présentent le même défaut (24 fichiers
  non-ASCII sans BOM) mais sont **hors périmètre** de cette passe — à traiter
  dans une passe dédiée.
- **T3** : `Wait-SCJobCompletion` accepte `Completed` et `SucceedWithInfo`
  (ce dernier journalise un `Write-Warning` avec `ErrorInfo`).
- **T4** : rejet explicite des groupes homonymes multiples ; les hôtes des
  sous-groupes sont inclus via `AllChildHosts` (repli sur l'ancien filtre par
  `VMHostGroup.ID` si la propriété est absente).
- **P1 (section M)** : nouveaux helpers `New-PortEndpoint` /
  `Invoke-PortEndpointChecks` — tous les `BeginConnect` d'un même lot
  démarrent en parallèle et partagent une seule fenêtre de timeout (un DC
  injoignable coûte ~2 s au lieu de 16 s). Couvert par 5 nouveaux tests
  Pester.
- **P1 (sections I/J)** : comparaison LUN inter-nœuds en un seul
  `Invoke-Command` fan-out (parallélisme WinRM natif, wrapper par nœud pour
  distinguer « zéro disque » d'« échec de requête ») ; hotfix + état de la
  feature Failover-Clustering regroupés en un seul aller-retour par nœud ;
  une seule session CIM par nœud (au lieu de deux connexions). La cohérence
  des correctifs compare désormais les **listes** de `HotFixID`, plus les
  simples comptages.
- **H3/P2** : `Write-ReadinessLog` écrit via un `StreamWriter` unique
  (AutoFlush), résilient — un chemin de log non inscriptible dégrade en
  sortie console avec un unique avertissement au lieu d'avorter le run.

Validation : `Test-ScriptParse` propre, PSScriptAnalyzer **0 finding**
(3 avant), Pester **47/47** (42 existants + 5 nouveaux), test fonctionnel de
la détection de marqueurs de conflit CRLF.
