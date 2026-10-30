# Safe syntax-only test: does NOT execute the repair script.
$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot '..\scripts\Repair-TemporaryProfile.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $target).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_.ToString() }
    throw 'PowerShell syntax errors found.'
}
Write-Host 'PowerShell syntax valid.'
