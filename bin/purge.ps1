# Sweepr - Purge Command
# Aggressive cleanup of project build artifacts

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('dry-run')]
    [switch]$DryRun,

    [Alias('d')]
    [switch]$DebugMode,
    
    [Alias('p')]
    [switch]$Paths,
    
    [Alias('h')]
    [switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

# Import core modules
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"
. "$libDir\core\file_ops.ps1"
. "$libDir\clean\projects.ps1"

# ============================================================================
# Configuration
# ============================================================================

$script:ConfigFile = Join-Path $script:Config.ConfigPath 'purge_paths.txt'

$script:TotalSizeCleaned = 0
$script:ItemsCleaned = 0

# ============================================================================
# Help
# ============================================================================

function Show-PurgeHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mfm purge$esc[0m - Clean project build artifacts"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m sw purge [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --dry-run    Show what would be removed, change nothing"
    Write-Host "  --paths      Edit custom scan directories"
    Write-Host "  --debug      Enable debug logging"
    Write-Host "  --help       Show this help message"
    Write-Host ""
    Write-Host "$esc[33mDefault Search Paths:$esc[0m"
    foreach ($path in $script:DefaultSearchPaths) {
        if (Test-Path -LiteralPath $path) {
            Write-Host "  $esc[32m+$esc[0m $path"
        }
        else {
            Write-Host "  $esc[90m-$esc[0m $path (not found)"
        }
    }
    Write-Host ""
    Write-Host "$esc[33mArtifacts Cleaned:$esc[0m"
    Write-Host "  node_modules, vendor, venv, target, build, dist, __pycache__, etc."
    Write-Host ""
}

# ============================================================================
# Path Management
# ============================================================================

function Get-SearchPaths {
    <#
    .SYNOPSIS
        Get list of paths to scan for projects
    #>

    $paths = @()

    # Load custom paths if available
    if (Test-Path -LiteralPath $script:ConfigFile) {
        $customPaths = Get-Content -LiteralPath $script:ConfigFile -ErrorAction SilentlyContinue |
                       Where-Object { $_ -and -not $_.StartsWith('#') } |
                       ForEach-Object { $_.Trim() }

        foreach ($path in $customPaths) {
            if (Test-Path -LiteralPath $path) {
                $paths += $path
            }
        }
    }

    # Add default paths if no custom paths or custom paths don't exist
    if ($null -eq $paths -or @($paths).Count -eq 0) {
        foreach ($path in $script:DefaultSearchPaths) {
            if (Test-Path -LiteralPath $path) {
                $paths += $path
            }
        }
    }

    return $paths
}

function Edit-SearchPaths {
    <#
    .SYNOPSIS
        Open search paths configuration for editing
    #>

    $configDir = Split-Path -Parent $script:ConfigFile

    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
        $defaultContent = @"
# Sweepr Purge - Custom Search Paths
# Add directories to scan for project artifacts (one per line)
# Lines starting with # are ignored
#
# Examples:
# D:\MyProjects
# E:\Work\Code
#
# Default paths (used if this file is empty):
# $env:USERPROFILE\Documents
# $env:USERPROFILE\Projects
# $env:USERPROFILE\Code

"@
        Set-Content -LiteralPath $script:ConfigFile -Value $defaultContent
    }

    Write-Info "Opening paths configuration: $($script:ConfigFile)"
    Start-Process notepad.exe -ArgumentList ('"{0}"' -f $script:ConfigFile) -Wait

    Write-Success "Configuration saved"
}

# ============================================================================
# Project Selection UI
# ============================================================================

function Show-ProjectSelectionMenu {
    <#
    .SYNOPSIS
        Interactive menu for selecting projects to clean
    #>
    param([array]$Projects)

    $projectCount = if ($null -eq $Projects) { 0 } else { @($Projects).Count }
    if ($projectCount -eq 0) {
        Write-SweeprWarning "No projects with cleanable artifacts found"
        return @()
    }

    $esc = [char]27
    $selectedIndices = @{}
    $currentIndex = 0
    $pageSize = 12
    $pageStart = 0

    try { [Console]::CursorVisible = $false } catch { }

    try {
        while ($true) {
            Clear-Host

            # Header
            Write-Host ""
            Write-Host "$esc[1;35mSelect Projects to Clean$esc[0m"
            Write-Host ""
            Write-Host "$esc[90mUse: $($script:Icons.NavUp)$($script:Icons.NavDown) navigate | Space select | A select all | Enter confirm | Q quit$esc[0m"
            Write-Host ""

            # Display projects
            $pageEnd = [Math]::Min($pageStart + $pageSize, $projectCount)

            for ($i = $pageStart; $i -lt $pageEnd; $i++) {
                $project = $Projects[$i]
                $isSelected = $selectedIndices.ContainsKey($i)
                $isCurrent = ($i -eq $currentIndex)

                $checkbox = if ($isSelected) { "$esc[32m[$($script:Icons.Success)]$esc[0m" } else { "[ ]" }

                if ($isCurrent) {
                    Write-Host "$esc[7m" -NoNewline
                }

                $artifactCount = if ($null -eq $project.Artifacts) { 0 } else { @($project.Artifacts).Count }
                $entry = Format-SizeListEntry -Name $project.DisplayPath -Size $project.TotalSizeHuman -Suffix " ($artifactCount $(if ($artifactCount -eq 1) { 'item' } else { 'items' }))" -NameWidth 60 -KeepEnd
                Write-Host "  $checkbox $entry" -NoNewline

                if ($isCurrent) {
                    Write-Host "$esc[0m"
                }
                else {
                    Write-Host ""
                }
            }

            # Footer
            Write-Host ""
            $selectedCount = $selectedIndices.Count
            if ($selectedCount -gt 0) {
                $totalSize = 0
                foreach ($idx in $selectedIndices.Keys) {
                    $totalSize += $Projects[$idx].TotalSizeKB
                }
                $totalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)
                $noun = if ($selectedCount -eq 1) { 'project' } else { 'projects' }
                Write-Host "$esc[33mSelected:$esc[0m $selectedCount $noun ($totalSizeHuman)"
            }

            # Page indicator
            $totalPages = [Math]::Ceiling($projectCount / $pageSize)
            $currentPage = [Math]::Floor($pageStart / $pageSize) + 1
            Write-Host "$esc[90mPage $currentPage of $totalPages | Total: $projectCount $(if ($projectCount -eq 1) { 'project' } else { 'projects' })$esc[0m"

            # Handle input
            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow' {
                    if ($currentIndex -gt 0) {
                        $currentIndex--
                        if ($currentIndex -lt $pageStart) {
                            $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                        }
                    }
                }
                'DownArrow' {
                    if ($currentIndex -lt $projectCount - 1) {
                        $currentIndex++
                        if ($currentIndex -ge $pageStart + $pageSize) {
                            $pageStart += $pageSize
                        }
                    }
                }
                'PageUp' {
                    $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                    $currentIndex = $pageStart
                }
                'PageDown' {
                    $pageStart = [Math]::Min($projectCount - $pageSize, $pageStart + $pageSize)
                    if ($pageStart -lt 0) { $pageStart = 0 }
                    $currentIndex = $pageStart
                }
                'Spacebar' {
                    if ($selectedIndices.ContainsKey($currentIndex)) {
                        $selectedIndices.Remove($currentIndex)
                    }
                    else {
                        $selectedIndices[$currentIndex] = $true
                    }
                }
                'A' {
                    # Select/deselect all
                    if ($selectedIndices.Count -eq $projectCount) {
                        $selectedIndices.Clear()
                    }
                    else {
                        for ($i = 0; $i -lt $projectCount; $i++) {
                            $selectedIndices[$i] = $true
                        }
                    }
                }
                'Enter' {
                    if ($selectedIndices.Count -gt 0) {
                        $selected = @()
                        foreach ($idx in $selectedIndices.Keys) {
                            $selected += $Projects[$idx]
                        }
                        return $selected
                    }
                }
                'Escape' { return @() }
                'Q' { return @() }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

# ============================================================================
# Cleanup
# ============================================================================

function Remove-ProjectArtifacts {
    <#
    .SYNOPSIS
        Remove artifacts from selected projects
    #>
    param([array]$Projects)

    $esc = [char]27

    Write-Host ""
    Write-Host "$esc[1;35mCleaning Project Artifacts$esc[0m"
    Write-Host ""

    foreach ($project in $Projects) {
        Write-Host "$esc[34m$($script:Icons.Arrow)$esc[0m $(Get-PurgeDisplayPath $project.Path)"

        foreach ($artifact in $project.Artifacts) {
            if (Test-Path -LiteralPath $artifact.Path) {
                if (-not (Test-SweeprPathSnapshot $artifact.Snapshot) -or
                    -not (Test-PurgeArtifactContent $project.Path $artifact.Path)) { continue }
                $projectPath = $project.Path
                $previewSnapshot = $artifact.Snapshot
                $guard = {
                    param($candidate)
                    return (Test-SweeprPathSnapshot $previewSnapshot) -and
                        (Test-PurgeArtifactContent $projectPath $candidate)
                }
                # Remove-SafeItem prints the result row and adds the size to
                # $script:TotalSizeCleaned; counting it here as well doubled it.
                $success = Remove-SafeItem -Path $artifact.Path -Description $artifact.Name -Recurse -Guard $guard

                if ($success) {
                    $script:ItemsCleaned++
                }
                else {
                    Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m $($artifact.Name) - removal failed"
                }
            }
        }
    }
}

# ============================================================================
# Summary
# ============================================================================

function Show-PurgeSummary {
    $heading = if ($script:SweeprDryRunMode) { 'Dry run complete - no changes made' } else { 'Purge complete' }
    $details = @()
    if ($script:TotalSizeCleaned -gt 0) {
        $size = Format-ByteSize -Bytes ($script:TotalSizeCleaned * 1024)
        $label = if ($script:SweeprDryRunMode) { 'Potential space' } else { 'Tracked cleanup' }
        $details += "${label}: $(Get-SweeprColor -Name Green)$size$(Get-SweeprColor -Name NC) | Items: $($script:ItemsCleaned)"
    }
    else { $details += 'No artifacts to clean.' }
    $details += "Free space: $(Get-FreeSpace)"
    Show-SummaryBlock -Heading $heading -Details $details
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Main {
    # Enable debug if requested
    if ($DebugMode) {
        Enable-DebugMode
        $DebugPreference = "Continue"
    }

    # Show help
    if ($ShowHelp) {
        Show-PurgeHelp
        return
    }

    # Edit paths
    if ($Paths) {
        Edit-SearchPaths
        return
    }

    if ($DryRun) {
        $env:SWEEPR_DRY_RUN = "1"
        Set-DryRunMode -Enabled $true
    }

    # Clear screen
    Clear-Host

    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mPurge Project Artifacts$esc[0m"
    Write-Host ""

    # Get search paths
    $searchPaths = @(Get-SearchPaths)

    if ($null -eq $searchPaths -or $searchPaths.Count -eq 0) {
        Write-SweeprWarning "No valid search paths found"
        Write-Host "Run 'sw purge --paths' to configure search directories"
        return
    }

    Write-Info "Searching in $($searchPaths.Count) directories..."

    # Find projects
    $projects = @(Find-Projects -SearchPaths $searchPaths)

    if ($null -eq $projects -or $projects.Count -eq 0) {
        Write-Host ""
        Write-Host "$esc[32m$($script:Icons.Success)$esc[0m No cleanable artifacts found"
        Write-Host ""
        return
    }

    $totalSize = ($projects | Measure-Object -Property TotalSizeKB -Sum).Sum
    if ($null -eq $totalSize) { $totalSize = 0 }
    $totalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)

    Write-Host ""
    Write-Host "Found $esc[33m$($projects.Count)$esc[0m projects with $esc[33m$totalSizeHuman$esc[0m of artifacts"
    Write-Host ""

    # Project selection
    $selected = @(Show-ProjectSelectionMenu -Projects $projects)

    if ($null -eq $selected -or $selected.Count -eq 0) {
        Write-Info "No projects selected"
        return
    }

    # Confirm
    Clear-Host
    Write-Host ""
    $selectedSize = ($selected | Measure-Object -Property TotalSizeKB -Sum).Sum
    if ($null -eq $selectedSize) { $selectedSize = 0 }
    $selectedSizeHuman = Format-ByteSize -Bytes ($selectedSize * 1024)

    Write-Host "$esc[33mThe following will be cleaned ($selectedSizeHuman):$esc[0m"
    Write-Host ""

    foreach ($project in $selected) {
        Write-Host "  $($script:Icons.List) $($project.DisplayPath) ($($project.TotalSizeHuman))"
        foreach ($artifact in $project.Artifacts) {
            Write-Host "      $esc[90m$($artifact.Name) - $($artifact.SizeHuman)$esc[0m"
        }
    }

    Write-Host ""
    # A dry run only reports, so it needs no confirmation.
    if ($script:SweeprDryRunMode) {
        Remove-ProjectArtifacts -Projects $selected
        Show-PurgeSummary
        return
    }
    $confirm = Read-Host "Continue? (y/N)"

    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Remove-ProjectArtifacts -Projects $selected
        Show-PurgeSummary
    }
    else {
        Write-Info "Cancelled"
    }
}

# Run main
try { Main } finally { Stop-Spinner }
