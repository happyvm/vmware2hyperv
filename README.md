# vmware2hyperv

Ce dépôt propose une base de travail pour automatiser une migration VMware vers Hyper-V avec **PowerShell 7**.

## Script principal

- `Invoke-VMwareToHyperV.ps1` : scanne les artefacts VMware (`.vmx`, `.vmdk`, `.vhd`, `.vhdx`) et génère un plan JSON exploitable pour une migration.

## Améliorations PowerShell 7 utilisées

- `#requires -Version 7.0`
- Traitement parallèle avec `ForEach-Object -Parallel`
- Opérateurs de chaînage de pipeline `&&` / `||`
- Opérateur de coalescence nulle `??`
- Opérateur ternaire `? :`
- Écriture JSON UTF-8 via `Set-Content -Encoding utf8`

## Exemples

```bash
pwsh -File ./Invoke-VMwareToHyperV.ps1 \
  -SourcePath ./exports-vmware \
  -DestinationPath ./output \
  -ThrottleLimit 8
```

Simulation :

```bash
pwsh -File ./Invoke-VMwareToHyperV.ps1 \
  -SourcePath ./exports-vmware \
  -DestinationPath ./output \
  -WhatIf
```
