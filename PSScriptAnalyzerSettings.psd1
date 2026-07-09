@{
    # PSScriptAnalyzer custom settings for the vmware2hyperv project.
    #
    # Usage:
    #   Invoke-ScriptAnalyzer -Path .\powershell-migration\ -Settings .\PSScriptAnalyzerSettings.psd1
    #
    # Rationale for each exclusion is documented inline.

    Severity = @(
        'Error',
        'Warning'
    )

    # Rules to exclude from analysis.
    ExcludeRules = @(
        # Existing function names use plural nouns (e.g. Get-MigrationTargets,
        # Resolve-Datastores, Get-NetworkPaths). Renaming would break callers
        # across the migration scripts and worker pool.
        'PSUseSingularNouns',

        # These are batch orchestration scripts and migration helpers, not
        # sharable cmdlets. They are invoked from run-migration.ps1 and
        # worker-step3.ps1 with full operational context — ShouldProcess
        # confirmation prompts would block unattended migration pipelines.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
