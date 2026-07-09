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
        'PSUseShouldProcessForStateChangingFunctions',

        # All current PSReviewUnusedParameter hits are false positives caused by
        # the analyzer's inability to track variable usage through:
        #   - Invoke-SCVMMCommand / Invoke-VeeamCommand script-block nesting
        #   - Piped -UseWindowsPowerShellFallback:$UseWindowsPowerShellFallback syntax
        #   - Cross-function parameter forwarding (RecipientGroup)
        #   - Export-Csv parameter usage via string interpolation
        # Verified 2026-07-09: 0 truly unused parameters remain.
        'PSReviewUnusedParameter',

        # Invoke-MigrationConfigWizard (lib.ps1) and run-migration.ps1's interactive
        # mode use Write-Host deliberately for colored, non-pipeline console prompts
        # in a human-driven CLI wizard — there's no output to capture or redirect.
        'PSAvoidUsingWriteHost'
    )
}
