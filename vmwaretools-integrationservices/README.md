# Documentation — `install-integration-services.bat`

Ce dossier contient un script batch de **post‑migration VMware -> Hyper‑V** pour des VM Windows legacy.

## Objectif

Le script `install-integration-services.bat` permet, après le premier démarrage de la VM sur Hyper‑V :

- de vérifier l’hyperviseur détecté ;
- de ne rien faire si la machine tourne encore sur VMware ;
- de désinstaller VMware Tools quand nécessaire ;
- d’installer les **Hyper‑V Integration Services** pour les OS éligibles (Windows <= 6.1) ;
- de planifier un redémarrage si requis.

## Emplacement des fichiers attendus

Le script attend les installateurs Integration Services dans :

- `C:\temp\HYPERVIS\amd64\setup.exe` (OS 64 bits)
- `C:\temp\HYPERVIS\x86\setup.exe` (OS 32 bits)

## Prérequis

- Exécuter le script en **Administrateur**.
- Lancer le script **après** la migration et le premier boot sur Hyper‑V.
- Préparer les binaires Integration Services dans les chemins ci‑dessus.

## Utilisation

### Exécution standard

```bat
install-integration-services.bat
```

### Options disponibles

- `/reboot` ou `-reboot` : active le redémarrage automatique si le script détecte qu’il est requis.
- `/noreboot` ou `-noreboot` : force la désactivation du redémarrage automatique (comportement par défaut actuel).
- `/forcecleanup` : active un nettoyage VMware forcé supplémentaire.
- `/forceisinstall` (alias `/forceis`) : force l’installation des Integration Services même si les services core semblent déjà présents.
- `/usewmic` : réactive explicitement les fallbacks WMIC (désactivés par défaut pour éviter les popups `wmic.exe` sur certains OS legacy).

Exemple :

```bat
install-integration-services.bat /reboot /forcecleanup /forceisinstall
```

## Journalisation

Le log est écrit dans :

- `C:\temp\vmware2hyperv-postmigration.log`

Le script crée `C:\temp` si le dossier n’existe pas.

## Codes de sortie

- `0` : succès
- `1` : erreur
- `2` : nettoyage VMware partiel (fallback forcé appliqué)

## Logique de fonctionnement (résumé)

1. Vérifie les droits administrateur.
2. Détecte fabricant/modèle (registre/services puis fallback WMIC optionnel).
3. Si VMware détecté : sortie sans action.
4. Si Hyper‑V détecté : désinstallation/cleanup VMware.
5. Vérifie l’éligibilité OS pour Integration Services.
6. Si service `vmicheartbeat` absent : lance `setup.exe /quiet /norestart` selon l’architecture.
7. Si nécessaire, planifie un reboot uniquement si `/reboot` est fourni (sinon il l’indique sans le déclencher).
8. Cas legacy Windows 5.x : si aucune entrée Integration Services n’est trouvée dans Ajout/Suppression de programmes, le script force l’installation même si certains services existent déjà.

## Recommandations d’exploitation

- Exécuter d’abord en fenêtre interactive pour valider le comportement sur un échantillon de VM.
- Contrôler le fichier de log après chaque exécution.
- En cas d’échec (`exit code 1`), vérifier en priorité :
  - privilèges administrateur,
  - présence des installateurs Integration Services,
  - état des services/pilotes VMware résiduels.

## Dépannage rapide

- Si le script affiche `Hyperviseur detecte (manufacturer): UNKNOWN` et `Modele detecte: UNKNOWN`, il peut s’agir d’un OS legacy où WMIC/BIOS ne remonte pas correctement les infos.
- Le script tente désormais aussi une détection Hyper‑V via :
  - `HKLM\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters` ;
  - le service `vmbus`.
- En cas de popup `wmic.exe - Application Error`, laisser WMIC désactivé (comportement par défaut) ; n’utiliser `/usewmic` que si nécessaire pour diagnostic.
