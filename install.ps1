#!/usr/bin/env pwsh
# Sweepr Windows Installer
# Installs Sweepr Windows support to the system and adds to PATH

#Requires -Version 5.1
param(
    # %LOCALAPPDATA%\Sweepr is reserved for app data, so new installs never go
    # there; see Uninstall-Sweepr for installs that already did.
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\sweepr-cli",
    [switch]$AddToPath,
    [switch]$CreateShortcut,
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$ShowHelp,
    # Keep the two newest parameters last: the legacy decoder below depends on
    # the positions of the older ones.
    [string]$Components,
    [switch]$NoPrompt
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$script:InstallDirGiven = $PSBoundParameters.ContainsKey("InstallDir")

# ============================================================================
# Configuration
# ============================================================================

# Same check as bin/update.ps1: is this exact folder an entry of the user PATH?
function Test-InstallDirOnUserPath {
    param([string]$Path)

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $currentPath) {
        return $false
    }

    return $currentPath -split ";" | Where-Object { $_ -eq $Path }
}

function Resolve-InstallInvocation {
    param(
        [string]$SourceDir,
        [string]$RequestedInstallDir,
        [switch]$RequestedAddToPath,
        [switch]$RequestedCreateShortcut
    )

    # v1.30.0 passed @("-InstallDir", $sourceDir, optional "-AddToPath")
    # through array splatting, so every element bound positionally: the text
    # "-InstallDir" became the value of InstallDir. With -Components declared,
    # the source folder then binds positionally to -Components (seen on pwsh 7
    # and in the Windows CI for Windows PowerShell 5.1), so the switch values
    # say nothing reliable about what the old updater meant. Decode only that
    # exact legacy shape for the first update that pulls this installer while
    # the old updater is still running: install the folder the script lives in
    # and keep PATH only if that folder is already on the user PATH, the same
    # check bin/update.ps1 makes.
    if ($RequestedInstallDir -ceq "-InstallDir") {
        return [PSCustomObject]@{
            InstallDir     = $SourceDir
            AddToPath      = [bool](Test-InstallDirOnUserPath -Path $SourceDir)
            CreateShortcut = $false
        }
    }

    return [PSCustomObject]@{
        InstallDir     = $RequestedInstallDir
        AddToPath      = $RequestedAddToPath.IsPresent
        CreateShortcut = $RequestedCreateShortcut.IsPresent
    }
}

$script:SourceDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}
# The v1.30.0 updater passes its source folder positionally after
# "-InstallDir"; with -Components declared, that path binds to -Components. It is not a
# component list, and that old updater must never see the menu.
$script:LegacyInvocation = $InstallDir -ceq "-InstallDir"
if ($script:LegacyInvocation) {
    $Components = $null
    $NoPrompt = [switch]$true
}
$resolvedInvocation = Resolve-InstallInvocation `
    -SourceDir $script:SourceDir `
    -RequestedInstallDir $InstallDir `
    -RequestedAddToPath:$AddToPath `
    -RequestedCreateShortcut:$CreateShortcut
$InstallDir = $resolvedInvocation.InstallDir
$AddToPath = [switch]$resolvedInvocation.AddToPath
$CreateShortcut = [switch]$resolvedInvocation.CreateShortcut
# Tools prepared up front by Install-Sweepr; Main narrows it to the selection.
$script:InstallTools = @("analyze", "status")
$script:CoreDir = Join-Path $script:SourceDir "lib\core"
# The Start menu entry names the CLI explicitly; a plain "Sweepr" may belong to another app.
$script:ShortcutName = "Sweepr CLI"

. (Join-Path $script:CoreDir "version.ps1")
$script:VERSION = Get-SweeprVersionString -RootDir $script:SourceDir

# Colors (using [char]27 for PowerShell 5.1 compatibility)
$script:ESC = [char]27
$script:Colors = @{
    Red     = "$($script:ESC)[31m"
    Green   = "$($script:ESC)[32m"
    Yellow  = "$($script:ESC)[33m"
    Blue    = "$($script:ESC)[34m"
    Cyan    = "$($script:ESC)[36m"
    Gray    = "$($script:ESC)[90m"
    NC      = "$($script:ESC)[0m"
}

. (Join-Path $script:CoreDir "tui_binaries.ps1")

# ============================================================================
# Helpers
# ============================================================================

function Write-Info {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Blue)INFO$($c.NC)  $Message"
}

function Write-Success {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Green)OK$($c.NC)    $Message"
}

function Write-SweeprWarning {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Yellow)WARN$($c.NC)  $Message"
}

function Write-SweeprError {
    param([string]$Message)
    $c = $script:Colors
    Write-Host "  $($c.Red)ERROR$($c.NC) $Message"
}

function Get-NormalizedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-SamePath {
    param(
        [string]$PathA,
        [string]$PathB
    )

    return (Get-NormalizedPath -Path $PathA) -eq (Get-NormalizedPath -Path $PathB)
}

function Test-ProtectedInstallRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    try {
        $normalizedPath = Get-NormalizedPath -Path $Path
    }
    catch {
        return $true
    }

    $protectedRoots = @(
        $env:USERPROFILE
        [Environment]::GetFolderPath("UserProfile")
        $env:LOCALAPPDATA
        (Join-Path $env:LOCALAPPDATA "Programs")
        $env:APPDATA
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:ProgramData
        "$env:SystemDrive\"
        "$env:WINDIR"
        "$env:SYSTEMROOT"
    )

    foreach ($root in $protectedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        try {
            if ($normalizedPath -eq (Get-NormalizedPath -Path $root)) {
                return $true
            }
        }
        catch {
            continue
        }
    }

    return $false
}

# Installer copies and removals never follow a junction, including ancestors.
function Assert-InstallPhysicalPath {
    param([string]$Path)

    $current = [System.IO.Path]::GetFullPath($Path)
    while ($current) {
        try {
            $attributes = [System.IO.File]::GetAttributes($current)
            if ($attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing linked install path: $current"
            }
        }
        catch {
            $errorObject = $_.Exception
            while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
            if (($errorObject.HResult -band 0xffff) -notin @(2, 3)) { throw }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Copy-SweeprInstallEntry {
    param([string]$Source, [string]$Destination)

    Assert-InstallPhysicalPath -Path $Source
    Assert-InstallPhysicalPath -Path $Destination
    $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
            Copy-SweeprInstallEntry -Source $child.FullName -Destination (Join-Path $Destination $child.Name)
        }
    }
    else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Show-Banner {
    $c = $script:Colors
    Write-Host ""
    Write-Host "  $($c.Cyan)Sweepr CLI for Windows$($c.NC)"
    Write-Host "  $($c.Gray)Deep clean and optimize your PC. https://github.com/brummilab/sweepr$($c.NC)"
    Write-Host ""
}

function Show-InstallerHelp {
    Show-Banner

    $c = $script:Colors
    Write-Host "  $($c.Green)USAGE:$($c.NC)"
    Write-Host ""
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 [options]"
    Write-Host ""
    Write-Host "  $($c.Green)OPTIONS:$($c.NC)"
    Write-Host ""
    Write-Host "    $($c.Cyan)-InstallDir <path>$($c.NC)   Installation directory"
    Write-Host "                         Default: $env:LOCALAPPDATA\Programs\sweepr-cli"
    Write-Host ""
    Write-Host "    $($c.Cyan)-AddToPath$($c.NC)           Add Sweepr to user PATH"
    Write-Host ""
    Write-Host "    $($c.Cyan)-CreateShortcut$($c.NC)      Create Start Menu shortcut"
    Write-Host ""
    Write-Host "    $($c.Cyan)-Components <list>$($c.NC)   Comma separated components to install:"
    Write-Host "                         path, shortcut, analyze, status (core is always installed)"
    Write-Host "                         Overrides the SWEEPR_COMPONENTS environment variable and the menu"
    Write-Host ""
    Write-Host "    $($c.Cyan)-NoPrompt$($c.NC)            Never show the component menu"
    Write-Host ""
    Write-Host "    $($c.Cyan)-Uninstall$($c.NC)           Remove Sweepr from system"
    Write-Host ""
    Write-Host "    $($c.Cyan)-Force$($c.NC)               Overwrite existing installation"
    Write-Host ""
    Write-Host "    $($c.Cyan)-ShowHelp$($c.NC)            Show this help message"
    Write-Host ""
    Write-Host "  $($c.Green)EXAMPLES:$($c.NC)"
    Write-Host ""
    Write-Host "    $($c.Gray)# Install with defaults$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1"
    Write-Host ""
    Write-Host "    $($c.Gray)# Install and add to PATH$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath"
    Write-Host ""
    Write-Host "    $($c.Gray)# Custom install location$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir C:\Tools\Sweepr -AddToPath"
    Write-Host ""
    Write-Host "    $($c.Gray)# Full installation$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath -CreateShortcut"
    Write-Host ""
    Write-Host "    $($c.Gray)# Choose components without the menu (or set SWEEPR_COMPONENTS)$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Components path,status -NoPrompt"
    Write-Host ""
    Write-Host "    $($c.Gray)# Uninstall$($c.NC)"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
    Write-Host ""
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ToUserPath {
    param([string]$Directory)

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    if ($currentPath -split ";" | Where-Object { $_ -eq $Directory }) {
        Write-Info "Already in PATH: $Directory"
        return $true
    }

    $newPath = if ($currentPath) { "$currentPath;$Directory" } else { $Directory }

    try {
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Success "Added to PATH: $Directory"

        # Update current session
        $env:PATH = "$env:PATH;$Directory"
        return $true
    }
    catch {
        Write-SweeprError "Failed to update PATH: $_"
        return $false
    }
}

function Remove-FromUserPath {
    param([string]$Directory)

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    if (-not $currentPath) {
        return $true
    }

    $paths = $currentPath -split ";" | Where-Object { $_ -ne $Directory -and $_ -ne "" }
    $newPath = $paths -join ";"

    try {
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Success "Removed from PATH: $Directory"
        return $true
    }
    catch {
        Write-SweeprError "Failed to update PATH: $_"
        return $false
    }
}

function New-StartMenuShortcut {
    param(
        [string]$TargetPath,
        [string]$ShortcutName,
        [string]$Description
    )

    $startMenuPath = [Environment]::GetFolderPath("StartMenu")
    $programsPath = Join-Path $startMenuPath "Programs"
    $shortcutPath = Join-Path $programsPath "$ShortcutName.lnk"

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$TargetPath`""
        $shortcut.Description = $Description
        $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
        $shortcut.Save()

        Write-Success "Created shortcut: $shortcutPath"
        return $true
    }
    catch {
        Write-SweeprError "Failed to create shortcut: $_"
        return $false
    }
}

# Removes the Start menu shortcut this install created: "Sweepr CLI.lnk", or
# "Sweepr.lnk" from 1.30.0, and only when it starts this install's sweepr.ps1.
# A "Sweepr.lnk" that points anywhere else belongs to another app.
function Remove-StartMenuShortcut {
    param(
        [string]$InstallDir,
        [string]$ProgramsPath = (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs")
    )

    $sweeprScript = Join-Path $InstallDir "sweepr.ps1"
    $shell = New-Object -ComObject WScript.Shell
    foreach ($name in @("Sweepr CLI", "Sweepr")) {
        $shortcutPath = Join-Path $ProgramsPath "$name.lnk"
        if (-not (Test-Path -LiteralPath $shortcutPath)) {
            continue
        }
        $arguments = $shell.CreateShortcut($shortcutPath).Arguments
        if (-not $arguments -or $arguments.IndexOf($sweeprScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }
        try {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Success "Removed shortcut: $shortcutPath"
        }
        catch {
            Write-SweeprError "Failed to remove shortcut: $_"
            return $false
        }
    }
    return $true
}

# ============================================================================
# Component selection
# ============================================================================

$script:InstallComponentNames = @("analyze", "path", "shortcut", "status")

function ConvertTo-InstallComponents {
    param([string]$Text)

    $names = @()
    foreach ($part in @($Text -split "[,\s]+")) {
        if ($part) { $names += $part.ToLowerInvariant() }
    }
    $allowed = $script:InstallComponentNames
    foreach ($name in $names) {
        if ($allowed -notcontains $name) {
            throw "Unknown component '$name'. Allowed components: $($allowed -join ', ')"
        }
    }
    return @($names | Sort-Object -Unique)
}

function Test-InstallInteractive {
    param(
        [bool]$NoPrompt,
        [bool]$Uninstall,
        [bool]$InputRedirected = [Console]::IsInputRedirected,
        [bool]$OutputRedirected = [Console]::IsOutputRedirected,
        [bool]$UserInteractive = [Environment]::UserInteractive
    )

    # The menu reads single keys, so it needs a real console on both sides.
    return ((-not $NoPrompt) -and (-not $Uninstall) -and (-not $InputRedirected) -and
        (-not $OutputRedirected) -and $UserInteractive)
}

# Separate function so tests can replace the key source.
function Read-InstallMenuKey {
    return [Console]::ReadKey($true)
}

function Show-InstallComponentMenu {
    param([string[]]$Default)

    $items = @(
        @{ Name = "path"; Text = "Add Sweepr to your user PATH" },
        @{ Name = "shortcut"; Text = "Create a Start Menu shortcut" },
        @{ Name = "analyze"; Text = "Prepare the disk explorer (analyze)" },
        @{ Name = "status"; Text = "Prepare the system monitor (status)" }
    )
    $checked = @{}
    foreach ($item in $items) { $checked[$item.Name] = (@($Default) -contains $item.Name) }
    $index = 0

    while ($true) {
        Write-Host ""
        Write-Host "  Select components (the core is always installed):"
        Write-Host "  Up/Down = move, Space = toggle, Enter = install, Esc or Q = cancel"
        Write-Host ""
        for ($i = 0; $i -lt $items.Count; $i++) {
            $mark = if ($checked[$items[$i].Name]) { "[x]" } else { "[ ]" }
            $pointer = if ($i -eq $index) { ">" } else { " " }
            Write-Host ("  {0} {1} {2,-9} {3}" -f $pointer, $mark, $items[$i].Name, $items[$i].Text)
        }

        $key = Read-InstallMenuKey
        switch ($key.Key) {
            "UpArrow" { if ($index -gt 0) { $index-- } }
            "DownArrow" { if ($index -lt $items.Count - 1) { $index++ } }
            "Spacebar" { $checked[$items[$index].Name] = -not $checked[$items[$index].Name] }
            "Enter" {
                $selected = @($items | Where-Object { $checked[$_.Name] } | ForEach-Object { $_.Name } | Sort-Object)
                # The comma keeps an empty selection an empty array instead of $null.
                return , $selected
            }
            "Escape" { return $null }
            "Q" { return $null }
        }
    }
}

function Get-InstallComponentSelection {
    param(
        [string]$Components,
        [string]$EnvComponents,
        [bool]$AddToPath,
        [bool]$CreateShortcut,
        [bool]$Interactive
    )

    if (-not [string]::IsNullOrWhiteSpace($Components)) {
        return , @(ConvertTo-InstallComponents -Text $Components)
    }
    if (-not [string]::IsNullOrWhiteSpace($EnvComponents)) {
        return , @(ConvertTo-InstallComponents -Text $EnvComponents)
    }

    $default = @("analyze", "status")
    if ($AddToPath) { $default += "path" }
    if ($CreateShortcut) { $default += "shortcut" }
    $default = @($default | Sort-Object)

    if ($Interactive) {
        $chosen = Show-InstallComponentMenu -Default $default
        if ($null -eq $chosen) { return $null }
        return , @($chosen)
    }
    return , $default
}

# ============================================================================
# Install
# ============================================================================

function Ensure-OptionalTuiTools {
    param(
        [string]$RootDir,
        # Only these tools are prepared; others load or build on first use.
        [string[]]$Tools = @("analyze", "status")
    )

    $wanted = @($Tools | Where-Object { $_ })
    if ($wanted.Count -eq 0) {
        Write-Info "Skipping optional TUI tools (not selected)."
        return
    }

    Write-Info "Ensuring optional TUI tools..."

    $catalog = @(
        @{ Name = "analyze"; Output = "bin\analyze.exe"; Source = "./cmd/analyze/" },
        @{ Name = "status"; Output = "bin\status.exe"; Source = "./cmd/status/" }
    ) | Where-Object { $wanted -contains $_.Name }

    $version = Get-SweeprVersionFromScriptFile -WindowsDir $RootDir
    $refreshSourceTools = Test-Path -LiteralPath (Join-Path $RootDir ".git")
    $failedTools = @()

    foreach ($tool in $catalog) {
        $destination = Join-Path $RootDir $tool.Output
        $hadExisting = Test-Path -LiteralPath $destination
        try {
            $binPath = Ensure-TuiBinary -Name $tool.Name -WindowsDir $RootDir -DestinationPath $destination -SourcePath $tool.Source -Version $version -Refresh:$refreshSourceTools
        }
        catch {
            Write-SweeprWarning "Skipping $($tool.Name).exe after a non-fatal setup error: $_"
            $binPath = $null
        }
        if ($binPath) {
            Write-Success "Ready: $($tool.Name).exe"
        }
        else {
            Write-SweeprWarning "Could not prepare $($tool.Name).exe. Install Go, or run sw update later to fetch the release build."
            # Only a tool that stays at an older build is a failed refresh; with
            # nothing installed yet, the command fetches the release on first use.
            if ($hadExisting) { $failedTools += $tool.Name }
        }
    }
    if ($refreshSourceTools -and $failedTools.Count -gt 0) {
        throw "Could not refresh $($failedTools -join ', ') from this source. Install Go and rerun this installer. Existing tools were kept."
    }
}

function Install-Sweepr {
    Write-Info "Installing Sweepr v$script:VERSION..."
    Write-Host ""

    if (Test-ProtectedInstallRoot -Path $InstallDir) {
        Write-SweeprError "Refusing to use protected install directory: $InstallDir"
        return $false
    }

    Assert-InstallPhysicalPath -Path $InstallDir
    $inPlaceInstall = Test-SamePath -PathA $script:SourceDir -PathB $InstallDir
    if (-not $inPlaceInstall -and (Test-Path -LiteralPath $InstallDir) -and
        @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction Stop).Count -gt 0 -and
        -not (Test-SweeprInstallDir -Path $InstallDir)) {
        Write-SweeprError "Refusing to merge into a directory not owned by this install: $InstallDir"
        return $false
    }

    # Check if already installed
    if ((Test-Path $InstallDir) -and -not $Force -and -not $inPlaceInstall) {
        Write-SweeprError "Sweepr is already installed at: $InstallDir"
        Write-Host ""
        Write-Host "  Use -Force to overwrite or -Uninstall to remove first"
        Write-Host ""
        return $false
    }

    # Create install directory
    if (-not (Test-Path $InstallDir)) {
        try {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            Write-Success "Created directory: $InstallDir"
        }
        catch {
            Write-SweeprError "Failed to create directory: $_"
            return $false
        }
    }

    if ($inPlaceInstall) {
        Write-Info "Using in-place source installation in: $InstallDir"
    }
    else {
        # Copy files
        Write-Info "Copying files..."

        $filesToCopy = @(
            # VERSION travels with the install: without it every command falls
            # back to the compiled-in default and reports a stale version.
            "VERSION"
            "sweepr.ps1"
            "install.ps1"
            "go.mod"
            "go.sum"
            "bin"
            "lib"
            "cmd"
        )

        foreach ($item in $filesToCopy) {
            $src = Join-Path $script:SourceDir $item
            $dst = Join-Path $InstallDir $item

            if (Test-Path $src) {
                try {
                    Copy-SweeprInstallEntry -Source $src -Destination $dst
                    Write-Success "Copied: $item"
                }
                catch {
                    Write-SweeprError "Failed to copy $item`: $_"
                    return $false
                }
            }
        }
    }

    # Create scripts and tests directories if they don't exist
    $extraDirs = @("scripts", "tests")
    foreach ($dir in $extraDirs) {
        $dirPath = Join-Path $InstallDir $dir
        if (-not (Test-Path $dirPath)) {
            New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        }
    }

    Write-Host ""
    $selectedTools = @("analyze", "status")
    if (Get-Variable -Name InstallTools -Scope Script -ErrorAction SilentlyContinue) {
        $selectedTools = @($script:InstallTools)
    }
    Ensure-OptionalTuiTools -RootDir $InstallDir -Tools $selectedTools

    # Pass native arguments to -File, never interpolate them into PowerShell
    # source. Expand the invocation before ending the self-removing batch.
    $batchContent = @'
@echo off
setlocal DisableDelayedExpansion
(goto) 2>nul & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -NoLogo -NoProfile -File "%~dp0sweepr.ps1" %*
'@
    $batchPath = Join-Path $InstallDir "sweepr.cmd"
    Assert-InstallPhysicalPath -Path $batchPath
    Set-Content -LiteralPath $batchPath -Value $batchContent -Encoding ASCII
    Write-Success "Created launcher: sweepr.cmd"
    
    # Also create 'sw' alias
    $moPath = Join-Path $InstallDir "sw.cmd"
    Assert-InstallPhysicalPath -Path $moPath
    Set-Content -LiteralPath $moPath -Value $batchContent -Encoding ASCII
    Write-Success "Created launcher: sw.cmd (short alias)"

    # Add to PATH if requested
    if ($AddToPath) {
        Write-Host ""
        if (-not (Add-ToUserPath -Directory $InstallDir)) {
            return $false
        }
    }

    # Create shortcut if requested
    if ($CreateShortcut) {
        Write-Host ""
        $targetPath = Join-Path $InstallDir "sweepr.ps1"
        if (-not (New-StartMenuShortcut -TargetPath $targetPath -ShortcutName $script:ShortcutName -Description "Windows System Maintenance Toolkit")) {
            return $false
        }
    }

    Write-Host ""
    Write-Success "Sweepr installed successfully!"
    Write-Host ""
    Write-Host "  Location: $InstallDir"
    Write-Host ""

    if ($AddToPath) {
        Write-Host "  Run 'sw' or 'sweepr' from any terminal to start"
    }
    else {
        Write-Host "  Run the following to start:"
        Write-Host "    & `"$InstallDir\sweepr.ps1`""
        Write-Host ""
        Write-Host "  Or add to PATH with:"
        Write-Host "    powershell -ExecutionPolicy Bypass -File .\install.ps1 -AddToPath"
    }

    Write-Host ""
    Write-Host "  Run 'sw update' to pull the latest source from the main branch"
    Write-Host ""
    return $true
}

# ============================================================================
# Uninstall
# ============================================================================

# Top-level entries a Sweepr CLI install can hold: the repository tree, files
# older releases shipped, git metadata and the launchers this script writes.
# Anything else in the folder belongs to someone else and is kept.
function Get-SweeprInstallEntries {
    return @(
        ".editorconfig", ".git", ".gitattributes", ".github", ".gitignore", ".golangci.yml", ".shellcheckrc",
        "CONTRIBUTING.md", "LICENSE", "Makefile", "NOTICE.md", "Projektinhalt.md",
        "README.md", "RELEASE.md", "SECURITY.md", "VERSION",
        "bin", "cmd", "go.mod", "go.sum", "install.ps1", "lib", "sw.cmd", "sw.exe", "sweepr.cmd", "sweepr.ps1",
        "packaging", "quick-install.ps1", "scripts", "tests"
    )
}

# Exact shipped files, not directory names, establish removal scope. Keep
# unknown files in shared folders and Git metadata; prune only empty folders.
function Get-SweeprInstallNestedFiles {
    return @(
        ".github\ISSUE_TEMPLATE\bug_report.md"
        ".github\ISSUE_TEMPLATE\config.yml"
        ".github\ISSUE_TEMPLATE\feature_request.md"
        ".github\dependabot.yml"
        ".github\workflows\check.yml"
        ".github\workflows\release-windows.yml"
        ".github\workflows\test.yml"
        "bin\analyze.exe"
        "bin\analyze.ps1"
        "bin\clean.ps1"
        "bin\features.ps1"
        "bin\history.ps1"
        "bin\inspect.ps1"
        "bin\optimize.ps1"
        "bin\purge.ps1"
        "bin\remove.ps1"
        "bin\status.exe"
        "bin\status.ps1"
        "bin\uninstall.ps1"
        "bin\update.ps1"
        "cmd\analyze\cleanable.go"
        "cmd\analyze\cleanable_test.go"
        "cmd\analyze\cli.go"
        "cmd\analyze\constants.go"
        "cmd\analyze\delete.go"
        "cmd\analyze\directory_browsing_test.go"
        "cmd\analyze\format.go"
        "cmd\analyze\format_test.go"
        "cmd\analyze\heap.go"
        "cmd\analyze\json.go"
        "cmd\analyze\json_test.go"
        "cmd\analyze\lifecycle_test.go"
        "cmd\analyze\live_config.go"
        "cmd\analyze\live_scan.go"
        "cmd\analyze\live_update_test.go"
        "cmd\analyze\main_other.go"
        "cmd\analyze\main_windows.go"
        "cmd\analyze\model.go"
        "cmd\analyze\oplog.go"
        "cmd\analyze\oplog_test.go"
        "cmd\analyze\overview.go"
        "cmd\analyze\platform_other.go"
        "cmd\analyze\platform_windows.go"
        "cmd\analyze\protect_windows.go"
        "cmd\analyze\recycle_guard_windows.go"
        "cmd\analyze\scanner.go"
        "cmd\analyze\update.go"
        "cmd\analyze\view.go"
        "cmd\analyze\view_test.go"
        "cmd\analyze\windows_test.go"
        "cmd\sw\main.go"
        "cmd\sw\main_test.go"
        "cmd\status\battery_windows_test.go"
        "cmd\status\collection.go"
        "cmd\status\diagnosis.go"
        "cmd\status\main.go"
        "cmd\status\main_test.go"
        "cmd\status\metrics.go"
        "cmd\status\metrics_health.go"
        "cmd\status\metrics_health_test.go"
        "cmd\status\metrics_other.go"
        "cmd\status\metrics_test.go"
        "cmd\status\metrics_windows.go"
        "cmd\status\platform_names.go"
        "cmd\status\prefs.go"
        "cmd\status\prefs_lock_other.go"
        "cmd\status\prefs_lock_windows.go"
        "cmd\status\prefs_test.go"
        "cmd\status\process_watch.go"
        "cmd\status\process_watch_test.go"
        "cmd\status\proxy_privacy_test.go"
        "cmd\status\testhelpers_test.go"
        "cmd\status\units.go"
        "cmd\status\usage_test.go"
        "cmd\status\view.go"
        "cmd\status\view_test.go"
        "cmd\status\watch.go"
        "cmd\status\watch_test.go"
        "cmd\status\windows_logic_test.go"
        "docs\development-pitfalls.md"
        "docs\img\logo-wordmark-dark.svg"
        "docs\img\logo-wordmark-light.svg"
        "docs\img\logo.svg"
        "docs\img\social-preview.png"
        "lib\clean\apps.ps1"
        "lib\clean\caches.ps1"
        "lib\clean\cache_guard.ps1"
        "lib\clean\dev.ps1"
        "lib\clean\system.ps1"
        "lib\clean\user.ps1"
        "lib\core\base.ps1"
        "lib\core\common.ps1"
        "lib\core\features.ps1"
        "lib\core\file_ops.ps1"
        "lib\core\history.ps1"
        "lib\core\log.ps1"
        "lib\core\rea.ps1"
        "lib\core\tui_binaries.ps1"
        "lib\core\ui.ps1"
        "lib\core\update_check.ps1"
        "lib\core\version.ps1"
        "packaging\README.md"
        "packaging\scoop\sweepr.json"
        "packaging\winget\brummilab.Sweepr.installer.yaml"
        "packaging\winget\brummilab.Sweepr.locale.en-US.yaml"
        "packaging\winget\brummilab.Sweepr.yaml"
        "scripts\build-msi.ps1"
        "scripts\build-release.ps1"
        "scripts\build.ps1"
        "scripts\gate-pester.ps1"
        "scripts\gate.sh"
        "scripts\e2e_windows.py"
        "scripts\sweepr-installer.wxs"
        "scripts\new-release-zip.ps1"
        "scripts\render-packaging.ps1"
        "scripts\sign-release.ps1"
        "scripts\test.ps1"
        "scripts\write-checksums.ps1"
        "tests\CheckCleanPreview.Tests.ps1"
        "tests\CheckHealth.Tests.ps1"
        "tests\CheckPurgePreview.Tests.ps1"
        "tests\CheckRegression.Tests.ps1"
        "tests\Clean.Tests.ps1"
        "tests\CleanupBoundary.Tests.ps1"
        "tests\CleanupTargets.Tests.ps1"
        "tests\AppCacheSafety.Tests.ps1"
        "tests\Commands.Tests.ps1"
        "tests\Core.Tests.ps1"
        "tests\DataDirProtection.Tests.ps1"
        "tests\DryRun.Tests.ps1"
        "tests\DryRunEnvironment.Tests.ps1"
        "tests\e2e_harness_test.py"
        "tests\Features.Tests.ps1"
        "tests\FeaturesCommand.Tests.ps1"
        "tests\GitProxy.Tests.ps1"
        "tests\History.Tests.ps1"
        "tests\Inspect.Tests.ps1"
        "tests\Install.Tests.ps1"
        "tests\InstallComponents.Tests.ps1"
        "tests\InstallLifecycle.Tests.ps1"
        "tests\linux-known-failures.txt"
        "tests\LiteralPath.Tests.ps1"
        "tests\Optimize.Tests.ps1"
        "tests\Protection.Tests.ps1"
        "tests\Portable.Tests.ps1"
        "tests\PurgeBoundary.Tests.ps1"
        "tests\Recycle.Tests.ps1"
        "tests\Release.Tests.ps1"
        "tests\Router.Tests.ps1"
        "tests\TestRunner.Tests.ps1"
        "tests\UI.Tests.ps1"
        "tests\Uninstall.Tests.ps1"
        "tests\UninstallWait.Tests.ps1"
        "tests\UpdateNotice.Tests.ps1"
    )
}

function Remove-SweeprNestedFiles {
    param([string]$InstallPath, [string]$Root)

    $files = @(Get-SweeprInstallNestedFiles | Where-Object { $_.StartsWith("$Root\", [StringComparison]::OrdinalIgnoreCase) })
    $folders = @($Root)
    Assert-InstallPhysicalPath -Path (Join-Path $InstallPath $Root)
    foreach ($file in $files) {
        $path = Join-Path $InstallPath $file
        Assert-InstallPhysicalPath -Path $path
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        $folder = Split-Path -Parent $file
        while ($folder) {
            if ($folders -notcontains $folder) { $folders += $folder }
            $folder = Split-Path -Parent $folder
        }
    }
    # Deepest first, and only folders left empty.
    foreach ($folder in @($folders | Sort-Object { $_.Length } -Descending)) {
        $path = Join-Path $InstallPath $folder
        if ((Test-Path -LiteralPath $path -PathType Container) -and
            @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Test-SweeprInstallDir {
    param([string]$Path)

    return (Test-Path -LiteralPath (Join-Path $Path "sweepr.ps1")) -and
        (Test-Path -LiteralPath (Join-Path $Path "lib\core\base.ps1"))
}

# Removes one entry of the config folder without following links: a junction or
# symbolic link is unlinked itself, never recursed into, so its target survives.
# Windows PowerShell 5.1's Remove-Item -Recurse deletes a linked directory's
# target contents.
function Remove-SweeprConfigEntry {
    param([System.IO.FileSystemInfo]$Item)

    if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if ($Item.Attributes -band [System.IO.FileAttributes]::Directory) {
            [System.IO.Directory]::Delete($Item.FullName, $false)
        }
        else {
            [System.IO.File]::Delete($Item.FullName)
        }
        return
    }
    if ($Item.Attributes -band [System.IO.FileAttributes]::Directory) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop)) {
            Remove-SweeprConfigEntry -Item $child
        }
        # Never recursive: an entry added since the listing fails the removal
        # instead of Remove-Item offering to delete it.
        if ($Item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $Item.Attributes = $Item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        [System.IO.Directory]::Delete($Item.FullName, $false)
        return
    }
    Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
}

function Uninstall-Sweepr {
    Write-Info "Uninstalling Sweepr..."
    Write-Host ""

    # Without -InstallDir, remove the install this script belongs to. There is
    # no fallback to %LOCALAPPDATA%\Sweepr: that folder is reserved for app
    # data and must never be removed whole.
    $installPath = if ($script:InstallDirGiven) { $InstallDir } else { $script:SourceDir }

    if (-not (Test-Path -LiteralPath $installPath)) {
        Write-SweeprWarning "Sweepr is not installed at $installPath"
        return $true
    }

    # Portable keeps everything in its own folder. Checked inline (the library
    # helper is not loaded here) and before any change to PATH, shortcuts or files.
    if (Test-Path -LiteralPath (Join-Path $installPath 'sweepr.portable') -PathType Leaf) {
        Write-SweeprError "$installPath is a portable copy of Sweepr; nothing was removed. Delete the folder yourself if you no longer need it (your data is in its data folder)."
        return $false
    }

    if (Test-ProtectedInstallRoot -Path $installPath) {
        Write-SweeprError "Refusing to remove protected install directory: $installPath"
        return $false
    }

    if (-not (Test-SweeprInstallDir -Path $installPath)) {
        Write-SweeprError "$installPath is not a Sweepr install (no sweepr.ps1); nothing was removed"
        return $false
    }

    Assert-InstallPhysicalPath -Path $installPath

    # A running native launcher cannot be deleted on Windows. Check before
    # changing PATH, shortcuts or any files, rather than leaving half an install.
    $nativeLauncher = Join-Path $installPath 'sw.exe'
    if (Test-Path -LiteralPath $nativeLauncher) {
        try {
            Assert-InstallPhysicalPath -Path $nativeLauncher
            $handle = [IO.File]::Open($nativeLauncher, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $handle.Dispose()
        }
        catch {
            Write-SweeprError "Cannot remove sw.exe while it is inaccessible or a Sweepr command runs through it, this one included: $nativeLauncher"
            $removeScript = (Join-Path $installPath 'sweepr.ps1').Replace("'", "''")
            Write-Info "Close other Sweepr sessions, then run in PowerShell: & '$removeScript' remove"
            return $false
        }
    }

    # Remove from PATH
    $null = Remove-FromUserPath -Directory $installPath

    # Remove shortcut
    $null = Remove-StartMenuShortcut -InstallDir $installPath

    # Remove only what Sweepr installed; another app may share the folder
    # (for example app data in %LOCALAPPDATA%\Sweepr).
    $known = Get-SweeprInstallEntries
    $nestedRoots = @(Get-SweeprInstallNestedFiles | ForEach-Object { ($_ -split '\\')[0] } | Select-Object -Unique)
    $kept = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $installPath -Force)) {
        if ($entry.Name -eq ".git" -and -not $entry.PSIsContainer) {
            $kept += $entry.Name
            continue
        }
        if ($nestedRoots -contains $entry.Name -or ($entry.PSIsContainer -and $known -contains $entry.Name)) {
            try {
                Remove-SweeprNestedFiles -InstallPath $installPath -Root $entry.Name
            }
            catch {
                Write-SweeprError "Failed to remove $($entry.FullName): $_"
                return $false
            }
            if (Test-Path -LiteralPath $entry.FullName) { $kept += $entry.Name }
            continue
        }
        if ($known -notcontains $entry.Name) {
            $kept += $entry.Name
            continue
        }
        try {
            Assert-InstallPhysicalPath -Path $entry.FullName
            Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
        }
        catch {
            Write-SweeprError "Failed to remove $($entry.FullName): $_"
            return $false
        }
    }

    if ($kept.Count -eq 0) {
        try {
            Remove-Item -LiteralPath $installPath -Force -ErrorAction Stop
            Write-Success "Removed directory: $installPath"
        }
        catch {
            Write-SweeprError "Failed to remove directory: $_"
            return $false
        }
    }
    else {
        Write-Success "Removed Sweepr from: $installPath"
        Write-SweeprWarning "Kept $($kept.Count) item(s) Sweepr did not install: $($kept -join ', ')"
    }

    # With SWEEPR_DATA_DIR set, Sweepr kept its data there and nothing in the profile.
    # That folder belongs to the user, so it is only named, never removed or asked about.
    if (-not [string]::IsNullOrWhiteSpace($env:SWEEPR_DATA_DIR)) {
        Write-Info "Your Sweepr data stays in $($env:SWEEPR_DATA_DIR); delete it yourself if you no longer need it."
    }
    else {
        # The cache folder is Sweepr-owned and rebuildable: downloaded tool
        # binaries and scan caches, never
        # user-authored state. A linked cache root is kept rather than followed.
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $cachePath = Join-Path $env:USERPROFILE ".cache\sweepr"
            if (Test-Path -LiteralPath $cachePath) {
                try {
                    $cacheRoot = Get-Item -LiteralPath $cachePath -Force -ErrorAction Stop
                    if ($cacheRoot.PSIsContainer -and
                        -not ($cacheRoot.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                        Remove-SweeprConfigEntry -Item $cacheRoot
                        if (Get-Command Write-SweeprOperation -ErrorAction SilentlyContinue) {
                            Write-SweeprOperation -Action "REMOVED" -Path $cachePath -Detail "cache"
                        }
                        Write-Success "Removed cache: $cachePath"
                    }
                }
                catch {
                    Write-SweeprWarning "Kept cache: $cachePath ($($_.Exception.Message))"
                }
            }
        }

        # Remove config directory if different from install
        $configDir = Join-Path $env:USERPROFILE ".config\sweepr"
        if (Test-Path $configDir) {
            Write-Info "Found config directory: $configDir"
            $response = Read-Host "  Remove config files? (y/N)"
            if ($response -eq "y" -or $response -eq "Y") {
                # operations.log is the record of what Sweepr removed; support reads it after
                # a report, so it outlives the CLI along with its rotated copy.
                try {
                    # Checking children cannot protect a linked config root or ancestor:
                    # enumeration would already have followed it into another directory.
                    Assert-InstallPhysicalPath -Path $configDir
                    $kept = @()
                    foreach ($item in @(Get-ChildItem -LiteralPath $configDir -Force -ErrorAction Stop)) {
                        Assert-InstallPhysicalPath -Path $configDir
                        if ($item.Name -like 'operations.log*') { $kept += $item.Name; continue }
                        Remove-SweeprConfigEntry -Item $item
                    }
                    if ($kept.Count -eq 0) {
                        Remove-Item -LiteralPath $configDir -Force -ErrorAction Stop
                        Write-Success "Removed config: $configDir"
                    }
                    else {
                        Write-Success "Removed config: $configDir (kept $($kept -join ', '))"
                    }
                }
                catch {
                    Write-SweeprWarning "Failed to remove config: $_"
                }
            }
        }
    }

    Write-Host ""
    Write-Success "Sweepr uninstalled successfully!"
    Write-Host ""
    return $true
}

# ============================================================================
# Main
# ============================================================================

function Main {
    if ($ShowHelp) {
        Show-InstallerHelp
        return
    }

    Show-Banner

    if ($Uninstall) {
        $ok = Uninstall-Sweepr
    }
    else {
        # Decide before anything is copied: a bad name or a cancelled menu
        # must leave the machine untouched.
        $interactive = Test-InstallInteractive -NoPrompt ([bool]$NoPrompt) -Uninstall $false
        # The old updater never meant a component choice, so the variable is ignored for it.
        $envComponents = if ($script:LegacyInvocation) { "" } else { $env:SWEEPR_COMPONENTS }
        try {
            $selection = Get-InstallComponentSelection `
            -Components $Components `
            -EnvComponents $envComponents `
            -AddToPath ([bool]$AddToPath) `
            -CreateShortcut ([bool]$CreateShortcut) `
            -Interactive $interactive
        }
        catch {
            Write-SweeprError "$($_.Exception.Message)"
            exit 2
        }
        if ($null -eq $selection) {
            Write-Host ""
            Write-Info "Installation cancelled. Nothing was installed."
            # 3 = cancelled, so callers can tell it from a failure (1) and bad arguments (2).
            exit 3
        }
        $selection = @($selection)
        $script:AddToPath = [switch]($selection -contains "path")
        $script:CreateShortcut = [switch]($selection -contains "shortcut")
        $script:InstallTools = @($selection | Where-Object { $_ -eq "analyze" -or $_ -eq "status" })
        $ok = Install-Sweepr
    }

    if (-not $ok) {
        exit 1
    }
}

# Run
try {
    Main
}
catch {
    Write-Host ""
    Write-Host "  $($script:Colors.Red)ERROR$($script:Colors.NC) Installation failed: $_"
    Write-Host ""
    exit 1
}
