#!/usr/bin/env pwsh
# Sweepr Quick Installer for Windows
# One-liner install: iwr -useb https://raw.githubusercontent.com/brummilab/sweepr/main/quick-install.ps1 | iex

#Requires -Version 5.1

param(
    [string]$InstallDir
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# A source install found in %LOCALAPPDATA%\Sweepr keeps updating in place;
# new installs go to their own folder.
if (-not $InstallDir) {
    $legacyDir = Join-Path $env:LOCALAPPDATA "Sweepr"
    if ((Test-Path (Join-Path $legacyDir ".git")) -and (Test-Path (Join-Path $legacyDir "sweepr.ps1"))) {
        $InstallDir = $legacyDir
    }
    else {
        $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
    }
}

# Colors
$ESC = [char]27
$Colors = @{
    Green  = "$ESC[32m"
    Yellow = "$ESC[33m"
    Cyan   = "$ESC[36m"
    Red    = "$ESC[31m"
    NC     = "$ESC[0m"
}

function Write-Step {
    param([string]$Message)
    Write-Host "  $($Colors.Cyan)$([char]0x2192)$($Colors.NC) $Message"
}

function Write-Success {
    param([string]$Message)
    Write-Host "  $($Colors.Green)$([char]0x2713)$($Colors.NC) $Message"
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "  $($Colors.Red)$([char]0x2717)$($Colors.NC) $Message"
}

function Test-SourceInstall {
    param([string]$Path)

    return (Test-Path (Join-Path $Path ".git"))
}

$script:SweeprGitProxyArguments = $null

# Git ignores the Windows system proxy that PowerShell downloads use, so on a
# machine that reaches GitHub only through that proxy, clone and pull fail
# while every other download works. Pass the system proxy to git for this
# run, unless the user already gave git a proxy of their own.
function Get-SweeprSystemProxy {
    param([Uri]$Target)

    try {
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($Target)
    }
    catch {
        return $null
    }
    if (-not $proxy -or $proxy.AbsoluteUri -eq $Target.AbsoluteUri) {
        return $null
    }
    return $proxy.AbsoluteUri.TrimEnd('/')
}

function Get-GitProxyArguments {
    if ($null -ne $script:SweeprGitProxyArguments) {
        return $script:SweeprGitProxyArguments
    }
    $script:SweeprGitProxyArguments = @()

    foreach ($name in @("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY")) {
        if ([Environment]::GetEnvironmentVariable($name) -or [Environment]::GetEnvironmentVariable($name.ToLowerInvariant())) {
            return $script:SweeprGitProxyArguments
        }
    }
    foreach ($key in @("http.proxy", "https.proxy")) {
        try {
            $configured = & git config --get $key 2>$null
        }
        catch {
            $configured = $null
        }
        if ($configured) {
            return $script:SweeprGitProxyArguments
        }
    }

    $proxy = Get-SweeprSystemProxy -Target ([Uri]"https://github.com/")
    if ($proxy) {
        $script:SweeprGitProxyArguments = @("-c", "http.proxy=$proxy")
    }
    return $script:SweeprGitProxyArguments
}

function Invoke-GitCommand {
    param(
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousNativeErrorPreference = $null
    $hasNativeErrorPreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $hasNativeErrorPreference = $true
    }

    try {
        $gitArguments = @()
        if ($WorkingDirectory) {
            $gitArguments += @("-C", $WorkingDirectory)
        }
        $gitArguments += @(Get-GitProxyArguments)
        $gitArguments += $Arguments

        $output = & git @gitArguments 2>&1
        $exitCode = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $exitCode
            Text = ((@($output) | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        }
    }
    finally {
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }
}

function Get-PowerShellCommand {
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        return "powershell.exe"
    }

    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        return "pwsh"
    }

    throw "PowerShell executable not found"
}

# Main installation
try {
    Write-Host ""
    Write-Host "  $($Colors.Cyan)Sweepr Quick Installer$($Colors.NC)"
    Write-Host "  $($Colors.Yellow)Installing Sweepr from the main branch...$($Colors.NC)"
    Write-Host ""

    # Check prerequisites
    Write-Step "Checking prerequisites..."

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-ErrorMsg "Git is not installed. Please install Git first:"
        Write-Host "    https://git-scm.com/download/win"
        exit 1
    }

    Write-Success "Git found"

    if (Test-Path $InstallDir) {
        if (Test-SourceInstall -Path $InstallDir) {
            Write-Step "Existing source install found, refreshing..."

            $fetchResult = Invoke-GitCommand -WorkingDirectory $InstallDir -Arguments @("fetch", "--quiet", "--tags", "origin", "main")
            if ($fetchResult.ExitCode -ne 0) {
                Write-ErrorMsg "Failed to fetch latest source"
                if ($fetchResult.Text) {
                    Write-Host "    $($fetchResult.Text)"
                }
                exit 1
            }

            $pullResult = Invoke-GitCommand -WorkingDirectory $InstallDir -Arguments @("pull", "--ff-only", "origin", "main")
            if ($pullResult.ExitCode -ne 0) {
                Write-ErrorMsg "Failed to fast-forward source install"
                if ($pullResult.Text) {
                    Write-Host "    $($pullResult.Text)"
                }
                exit 1
            }
        }
        else {
            Write-ErrorMsg "Install directory already exists and is not a source install: $InstallDir"
            Write-Host "    Remove it first or reinstall with the latest quick installer."
            exit 1
        }
    }
    else {
        Write-Step "Cloning Sweepr source..."

        $cloneResult = Invoke-GitCommand -Arguments @("clone", "--quiet", "--single-branch", "--branch", "main", "https://github.com/brummilab/sweepr.git", $InstallDir)
        if ($cloneResult.ExitCode -ne 0) {
            Write-ErrorMsg "Failed to clone source installer"
            if ($cloneResult.Text) {
                Write-Host "    $($cloneResult.Text)"
            }
            exit 1
        }

        if (-not (Test-Path (Join-Path $InstallDir "install.ps1"))) {
            Write-ErrorMsg "Failed to clone source installer"
            exit 1
        }

        Write-Success "Cloned source to $InstallDir"
    }

    # Run installer
    Write-Step "Running installer..."
    Write-Host ""

    $powerShellCommand = Get-PowerShellCommand
    & $powerShellCommand -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir "install.ps1") -InstallDir $InstallDir -AddToPath
    if ($LASTEXITCODE -ne 0) {
        throw "Installer exited with code $LASTEXITCODE"
    }

    # install.ps1 already printed the result, location and next commands.

} catch {
    Write-ErrorMsg "Installation failed: $_"
    exit 1
}
