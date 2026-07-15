<#
.SYNOPSIS
    Validates that every .ps1 file under a directory parses cleanly.

.DESCRIPTION
    Deployment integrity check for the migration toolkit. Detects the corruptions
    seen on operator machines after copy/transfer of the scripts:
      - PowerShell parse errors (first error reported per file),
      - a double-encoded UTF-8 BOM (literal 'ï»¿' characters before '<#', which
        silently disables the comment-based help block and breaks parsing),
      - leftover git conflict markers.

    Run it against the deployment folder before launching a migration:
        pwsh .\Test-ScriptParse.ps1 -Path D:\Scripts\API

.PARAMETER Path
    Directory containing the deployed scripts. Defaults to the repository's
    powershell-migration folder next to this script.

.OUTPUTS
    One object per problem found. Exits 0 when everything is clean, 1 otherwise.
#>

param (
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'powershell-migration')
)

Set-StrictMode -Version Latest

if (-not (Test-Path -Path $Path)) {
    throw "Path '$Path' not found."
}

$mojibakeBom = [char]0x00EF + [char]0x00BB + [char]0x00BF   # 'ï»¿' as literal text
$problems = @()

foreach ($file in Get-ChildItem -Path $Path -Recurse -Filter *.ps1 -File) {
    $raw = Get-Content -Path $file.FullName -Raw

    if ($raw.StartsWith($mojibakeBom)) {
        $problems += [pscustomobject]@{
            File    = $file.FullName
            Line    = 1
            Problem = "Double-encoded UTF-8 BOM (literal 'ï»¿') — re-copy the file from the repository."
        }
    }

    # Split on `r?`n: the repository materializes .ps1 files with CRLF endings
    # (.gitattributes), and a trailing `r would prevent '={7}$' from matching.
    foreach ($marker in ($raw -split "`r`n|`n" | Select-String -Pattern '^(<{7} |={7}$|>{7} )' -SimpleMatch:$false)) {
        $problems += [pscustomobject]@{
            File    = $file.FullName
            Line    = $marker.LineNumber
            Problem = "Unresolved git conflict marker: $($marker.Line.Trim())"
        }
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors) {
        $problems += [pscustomobject]@{
            File    = $file.FullName
            Line    = $parseErrors[0].Extent.StartLineNumber
            Problem = "Parse error: $($parseErrors[0].Message)"
        }
    }
}

if ($problems) {
    $problems | Format-Table -AutoSize -Wrap | Out-String -Width 4096 | Write-Host
    Write-Host "$(@($problems).Count) problem(s) found in '$Path'." -ForegroundColor Red
    exit 1
}

Write-Host "All .ps1 files under '$Path' parse cleanly." -ForegroundColor Green
exit 0
