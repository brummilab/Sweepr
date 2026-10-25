# Sweepr - Gate, PowerShell part: parse every script, then run Pester.
# Called by scripts/gate.sh; -Scope all runs every test file, portable only
# the files that pass without Windows.

#Requires -Version 5.1
param(
    [ValidateSet('all', 'portable')]
    [string]$Scope = 'portable'
)

$ErrorActionPreference = 'Stop'

$parseErrors = 0
foreach ($file in Get-ChildItem -Path . -Recurse -Filter *.ps1 -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in @($errors)) {
        Write-Host "$($file.FullName):$($e.Extent.StartLineNumber): $($e.Message)"
        $parseErrors++
    }
}
if ($parseErrors -gt 0) { Write-Host "PowerShell parse errors: $parseErrors"; exit 1 }

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' })) {
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck -Scope CurrentUser
}
Import-Module Pester -MinimumVersion 5.0.0

# Test files that pass without Windows.
$portable = @(
    'DryRunEnvironment.Tests.ps1', 'GitProxy.Tests.ps1', 'Inspect.Tests.ps1',
    'InstallComponents.Tests.ps1', 'LiteralPath.Tests.ps1', 'Portable.Tests.ps1', 'Release.Tests.ps1', 'UpdateNotice.Tests.ps1'
)
$paths = if ($Scope -eq 'all') { @('./tests') } else { @($portable | ForEach-Object { Join-Path './tests' $_ }) }

$config = New-PesterConfiguration
$config.Run.Path = $paths
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
