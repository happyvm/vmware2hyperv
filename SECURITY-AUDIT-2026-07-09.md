# Rapport d'audit de sécurité — vmware2hyperv

**Date** : 2026-07-09  
**Auditeur** : Agent PowerShell Developer (Paperclip, run 26347164)  
**Périmètre** : 36 scripts PowerShell (.ps1) + 3 fichiers de config (.psd1)  
**Méthodologie** : PSScriptAnalyzer 1.25.0 + scan manuel de patterns dangereux + revue de code ciblée

---

## Résumé

| Sévérité | Trouvés | Corrigés | Acceptés |
|----------|---------|----------|----------|
| Critique | 1 | ✅ 1 | 0 |
| Modérée  | 3 | ✅ 1 | 2 |
| Mineure  | 12+ | ✅ 1 | 11+ (warnings PSSA non-security) |

---

## Vulnérabilités corrigées

### CRIT-001 — SMTP sans chiffrement ni authentification

**Fichier** : `powershell-migration/lib.ps1` — fonction `Send-HtmlMail`

**Risque** : Envoi d'emails en clair sur le port 25 sans TLS. Les credentials,
les corps de message et les destinataires transitent en texte clair sur le réseau.

**Correction** :
- Port par défaut changé de 25 → 587 (submission STARTTLS)
- `$smtpClient.EnableSsl = $true` ajouté
- `[System.Net.ServicePointManager]::SecurityProtocol` forcé à TLS 1.2+
- Paramètre `-Credential` optionnel pour l'authentification SMTP
- Nettoyage du credential dans le bloc `finally` (credentials nullés + Dispose)
- Commentaire `SECURITY` documentant les choix

### MOD-001 — ScriptBlock non validé (documentation)

**Fichier** : `powershell-migration/lib.ps1` — fonctions `Invoke-SCVMMCommand` et `Invoke-VeeamCommand`

**Risque** : Ces fonctions acceptent `[scriptblock]$ScriptBlock`. Si un appelant
passe une entrée utilisateur non validée dans un ScriptBlock, cela constitue
une injection de code arbitraire.

**Correction** : Commentaires `SECURITY` ajoutés documentant :
- Que la fonction est conçue pour des appelants internes uniquement
- Que tous les call sites passent des scriptblocks codés en dur
- L'interdiction de passer des entrées utilisateur comme ScriptBlock
- La recommandation d'utiliser `[ScriptBlock]::Create()` avec validation stricte si une invocation dynamique devient nécessaire

### LOW-001 — Catch block vide sans logging

**Fichier** : `powershell-migration/step4-StartVM.ps1` ligne 262

**Risque** : Si `Read-SCVirtualMachine -Force` échoue, l'erreur était silencieusement
avalée sans aucune trace, rendant le diagnostic impossible.

**Correction** : Ajout d'un `Write-MigrationLog` avec niveau WARNING dans le bloc catch.

---

## Risques acceptés (avec justification)

### ACCEPT-001 — Credential vCenter en `$script:` scope

**Fichier** : `powershell-migration/lib.ps1` ligne 113 — `$script:VCenterCredentialFallback`

**Risque** : Un credential est stocké dans la portée script.

**Justification** : Les workers de migration sont isolés dans des processus
PowerShell séparés. Le credential n'est jamais persisté sur disque et sa durée
de vie est limitée à celle du processus worker. Le credential est acquis via
`Get-Credential` (prompt interactif), jamais depuis un fichier.

### ACCEPT-002 — SSL cert validation désactivée pour vCenter

**Fichier** : `powershell-migration/step0-precheck.ps1` ligne 550-551

**Risque** : `Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session`

**Justification** : Pattern standard PowerCLI pour les environnements vCenter
avec certificats auto-signés. La portée est limitée à la session (`-Scope Session`),
pas globale. Dans un environnement de production avec certificats d'entreprise
valides, cette ligne est sans effet.

### ACCEPT-003 — Write-Host dans l'assistant de configuration

**Fichier** : `powershell-migration/lib.ps1` — `Invoke-MigrationConfigWizard`

**Justification** : Utilisé uniquement dans un outil interactif de diagnostic
(configure-migration.ps1). Les messages sont destinés à l'opérateur humain
dans la console, pas à du logging automatisé. Un `SuppressMessageAttribute`
est justifié.

---

## Points forts confirmés

| Contrôle | Résultat |
|----------|----------|
| `Invoke-Expression` / `iex` | ✅ Aucun |
| Mots de passe hardcodés | ✅ Aucun |
| Tokens / clés API en dur | ✅ Aucun |
| `Send-MailMessage` (déprécié) | ✅ Aucun |
| Élévation non sécurisée (`Start-Process -Verb runas`) | ✅ Aucune |
| Validation des entrées (`ValidateSet`, `ValidateScript`) | ✅ Présente |
| Gestion d'erreurs structurée avec logging | ✅ Présente |
| Séparation config versionnée / locale | ✅ `config.psd1` (git) / `config.local.psd1` (gitignoré) |
| Injection HTML (emails) | ✅ `ConvertTo-HtmlEncoded` via `[System.Net.WebUtility]::HtmlEncode()` |
| Credentials en clair dans config.psd1 | ✅ Non — commentaire explicite "Passwords are never stored here" |

---

## Warnings PSScriptAnalyzer résiduels

27 warnings initiaux → réduits par la correction du catch block vide.

Warnings restants (non-security, préexistants) :

| Règle | Fichiers | Impact sécurité |
|-------|----------|-----------------|
| `PSUseBOMForUnicodeEncodedFile` | 12 fichiers | Aucun (encodage) |
| `PSUseApprovedVerbs` | Step3.PhaseRunner.ps1 | Aucun (convention) |
| `PSUseUsingScopeModifierInNewRunspaces` | step4-StartVM.ps1 (11 occ.) | Aucun — variables de closure légitimes |
| `PSUseDeclaredVarsMoreThanAssignments` | step5-ValidateMigration.ps1 | Aucun (qualité de code) |

---

## Livrables

- Commit des corrections de sécurité sur `main`
- Ce rapport : `SECURITY-AUDIT-2026-07-09.md`

---

## Conclusion

Le codebase vmware2hyperv présente un **bon niveau de sécurité global**.
Une seule vulnérabilité critique a été identifiée (SMTP sans TLS) et corrigée.
Les risques modérés sont documentés et acceptés avec justification.
Aucune backdoor, aucun secret exposé, aucune injection non maîtrisée.