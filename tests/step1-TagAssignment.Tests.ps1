<#
.SYNOPSIS
    Tests for the step1 tag assignment path.
.DESCRIPTION
    Covers the three defects a production run surfaced: a bulk lookup that
    walked every tagged object in vCenter (including CNS/FCD volumes, which make
    PowerCLI throw), a category comparison that assumed one object shape, and a
    remove-then-re-add cycle that briefly left a VM with no batch tag.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MigrationRoot = Join-Path $script:RepoRoot 'powershell-migration'
    . (Join-Path $script:MigrationRoot 'lib.ps1')
    $script:Step1Source = Get-Content -Path (Join-Path $script:MigrationRoot 'step1-TagResources_CreateVeeamJob.ps1') -Raw
}

Describe 'Get-VmwareTagCategoryName' {

    # PowerCLI returns Tag.Category as an object on some versions and as a bare
    # string on others. Reading .Name blindly throws under StrictMode against the
    # string form.
    It 'reads the name from a TagCategory object' {
        Get-VmwareTagCategoryName -Category ([pscustomobject]@{ Name = 'MigrationTags' }) | Should -Be 'MigrationTags'
    }

    It 'passes a plain string through unchanged' {
        Get-VmwareTagCategoryName -Category 'MigrationTags' | Should -Be 'MigrationTags'
    }

    It 'does not throw under StrictMode on a string category' {
        { Get-VmwareTagCategoryName -Category 'MigrationTags' } | Should -Not -Throw
    }

    It 'falls back to the string form when the object exposes no usable Name' {
        $category = [pscustomobject]@{ Name = '' }
        Get-VmwareTagCategoryName -Category $category | Should -Not -BeNullOrEmpty
    }

    It 'returns an empty string for a null category' {
        Get-VmwareTagCategoryName -Category $null | Should -Be ''
    }
}

Describe 'step1 bulk tag assignment lookup' {

    # A bare 'Get-TagAssignment -Category' enumerates every tagged object in
    # vCenter. On a vCenter hosting Kubernetes CNS volumes it throws
    # "An item with the same key has already been added. Key: pvc-<guid>",
    # which pushed the step onto its per-VM fallback on every run.
    It 'scopes the query to the batch VMs' {
        $script:Step1Source | Should -Match 'Get-TagAssignment -Entity \$batchVmObjects -Category \$TagCategory -ErrorAction Stop'
        $script:Step1Source | Should -Not -Match 'Get-TagAssignment -Category \$TagCategory -ErrorAction Stop'
    }

    It 'keeps the per-VM fallback as a safety net' {
        $script:Step1Source | Should -Match 'falling back to per-VM queries'
    }

    It 'falls back directly when the batch resolved no VM' {
        $script:Step1Source | Should -Match '\$batchVmObjects = @\(\$vmsByName\.Values\)'
        $script:Step1Source | Should -Match 'if \(\$batchVmObjects\.Count -eq 0\)'
    }

    It 'compares the category through the shape-agnostic helper' {
        $script:Step1Source | Should -Match 'Get-VmwareTagCategoryName -Category \$_\.Tag\.Category'
        $script:Step1Source | Should -Not -Match '\[string\]\$_\.Tag\.Category\.Name -eq \$TagCategory'
    }
}

Describe 'step1 tag churn' {

    BeforeAll {
        # Transcription of the assignment decision, so the rule itself is tested
        # and not just its presence in the source.
        function script:Split-TagAssignment {
            param([object[]]$ExistingAssignments, [string]$TagName)
            $toRemove = @($ExistingAssignments | Where-Object { [string]$_.Tag.Name -ne $TagName })
            $alreadyAssigned = @($ExistingAssignments | Where-Object { [string]$_.Tag.Name -eq $TagName })
            [pscustomobject]@{
                Remove  = $toRemove
                AddTag  = ($alreadyAssigned.Count -eq 0)
            }
        }

        function script:New-TestAssignment {
            param([string]$TagName)
            [pscustomobject]@{ Tag = [pscustomobject]@{ Name = $TagName } }
        }
    }

    # Removing the correct tag only to add it straight back leaves a window with
    # no batch tag at all -- and the Veeam job targets that tag.
    It 'leaves an already correctly tagged VM untouched' {
        $result = Split-TagAssignment -ExistingAssignments @(New-TestAssignment -TagName 'HypMig-lot-test') -TagName 'HypMig-lot-test'
        $result.Remove.Count | Should -Be 0
        $result.AddTag | Should -BeFalse
    }

    It 'removes a stale batch tag and adds the new one' {
        $result = Split-TagAssignment -ExistingAssignments @(New-TestAssignment -TagName 'HypMig-lot-117') -TagName 'HypMig-lot-test'
        $result.Remove.Count | Should -Be 1
        $result.AddTag | Should -BeTrue
    }

    It 'removes only the stale tags when both are present' {
        $existing = @(
            (New-TestAssignment -TagName 'HypMig-lot-117'),
            (New-TestAssignment -TagName 'HypMig-lot-test')
        )
        $result = Split-TagAssignment -ExistingAssignments $existing -TagName 'HypMig-lot-test'
        $result.Remove.Count | Should -Be 1
        [string]$result.Remove[0].Tag.Name | Should -Be 'HypMig-lot-117'
        $result.AddTag | Should -BeFalse
    }

    It 'adds the tag to a VM that carries none' {
        $result = Split-TagAssignment -ExistingAssignments @() -TagName 'HypMig-lot-test'
        $result.Remove.Count | Should -Be 0
        $result.AddTag | Should -BeTrue
    }

    It 'is wired into step1' {
        $script:Step1Source | Should -Match '\$assignmentsToRemove = @\(\$existingAssignments \| Where-Object \{ \[string\]\$_\.Tag\.Name -ne \$tagName \}\)'
        $script:Step1Source | Should -Match 'Tag \$tagName already assigned to \$vmName'
    }
}
