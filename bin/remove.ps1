# Sweepr - Remove Command
# Removes Sweepr from the current installation directory.

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
    Write-Host "$esc[1;35msw remove$esc[0m - Remove Sweepr from this system"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m sw remove"
    Write-Host ""
    Write-Host "$esc[33mBehavior:$esc[0m"
    Write-Host "  - Removes the current Sweepr installation directory"
    Write-Host "  - Removes PATH entries and the Start Menu shortcut created for this install"
    Write-Host "  - Prompts before deleting Sweepr config files in your user profile (operations.log is kept)"
    Write-Host "  - Removes the Sweepr cache folder in your user profile after a successful uninstall"
    Write-Host ""
    Write-Host "$esc[33mNotes:$esc[0m"
    Write-Host "  - Portable copy (sweepr.portable next to sweepr.ps1): nothing is removed;"
    Write-Host "    delete the folder yourself, your settings and operation log are in its data folder"
    Write-Host "  - With SWEEPR_DATA_DIR set, that data folder is never removed, only named"
    Write-Host "  - winget or Scoop copies: prints that package manager's own command instead"
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
    if ($path -like "*\Microsoft\WinGet\Packages\brummilab.Sweepr_*") {
        return "winget uninstall brummilab.Sweepr"
    }
    if ($path -like "*\scoop\apps\sweepr\*") {
        return "scoop uninstall sweepr"
    }
    return $null
}

# Portable keeps everything in its own folder, so there is nothing to uninstall
# and nothing this command may delete.
if (Test-Path -LiteralPath (Join-Path $windowsDir "sweepr.portable") -PathType Leaf) {
    Write-Host "Sweepr portable leaves nothing outside its folder. To remove it, delete $windowsDir. Your settings and operation log are in $(Join-Path $windowsDir 'data')." -ForegroundColor Yellow
    exit 1
}

$removeCommand = Get-PackageManagerRemoveCommand -InstallDir $windowsDir
if ($removeCommand) {
    Write-Host "This copy of Sweepr is managed by a package manager." -ForegroundColor Yellow
    Write-Host "Remove it with: $removeCommand" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $installScript)) {
    Write-Host "Installer not found at: $installScript" -ForegroundColor Red
    exit 1
}

# Removing Sweepr is not undoable, so it is never a side effect of a typo.
$answer = "$(Read-Host "Remove Sweepr from ${windowsDir}? (y/N)")".Trim()
if ($answer -ne "y" -and $answer -ne "Y") {
    Write-Host "Cancelled"
    exit 0
}

# Reset the automatic status so a caller's earlier native command cannot make a
# successful uninstall look failed.
$global:LASTEXITCODE = 0
& $installScript -InstallDir $windowsDir -Uninstall
