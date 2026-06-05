# Unit tests — Test-HyperVNodeReadiness

[Pester 5](https://pester.dev) unit tests for the platform-independent helper
functions of `../Test-HyperVNodeReadiness.ps1`.

The script under test guards its main block with
`if ($MyInvocation.InvocationName -eq '.') { return }`, so the tests dot-source
it to load every function **without** running any readiness check (and without
needing Windows-only cmdlets such as `Get-CimInstance` or `Get-NetAdapter`).

## What is covered

- `ConvertTo-LdapEscapedFilterValue` — LDAP filter escaping
- `Get-UniqueTextValues` — trim / case-insensitive de-duplication
- `ConvertTo-NetworkAdapterRole` — role-name normalization
- `ConvertTo-NetworkRoleMap` — both `@{ Name; Role }` and `@{ Nic = Role }` forms
- `Get-NetworkAdapterRole` — adapter-to-role lookup
- `Resolve-ClusterNodeIdentity` — short / FQDN / IP node identity
- `Read-CfgValue` — config parsing never prompts when a config file is loaded
- `Test-TcpPort` — open vs. reachable-but-closed port detection

Several cases are regression tests for bugs fixed during review (role mapping
silently dropping `@{ Name; Role }` entries, `Test-TcpPort` reporting a refused
port as open, `Read-CfgValue` blocking on prompts).

## Running

```powershell
# Install Pester 5 once (CurrentUser scope)
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

# From the repository root
Invoke-Pester -Path scripts/tests/Test-HyperVNodeReadiness.Tests.ps1
```
