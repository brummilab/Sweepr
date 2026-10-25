# Sweepr - Version helpers
# Provides a single source of truth for the Windows version string.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'SWEEPR_VERSION_HELPERS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_VERSION_HELPERS_LOADED) {
    return
}
$script:SWEEPR_VERSION_HELPERS_LOADED = $true

# sw.cmd starts Windows PowerShell 5.1 through cmd.exe, so from a PowerShell 7
# terminal the child inherits PowerShell 7's module folders first. Autoloading
# then finds the PowerShell 7 builds of shared modules and commands such as
# Get-FileHash stop resolving. Drop those folders for this process
# only, keep everything else the user added, and make sure the Windows
# PowerShell system modules stay reachable.
function Repair-SweeprModulePath {
    param([string]$Edition = $PSVersionTable.PSEdition)

    if ($Edition -ne 'Desktop' -or [string]::IsNullOrEmpty($env:PSModulePath)) {
        return
    }

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in ($env:PSModulePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry -match '\\PowerShell\\' -or $entry -match '\\Microsoft\.PowerShell_') { continue }
        $kept.Add($entry)
    }
    $systemModules = "$($env:SystemRoot.TrimEnd('\'))\System32\WindowsPowerShell\v1.0\Modules"
    if (-not ($kept | Where-Object { $_.TrimEnd('\') -ieq $systemModules })) {
        $kept.Add($systemModules)
    }
    $env:PSModulePath = $kept -join ';'
}

# Last-resort fallback for artifacts that ship without the VERSION file.
# Keep this equal to VERSION: released ZIP/EXE installs read it, not the file
# Locked by the "compiled-in fallback" test in tests/Core.Tests.ps1.
$script:SweeprDefaultVersion = "0.1.0"

function Get-SweeprVersionFilePath {
    param([string]$RootDir)

    if ([string]::IsNullOrWhiteSpace($RootDir)) {
        return $null
    }

    return Join-Path $RootDir "VERSION"
}

function Get-SweeprVersionString {
    param(
        [string]$RootDir,
        [string]$DefaultVersion = $script:SweeprDefaultVersion
    )

    $versionFile = Get-SweeprVersionFilePath -RootDir $RootDir
    if (-not $versionFile -or -not (Test-Path $versionFile)) {
        return $DefaultVersion
    }

    $version = (Get-Content $versionFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $DefaultVersion
    }

    return $version
}
