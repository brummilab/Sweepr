# freeMole - Remove Command
# Removes freeMole from the current installation directory.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('h')]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$windowsDir = Split-Path -Parent $scriptDir
$installScript = Join-Path $windowsDir "install.ps1"

function Show-RemoveHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mfm remove$esc[0m - Remove freeMole from this system"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m fm remove"
    Write-Host ""
    Write-Host "$esc[33mBehavior:$esc[0m"
    Write-Host "  - Removes the current freeMole installation directory"
    Write-Host "  - Removes PATH entries created for this install"
    Write-Host "  - Prompts before deleting freeMole config files"
    Write-Host "  - Removes the freeMole cache folder after a successful uninstall"
    Write-Host ""
}

if ($ShowHelp) {
    Show-RemoveHelp
    return
}

# winget and Scoop track their own files; removing them here leaves the
# package registered, so hand the user that manager's command instead.
function Get-PackageManagerRemoveCommand {
    param([string]$InstallDir)

    $path = $InstallDir.TrimEnd('\') + '\'
    if ($path -like "*\Microsoft\WinGet\Packages\tw93.MoleCLI_*") {
        return "winget uninstall tw93.MoleCLI"
    }
    if ($path -like "*\scoop\apps\mole\*") {
        return "scoop uninstall mole"
    }
    return $null
}

$removeCommand = Get-PackageManagerRemoveCommand -InstallDir $windowsDir
if ($removeCommand) {
    Write-Host "This copy of freeMole is managed by a package manager." -ForegroundColor Yellow
    Write-Host "Remove it with: $removeCommand" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $installScript)) {
    Write-Host "Installer not found at: $installScript" -ForegroundColor Red
    exit 1
}

# Removing freeMole is not undoable, so it is never a side effect of a typo.
$answer = "$(Read-Host "Remove freeMole from ${windowsDir}? (y/N)")".Trim()
if ($answer -ne "y" -and $answer -ne "Y") {
    Write-Host "Cancelled"
    exit 0
}

# Reset the automatic status so a caller's earlier native command cannot make a
# successful uninstall look failed.
$global:LASTEXITCODE = 0
& $installScript -InstallDir $windowsDir -Uninstall
