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

- `/noreboot` ou `-noreboot` : n’effectue pas de redémarrage automatique (même si nécessaire).
- `/forcecleanup` : active un nettoyage VMware forcé supplémentaire.

Exemple :

```bat
install-integration-services.bat /noreboot /forcecleanup
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
2. Détecte fabricant/modèle (WMIC puis fallback registre).
3. Si VMware détecté : sortie sans action.
4. Si Hyper‑V détecté : désinstallation/cleanup VMware.
5. Vérifie l’éligibilité OS pour Integration Services.
6. Si service `vmicheartbeat` absent : lance `setup.exe /quiet /norestart` selon l’architecture.
7. Si nécessaire, planifie un reboot (ou l’indique si `/noreboot`).

## Recommandations d’exploitation

- Exécuter d’abord en fenêtre interactive pour valider le comportement sur un échantillon de VM.
- Contrôler le fichier de log après chaque exécution.
- En cas d’échec (`exit code 1`), vérifier en priorité :
  - privilèges administrateur,
  - présence des installateurs Integration Services,
  - état des services/pilotes VMware résiduels.
