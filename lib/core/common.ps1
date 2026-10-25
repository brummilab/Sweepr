# Sweepr - Common Functions Library
# Main entry point that loads all core modules

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Prevent multiple sourcing
if ((Get-Variable -Name 'SWEEPR_COMMON_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_COMMON_LOADED) {
    return
}
$script:SWEEPR_COMMON_LOADED = $true

# Get the directory containing this script
$script:SWEEPR_CORE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SWEEPR_LIB_DIR = Split-Path -Parent $script:SWEEPR_CORE_DIR
$script:SWEEPR_ROOT_DIR = Split-Path -Parent $script:SWEEPR_LIB_DIR

# Version helpers are standalone and safe to load before the other core modules.
. "$script:SWEEPR_CORE_DIR\version.ps1"

# ============================================================================
# Load Core Modules
# ============================================================================

# Base definitions (colors, icons, constants)
. "$script:SWEEPR_CORE_DIR\base.ps1"

# Logging functions
. "$script:SWEEPR_CORE_DIR\log.ps1"

# Safe file operations
. "$script:SWEEPR_CORE_DIR\file_ops.ps1"

# UI components
. "$script:SWEEPR_CORE_DIR\ui.ps1"

# ============================================================================
# Version Information
# ============================================================================

$script:SWEEPR_VERSION = Get-SweeprVersionString -RootDir $script:SWEEPR_ROOT_DIR

function Get-SweeprVersion {
    <#
    .SYNOPSIS
        Get Sweepr version information
    #>
    return @{
        Version   = $script:SWEEPR_VERSION
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Windows    = (Get-WindowsVersion).Version
    }
}

# ============================================================================
# Initialization
# ============================================================================

function Initialize-Sweepr {
    <#
    .SYNOPSIS
        Initialize Sweepr environment
    #>

    # Ensure config directory exists
    $configPath = Get-ConfigPath

    # Ensure cache directory exists
    $cachePath = Get-CachePath

    Write-Debug "Sweepr initialized"
    Write-Debug "Config: $configPath"
    Write-Debug "Cache: $cachePath"
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# All functions from base.ps1, log.ps1, file_ops.ps1, and ui.ps1 are
# automatically available when this file is dot-sourced.
